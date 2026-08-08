# aws-connect

Tooling and a Microsoft Fabric solution for ingesting files from an Amazon S3 bucket into an
**Azure AI Search** index for RAG, governed by folder-based **ACLs** mapped to Entra ID groups.

## Contents

| Path | Purpose |
| --- | --- |
| `PRODUCT_SPEC.md` | Full product specification for the Fabric S3 → AI Search ingestion solution |
| `PROGRESS.md` | Live build status / changelog (updated as work proceeds) |
| `s3_pdf_demo.ipynb` | Standalone demo: connect to S3 with boto3, read a PDF, inspect metadata |
| `s3-rw-policy.json` | Example least-privilege IAM policy (read/write, single bucket) |
| `requirements.txt` | Python deps for the local demo (`boto3`, `jupyter`, `pypdf`) |
| `notebooks/` | Fabric notebooks — see the notebook table below |
| `config/` | Example `acls.json` and `config` defaults |

## Fabric notebooks

| Notebook | Role | When it runs |
| --- | --- | --- |
| `nb_00_bootstrap` | Create delta tables (`config`, `file_metadata`, `ingestion_state`, `ingestion_log`, `skipped_log`, `run_progress`, `throttle_log`) + seed config | Once, at setup / config change |
| `nb_00b_set_config` | **Template** to point config at your endpoints (placeholders only — copy to a gitignored `_local_` notebook and fill real values) | Once, after `nb_00` |
| `nb_01_metadata_delta` | Recursive source scan (S3 shortcut **or** direct S3) → change detection → `file_metadata` (new/reingest/deleted) | **Pipeline 1**, scheduled |
| `nb_02_create_search_index` | Create/upgrade the Azure AI Search index (HNSW vector + `allowed_groups`) | Once / on schema change |
| `nb_03_ingest_to_index` | Status-queue ingestion: ACL gate → Doc Intelligence → chunk → embed → Search; deletions, retries; **endpoint pools + batched writes + throttle log** | **Pipeline 2**, scheduled |
| `nb_04_acl_reconcile` | Re-stamp `allowed_groups` on ACL drift without re-ingesting | On-demand, after editing `acls.json` |
| `nb_05_status` | Read-only status dashboard (queue, errors, throughput, throttling, live Search count) | On-demand |
| `nb_06_reset_clean` | **Destructive** — wipe all pipeline Delta tables + empty the Search index (E2E clean slate) | E2E test only |
| `nb_07_e2e_verify` | PASS/FAIL E2E assertions: index↔Delta reconciliation, page coverage, security trimming, incremental correctness | E2E test only |
| `nb_08_search_examples` | How to query the index: keyword / filtered / **security-trimmed** / vector / hybrid / semantic | Reference |

## Deploying to Fabric

1. Import the `notebooks/*.ipynb` into your Fabric workspace and attach them to a lakehouse
   (this build used `aws_connect_lh`).
2. **Pick a source mode** (config `source_mode`):
   - `s3_shortcut` (default) — create an S3 shortcut under `Files/` pointing at your bucket
     (this build: `Files/s3_mmx_bucket`).
   - `s3_direct` — **no shortcut needed**; the pipeline reads straight from S3 over REST + AWS SigV4
     (stdlib only, no `boto3`). Set `s3_endpoint_url`, `s3_region`, `s3_bucket`, `s3_prefix`, and the
     Key Vault secret names `s3_access_key_secret` / `s3_secret_key_secret`. See *Source modes* below.
3. Store DI / Azure OpenAI / AI Search keys in Key Vault and set the `kv_*`, endpoint, and
   deployment values in the `config` table (`nb_00_bootstrap` seeds defaults from
   `config/config_defaults.json`).
4. **Set endpoints without committing them:** in Fabric, copy `nb_00b_set_config` to a
   `_local_set_config` notebook (the `notebooks/_local_*.ipynb` name is gitignored), fill in your real
   endpoints, and Run All. The committed `nb_00b` is a **placeholders-only template** — real endpoints
   live only in the `config` Delta table, never in git. See *Config hygiene* below.
5. Upload your `acls.json` to `Files/acls/acls.json` (see `config/acls.example.json`).
6. Run `nb_00_bootstrap`, then `nb_02_create_search_index`.
7. Build pipeline `pl_ingest` = [`nb_01_metadata_delta` → `nb_03_ingest_to_index`] and schedule it.
   For the first load set `backfill_mode=true` in `config`.

See `PRODUCT_SPEC.md` for the architecture, data model, ACL model, and scale/parallelism strategy.

## Source modes (S3 shortcut or direct S3)

The pipeline reads source files one of two ways, selected by the `source_mode` config key — the rest
of the pipeline (change detection, ACLs, chunking, indexing) is identical either way:

| `source_mode` | How files are read | Needs a shortcut? | Extra config |
| --- | --- | --- | --- |
| `s3_shortcut` (default) | Fabric OneLake S3 shortcut under `Files/` (`shortcut_root`) via `binaryFile` | Yes | `shortcut_root` |
| `s3_direct` | Directly from S3 over REST + **AWS SigV4** (stdlib `hashlib`/`hmac`, no `boto3`, no `%pip`) | No | `s3_endpoint_url`, `s3_region`, `s3_bucket`, `s3_prefix`, `s3_addressing` (`path`\|`virtual`), `s3_verify_tls`, `s3_access_key_secret`, `s3_secret_key_secret` |

`s3_direct` works with any S3-compatible endpoint (AWS, Cohesity, MinIO, …). File **identity is the
same in both modes** — `file_path` is the *src_key* (object path relative to the bucket root) — so you
can switch modes without changing ACLs or the change-detection scheme. Keys for `s3_direct` are read
from Key Vault by the secret **names** above (never committed).

**Index metadata:** each chunk also carries `folder_path` (filterable/facetable), `file_size`, and
`last_modified` (plus reserved `author`/`last_modified_by`) for folder faceting and filtering.

## Config hygiene (endpoints are not committed)

Service **endpoints and resource names are not stored in this repo** — only `<your-…>` placeholders.
Real values live solely in the Fabric `config` Delta table:

- `nb_00b_set_config.ipynb` is a **template**. Copy it to `notebooks/_local_set_config.ipynb`
  (gitignored via `notebooks/_local_*.ipynb`), fill real endpoints, and run once. The `config` table
  MERGE preserves operator overrides across `nb_00` re-runs, so you only set them once.
- `config/*.local.json` is gitignored for an optional local values file.
- Because Fabric headless jobs can't reliably read arbitrary OS environment variables, the config
  table (plus Key Vault for secrets) is the intended config mechanism — not `.env`/env vars.

## End-to-end test

`scripts/run_e2e_test.ps1` runs a repeatable, self-asserting end-to-end test:

1. Uploads `config/acls.json` to OneLake and seeds ~100 generated docs (mix of 1/2/3-page PDFs, a few
   txt/docx) under `testset/**/e2e/` in S3 — **additive**; pre-existing `testset/` objects are never
   touched.
2. `nb_06_reset_clean` wipes Delta tables + the Search index.
3. `nb_01 → nb_03` ingest (baseline), then `nb_07_e2e_verify PHASE=baseline`.
4. Mutates the corpus (modify 2, add 1, delete 1), `nb_01 → nb_03` again, then
   `nb_07_e2e_verify PHASE=incremental`.

`nb_07` asserts (PASS/FAIL): index↔`ingestion_state` reconciliation, **full page coverage** (every
source page represented, with the `[pN` marker on page *N*), **security trimming** per Entra group,
and **only-changes-reprocessed** on the incremental pass. Results are written to
`Files/_diag/e2e_result.json`. The seed reconciles the corpus to a canonical state each run, so it is
fully repeatable. Manage the corpus directly with `scripts/e2e_testdata.py {seed|mutate|cleanup}`.

## Concurrency model & scaling (design decision)

**`nb_03` ingests on the Spark *driver* using a bounded `ThreadPoolExecutor` (`max_concurrency`,
default 8) — it does not distribute per-file work across Spark executors.** This is a deliberate
choice, not an oversight.

**Why driver-side, not `foreachPartition`/`mapPartitions`:**
- The per-file cost is almost entirely **external-service network I/O** (Document Intelligence
  extract, Azure OpenAI embeddings, AI Search upload) — not driver CPU. The binding constraint is
  those services' **per-account rate limits**, not the number of machines.
- The driver pool acts as a single, centralized **rate controller**: bounded concurrency +
  round-robin **endpoint pools** + `throttle_log`. Distributing to N executors would multiply request
  rate by N and hit **429s** N× faster unless a *global* rate budget were reintroduced.
- All durable coordination lives in one place: Delta `MERGE` for claim/checkpoint/retry/lease, the
  self-excluding claim, stuck-file reclaim, and the single throttled `run_progress` row. Writing
  pipeline state **from executors is a Delta anti-pattern** (commit conflicts, small-file storms).
- Secrets/tokens (`getSecret`, Entra tokens) are acquired on the driver; distributing would require
  broadcasting secrets or fragile per-executor token minting.

**How to scale first (cheapest → most involved):**
1. **Measure** `throttle_log` + `run_progress.rate_per_min`. If you're already throttling at
   `max_concurrency=8`, more machines won't help — **raise service quotas / add DI+AOAI endpoints**.
2. **Turn the dials:** raise `max_concurrency` (I/O-bound threads are cheap — 32–64 is fine), add
   endpoints to the pool, use a larger driver node. The **batched drain loop** already scales file
   *count* safely (bounded `batch_size` per run, resumable across runs).
3. **Only if the driver is genuinely saturated *and* the external APIs have headroom**, refactor to a
   **structured `mapPartitions`**: the driver claims a batch up-front and distributes it; **executors
   do only the stateless work** (read → extract → chunk → embed → push to Search) and return
   lightweight result rows; **the driver performs every Delta write**. Enforce a global budget so
   `partitions × per-partition-concurrency ≤ quota`. Tracked as a Sprint 13 option.

In short: `foreachPartition` = "use the whole cluster instead of just the driver node," but it only
pays off once **service quotas — not the driver — are the ceiling**, and it trades simplicity for a
real rewrite of the state/rate-limit/secret handling.

## Required permissions

The notebooks use **keyless (Entra ID) authentication** — this subscription enforces
`disableLocalAuth=true` on Cognitive Services, so account keys are unavailable. Grant the identity
that **runs the Fabric notebooks** (the interactive user, or the workspace/pipeline identity used for
scheduled runs) these data-plane roles:

| Resource | Role | Needed by |
| --- | --- | --- |
| Document Intelligence | **Cognitive Services User** | `nb_03` (extract) |
| Azure OpenAI | **Cognitive Services OpenAI User** | `nb_03` (embeddings) |
| Azure AI Search | **Search Index Data Contributor** | `nb_02`, `nb_03`, `nb_04` (read/write index + docs) |

Additional requirements:
- **Azure AI Search must have RBAC enabled** (`authOptions` / role-based data-plane access).
- The identity needs read access to the **OneLake lakehouse** (`aws_connect_lh`) and the attached S3
  shortcut so files resolve at `/lakehouse/default/Files/...`.
- The **AWS S3 access key** (scoped, non-root) is configured on the Fabric **S3 connection**, not in
  the notebooks. Locally, the demo uses a named AWS CLI profile.

Assign the Azure roles with, e.g.:

```powershell
$oid = az ad signed-in-user show --query id -o tsv
az role assignment create --assignee $oid --role "Cognitive Services User" --scope <di-resource-id>
az role assignment create --assignee $oid --role "Cognitive Services OpenAI User" --scope <aoai-resource-id>
az role assignment create --assignee $oid --role "Search Index Data Contributor" --scope <search-resource-id>
```

## Local S3 demo

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
# configure a scoped, non-root access key as a named CLI profile:
aws configure --profile s3-bucket
jupyter notebook s3_pdf_demo.ipynb
```

## Security

- No credentials are stored in this repo. Service auth is keyless (Entra ID); the S3 key lives on the
  Fabric connection / a local AWS CLI profile.
- `.gitignore` excludes `.venv/`, `downloads/`, `.env`, `infra/deployment-outputs.json`, and common
  credential files.

