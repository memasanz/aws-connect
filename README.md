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
| `notebooks/` | Fabric notebooks (metadata, index creation, ingestion) — added per sprint |
| `config/` | Example `acls.json` and `config` defaults |

## Solution overview

```
S3 bucket ──(Fabric S3 shortcut)──► OneLake ──► [Pipeline 1: metadata delta]
                                                       │
                                                       ▼
                                          [Pipeline 2: Doc Intelligence → chunk → embed → AI Search]
```

See `PRODUCT_SPEC.md` for the architecture, data model, notebooks, pipelines, ACL model, and
scale/parallelism strategy.

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
