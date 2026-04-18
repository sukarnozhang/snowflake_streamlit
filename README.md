# 🫀 Clinical Decision Support — Cardiology Specialist Agent

> **Phase 1 of a multi-agent clinical AI system** — a RAG pipeline enabling clinicians to semantically search cardiology research papers and clinical guidelines using Snowflake Cortex.

---

## 🧠 Project Vision

This project is being built toward a **multi-agent clinical decision support system**, where specialist AI agents (cardiology, nephrology, oncology, etc.) are orchestrated by a **geriatrician master agent** — routing complex, multi-morbidity clinical questions to the right specialists and synthesising their responses.

**Current status: Phase 1 — Cardiology Specialist Agent**

The cardiology agent is a fully functional RAG pipeline built natively on Snowflake Cortex, serving as the foundation for the broader multi-agent architecture.

---

## 🏗️ Architecture

```
Azure Blob Storage (PDFs - as external stage)
        ↓
  Snowpipe (auto-ingest)
        ↓
  Landing Stage (PAPER_FROM_BLOB2 as Snowflake internal stage)
        ↓
  AI_PARSE_DOCUMENT (Cortex)
        ↓
  Recursive Text Chunking
        ↓
  Cortex Search Service (vector search)
        ↓
  Streamlit UI (query interface)
```

---

## 🔬 What It Does

- **Ingests** cardiology research papers and clinical guidelines from Azure Blob Storage via Snowpipe
- **Parses** PDFs using Snowflake Cortex `AI_PARSE_DOCUMENT` with layout-aware extraction
- **Chunks** documents using `SPLIT_TEXT_RECURSIVE_CHARACTER` (512 tokens, 50 token overlap)
- **Indexes** chunks into a Cortex Search Service for semantic retrieval
- **Serves** a Streamlit interface where clinicians can query across papers with paper-level filtering
- **Automates** end-to-end ingestion via Snowflake Streams and Tasks — new PDFs are processed automatically

---

## 🛠️ Tech Stack

| Layer | Technology |
|---|---|
| Cloud Storage | Azure Blob Storage |
| Data Platform | Snowflake |
| AI/LLM Services | Snowflake Cortex (AI_PARSE_DOCUMENT, Cortex Search) |
| Ingestion | Snowpipe, Snowflake Streams & Tasks |
| Frontend | Streamlit (hosted on Snowflake) |
| Version Control | GitHub |

---

## 📁 Repository Structure

```
├── pipeline.sql          # End-to-end pipeline: ingestion → parsing → chunking → search service
├── streamlit_app.py      # Query interface with paper filtering and semantic search
└── README.md
```

---

## 🚀 How to Run

### Prerequisites
- Snowflake account with Cortex enabled
- Azure Blob Storage with cardiology PDFs
- External stage configured pointing to Azure Blob

### Setup
1. Configure your Snowflake external stage to point to your Azure Blob container
2. Run `pipeline.sql` sequentially in a Snowflake worksheet
3. Upload `streamlit_app.py` to your internal Snowflake stage:
```sql
PUT file://./streamlit_app.py @YOUR_STAGE/streamlit/ AUTO_COMPRESS=FALSE OVERWRITE=TRUE;
```
4. Create and launch the Streamlit app in Snowsight

---

## 🗺️ Roadmap — Multi-Agent System

This cardiology agent is Phase 1 of a larger architecture:

| Phase | Description | Status |
|---|---|---|
| Phase 1 | Cardiology Specialist Agent (RAG pipeline) | ✅ Complete |
| Phase 2 | Additional specialist agents (nephrology, pharmacology) | 🔄 Planned |
| Phase 3 | Geriatrician Master Agent — routes multi-morbidity queries to specialists and synthesises responses | 🔄 Planned |
| Phase 4 | Evaluation framework using Snowflake Cortex native eval (faithfulness, answer relevancy, context precision) | 🔄 Planned |

The geriatrician master agent is clinically motivated — elderly patients typically present with multiple comorbidities requiring input from several specialties simultaneously. A geriatrician's role is to synthesise this complexity, making it a natural orchestration layer.

---

## 💡 Architectural Decisions

**Why Snowflake Cortex over LangChain?**
Data was already flowing into Snowflake, making a native Cortex implementation the simplest, most governed approach — no external vector DB, no additional infrastructure, and full data lineage within the Snowflake ecosystem.

**Why recursive character chunking?**
Medical literature has variable structure — abstracts, methodology sections, and clinical tables require context-aware splitting rather than fixed-size chunking to preserve semantic meaning across chunk boundaries.

**Why a geriatrician as master agent?**
Geriatricians specialise in multi-morbidity — patients with overlapping conditions across cardiology, nephrology, pharmacology, and more. This makes the geriatrician a clinically accurate orchestration metaphor, not just a technical convenience.

