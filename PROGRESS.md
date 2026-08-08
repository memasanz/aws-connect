# Build Progress

Live status of the Fabric S3 → AI Search ingestion build. Most recent entries at the top.
The agent commits + pushes to `main` at the end of each sprint so progress is visible remotely.

## Status board

| Sprint | Scope | Status |
| --- | --- | --- |
| S0 | Repo & scaffolding + `PRODUCT_SPEC.md` | ✅ done |
| S1 | Delta schemas + `config` + `acls.json` | ✅ done |
| S2 | `nb_01_metadata_delta` (scan/change/delete) | ✅ done |
| S3 | `nb_02_create_search_index` | ✅ done |
| S4 | `nb_03_ingest_to_index` (core) | ✅ done |
| S5 | ACL drift + delete purge + bounded parallelism | ✅ done |
| S6 | Pipelines + docs | ✅ done |
| S7 | End-to-end test: fake docs → S3 → deploy Azure → run in Fabric | 🏗️ in progress |
| S8 | Batch durability hardening: stuck-file reclaim-as-retry, stop/restart, visibility | 🏗️ in progress |

**Core build complete** (S0–S6). **Sprint 7** adds a live end-to-end test with real data + deployed
Azure resources. **Sprint 8** hardens the pipeline for repeated stop/restart batch runs with strong
visibility and self-healing of stuck documents.

### Sprint 8 plan — batch durability & visibility
Goal: the pipeline must handle documents in **batches**, be safe to **stop and restart** at any time,
never get permanently stuck on a single document, and give **live visibility** into a running job.

| # | Task | Status |
| --- | --- | --- |
| 8.1 | **Batched drain loop** — one invocation claims `batch_size` (100) files at a time, processes them, checkpoints, then asks "any more?" and repeats until drained or `max_batches_per_run`/`run_time_budget_min` cap hit | ✅ done |
| 8.2 | **Honest `ingesting` state** — mark **only** the in-flight batch `ingesting` (no bulk pre-claim); status always reflects what is actually being processed | ✅ done |
| 8.3 | **Scale-safe self-excluding claim** — claim only rows untouched since `RUN_START_TS`, so a file that errors mid-run retries on the *next* invocation, never hot-loops | ✅ done |
| 8.4 | **Stuck-file reclaim as a retry** — `ingesting` past `ingesting_lease_minutes` → `retry_count+=1`; under cap → `reingest`, at/over cap → `dead_letter` (poison files can't loop forever) | ✅ done |
| 8.5 | **Per-file time bounds** — DI poll deadline (180s) + HTTP read timeouts bound how long one doc can hold a worker | ✅ done |
| 8.6 | **Robust S3-shortcut reads** — local mount can miss shortcut bytes (`FileNotFoundError`); retry local read then fall back to the Fabric fs API copy-to-temp | ✅ done |
| 8.7 | **Stage-tagged errors + full tracebacks** — `extract_error`/`embed_error`/`search_error` reason + full stack in `skipped_log.detail` | ✅ done |
| 8.8 | **Live progress in Delta** — `run_progress` table (one row/run, throttled upsert, MVCC = no locks): phase, processed/total, throughput, ETA, last file | ✅ done |
| 8.9 | **Job monitor** — `scripts/watch_job.ps1` reads real server-side Fabric job status on demand (a stopped poller ≠ a stopped job) | ✅ done |
| 8.10 | **nb_05 live panel** — section 1b renders `run_progress` while a run is in flight | ✅ done |
| 8.11 | **Clean-index E2E test** — empty index, reset queue, run drain loop, verify visibility + counts; then delete + update scenarios | 🏗️ in progress |

Config added: `batch_size=100`, `max_batches_per_run=0` (0=drain), `run_time_budget_min=0` (0=no cap).

### Sprint 7 plan — end-to-end test
Goal: prove the whole pipeline on real data and deployed services.
1. **Generate fake documents** in a deeply-nested folder hierarchy (multi-page PDFs, docx, txt, plus
   one intentionally-unsupported file to exercise the skip path).
2. **Upload to S3** under a test prefix, preserving the folder hierarchy.
3. **Author deployment scripts** (Bicep + `deploy.ps1`) for: Resource Group, **Key Vault**,
   **Document Intelligence**, **Azure OpenAI (Foundry)** with a `text-embedding-3-large` deployment,
   and **Azure AI Search**. Service keys are written into Key Vault.
4. **Deploy** the resources and capture endpoints + KV secret names.
5. **Configure**: import notebooks into Fabric, attach `aws_connect_lh`, upload `acls.json` to
   OneLake, set the `config` table values.
6. **Run in Fabric**: `nb_00` → `nb_02` → `nb_01` → `nb_03`, end-to-end.
7. **Report** results + evidence in this file.

## Fabric connectivity test
- ✅ **S3 shortcut created and verified end-to-end.**
  - Workspace: `workspace_FABRIC` (`ef1eda73-0a00-4ad0-80b2-5eccf9a98a5f`)
  - Lakehouse: `aws_connect_lh` (`35f024b6-9a0e-44b0-9c3b-3a43260c8f51`)
  - Connection: `aws-connect-s3-mmx` (`20509714-7563-4017-bc21-7a3f541b1a1a`), Amazon S3 / Basic (access key)
  - Shortcut: `Files/s3_mmx_bucket` → `https://mmx-amazon-s3-bucket.s3.us-east-2.amazonaws.com`
  - Verified via OneLake listing: `Files/s3_mmx_bucket/Fabric Data Agent.pdf` (649,958 bytes) is visible.
  - Note: bucket region is **us-east-2** (initial us-east-1 URL returned a 301).

## Changelog

### Sprint 8 — batch durability, honest state & live visibility
- **Batched drain loop** in `nb_03`: one invocation now claims `batch_size` (100) files at a time,
  processes + checkpoints them, then re-checks for more, draining the queue in bounded chunks with
  optional `max_batches_per_run` / `run_time_budget_min` caps. Replaces the single bulk pre-claim.
- **Honest `ingesting` state:** only the in-flight batch is marked `ingesting` (bug fix — the old bulk
  pre-claim left files `ingesting` that were never processed when a run ended). Status now reflects
  what is actually being worked.
- **Scale-safe self-excluding claim:** claims only rows untouched since `RUN_START_TS`, so a file that
  errors mid-run retries on the *next* invocation instead of hot-looping.
- **Stuck-file reclaim as a retry:** `ingesting` past `ingesting_lease_minutes` → `retry_count+=1`;
  under cap → `reingest`, at/over cap → `dead_letter` (poison files can't loop forever).
- **Robust S3-shortcut reads:** `read_file_bytes()` retries the local mount then falls back to the
  Fabric fs API (copy-to-temp) — fixes intermittent `FileNotFoundError` on shortcut content.
- **Live progress in Delta:** new `run_progress` table (one row/run, throttled MVCC upsert = no file
  locks) with phase, processed/total, throughput, ETA, last file; surfaced in `nb_05` section 1b.
- **Job monitor:** `scripts/watch_job.ps1` reads the real server-side Fabric job status on demand
  (a stopped client poller is not a stopped job).
- Config: `batch_size` 200→100, added `max_batches_per_run=0`, `run_time_budget_min=0`. Updated
  `nb_00_bootstrap`, `config_defaults.json`, `PRODUCT_SPEC.md` (§7.3, §11).

### Post-build refinements — chunking + durability
- **Chunk by page, no overlap** (per @memasanz): `nb_03` now emits one chunk per page (splitting only
  pages that exceed `chunk_size`), matching Azure AI Search's default page chunking where
  `pageOverlapLength`=0. Removed `chunk_overlap`; raised `chunk_size` default to `8000` (page cap);
  `chunk_strategy_version`→`page-v1`. Verified with a local unit test.
- **Crash durability:** added stale-lease recovery — `ingesting` rows left by a crashed/timed-out run
  are reclaimed after `ingesting_lease_minutes` (default 120) so no file is stranded. Documented that
  status is committed per-file (incremental checkpointing) and Search uploads are batched (500/req).
- Updated `config_defaults.json`, `nb_00_bootstrap`, and `PRODUCT_SPEC.md` (§6, §7.3) accordingly.

### Sprint 6 — pipelines + docs polish
- Expanded `PRODUCT_SPEC.md` §7–8: documented `nb_00_bootstrap` (7.0) and `nb_04_acl_reconcile`
  (7.4), corrected §7.3 to reflect deletion/backfill/two-phase parallelism as built (ACL drift moved
  to nb_04), and rewrote §8 with concrete setup/pipeline/maintenance orchestration + scheduling
  (recommended `pl_ingest` = nb_01 → nb_03 daily; nb_00/nb_02 at setup; nb_04 after ACL edits).
- Rewrote `README.md`: full Fabric notebook role table + step-by-step "Deploying to Fabric" guide.
- **Build complete** — the full notebook set + spec are in `main`. Notebooks are authored and
  JSON-validated locally; they are designed for Fabric Spark and have **not** been executed against
  live Fabric (only the S3 shortcut connectivity was verified end-to-end).

### Sprint 5 — ACL drift + bounded parallelism + backfill pacing
- Reworked `nb_03` processing into two phases: network-heavy work (DI → embed → Search) runs in a
  bounded `ThreadPoolExecutor(max_concurrency)`, while all Delta status/state/log writes are applied
  serially on the driver to avoid optimistic-concurrency conflicts.
- Added backfill pacing: runs claim at most `batch_size` (or `backfill_batch_size` when
  `backfill_mode=true`) files per run, ordered deterministically — status-driven so a huge corpus
  ingests incrementally and resumably.
- Added `notebooks/nb_04_acl_reconcile.ipynb`: fast path that re-stamps `allowed_groups` on existing
  Search chunks when `acls.json` changes — comparing the stored `acl_version` vs the freshly resolved
  one and merge-patching only drifted files, with **no** Doc Intelligence / embedding re-runs.
- Seeded `batch_size` / `backfill_batch_size` config defaults (bootstrap + `config_defaults.json`).

### Sprint 4 — nb_03_ingest_to_index (core ingestion)
- Added `notebooks/nb_03_ingest_to_index.ipynb`: works the `file_metadata` status queue end-to-end.
  - Claims `new`/`changed`/`reingest`/`error` rows (`pending`→`ingesting`) below `max_retries`.
  - ACL gate via efficient nearest-ancestor resolver over `acls.json` (+ `acl_bypass_enabled`),
    stamping `allowed_groups` on every chunk for security trimming.
  - Extension pre-filter → Document Intelligence extract → page-aware chunking → Azure OpenAI
    embeddings → batched upload to AI Search.
  - Deterministic `chunk_id` + delete-by-file before upload = re-ingest never duplicates.
  - Deletion handling: purges chunks + `ingestion_state` for `deleted` files.
  - Retries with `retry_count`; `error`→`dead_letter` on exceeding `max_retries`; a poison file
    never blocks the run. Writes `ingestion_state`, `ingestion_log`, `skipped_log`.
  - Secrets (DI/AOAI/Search keys) sourced from Key Vault; endpoints/params from `config`.

### Sprint 3 — nb_02_create_search_index
- Added `notebooks/nb_02_create_search_index.ipynb`: idempotent `create_or_update_index` with a
  HNSW vector field (`content_vector`), `page_number`/`chunk_index`, semantic config, and the
  `allowed_groups` collection for query-time security trimming. Admin key read from Key Vault.

### Sprint 2 — nb_01_metadata_delta
- Added `notebooks/nb_01_metadata_delta.ipynb`: recursive Spark-native listing of the S3 shortcut
  (`binaryFile` + `recursiveFileLookup`, column-pruned so file bytes are never read), computes a
  size+mtime `change_hash`, MERGEs into `file_metadata` driving `new`/`reingest`, refreshes
  `last_seen_utc`, and flags `deleted` via a not-matched-by-source sweep.

### Sprint 1 — data model + config + ACLs
- Added `notebooks/nb_00_bootstrap.ipynb`: idempotently creates `config`, `file_metadata`,
  `ingestion_state`, `ingestion_log`, `skipped_log` delta tables and seeds config defaults
  (MERGE preserves operator overrides). Includes `load_config()` helper + ACL file validation.
- Added `config/config_defaults.json` and `config/acls.example.json`.

### Sprint 0 — repo & scaffolding
- Initialized git repo, added remote `origin` → `github.com/memasanz/aws-connect`.
- Hardened `.gitignore` (excludes venv, downloads, `.env`, credential files).
- Added `PRODUCT_SPEC.md` (full solution spec), `README.md`, this `PROGRESS.md`.
- Verified no secrets in tracked files.
