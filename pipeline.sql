-- ============================================
-- CARDIOLOGY SPECIALIST AGENT
-- RAG Pipeline on Snowflake Cortex
-- ============================================

-- 0. Check existing stages (to make sure STAGE PAPER_FROM_BLOB2 exists. It's used to keep pdf from Azure)
SHOW STAGES IN DATABASE SNOWFLAKE_LEARNING_DB;

-- 1. Verify PDFs have landed into internal stage (PAPER_FROM_BLOB2)
LIST @PAPER_FROM_BLOB2;


-- ============================================
-- INGESTION
-- ============================================

-- 3. Create landing table
CREATE OR REPLACE TABLE SNOWFLAKE_LEARNING_DB.PUBLIC.landing_table (
    file_name STRING,
    stage_path STRING,
    ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- 4. Load files from Azure Blob into landing table
TRUNCATE TABLE SNOWFLAKE_LEARNING_DB.PUBLIC.landing_table;

INSERT INTO SNOWFLAKE_LEARNING_DB.PUBLIC.landing_table (file_name, stage_path)
SELECT
    RELATIVE_PATH,
    '@PAPER_FROM_BLOB2/' || RELATIVE_PATH
FROM DIRECTORY(@PAPER_FROM_BLOB2);

-- 5. Verify landing table
SELECT * FROM SNOWFLAKE_LEARNING_DB.PUBLIC.landing_table LIMIT 10;
SELECT COUNT(*) FROM SNOWFLAKE_LEARNING_DB.PUBLIC.landing_table;

-- ============================================
-- STREAMING
-- ============================================

-- 6. Create stream on landing table (append-only for new file detection)
-- Stream created to support future Snowpipe auto-ingestion
-- Currently pipeline is triggered manually
-- When Snowpipe is configured, new PDFs will be processed automatically
CREATE OR REPLACE STREAM SNOWFLAKE_LEARNING_DB.PUBLIC.llm_stream
    ON TABLE SNOWFLAKE_LEARNING_DB.PUBLIC.landing_table
    APPEND_ONLY = TRUE;

-- 7. Wake up stream
-- uncomment this when azure trigger has been configured
--INSERT INTO SNOWFLAKE_LEARNING_DB.PUBLIC.landing_table (file_name, stage_path)
--SELECT file_name, stage_path
--FROM SNOWFLAKE_LEARNING_DB.PUBLIC.landing_table;

-- 8. Verify stream has data
SELECT SYSTEM$STREAM_HAS_DATA('llm_stream');

-- ============================================
-- PARSING
-- ============================================

-- 9. Create parsed docs table
CREATE OR REPLACE TABLE SNOWFLAKE_LEARNING_DB.PUBLIC.parsed_docs (
    file_name STRING,
    stage_path STRING,
    markdown_text VARIANT,
    parsed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- 9.5. Copy PDFs from external Azure stage to internal stage
--      Required because AI_PARSE_DOCUMENT only works with internal stages
COPY FILES
    INTO @SERVER_ENCRYPT
    FROM @PAPER_FROM_BLOB2;

-- 10. Parse PDFs using AI_PARSE_DOCUMENT
-- NOTE: AI_PARSE_DOCUMENT requires an internal stage
--       Files are copied from external Azure stage to SERVER_ENCRYPT (internal) first
INSERT INTO SNOWFLAKE_LEARNING_DB.PUBLIC.parsed_docs (file_name, stage_path, markdown_text)
SELECT
    file_name,
    stage_path,
    SNOWFLAKE.CORTEX.AI_PARSE_DOCUMENT(
        TO_FILE('@SERVER_ENCRYPT/' || file_name),
        {'mode': 'LAYOUT'}
    ) AS markdown_text
FROM SNOWFLAKE_LEARNING_DB.PUBLIC.landing_table;

-- 11. Monitor parsing progress
SELECT COUNT(*) FROM SNOWFLAKE_LEARNING_DB.PUBLIC.parsed_docs;

SELECT * FROM SNOWFLAKE_LEARNING_DB.PUBLIC.parsed_docs;

-- 12. Verify parsed output structure
SELECT
    file_name,
    markdown_text:content::STRING AS content,
    markdown_text:metadata:pageCount::INT AS page_count
FROM SNOWFLAKE_LEARNING_DB.PUBLIC.parsed_docs
LIMIT 5;

-- ============================================
-- TASK (AUTO-PROCESSING FOR NEW PDFS)
-- ============================================

-- 13. Create task to auto-process new PDFs when stream has data
-- control by WHERE METADATA$ACTION = 'INSERT';
CREATE OR REPLACE TASK SNOWFLAKE_LEARNING_DB.PUBLIC.llm_task
    WAREHOUSE = COMPUTE_WH
    SCHEDULE = '1 MINUTE'
    WHEN SYSTEM$STREAM_HAS_DATA('llm_stream')
AS
    INSERT INTO SNOWFLAKE_LEARNING_DB.PUBLIC.parsed_docs (file_name, stage_path, markdown_text)
    SELECT
        file_name,
        stage_path,
        SNOWFLAKE.CORTEX.AI_PARSE_DOCUMENT(
            TO_FILE('@SERVER_ENCRYPT/' || file_name),
            {'mode': 'LAYOUT'}
        ) AS markdown_text
    FROM SNOWFLAKE_LEARNING_DB.PUBLIC.llm_stream
    WHERE METADATA$ACTION = 'INSERT';

-- 14. Resume task
ALTER TASK SNOWFLAKE_LEARNING_DB.PUBLIC.llm_task RESUME;

-- ============================================
-- CHUNKING
-- ============================================

-- 15. Create chunked docs table
CREATE OR REPLACE TABLE SNOWFLAKE_LEARNING_DB.PUBLIC.chunked_docs (
    file_name STRING,
    chunk_index INT,
    chunk_text STRING
);

-- 16. Chunk markdown text using recursive character splitting
-- 512 token chunks with 50 token overlap to preserve context across boundaries
INSERT INTO SNOWFLAKE_LEARNING_DB.PUBLIC.chunked_docs (file_name, chunk_index, chunk_text)
SELECT
    file_name,
    c.index AS chunk_index,
    c.value::STRING AS chunk_text
FROM SNOWFLAKE_LEARNING_DB.PUBLIC.parsed_docs,
LATERAL FLATTEN(
    INPUT => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
        markdown_text:content::STRING,
        'markdown',
        512,
        50
    )
) c;

-- 17. Verify chunk count
SELECT COUNT(*) FROM SNOWFLAKE_LEARNING_DB.PUBLIC.chunked_docs;

-- 18. Preview chunks
SELECT
    file_name,
    chunk_index,
    LEFT(chunk_text, 200) AS preview
FROM SNOWFLAKE_LEARNING_DB.PUBLIC.chunked_docs
ORDER BY file_name, chunk_index
LIMIT 100;

-- ============================================
-- CORTEX SEARCH SERVICE
-- ============================================

-- 19. Create Cortex Search Service for semantic retrieval
CREATE OR REPLACE CORTEX SEARCH SERVICE SNOWFLAKE_LEARNING_DB.PUBLIC.cardiology_search
    ON chunk_text
    ATTRIBUTES file_name, chunk_index
    WAREHOUSE = COMPUTE_WH
    TARGET_LAG = '1 minute'
    AS (
        SELECT
            file_name,
            chunk_index,
            chunk_text
        FROM SNOWFLAKE_LEARNING_DB.PUBLIC.chunked_docs
    );

-- 20. Verify search service was created
SHOW CORTEX SEARCH SERVICES;

-- 21. Sanity check query against the search service
SELECT PARSE_JSON(
    SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
        'cardiology_search',
        '{
            "query": "What are the treatment guidelines for atrial fibrillation?",
            "columns": ["file_name", "chunk_index", "chunk_text"],
            "limit": 5
        }'
    )
)['results'] AS results;

-- ============================================
-- STREAMLIT APP
-- ============================================

-- 22. Upload streamlit_app.py to stage before running this:
-- PUT file://./streamlit_app.py @SERVER_ENCRYPT/streamlit/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- 23. Create Streamlit app
CREATE OR REPLACE STREAMLIT SNOWFLAKE_LEARNING_DB.PUBLIC.cardiology_app
    ROOT_LOCATION = '@SNOWFLAKE_LEARNING_DB.PUBLIC.SERVER_ENCRYPT/streamlit'
    MAIN_FILE = 'streamlit_app.py'
    QUERY_WAREHOUSE = COMPUTE_WH
    COMMENT = 'Cardiology Specialist Agent — Cortex Search UI';

-- 24. Grant access if sharing with teammates
GRANT USAGE ON STREAMLIT SNOWFLAKE_LEARNING_DB.PUBLIC.cardiology_app TO ROLE SYSADMIN;