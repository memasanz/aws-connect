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
| `nb_00_bootstrap` | Create delta tables (`config`, `file_metadata`, `ingestion_state`, `ingestion_log`, `skipped_log`) + seed config | Once, at setup / config change |
| `nb_01_metadata_delta` | Recursive S3-shortcut scan → change detection → `file_metadata` (new/reingest/deleted) | **Pipeline 1**, scheduled |
| `nb_02_create_search_index` | Create/upgrade the Azure AI Search index (HNSW vector + `allowed_groups`) | Once / on schema change |
| `nb_03_ingest_to_index` | Status-queue ingestion: ACL gate → Doc Intelligence → chunk → embed → Search; deletions, retries | **Pipeline 2**, scheduled |
| `nb_04_acl_reconcile` | Re-stamp `allowed_groups` on ACL drift without re-ingesting | On-demand, after editing `acls.json` |

## Deploying to Fabric

1. Import the `notebooks/*.ipynb` into your Fabric workspace and attach them to a lakehouse
   (this build used `aws_connect_lh`).
2. Create an S3 shortcut under `Files/` pointing at your bucket (this build: `Files/s3_mmx_bucket`).
3. Store DI / Azure OpenAI / AI Search keys in Key Vault and set the `kv_*`, endpoint, and
   deployment values in the `config` table (`nb_00_bootstrap` seeds defaults from
   `config/config_defaults.json`).
4. Upload your `acls.json` to `Files/acls/acls.json` (see `config/acls.example.json`).
5. Run `nb_00_bootstrap`, then `nb_02_create_search_index`.
6. Build pipeline `pl_ingest` = [`nb_01_metadata_delta` → `nb_03_ingest_to_index`] and schedule it.
   For the first load set `backfill_mode=true` in `config`.

See `PRODUCT_SPEC.md` for the architecture, data model, ACL model, and scale/parallelism strategy.

## Local S3 demo

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
# configure a scoped, non-root access key as a named CLI profile:
aws configure --profile s3-bucket
jupyter notebook s3_pdf_demo.ipynb
```

## Security

- No credentials are stored in this repo. Secrets live in the AWS CLI profile / Azure Key Vault.
- `.gitignore` excludes `.venv/`, `downloads/`, `.env`, and common credential files.
