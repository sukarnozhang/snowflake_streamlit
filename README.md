markdown# 🫀 Clinical Decision Support — Cardiology Specialist Agent

> **Phase 1 of a multi-agent clinical AI system** — a RAG pipeline enabling clinicians to semantically search cardiology research papers and clinical guidelines using Snowflake Cortex.

---

## 🧠 Project Vision

This project is being built toward a **multi-agent clinical decision support system**, where specialist AI agents (cardiology, nephrology, oncology, etc.) are orchestrated by a **geriatrician master agent** — routing complex, multi-morbidity clinical questions to the right specialists and synthesising their responses.

**Current status: Phase 1 — Cardiology Specialist Agent (complete)**

The cardiology agent is a fully functional RAG pipeline built natively on Snowflake Cortex, serving as the foundation for the broader multi-agent architecture. Phases 2–5 are planned and tracked in the roadmap below.

---

## 🏗️ Architecture
Azure Blob Storage (@PAPER_FROM_BLOB2 — external stage)
↓
Landing Table (file registry) — manually triggered
↓
COPY FILES → @SERVER_ENCRYPT (internal stage)
↓
AI_PARSE_DOCUMENT — layout-aware PDF parsing (Cortex)
↓
Recursive Text Chunking (512 tokens, 50 token overlap)
↓
Cortex Search Service (semantic vector search)
↓
CORTEX.COMPLETE — LLM synthesis (mistral-large)
↓
Streamlit UI (query interface hosted on Snowflake)

> Note: Snowpipe auto-ingestion via Azure Event Grid is planned for Phase 2. The current pipeline is triggered manually.

---

## 🔬 What It Does

- **Ingests** cardiology research papers and clinical guidelines from Azure Blob Storage
- **Parses** PDFs using Snowflake Cortex `AI_PARSE_DOCUMENT` with layout-aware extraction — preserving tables, headings, and multi-column structure critical in medical literature
- **Chunks** documents using `SPLIT_TEXT_RECURSIVE_CHARACTER` (512 tokens, 50 token overlap) with noise filtering to remove bibliography and figure caption chunks
- **Indexes** chunks into a Cortex Search Service for semantic retrieval using vector embeddings
- **Generates** answers using `CORTEX.COMPLETE` (mistral-large) grounded strictly on retrieved chunks — minimising hallucination risk in a clinical context
- **Serves** a Streamlit interface where clinicians can query across papers with paper-level filtering and model selection
- **Evaluates** retrieval and generation quality using RAGAS across faithfulness, answer relevancy, context recall, and context precision

---

## 🛠️ Tech Stack

| Layer | Technology |
|---|---|
| Cloud Storage | Azure Blob Storage |
| Data Platform | Snowflake |
| PDF Parsing | Snowflake Cortex `AI_PARSE_DOCUMENT` (LAYOUT mode) |
| LLM Synthesis | Snowflake Cortex `COMPLETE` (mistral-large) |
| Vector Search | Snowflake Cortex Search Service |
| Pipeline Automation | Snowflake Streams + Tasks |
| Evaluation | RAGAS + Claude Haiku + sentence-transformers |
| Frontend | Streamlit (hosted natively on Snowflake) |
| Version Control | GitHub |

---

## 📁 Repository Structure
├── pipeline.sql              # End-to-end pipeline: ingestion → parsing → chunking → search service
├── streamlit_app.py          # Streamlit query interface with paper filtering, model selection, and LLM synthesis
├── requirements.txt          # Python dependencies for local development
├── config.example.py         # Example credentials file — copy to config.py and fill in values
├── evaluation/
│   └── ragas_eval.py         # RAGAS evaluation: faithfulness, answer relevancy, context precision/recall
└── README.md

---

## 🚀 How to Run

### Prerequisites
- Snowflake account with Cortex enabled
- Azure Blob Storage containing cardiology PDFs
- External stage (`@PAPER_FROM_BLOB2`) configured pointing to Azure Blob container
- Internal stage (`@SERVER_ENCRYPT`) for AI_PARSE_DOCUMENT (required — Cortex only supports internal stages)

### Local setup (evaluation script)

1. Clone the repo and install dependencies:
```bash
pip install -r requirements.txt
```

2. Copy the example config and fill in your credentials:
```bash
cp config.example.py config.py
```

3. Run the evaluation:
```bash
python evaluation/ragas_eval.py
```

### Snowflake pipeline setup

1. **Refresh the external stage directory** to detect all files:
```sql
ALTER STAGE PAPER_FROM_BLOB2 REFRESH;
```

2. **Run `pipeline.sql` sequentially** in a Snowflake worksheet — covers ingestion, parsing, chunking, and search service creation

3. **Upload Streamlit app** to your internal stage:
```sql
PUT file://./streamlit_app.py @SERVER_ENCRYPT/streamlit/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
```

4. **Create and launch the Streamlit app** in Snowsight:
```sql
CREATE OR REPLACE STREAMLIT SNOWFLAKE_LEARNING_DB.PUBLIC.cardiology_app
    ROOT_LOCATION = '@SNOWFLAKE_LEARNING_DB.PUBLIC.SERVER_ENCRYPT/streamlit'
    MAIN_FILE = 'streamlit_app.py'
    QUERY_WAREHOUSE = COMPUTE_WH;
```

---

## 💡 Architectural Decisions

**Why Snowflake Cortex over LangChain/external vector DB?**
Data was already flowing into Snowflake, making a native Cortex implementation the most governed approach — no external vector database, no additional infrastructure, and full data lineage within the Snowflake ecosystem. In a regulated clinical environment, data residency and governance matter.

**Why `AI_PARSE_DOCUMENT` with LAYOUT mode?**
Medical literature has complex structure — multi-column layouts, tables with numerical results, and figure captions. Raw text extraction scrambles this. LAYOUT mode preserves the logical reading order and table structure, which directly improves chunk quality and retrieval accuracy.

**Why recursive character chunking with noise filtering?**
Medical literature contains bibliography sections, figure captions, and header-only chunks that carry keywords but no clinical content. A `LEN > 150` filter removes these noise chunks, improving context precision during retrieval. 512 token chunks with 50 token overlap balances semantic completeness with retrieval precision.

**Why a geriatrician as master agent?**
Geriatricians specialise in multi-morbidity — patients with overlapping conditions across cardiology, nephrology, pharmacology, and more. This makes the geriatrician a clinically accurate orchestration metaphor: routing complex multi-system questions to specialist agents and synthesising their responses mirrors real clinical workflow, not just a technical convenience.

---

## 📊 Evaluation

RAG pipeline evaluated using RAGAS across four metrics:

| Metric | Description |
|---|---|
| Faithfulness | Did the LLM answer stay grounded in retrieved chunks? |
| Answer Relevancy | Did the answer address the question asked? |
| Context Recall | Did retrieved chunks contain the relevant information? |
| Context Precision | Were retrieved chunks relevant or mostly noise? |

**Results on 6 cardiology test questions (generated by running `ragas_eval.py`):**

| Question | Faithfulness | Answer Relevancy | Context Recall | Context Precision |
|---|---|---|---|---|
| AF anticoagulation | 1.00 | 0.93 | 0.00 | 0.95 |
| Hypertension first line | 1.00 | 0.99 | 1.00 | 0.80 |
| HFrEF quadruple therapy | 1.00 | 0.91 | 1.00 | 0.50 |
| HF management in T2D | 1.00 | 0.94 | 0.00 | 0.42 |
| Lancet Commission — CAD rethink | 1.00 | 0.97 | 0.00 | 0.25 |
| GDMT in HFimpEF | 0.83 | 0.00 | 1.00 | 0.89 |

**Observations:**

- Faithfulness is strong across all questions — the LLM stays grounded in retrieved chunks and does not hallucinate
- Context recall is 0.00 for three questions, meaning the retrieval pipeline is missing chunks that contain the ground truth answer — the papers covering those topics may not be in the index, or chunking is splitting relevant content across boundaries
- Answer relevancy dropped to 0.00 for the GDMT question — the model produced a nuanced hedged answer that RAGAS penalised for not directly addressing the yes/no framing of the question
- Context precision is weakest for the Lancet Commission question (0.25), suggesting retrieved chunks contain a lot of loosely related content alongside the relevant material

**Known limitation:** Context recall of 0.00 on three questions reflects gaps in the current paper corpus rather than a retrieval algorithm failure. Expanding the indexed document set is a Phase 2 priority.

---

## 🗺️ Roadmap — Multi-Agent System

| Phase | Description | Status |
|---|---|---|
| Phase 1 | Cardiology Specialist Agent (RAG pipeline) | ✅ Complete |
| Phase 2 | Snowpipe + Azure Event Grid auto-ingestion (full pipeline automation) | 🔄 Planned |
| Phase 3 | Additional specialist agents (nephrology, pharmacology) | 🔄 Planned |
| Phase 4 | Geriatrician Master Agent — routes multi-morbidity queries to specialists and synthesises responses | 🔄 Planned |
| Phase 5 | Production evaluation framework with RAGAS and automated regression testing | 🔄 Planned |