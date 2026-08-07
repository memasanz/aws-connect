# Product Spec: Fabric S3 → AI Search RAG Ingestion Solution

## 1. Overview & Goals

### Summary
A Microsoft Fabric solution that incrementally ingests files from an Amazon S3 bucket
(surfaced in Fabric via an **S3 shortcut**) into an **Azure AI Search** index for
Retrieval-Augmented Generation (RAG), governed by folder-based **ACLs** mapped to Entra ID groups.

The solution is built from a small set of Fabric **notebooks** and two **Data Pipelines**.
It favors **low abstraction / clean code** over heavy frameworks, and leverages **PySpark**
for smart, bounded parallelism. Real data is **deeply nested folders with large volumes of files**,
so the design is depth-agnostic, incremental, and resumable.

### Goals
- Incrementally detect new / changed / deleted files in the S3 source without full reprocessing.
- Extract content with **Azure AI Document Intelligence**, chunk it (with page numbers),
  vectorize with **Azure OpenAI embeddings**, and push to **Azure AI Search**.
- Enforce **folder-based ACLs**: gate ingestion and stamp `allowed_groups` on each chunk for
  query-time security trimming.
- Provide clear operational state (per-file status), logging, and idempotent reruns.

### Non-Goals
- Copying the raw file bytes is handled by the Fabric S3 shortcut (no custom copy).
- The query / chat application that consumes the index is out of scope (contract in §13).
- Managing Entra group membership itself (assumed to exist).

---

## 2. Architecture

```
Amazon S3 bucket
      │  (Fabric S3 shortcut — read-only surface in OneLake)
      ▼
OneLake  Files/<shortcut>/...
      │
      │  ┌────────────────── Pipeline 1: Metadata Refresh ──────────────────┐
      │  │  nb_01_metadata_delta                                            │
      ▼  ▼                                                                  │
  Delta: file_metadata  (process_status state machine)                     │
      │  └────────────────────────────────────────────────────────────────┘
      │
      │  ┌────────────────── Pipeline 2: Index Ingestion ───────────────────┐
      │  │  nb_03_ingest_to_index  (index built by nb_02_create_search_index)│
      ▼  ▼                                                                  │
  For each changed file:  ACL gate (acls.json + config.acl_bypass_enabled)  │
      │        ├─► Azure AI Document Intelligence  ──► text + page numbers   │
      │        ├─► chunk (size/overlap from config) ──► Azure OpenAI embed   │
      │        └─► push chunks (+ allowed_groups) ──► Azure AI Search        │
      │  Delta: ingestion_state / ingestion_log / skipped_log               │
      │  └────────────────────────────────────────────────────────────────┘
      ▼
Azure AI Search index (vector + content + page_number + file_path + allowed_groups + metadata)
```

### Components
| Component | Role |
| --- | --- |
| Amazon S3 bucket | Source of files |
| Fabric S3 shortcut | Read-only surface of S3 in OneLake |
| OneLake Lakehouse | Hosts delta tables, `acls.json`, `config` |
| Fabric Notebooks (PySpark) | Metadata scan, index creation, ingestion |
| Fabric Data Pipelines | Orchestrate notebooks on a schedule / on demand |
| Azure AI Document Intelligence | Extract text + layout + page numbers |
| Azure OpenAI | Generate embeddings for chunks |
| Azure AI Search | Vector index + security-trimmed retrieval |
| Azure Key Vault | Stores all secrets; config holds only pointers |

---

## 3. Prerequisites

### Azure
- Azure AI Document Intelligence resource (endpoint + key/managed identity).
- Azure OpenAI resource with an embedding deployment (e.g. `text-embedding-3-large`).
- Azure AI Search service (tier sized for vector workload).
- Azure Key Vault for secrets.
- Entra ID groups representing access boundaries (GUIDs used in `acls.json`).

### Fabric
- A workspace + Lakehouse.
- An **S3 shortcut** configured against the target bucket (credentials via a Fabric connection).
- Workspace identity or service principal with access to the Azure services above.
- Fabric capacity sized for Spark + pipeline runs.

---

## 4. OneLake Data Model

All tables are **delta** tables in the Lakehouse. Created-if-missing by the notebooks.

### 4.1 `file_metadata`
One row per source file. Drives change detection and the processing state machine.

| column | type | notes |
| --- | --- | --- |
| `file_path` | STRING (PK) | full OneLake path within the shortcut |
| `file_name` | STRING | |
| `file_extension` | STRING | lower-cased, no dot |
| `file_size` | LONG | bytes |
| `modified_datetime` | TIMESTAMP | source last-modified |
| `author` | STRING | if available |
| `etag` | STRING | source etag |
| `content_hash` | STRING | optional stronger hash of bytes |
| `change_hash` | STRING | composite: size + modified + etag (+ content_hash) |
| `acl_version` | STRING | hash of the folder's ACL entry at last ingest |
| `last_seen_utc` | TIMESTAMP | set every scan; drives deletion detection |
| `process_status` | STRING | state machine (see §5) |
| `status_reason` | STRING | skip/error detail |
| `retry_count` | INT | failed attempts |
| `status_updated_utc` | TIMESTAMP | last transition |

### 4.2 `ingestion_state`
Which file version is currently in the index.

| column | type | notes |
| --- | --- | --- |
| `file_path` | STRING (PK) | |
| `change_hash` | STRING | version currently indexed |
| `acl_version` | STRING | ACL version currently stamped |
| `chunk_count` | INT | chunks in the index |
| `embedding_model` | STRING | model used |
| `chunk_strategy_version` | STRING | chunking version |
| `indexed_utc` | TIMESTAMP | |

### 4.3 `ingestion_log`
Append-only success log: `file_path, chunks, pages, duration_ms, embedding_model, di_model, run_id, ts_utc`.

### 4.4 `skipped_log`
Append-only skip/failure log: `file_path, reason, detail, run_id, ts_utc`.
`reason` ∈ {`doc_intel_unsupported`, `doc_intel_error`, `no_acl`, `empty_extract`, `dead_letter`}.

### 4.5 `acls/acls.json` (OneLake Files)
Folder-path → Entra group IDs. Pattern from `memasanz/cohesityACLsIntoFabric`.

```json
{
  "version": "2026-08-07",
  "folders": [
    { "path": "Files/shortcut/finance", "groups": ["<entra-group-guid-1>", "<entra-group-guid-2>"] },
    { "path": "Files/shortcut/hr",      "groups": ["<entra-group-guid-3>"] }
  ]
}
```
Resolution: a file inherits the ACL of the **nearest ancestor folder** present in `acls.json`.

---

## 5. `file_metadata.process_status` State Machine

The `process_status` column **is** the incremental work queue — Pipeline 2 selects rows that need
work; no anti-join required.

| status | meaning | set by |
| --- | --- | --- |
| `new` | discovered, never ingested | nb_01 (insert) |
| `changed` / `reingest` | `change_hash` differs from indexed version | nb_01 (merge) |
| `pending` | claimed for the current ingestion run | nb_03 |
| `ingesting` | actively processed (DI→chunk→embed→push) | nb_03 |
| `complete` | successfully indexed; `change_hash` recorded | nb_03 |
| `skipped` | not indexed (no ACL / unsupported / empty) | nb_03 |
| `error` | failed; eligible for retry | nb_03 |
| `dead_letter` | exceeded `max_retries`; manual attention | nb_03 |
| `deleted` | absent from S3 (stale `last_seen_utc`); chunks purged | nb_01/nb_03 |

**Transitions:** `new`/`changed`/`reingest`/`error` → `pending` → `ingesting` → `complete` | `skipped` | `error` | `dead_letter`.
- If a `complete` file's `change_hash` later changes → nb_01 sets `reingest`.
- If a previously-seen file is absent in the current scan → nb_01 sets `deleted` and queues chunk purge.

---

## 6. Configuration `config` Delta Table

Single source of truth for runtime behavior. Read at the top of every notebook.
Schema: `config(key STRING, value STRING, value_type STRING, updated_utc TIMESTAMP)`.
Created-if-missing with defaults by `nb_00_bootstrap` (or nb_01).

| key | example | purpose |
| --- | --- | --- |
| `acl_bypass_enabled` | `false` | ingest even when a folder has no ACL entry |
| `doc_intelligence_endpoint` | `https://...` | DI endpoint |
| `doc_intelligence_model` | `prebuilt-layout` | DI model |
| `aoai_endpoint` | `https://...` | Azure OpenAI endpoint |
| `aoai_embedding_deployment` | `text-embedding-3-large` | embedding deployment |
| `embedding_dimensions` | `3072` | vector length |
| `search_endpoint` | `https://x.search.windows.net` | AI Search endpoint |
| `search_index_name` | `docs-rag` | target index |
| `chunk_size` | `1000` | chunk size (tokens/chars) |
| `chunk_overlap` | `150` | chunk overlap |
| `chunk_strategy_version` | `v1` | bump to force re-chunk |
| `max_concurrency` | `8` | bounded parallelism vs throttling |
| `max_retries` | `3` | before `dead_letter` |
| `supported_extensions` | `pdf,docx,pptx,xlsx,html,txt` | pre-filter before DI |
| `backfill_mode` | `false` | larger batches / pacing for first load |
| `kv_*` | secret names | Key Vault pointers (never secrets themselves) |

Secrets are **never** stored here — only Key Vault references.

---

## 7. Notebooks

Kept minimal, low-abstraction, PySpark-parallel where it helps.

### 7.0 `nb_00_bootstrap` (run once / on config change)
**Purpose:** idempotently create the `config`, `file_metadata`, `ingestion_state`, `ingestion_log`,
and `skipped_log` delta tables and seed `config` defaults (MERGE preserves operator overrides).
Provides the `load_config(spark)` helper reused by the other notebooks and validates `acls.json`.

### 7.1 `nb_01_metadata_delta` (Pipeline 1)
**Purpose:** scan the S3 shortcut, compute change-detection metadata, maintain `file_metadata`.
- Create `config` + `file_metadata` if missing.
- **Recursive, depth-agnostic** listing of the shortcut, distributed with Spark (no driver-side walk
  that collects all paths into memory); handle very large file counts by partitioning the tree.
- Compute `change_hash` (+ optional `content_hash`).
- **MERGE** into `file_metadata`: unseen → `new`; changed `change_hash` → `reingest`; unchanged →
  keep `complete` (refresh `last_seen_utc`).
- **Deletion detection:** rows with `last_seen_utc` < run start → `deleted`.

### 7.2 `nb_02_create_search_index` (run once / on schema change)
**Purpose:** define/create the Azure AI Search index (idempotent). Fields (at least):
`chunk_id` (key), `file_path`, `file_name`, `file_extension`, `content` (searchable),
`content_vector` (vector, `embedding_dimensions`), `page_number`, `chunk_index`,
`allowed_groups` (collection, filterable), `embedding_model`, `chunk_strategy_version`, `indexed_utc`.
Vector config: HNSW; optional semantic ranker.

### 7.3 `nb_03_ingest_to_index` (Pipeline 2)
**Purpose:** ingest changed/new files + handle deletions.
- Select rows `process_status IN ('new','changed','reingest','error')` under `max_retries`; process
  `deleted` rows first (purge chunks + `ingestion_state`).
- **Claim:** MERGE-guarded transition `→ pending → ingesting` (prevents double-processing).
- **Batch/backfill pacing:** claim at most `batch_size` (or `backfill_batch_size` when
  `backfill_mode=true`) files per run, ordered deterministically — status-driven so the corpus
  ingests incrementally and resumably.
- **Deletion:** for `deleted`, delete all chunks for `file_path` from Search + remove `ingestion_state`.
- **Full ingest** (new/changed):
  1. Resolve folder → groups via `acls.json`; none & `acl_bypass_enabled=false` → `skipped(no_acl)`.
  2. Extension in `supported_extensions`? else → `skipped(doc_intel_unsupported)`.
  3. **Re-ingest cleanup:** delete existing chunks for `file_path` (deterministic `chunk_id`).
  4. Doc Intelligence → text + page numbers; empty → `skipped(empty_extract)`.
  5. Chunk (size/overlap/strategy from config) with page numbers.
  6. Embed via Azure OpenAI.
  7. Push chunks (+ `allowed_groups`, `embedding_model`, `chunk_strategy_version`) to Search.
  8. Update `ingestion_state`, write `ingestion_log`, set `complete`.
- **Errors:** increment `retry_count`; ≥ `max_retries` → `dead_letter` + `skipped_log`; else `error`.
- **Parallelism:** two-phase — network-heavy work (DI/embed/Search) fans out in a bounded
  `ThreadPoolExecutor(max_concurrency)`; Delta status/state/log writes are applied serially on the
  driver to avoid optimistic-concurrency conflicts. Search uploads are batched.

### 7.4 `nb_04_acl_reconcile` (run after editing `acls.json`)
**Purpose:** keep security trimming in sync with ACL changes **without** re-running Doc Intelligence
or embeddings. For each `complete` file whose freshly-resolved `acl_version` differs from the value
in `ingestion_state`, merge-patch only the `allowed_groups` field on that file's existing Search
chunks and update the stored `acl_version`.

---

## 8. Pipelines

The solution runs as two scheduled Fabric Data Pipelines plus two on-demand setup/maintenance
notebooks. Each pipeline step is a **Notebook activity** bound to the `aws_connect_lh` lakehouse.

### Setup (run once, on-demand)
1. `nb_00_bootstrap` — create tables + seed config.
2. `nb_02_create_search_index` — create/upgrade the AI Search index. Re-run only on schema change.

### Pipeline 1 — Metadata Refresh
Runs `nb_01_metadata_delta`. **Schedule:** hourly or daily (via pipeline schedule trigger) + on-demand.
Output: fresh `file_metadata` statuses (`new`/`reingest`/`deleted`). Cheap — safe to run frequently.

### Pipeline 2 — Index Ingestion
Runs `nb_03_ingest_to_index` (index must exist via `nb_02`). **Schedule:** chained after Pipeline 1
(single pipeline with both activities in sequence) or on its own cadence. Idempotent + resumable
(status-driven), so overlapping/failed runs are safe and pick up where they left off. For the
initial load, set `backfill_mode=true` and let it run repeatedly until the queue drains.

### Maintenance — ACL Reconcile (on-demand)
Run `nb_04_acl_reconcile` after editing `acls.json` to re-stamp `allowed_groups` on already-indexed
content without re-ingesting. Optionally add it as a scheduled step if ACLs change frequently.

**Recommended orchestration:** one pipeline `pl_ingest` = [`nb_01_metadata_delta` → `nb_03_ingest_to_index`]
on a daily schedule; `nb_00`/`nb_02` run manually at setup; `nb_04` run manually after ACL edits.

---

## 9. Change Detection
A file is "changed" when its `change_hash` (size + `modified_datetime` + `etag`, optionally
`content_hash`) differs from the indexed value. nb_01 sets `new`/`reingest`; Pipeline 2 works the
status queue. Deletion is detected via stale `last_seen_utc`.

---

## 10. ACL Governance & Security Trimming
- **`acls.json`** maps folder path → Entra group GUIDs; a file inherits the nearest ancestor's ACL.
- **Ingestion gate:** no ACL + `acl_bypass_enabled=false` → `skipped(no_acl)`; else ingest.
- **Security trimming:** resolved group GUIDs written to each chunk's `allowed_groups`; query layer
  filters on the caller's group membership.
- **ACL drift:** `acl_version` tracked per file; ACL-only change → re-stamp `allowed_groups`
  (no DI/embeddings).

---

## 11. Error Handling & Logging
- `skipped_log` captures every non-ingest with a reason.
- `ingestion_log` captures every success (chunks, pages, duration, models).
- Retries with backoff up to `max_retries`; poison files land in `dead_letter` and never block a run.

---

## 12. Parallelism / Performance (deeply nested + high volume)
- Spark distributes recursive listing + hashing (nb_01) and per-file ingestion (nb_03).
- Bounded concurrency (`max_concurrency`) protects DI / AOAI / Search from throttling.
- Batch Search uploads; deterministic `chunk_id` for clean replace.
- Partition / Z-ORDER + periodic `OPTIMIZE` on `file_metadata` for fast status queries at scale.
- Efficient nearest-ancestor ACL lookup (sorted prefix map, not per-file full scan).
- **Backfill mode** (`backfill_mode=true`) uses larger batches + pacing for the first full load;
  status-driven design makes it resumable.

---

## 13. Open Questions / Future Work
- **Query / retrieval contract:** how the chat/query app queries the index and obtains the caller's
  Entra group membership (e.g. OBO flow) to filter on `allowed_groups`.
- **Vector / index specifics:** finalize embedding dimensions, HNSW params, semantic ranker on/off;
  store `embedding_model` + `chunk_strategy_version` per chunk so model/strategy changes trigger re-embed.
- **Doc Intelligence limits & cost:** file-size / page caps, very large file handling, and a cost
  model (DI pages + AOAI tokens + Search tier).
- **Observability:** run-summary metrics, dashboards, alerting on `dead_letter` growth.
- **Other:** PII/compliance stance, multilingual handling, S3 shortcut auth/secret rotation.

---

## 14. Security & Secrets
- All secrets in **Azure Key Vault**; `config` holds only references.
- Prefer workspace-managed identity / service principal for Azure service auth.
- No credentials in notebooks or source control.
