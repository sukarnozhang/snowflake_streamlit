import streamlit as st
import json
from snowflake.snowpark.context import get_active_session

session = get_active_session()

st.set_page_config(page_title="Drug Discovery Search", page_icon="💊", layout="wide")
st.title("💊 Drug Discovery — Research Paper Search")
st.caption("Powered by Snowflake Cortex Search · AI_PARSE_DOCUMENT · LLM Branch")

with st.sidebar:
    st.header("Search Settings")
    top_k = st.slider("Results to return", min_value=1, max_value=20, value=5)
    show_raw = st.checkbox("Show raw JSON response", value=False)
    st.divider()
    st.subheader("Filter by paper (optional)")
    papers_df = session.sql(
        "SELECT DISTINCT file_name FROM chunked_docs ORDER BY file_name"
    ).to_pandas()
    paper_options = ["All papers"] + papers_df["FILE_NAME"].tolist()
    selected_paper = st.selectbox("Paper", paper_options)

query = st.text_input(
    "🔍 Ask a research question",
    placeholder="e.g. What are the IC50 values reported for compound X?"
)

if query:
    filter_clause = ""
    if selected_paper != "All papers":
        filter_clause = f', "filter": {{"@eq": {{"file_name": "{selected_paper}"}}}}'

    search_query = f"""
    SELECT PARSE_JSON(
      SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'drug_discovery_search',
        '{{"query": "{query.replace("'", "''")}", "columns": ["file_name", "chunk_index", "chunk_text"], "limit": {top_k}{filter_clause}}}'
      )
    )['results'] AS results
    """

    with st.spinner("Searching research papers..."):
        result_df = session.sql(search_query).to_pandas()
        results = json.loads(result_df["RESULTS"].iloc[0])

    if not results:
        st.warning("No results found. Try a different query.")
    else:
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
st.caption("Stream 1 · LLM Branch · Snowflake Cortex")