# Build Progress

Live status of the Fabric S3 → AI Search ingestion build. Most recent entries at the top.
The agent commits + pushes to `main` at the end of each sprint so progress is visible remotely.

## Status board

| Sprint | Scope | Status |
| --- | --- | --- |
| S0 | Repo & scaffolding + `PRODUCT_SPEC.md` | ✅ done |
| S1 | Delta schemas + `config` + `acls.json` | ✅ done |
| S2 | `nb_pipeline_01_metadata_delta` (scan/change/delete) | ✅ done |
| S3 | `nb_setup_03_create_search_index` | ✅ done |
| S4 | `nb_pipeline_02_ingest_to_index` (core) | ✅ done |
| S5 | ACL drift + delete purge + bounded parallelism | ✅ done |
| S6 | Pipelines + docs | ✅ done |
| S7 | End-to-end test: fake docs → S3 → deploy Azure → run in Fabric | ✅ done |
| S8 | Batch durability hardening: stuck-file reclaim-as-retry, stop/restart, visibility | ✅ done |
| S9 | Scale hardening: endpoint pools, batched status writes, throttle visibility | ✅ done |
| S10 | E2E incremental + AI Search quality test (+ config hygiene) | ✅ code done · E2E run deferred to S11 |
| S11 | Dual source (S3 shortcut **or** direct S3) + index metadata fields | ✅ done · E2E green in `poc_ws_0808` |
| S12 | Bug-fixes surfaced by the S11 clean-workspace E2E run | ✅ done |
| S13 | Config single-sourcing + author extraction + all-filetype DI quality tests + slimmer index | 🏗️ code done · E2E pending in `poc_ws_0808c` |

**Core build complete** (S0–S6). **Sprint 7** adds a live end-to-end test with real data + deployed
Azure resources. **Sprint 8** hardens the pipeline for repeated stop/restart batch runs with strong
visibility and self-healing of stuck documents. **Sprint 9** hardens *throughput* so the same
pipeline scales toward 100k+ files without super-linear slowdown or invisible rate-limiting.
**Sprint 10** adds a repeatable, self-asserting end-to-end test (differentiated ACLs, incremental
change detection, index↔Delta reconciliation, full page coverage, security trimming) and removes
service endpoints from the git repo (config hygiene). **Sprint 11** lets the pipeline read from an
S3-compatible endpoint **directly** (REST + SigV4, no boto3) as an alternative to the OneLake S3
shortcut, and enriches the Search index with folder-path + document metadata fields. The next
end-to-end validation run targets a **clean Fabric workspace** (`poc_ws_0808`).

### Sprint 13 plan — config single-sourcing + author + all-filetype quality + slimmer index
Goal: eliminate config drift, populate the previously-empty `author`, prove Doc Intelligence
extraction quality for **every** supported file type, and drop redundant index metadata. E2E targets
a clean workspace (`poc_ws_0808c`).

| # | Task | Status |
| --- | --- | --- |
| 13.1 | **Config single source of truth** — deleted `config/config_defaults.json` (it was never read; the bootstrap seeds from its inline `DEFAULT_CONFIG`, so the JSON could silently drift). Removed the dead `CONFIG_DEFAULTS_PATH`; repointed SETUP/README at the notebook | ✅ done |
| 13.2 | **`source_mode` default = `s3_direct`** everywhere (inline `DEFAULT_CONFIG`, `gen_source` runtime fallback, docs). Mode is always sourced from the Fabric `config` table — never overridable via script/env/params | ✅ done |
| 13.3 | **Effective-config echo** — `nb_pipeline_01`/`02` print the full config (sorted) at run start so historical runs are self-documenting (which `source_mode`/`backfill_mode`/chunk settings were used). Safe: config stores only secret *names* | ✅ done |
| 13.4 | **Author extraction (stdlib only)** — populate `author` from document properties: Office `docProps/core.xml` `<dc:creator>` via `zipfile`, best-effort PDF `/Author`. No new packages in the pipeline | ✅ done |
| 13.5 | **All-filetype DI quality tests** — test-data generator + E2E corpus now exercise every supported type (pdf, docx, pptx, xlsx, html, htm, txt, md) with an embedded `CONTENTMARKER-<EXT>`; `nb_ops_03` group E asserts per-type marker extraction, contiguous chunk completeness (0..K-1 == `ingestion_state`), and Office author | ✅ done |
| 13.6 | **Slimmer index** — removed `embedding_model` field from the Search index schema + doc payload (still generated + stored as `content_vector`; `embedding_model` kept in Delta `ingestion_state`/`ingestion_log` for re-embed detection). `nb_setup_03` now recreates the index if a schema change isn't updatable in place | ✅ done |
| 13.7 | **Deployment docs** — surfaced `infra/deploy.ps1` (Option A automated deploy) in SETUP/README; corrected stale keyless-only infra prose to the actual hybrid model; added Key Vault Secrets User grant to README quick-start | ✅ done |
| 13.8 | **E2E in clean workspace `poc_ws_0808c`** | 🏗️ pending |

### Sprint 11 plan — dual S3 source + index metadata fields
Goal: read source files either via the existing **Fabric S3 shortcut** or **directly from S3**
(config switch), without adding package dependencies; and add a **folder-path** field (plus other
useful metadata) to the Search index. Then run the E2E in a clean workspace.

| # | Task | Status |
| --- | --- | --- |
| 11.1 | **Dual source abstraction** — `source_mode = s3_shortcut \| s3_direct`; a small source interface (`list_files()` / `read_bytes()`) with two implementations selected by config | ✅ done |
| 11.2 | **Direct S3 via REST + SigV4** — sign requests with stdlib `hashlib`/`hmac` (no `boto3`, no `%pip`); path-style addressing; `s3_endpoint_url`, `s3_bucket`, `s3_prefix`, `s3_region`, `s3_verify_tls`; keys from Key Vault secret names | ✅ done |
| 11.3 | **Stable path identity** — `file_path` = **src_key** (object path relative to the bucket root) in both modes so change-detection + `chunk_id` + ACL folder resolution behave identically; shortcut mode derives it by stripping the shortcut root | ✅ done |
| 11.4 | **Index metadata fields** — added `folder_path` (filterable/facetable) + `file_size`, `last_modified` from source listing; `author`/`last_modified_by` reserved (nullable). Updated `nb_setup_03` schema, `nb_pipeline_02` doc build, `nb_ops_04` examples | ✅ done |
| 11.5 | **E2E in clean workspace `poc_ws_0808`** — bootstrap (lakehouse, config, isolated `docs-rag-0808` index) → reset → seed → 01 → 03 → 07 (baseline **13/13**) → mutate → 01 → 03 → 07 (incremental **18/18**). Ran in **s3_direct** mode (no shortcut). **All green** | ✅ done |

### Sprint 12 — bug-fixes from the S11 E2E run
The first clean-workspace E2E (s3_direct) surfaced three real bugs; each was root-caused, fixed, and
re-verified until both phases went fully green. See the changelog for detail.

| # | Bug | Symptom | Fix | Status |
| --- | --- | --- | --- | --- |
| 12.1 | **`nb_pipeline_02` emitted a naive `last_modified`** (`2026-08-08T15:51:13`, no offset) | Azure Search rejected the whole upload batch → **400 `Cannot convert … to Edm.DateTimeOffset`** → 148 files `error`, index stayed empty, every quality/trimming check failed | Normalize `modified_datetime` to tz-aware UTC ISO-8601 (`…+00:00`) in `compute()` before `build_docs`; verified with a live single-doc upload probe | ✅ fixed |
| 12.2 | **`nb_ops_03` page-coverage self-join** on `ingestion_log` | `AnalysisException: Column file_path … are ambiguous` crashed the verifier before it could report (job `Failed`, generic `System_Cancelled_Session_Statements_Failed`) | Replace the `groupBy`+self-join with a `row_number()` window to pick the latest row per `file_path` | ✅ fixed |
| 12.3 | **`nb_ops_03` `[pN` marker check false-positive on `.txt`** | 5 `.txt` notes failed the "page N chunk contains `[pN`" check — plain-text notes have no page markers (only `multipage_pdf` injects them) | Scope the marker assertion to `.pdf` files; page-coverage (1..N) still applies to txt | ✅ fixed |

### Sprint 10 plan — E2E incremental + quality test (+ config hygiene)
Goal: a **repeatable** end-to-end test that proves the whole pipeline — incremental change detection,
that index chunks reconcile with the Delta tables, that **every source page** is represented, and that
**security trimming** returns the right documents per Entra group — plus get real endpoints out of git.

| # | Task | Status |
| --- | --- | --- |
| 10.1 | **Config hygiene** — scrub `nb_setup_02_set_config` to `<your-…>` placeholders (template); gitignore `notebooks/_local_*.ipynb` + `config/*.local.json`; real endpoints live only in the Fabric `config` table (set once via a gitignored local copy). No endpoints in the repo | ✅ done |
| 10.2 | **Differentiated ACLs** — `config/acls.json` gives distinct groups per folder (finance/reports=111, finance/policies=222, hr=333, hr/onboarding=333+444, engineering=none) so trimming returns different results per group; `acls.example.json` mirrors the model | ✅ done |
| 10.3 | **`scripts/e2e_testdata.py`** — seed ~100 deterministic docs (mix of 1/2/3-page PDFs + a few txt/docx) under `testset/**/e2e/` in S3 (additive; pre-existing objects untouched) + a manifest; `seed` reconciles to a canonical state each run (repeatable); `mutate` = modify 2/add 1/delete 1; `cleanup` | ✅ done |
| 10.4 | **`nb_ops_02_reset_clean`** — destructive clean slate: empty all pipeline Delta tables + delete every Search doc (schema kept); `CONFIRM` guard | ✅ done |
| 10.5 | **`nb_ops_03_e2e_verify`** — PASS/FAIL assertions: index↔`ingestion_state` reconciliation, full page coverage (`[pN` marker on page N, count == `ingestion_log.pages`), security trimming per group, incremental correctness (only changes reprocessed; deleted purged; modified PDF grew) | ✅ done |
| 10.6 | **`nb_ops_04_search_examples`** — how to query the index: keyword, filtered, **security-trimmed**, vector, hybrid, semantic | ✅ done |
| 10.7 | **`scripts/run_e2e_test.ps1`** — orchestrator: upload ACLs+manifest to OneLake → reset → seed → 01 → 03 → verify(baseline) → mutate → 01 → 03 → verify(incremental) → report. `run_fabric_nb.ps1` gains typed job parameters | ✅ done |
| 10.8 | **E2E run in Fabric** — orchestrator wired + validated up to `nb_ops_02_reset_clean` (Completed). Surfaced + fixed a real blocker: the Key Vault had **public network access disabled**, so the Search-key `getSecret` (used by nb_pipeline_02/05/06) 403'd — re-enabled public access on that one vault. Full baseline+incremental run **deferred to the S11 clean-workspace run** | 🏗️ deferred to S11 |


### Sprint 9 plan — scale hardening (throughput + quota visibility)
Goal: keep every Sprint 8 guarantee (correctness, restart-safety, honest state) but remove the
throughput ceilings that appear at scale — the per-file Delta rewrite (O(N²)), a single Doc
Intelligence / Azure OpenAI endpoint (429 ceiling), and invisible throttling.

| # | Task | Status |
| --- | --- | --- |
| 9.1 | **Round-robin endpoint pools** — `doc_intelligence_endpoints` / `aoai_endpoints` (comma-separated) are load-balanced per request via a thread-safe round-robin; each falls back to the singular `*_endpoint` so 1..N works unchanged. Lifts DI pages/min + AOAI embeddings TPM ~N× | ✅ done |
| 9.2 | **Batched status writes (O(N²)→O(N))** — replace per-file `.update()` with one `apply_batch` per batch: a single MERGE into `file_metadata` (status/reason/retry_count), one MERGE into `ingestion_state`, one append each to `ingestion_log`/`skipped_log`. Removes the whole-table rewrite that dominated cost | ✅ done |
| 9.3 | **Throttle/retry visibility** — `http()` records every 429/5xx/network retry + attempt-exhaustion (which endpoint host, Retry-After wait) into a thread-safe buffer, flushed once per batch to a `throttle_log` Delta table. Rate-limiting is now a queryable signal, not just reduced throughput | ✅ done |
| 9.4 | **nb_ops_01 throttle panel** — section 5b summarizes `throttle_log` by kind + endpoint host (429 counts, total backoff) so throttling is visible on the dashboard | ✅ done |
| 9.5 | **Keyless multi-endpoint auth** — one `cognitiveservices.azure.com` Entra token spans every DI + AOAI endpoint in the pools (running identity needs the Cognitive Services role on each) — no per-endpoint keys | ✅ done |
| 9.6 | **Pools wired, single endpoint each (scale-ready)** — kept 1 DI + 1 AOAI for now (pay-per-use, no standing cost); `config` carries `doc_intelligence_endpoints`/`aoai_endpoints` (empty → fall back to the singular endpoint). Scaling out is a **config-only** change: no code/redeploy | ✅ done |
| 9.7 | **E2E validation in Fabric** — code-complete; end-to-end validation folded into the Sprint 11 clean-workspace E2E run (will confirm batched status leaves 0 stranded `ingesting`, `throttle_log` behaves, `run_progress` stays live, Search count matches Σ chunks) | 🏗️ pending (S11 run) |

Config added: `doc_intelligence_endpoints`, `aoai_endpoints` (both comma-separated; empty = fall back
to the singular endpoint). New table: `throttle_log`.

**Scaling the pool later (no code change):** provision more DI/AOAI resources, grant the running
identity the Cognitive Services role on each, then set the pooled config value to the comma-separated
endpoint list, e.g.
`UPDATE config SET value='https://di-1...azure.com/,https://di-2...azure.com/' WHERE key='doc_intelligence_endpoints'`
(or edit it in nb_setup_01's `DEFAULT_CONFIG`). nb_pipeline_02 round-robins across all of them on its next run;
`throttle_log` (nb_ops_01 §5b) tells you when a given endpoint is hitting 429s and needs company.

Design note — **why not batch the AOAI calls?** Spreading embeddings across N AOAI endpoints lifts the
TPM ceiling ~N× while keeping one call per chunk-list (simpler, order-preserving, no giant-payload
risk), so pooling was chosen over request batching.

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
| 8.10 | **nb_ops_01 live panel** — section 1b renders `run_progress` while a run is in flight | ✅ done |
| 8.11 | **Clean-index E2E test** — empty index, reset queue, run drain loop, verify visibility + counts | ✅ done |
| 8.12 | **`source_missing` terminal skip** — a file deleted from S3 after nb_pipeline_01 listed it now resolves to `skipped(source_missing)` instead of a retryable `error` (state reflects reality) | ✅ done |

Config added: `batch_size=100`, `max_batches_per_run=0` (0=drain), `run_time_budget_min=0` (0=no cap).

**E2E result (105-file corpus):** live `run_progress` showed `started → running → done` with
processed/total, throughput (~4.6/min) and ETA updating in place; batched drain claimed 100 files in a
single commit; final state **86 complete → 147 chunks in AI Search (exact match), 19 skipped
(14 no_acl + 1 unsupported + 4 source_missing), 0 error, 0 stranded `ingesting`**. A follow-up run
re-claimed **only** the 4 files still needing work — proving the status-driven work queue and
stop/restart safety.

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
6. **Run in Fabric**: `nb_setup_01` → `nb_setup_03` → `nb_pipeline_01` → `nb_pipeline_02`, end-to-end.
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

### Sprint 11 + 12 — dual S3 source, index metadata, and E2E green in `poc_ws_0808`
- **Dual source mode** (`source_mode` config): read files either through the Fabric OneLake **S3
  shortcut** (`s3_shortcut`) or **directly from S3 over REST + AWS SigV4** (`s3_direct`) — no `boto3`,
  no `%pip`. Signing uses stdlib `hashlib`/`hmac`; config adds `s3_endpoint_url`, `s3_region`,
  `s3_bucket`, `s3_prefix`, `s3_addressing`, `s3_verify_tls`, `s3_access_key_secret`,
  `s3_secret_key_secret`. `nb_pipeline_01` (listing) and `nb_pipeline_02` (reads) switch on the mode; the shared source
  layer is generated once (`files/gen_source.py`) and embedded in both.
- **Stable identity across modes:** `file_path` = **src_key** (object path relative to the bucket
  root) in both modes, so change-detection, `chunk_id`, and ACL folder resolution are mode-independent.
  `config/acls.json` paths are now src_key-relative (dropped the `Files/s3_mmx_bucket/` prefix).
- **Index metadata fields:** `folder_path` (filterable/facetable), `file_size`, `last_modified`, plus
  reserved `author`/`last_modified_by`. Updated `nb_setup_03` schema, `nb_pipeline_02` `build_docs`, and `nb_ops_04`
  facet/query examples.
- **First clean-workspace E2E (`poc_ws_0808`, s3_direct)** — bootstrapped an isolated lakehouse +
  `docs-rag-0808` index; ran the full reset → baseline → mutate → incremental sequence. Final:
  **baseline 13/13, incremental 18/18** — reconciliation, full page coverage, per-group security
  trimming (g111=50, g222=10, g333=32, g444=12, g999=0, engineering excluded), and incremental
  correctness (**only the 3 changed files reprocessed**, deleted file purged, modified PDF grew to 2p).
- **Bugs found + fixed during that run (Sprint 12):**
  - *DateTimeOffset 400 (critical):* `nb_pipeline_02` sent a naive `last_modified`; Azure Search rejected the
    entire batch (`Cannot convert '2026-08-08T15:51:13' to Edm.DateTimeOffset`) so **nothing indexed**.
    Now normalized to tz-aware UTC (`…+00:00`) before upload.
  - *`nb_ops_03` self-join ambiguity:* the page-coverage "latest row per file" used a `groupBy`+self-join
    that raised `Column file_path … ambiguous` and crashed the verifier; replaced with a `row_number()`
    window.
  - *`nb_ops_03` `[pN` marker false-positive on `.txt`:* the "right text on right page" marker check only
    applies to generated PDFs (plain-text notes carry no page markers); scoped it to `.pdf`.


- **Batched drain loop** in `nb_pipeline_02`: one invocation now claims `batch_size` (100) files at a time,
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
- **`source_missing` terminal skip:** when a file was deleted from S3 after nb_pipeline_01 listed it (every
  read method reports not-found), it resolves to `skipped(source_missing)` instead of a retryable
  `error`, so it never burns retries or dead-letters.
- **Live progress in Delta:** new `run_progress` table (one row/run, throttled MVCC upsert = no file
  locks) with phase, processed/total, throughput, ETA, last file; surfaced in `nb_ops_01` section 1b.
  Fixed a latent bug where `None` fields (eta/last_file on the `started`/`done` rows) inferred
  `NullType` and silently failed the MERGE — now written with an explicit typed schema.
- **Faster claim:** the per-batch `ingesting` mark is now a **single** Delta update, not one update
  per file (was ~100 commits / several minutes just to claim a batch).
- **Job monitor:** `scripts/watch_job.ps1` reads the real server-side Fabric job status on demand
  (a stopped client poller is not a stopped job); `scripts/read_onelake_json.ps1` reads notebook diag
  dumps back from OneLake.
- **Verified end-to-end in Fabric** (105-file corpus): live visibility + 86 complete → 147 AI Search
  chunks (exact match), 19 skipped, 0 error, 0 stranded ingesting; restart re-claimed only the 4 files
  still needing work.
- Config: `batch_size` 200→100, added `max_batches_per_run=0`, `run_time_budget_min=0`. Updated
  `nb_setup_01_bootstrap`, `config_defaults.json`, `PRODUCT_SPEC.md` (§7.3, §11).

### Post-build refinements — chunking + durability
- **Chunk by page, no overlap** (per @memasanz): `nb_pipeline_02` now emits one chunk per page (splitting only
  pages that exceed `chunk_size`), matching Azure AI Search's default page chunking where
  `pageOverlapLength`=0. Removed `chunk_overlap`; raised `chunk_size` default to `8000` (page cap);
  `chunk_strategy_version`→`page-v1`. Verified with a local unit test.
- **Crash durability:** added stale-lease recovery — `ingesting` rows left by a crashed/timed-out run
  are reclaimed after `ingesting_lease_minutes` (default 120) so no file is stranded. Documented that
  status is committed per-file (incremental checkpointing) and Search uploads are batched (500/req).
- Updated `config_defaults.json`, `nb_setup_01_bootstrap`, and `PRODUCT_SPEC.md` (§6, §7.3) accordingly.

### Sprint 6 — pipelines + docs polish
- Expanded `PRODUCT_SPEC.md` §7–8: documented `nb_setup_01_bootstrap` (7.0) and `nb_pipeline_03_acl_reconcile`
  (7.4), corrected §7.3 to reflect deletion/backfill/two-phase parallelism as built (ACL drift moved
  to nb_pipeline_03), and rewrote §8 with concrete setup/pipeline/maintenance orchestration + scheduling
  (recommended `pl_ingest` = nb_pipeline_01 → nb_pipeline_02 daily; nb_setup_01/nb_setup_03 at setup; nb_pipeline_03 after ACL edits).
- Rewrote `README.md`: full Fabric notebook role table + step-by-step "Deploying to Fabric" guide.
- **Build complete** — the full notebook set + spec are in `main`. Notebooks are authored and
  JSON-validated locally; they are designed for Fabric Spark and have **not** been executed against
  live Fabric (only the S3 shortcut connectivity was verified end-to-end).

### Sprint 5 — ACL drift + bounded parallelism + backfill pacing
- Reworked `nb_pipeline_02` processing into two phases: network-heavy work (DI → embed → Search) runs in a
  bounded `ThreadPoolExecutor(max_concurrency)`, while all Delta status/state/log writes are applied
  serially on the driver to avoid optimistic-concurrency conflicts.
- Added backfill pacing: runs claim at most `batch_size` (or `backfill_batch_size` when
  `backfill_mode=true`) files per run, ordered deterministically — status-driven so a huge corpus
  ingests incrementally and resumably.
- Added `notebooks/nb_pipeline_03_acl_reconcile.ipynb`: fast path that re-stamps `allowed_groups` on existing
  Search chunks when `acls.json` changes — comparing the stored `acl_version` vs the freshly resolved
  one and merge-patching only drifted files, with **no** Doc Intelligence / embedding re-runs.
- Seeded `batch_size` / `backfill_batch_size` config defaults (bootstrap + `config_defaults.json`).

### Sprint 4 — nb_pipeline_02_ingest_to_index (core ingestion)
- Added `notebooks/nb_pipeline_02_ingest_to_index.ipynb`: works the `file_metadata` status queue end-to-end.
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

### Sprint 3 — nb_setup_03_create_search_index
- Added `notebooks/nb_setup_03_create_search_index.ipynb`: idempotent `create_or_update_index` with a
  HNSW vector field (`content_vector`), `page_number`/`chunk_index`, semantic config, and the
  `allowed_groups` collection for query-time security trimming. Admin key read from Key Vault.

### Sprint 2 — nb_pipeline_01_metadata_delta
- Added `notebooks/nb_pipeline_01_metadata_delta.ipynb`: recursive Spark-native listing of the S3 shortcut
  (`binaryFile` + `recursiveFileLookup`, column-pruned so file bytes are never read), computes a
  size+mtime `change_hash`, MERGEs into `file_metadata` driving `new`/`reingest`, refreshes
  `last_seen_utc`, and flags `deleted` via a not-matched-by-source sweep.

### Sprint 1 — data model + config + ACLs
- Added `notebooks/nb_setup_01_bootstrap.ipynb`: idempotently creates `config`, `file_metadata`,
  `ingestion_state`, `ingestion_log`, `skipped_log` delta tables and seeds config defaults
  (MERGE preserves operator overrides). Includes `load_config()` helper + ACL file validation.
- Added `config/config_defaults.json` and `config/acls.example.json`.

### Sprint 0 — repo & scaffolding
- Initialized git repo, added remote `origin` → `github.com/memasanz/aws-connect`.
- Hardened `.gitignore` (excludes venv, downloads, `.env`, credential files).
- Added `PRODUCT_SPEC.md` (full solution spec), `README.md`, this `PROGRESS.md`.
- Verified no secrets in tracked files.
