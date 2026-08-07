# Build Progress

Live status of the Fabric S3 → AI Search ingestion build. Most recent entries at the top.
The agent commits + pushes to `main` at the end of each sprint so progress is visible remotely.

## Status board

| Sprint | Scope | Status |
| --- | --- | --- |
| S0 | Repo & scaffolding + `PRODUCT_SPEC.md` | 🟡 in progress |
| S1 | Delta schemas + `config` + `acls.json` | ⬜ pending |
| S2 | `nb_01_metadata_delta` (scan/change/delete) | ⬜ pending |
| S3 | `nb_02_create_search_index` | ⬜ pending |
| S4 | `nb_03_ingest_to_index` (core) | ⬜ pending |
| S5 | ACL drift + delete purge + bounded parallelism | ⬜ pending |
| S6 | Pipelines + docs | ⬜ pending |

## Fabric connectivity test
- ⏳ Attempting to create the S3 shortcut against `mmx-amazon-s3-bucket` in a Fabric lakehouse
  (using the scoped IAM access key). Result will be recorded here.

## Changelog

### Sprint 0 — repo & scaffolding
- Initialized git repo, added remote `origin` → `github.com/memasanz/aws-connect`.
- Hardened `.gitignore` (excludes venv, downloads, `.env`, credential files).
- Added `PRODUCT_SPEC.md` (full solution spec), `README.md`, this `PROGRESS.md`.
- Verified no secrets in tracked files.
