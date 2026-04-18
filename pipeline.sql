-- ============================================
-- STREAM 1 - LLM BRANCH
-- Drug Discovery Data Pipeline
-- ============================================

-- 0. Check existing stages
SHOW STAGES IN DATABASE SNOWFLAKE_LEARNING_DB;

-- 1. Verify Azure blob has PDFs
LIST @PAPER_FROM_BLOB2;

-- 2. Verify internal stage has PDFs
-- NOTE: If SERVER_ENCRYPT is empty, run:
-- COPY FILES INTO @SERVER_ENCRYPT FROM @PAPER_FROM_BLOB2;
LIST @SERVER_ENCRYPT;

-- 3. Create file format
CREATE OR REPLACE FILE FORMAT SNOWFLAKE_LEARNING_DB.PUBLIC.NULL_FORMAT
  TYPE = 'CSV'
  FIELD_DELIMITER = 'NONE'
  RECORD_DELIMITER = 'NONE';

-- 4. Create landing table
CREATE OR REPLACE TABLE landing_table (
  file_name STRING,
  stage_path STRING,
  ingested_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- 5. Load files from Azure blob into landing table
TRUNCATE TABLE landing_table;
INSERT INTO landing_table (file_name, stage_path)
SELECT
  RELATIVE_PATH,
  '@PAPER_FROM_BLOB2/' || RELATIVE_PATH
FROM DIRECTORY(@PAPER_FROM_BLOB2);

-- 6. Verify landing table
SELECT * FROM landing_table LIMIT 10;
SELECT COUNT(*) FROM landing_table;

-- 7. Create stream on landing table
CREATE OR REPLACE STREAM llm_stream
  ON TABLE landing_table
  APPEND_ONLY = TRUE;

-- 8. Wake up stream
INSERT INTO landing_table (file_name, stage_path)
SELECT file_name, stage_path FROM landing_table;

-- 9. Verify stream has data
SELECT SYSTEM$STREAM_HAS_DATA('llm_stream');

-- 10. Create parsed docs table
CREATE OR REPLACE TABLE parsed_docs (
  file_name STRING,
  stage_path STRING,
  markdown_text VARIANT,
  parsed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP()
);

-- 11. Parse PDFs using AI_PARSE_DOCUMENT
-- NOTE: Uses SERVER_ENCRYPT (internal stage) as AI_PARSE_DOCUMENT
--       does not support external Azure stages directly
INSERT INTO parsed_docs (file_name, stage_path, markdown_text)
SELECT
  file_name,
  stage_path,
  SNOWFLAKE.CORTEX.AI_PARSE_DOCUMENT(
    TO_FILE('@SERVER_ENCRYPT/' || file_name),
    {'mode': 'LAYOUT'}
  ) AS markdown_text
FROM landing_table;

-- 12. Monitor progress
SELECT COUNT(*) FROM parsed_docs;

-- 13. Verify parsed output structure
SELECT
  file_name,
  markdown_text:content::STRING AS content,
  markdown_text:metadata:pageCount::INT AS page_count
FROM parsed_docs
LIMIT 5;

-- 14. Create LLM task for future auto-processing
-- (fires automatically when new PDFs land via Snowpipe)
CREATE OR REPLACE TASK llm_task
  WAREHOUSE = COMPUTE_WH
  SCHEDULE = '0 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('llm_stream')
AS
  INSERT INTO parsed_docs (file_name, stage_path, markdown_text)
  SELECT
    file_name,
    stage_path,
    SNOWFLAKE.CORTEX.AI_PARSE_DOCUMENT(
      TO_FILE('@SERVER_ENCRYPT/' || file_name),
      {'mode': 'LAYOUT'}
    ) AS markdown_text
  FROM llm_stream
  WHERE METADATA$ACTION = 'INSERT';

-- 15. Resume task for future ingestion
ALTER TASK llm_task RESUME;

-- ============================================
-- CHUNKING
-- ============================================

-- 16. Create chunked docs table
CREATE OR REPLACE TABLE chunked_docs (
  file_name STRING,
  chunk_index INT,
  chunk_text STRING
);

-- 17. Chunk the markdown text
INSERT INTO chunked_docs (file_name, chunk_index, chunk_text)
SELECT
  file_name,
  c.index AS chunk_index,
  c.value::STRING AS chunk_text
FROM parsed_docs,
LATERAL FLATTEN(
  INPUT => SNOWFLAKE.CORTEX.SPLIT_TEXT_RECURSIVE_CHARACTER(
    markdown_text:content::STRING,
    'markdown',
    512,
    50
  )
) c;

-- 18. Verify chunk count
SELECT COUNT(*) FROM chunked_docs;

-- 19. Preview chunks
SELECT file_name, chunk_index, LEFT(chunk_text, 200) AS preview
FROM chunked_docs
-- WHERE file_name LIKE 'OG%'
ORDER BY file_name DESC, chunk_index
LIMIT 1000000;

-- 20. Create the Cortex Search Service on chunked_docs
CREATE OR REPLACE CORTEX SEARCH SERVICE drug_discovery_search
  ON chunk_text
  ATTRIBUTES file_name, chunk_index
  WAREHOUSE = COMPUTE_WH
  TARGET_LAG = '1 minute'
  AS (
    SELECT
      file_name,
      chunk_index,
      chunk_text
    FROM chunked_docs
  );

-- 21. Verify the service was created
SHOW CORTEX SEARCH SERVICES;

-- 22. Quick sanity-check query against the service
--     (optional — uses REST or Snowflake SQL API in practice)
SELECT PARSE_JSON(
  SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'drug_discovery_search',
    '{
       "query": "Any novelty of paper 4 incomparison to 14",
       "columns": ["file_name", "chunk_index", "chunk_text"],
       "limit": 5
    }'
  )
)['results'] AS results;


-- 23. Create the Streamlit app object (run in Snowsight or SnowSQL)
CREATE OR REPLACE STREAMLIT drug_discovery_app
  ROOT_LOCATION = '@SNOWFLAKE_LEARNING_DB.PUBLIC.SERVER_ENCRYPT/streamlit'

  snow://streamlit/SNOWFLAKE_LEARNING_DB.PUBLIC.ER9G1GPZPKJ42FKH/versions/live/streamlit_app.py
  
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = COMPUTE_WH
  COMMENT = 'Drug Discovery LLM Branch — Cortex Search UI';

-- 24. Upload your streamlit_app.py to the stage first:
PUT file://./streamlit_app.py @SERVER_SCRIPT/streamlit/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;

-- 25. Grant access if sharing with teammates
GRANT USAGE ON STREAMLIT drug_discovery_app TO ROLE SYSADMIN;