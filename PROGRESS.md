# Build Progress

Live status of the Fabric S3 → AI Search ingestion build. Most recent entries at the top.
The agent commits + pushes to `main` at the end of each sprint so progress is visible remotely.

## Status board

| Sprint | Scope | Status |
| --- | --- | --- |
| S0 | Repo & scaffolding + `PRODUCT_SPEC.md` | ✅ done |
| S1 | Delta schemas + `config` + `acls.json` | ✅ done |
| S2 | `nb_01_metadata_delta` (scan/change/delete) | ✅ done |
| S3 | `nb_02_create_search_index` | ⬜ pending |
| S4 | `nb_03_ingest_to_index` (core) | ⬜ pending |
| S5 | ACL drift + delete purge + bounded parallelism | ⬜ pending |
| S6 | Pipelines + docs | ⬜ pending |

## Fabric connectivity test
- ✅ **S3 shortcut created and verified end-to-end.**
  - Workspace: `workspace_FABRIC` (`ef1eda73-0a00-4ad0-80b2-5eccf9a98a5f`)
  - Lakehouse: `aws_connect_lh` (`35f024b6-9a0e-44b0-9c3b-3a43260c8f51`)
  - Connection: `aws-connect-s3-mmx` (`20509714-7563-4017-bc21-7a3f541b1a1a`), Amazon S3 / Basic (access key)
  - Shortcut: `Files/s3_mmx_bucket` → `https://mmx-amazon-s3-bucket.s3.us-east-2.amazonaws.com`
  - Verified via OneLake listing: `Files/s3_mmx_bucket/Fabric Data Agent.pdf` (649,958 bytes) is visible.
  - Note: bucket region is **us-east-2** (initial us-east-1 URL returned a 301).

## Changelog

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
