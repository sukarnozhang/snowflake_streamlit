import json
import os
import importlib
import snowflake.connector
from ragas import evaluate
from ragas.metrics import Faithfulness, AnswerRelevancy, ContextRecall, ContextPrecision
from ragas.llms import LangchainLLMWrapper
from datasets import Dataset
from langchain_anthropic import ChatAnthropic
from ragas.embeddings import LangchainEmbeddingsWrapper
from langchain_huggingface import HuggingFaceEmbeddings

embeddings = LangchainEmbeddingsWrapper(
    HuggingFaceEmbeddings(model_name="sentence-transformers/all-MiniLM-L6-v2")
)

import config
importlib.reload(config)
ANTHROPIC_API_KEY = config.ANTHROPIC_API_KEY

print("ANTHROPIC_API_KEY loaded")

llm = LangchainLLMWrapper(
    ChatAnthropic(
        model="claude-haiku-4-5-20251001",
        api_key=config.ANTHROPIC_API_KEY
    )
)

# ── Snowflake connection ──────────────────────────────────────
conn = snowflake.connector.connect(**config.SNOWFLAKE)
cursor = conn.cursor()

# ── Test cases ────────────────────────────────────────────────
test_cases = [
    {
        "question": "What anticoagulation is recommended for atrial fibrillation stroke prevention?",
        "ground_truth": (
            "DOACs (apixaban, rivaroxaban, edoxaban, dabigatran) are preferred over warfarin "
            "for stroke prevention in non-valvular AF due to better safety and efficacy profiles."
        ),
    },
    {
        "question": "What are first-line pharmacological treatments for hypertension?",
        "ground_truth": (
            "First-line agents include ACE inhibitors, ARBs, calcium channel blockers, "
            "and thiazide or thiazide-like diuretics, chosen based on patient comorbidities."
        ),
    },
    {
        "question": "What is the quadruple therapy for HFrEF management?",
        "ground_truth": (
            "Guideline-directed medical therapy for HFrEF consists of four drug classes: "
            "ACE inhibitor or ARNI (sacubitril/valsartan), beta-blocker, MRA, and SGLT2 inhibitor."
        ),
    },
    {
        "question": "How should heart failure be managed in patients with type 2 diabetes?",
        "ground_truth": (
            "SGLT2 inhibitors are recommended in patients with T2D and HF to reduce "
            "hospitalisation and cardiovascular death, regardless of ejection fraction."
        ),
    },
    {
        "question": "What is the Lancet Commission main argument about rethinking coronary artery disease?",
        "ground_truth": (
            "The commission argues CAD should be reframed from an ischaemia-centred model "
            "to an atheroma-centred model, emphasising plaque stabilisation and lipid control "
            "over revascularisation for stable disease."
        ),
    },
    {
        "question": "Should GDMT be continued in patients with heart failure with improved ejection fraction?",
        "ground_truth": (
            "Yes — withdrawing GDMT in HFimpEF is associated with relapse; guidelines recommend "
            "continuing therapy indefinitely even after EF normalises."
        ),
    },
]

# ── Run pipeline ──────────────────────────────────────────────
results = []

for case in test_cases:
    question = case["question"]
    print(f"\n🔍 Running: {question[:60]}...")

    # Step 1: Retrieve chunks from Cortex Search
    search_payload = json.dumps({
        "query": question,
        "columns": ["file_name", "chunk_index", "chunk_text"],
        "limit": 5
    })
    try:
        cursor.execute(
            "SELECT PARSE_JSON(SNOWFLAKE.CORTEX.SEARCH_PREVIEW('cardiology_search', %s))['results'] AS results",
            (search_payload,)
        )
        row = cursor.fetchone()
        chunks = json.loads(row[0]) if row and row[0] else []
    except Exception as e:
        print(f"  ⚠️  Search failed: {e}")
        chunks = []

    contexts = [c.get("chunk_text", "") for c in chunks]
    context_str = "\n\n".join(contexts)[:3000]

    # Step 2: Generate answer via Cortex COMPLETE
    prompt = (
        "You are a cardiology research assistant. "
        "Answer using ONLY the context provided. "
        "If the context lacks sufficient information, say so explicitly. "
        "Cite the source paper where possible.\n\n"
        f"Question: {question}\n\n"
        f"Context:\n{context_str}\n\n"
        "Answer concisely."
    )
    try:
        cursor.execute(
            "SELECT SNOWFLAKE.CORTEX.COMPLETE('mistral-large', %s) AS answer",
            (prompt,)
        )
        ai_answer = cursor.fetchone()[0]
    except Exception as e:
        print(f"  ⚠️  LLM call failed: {e}")
        ai_answer = "Error generating answer."

    results.append({
        "question": question,
        "answer": ai_answer,
        "contexts": contexts,
        "ground_truth": case["ground_truth"],
    })
    print(f"  ✅ Done — {len(contexts)} chunks retrieved")

# ── Evaluate with RAGAS ───────────────────────────────────────
print("\n📊 Running RAGAS evaluation...")
dataset = Dataset.from_list(results)

scores = evaluate(
    dataset,
    metrics=[
        Faithfulness(llm=llm),
        AnswerRelevancy(llm=llm, embeddings=embeddings),
        ContextRecall(llm=llm),
        ContextPrecision(llm=llm),
    ],
)

print("\n── RAGAS Scores ──────────────────────────────")
print(scores)

# ── Save results ──────────────────────────────────────────────
output = {
    "scores": scores.to_pandas().to_dict(orient="records"),
    "per_question": results,
}
with open("eval_results.json", "w") as f:
    json.dump(output, f, indent=2)

print("\n💾 Results saved to eval_results.json")

cursor.close()
conn.close()