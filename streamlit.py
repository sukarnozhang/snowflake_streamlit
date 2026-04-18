import streamlit as st
import json
from snowflake.snowpark.context import get_active_session

session = get_active_session()

st.set_page_config(page_title="Cardiology Specialist Agent", page_icon="🫀", layout="wide")
st.title("🫀 Cardiology Specialist Agent")
st.caption("Powered by Snowflake Cortex Search · AI_PARSE_DOCUMENT · LLM Branch")

with st.sidebar:
    st.header("Search Settings")
    top_k = st.slider("Results to return", min_value=1, max_value=20, value=5)
    show_raw = st.checkbox("Show raw JSON response", value=False)

    # ── LLM toggle ──────────────────────────────────────────────
    st.divider()
    st.subheader("AI Answer Settings")
    enable_llm = st.checkbox("Generate AI answer from results", value=True)
    llm_model = st.selectbox(
        "LLM Model",
        ["mistral-large", "mistral-large2", "llama3-70b", "snowflake-arctic"],
        index=0
    )
    # ────────────────────────────────────────────────────────────

    st.divider()
    st.subheader("Filter by paper (optional)")
    papers_df = session.sql(
        "SELECT DISTINCT file_name FROM chunked_docs ORDER BY file_name"
    ).to_pandas()
    paper_options = ["All papers"] + papers_df["FILE_NAME"].tolist()
    selected_paper = st.selectbox("Paper", paper_options)

query = st.text_input(
    "🔍 Ask a cardiology research question",
    placeholder="e.g. What are the treatment guidelines for atrial fibrillation?"
)

if query:
    filter_clause = ""
    if selected_paper != "All papers":
        filter_clause = f', "filter": {{"@eq": {{"file_name": "{selected_paper}"}}}}'

    search_query = f"""
    SELECT PARSE_JSON(
      SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'cardiology_search',
        '{{"query": "{query.replace("'", "''")}", "columns": ["file_name", "chunk_index", "chunk_text"], "limit": {top_k}{filter_clause}}}'
      )
    )['results'] AS results
    """

    with st.spinner("Searching cardiology research papers..."):
        result_df = session.sql(search_query).to_pandas()
        results = json.loads(result_df["RESULTS"].iloc[0])

    if not results:
        st.warning("No results found. Try a different query.")
    else:
        # ── RAG: Generate AI answer from retrieved chunks ────────
        if enable_llm:
            context = "\n\n".join([r.get("chunk_text", "") for r in results])
            safe_query  = query.replace("'", "''")
            safe_context = context[:3000].replace("'", "''").replace("\\", "\\\\")

            llm_sql = f"""
            SELECT SNOWFLAKE.CORTEX.COMPLETE(
                '{llm_model}',
                'You are a cardiology research assistant. Answer the question below using ONLY the context provided. If the context does not contain enough information, say so clearly.

Question: {safe_query}

Context:
{safe_context}

Answer concisely and cite which paper the information came from where possible.'
            ) AS answer
            """

            with st.spinner(f"Generating answer with {llm_model}..."):
                llm_df = session.sql(llm_sql).to_pandas()
                ai_answer = llm_df["ANSWER"].iloc[0]

            st.subheader("🤖 AI Answer")
            st.info(ai_answer)
            st.divider()
        # ────────────────────────────────────────────────────────

        st.success(f"Found **{len(results)}** relevant chunk(s)")
        for i, r in enumerate(results, 1):
            with st.expander(
                f"📄 {r.get('file_name', 'Unknown')}  ·  chunk {r.get('chunk_index', '?')}",
                expanded=(i == 1)
            ):
                st.markdown(r.get("chunk_text", ""))

        if show_raw:
            st.divider()
            st.subheader("Raw JSON")
            st.json(results)

st.divider()
st.caption("Cardiology Specialist Agent · Snowflake Cortex Search · RAG Pipeline")