# `scripts/` — developer & test tooling

Helper scripts for running the Fabric notebooks headlessly, driving the end-to-end (E2E) test, and
generating its test corpus. **None of these are part of the production pipeline** — the pipeline is
the `notebooks/nb_*.ipynb` set. These scripts are for setup automation, testing, and debugging from
a developer machine.

## Prerequisites

- **PowerShell 7+** (`pwsh`) and the **Azure CLI** (`az login`) for the `*.ps1` scripts — they call
  the Fabric / OneLake REST APIs with your Entra token.
- The repo **`.venv`** (Python 3.10+) with `boto3` + the doc-builder deps (`reportlab`, `python-docx`,
  `python-pptx`, `openpyxl`) for the Python scripts. See `requirements.txt`.
- A repo-root **`.env`** (gitignored; copy `.env.example`) with your `FABRIC_WORKSPACE_ID`,
  `FABRIC_LAKEHOUSE_ID`, `FABRIC_LAKEHOUSE_NAME`, and `E2E_PYTHON`. The PowerShell scripts read this
  so workspace/lakehouse GUIDs aren't hardcoded.

## Scripts at a glance

| Script | Language | What it does | When you'd use it |
| --- | --- | --- | --- |
| `run_e2e_test.ps1` | PowerShell | **Top-level E2E orchestrator.** Uploads `config/acls.json`, seeds the corpus, then runs reset → baseline ingest+verify → mutate → incremental ingest+verify, and prints the PASS/FAIL result. | Prove the whole pipeline works end-to-end in a workspace. |
| `run_fabric_nb.ps1` | PowerShell | **Run one notebook headlessly.** Imports (or updates) a local `.ipynb` into the workspace, binds the default lakehouse, starts a `RunNotebook` job, and polls to completion. | Run/re-run a single notebook without opening Fabric; the E2E calls this per step. |
| `watch_job.ps1` | PowerShell | **Read a notebook job's server-side status** (latest instances, or `-Follow` a running one). The job keeps running even if you stop watching. | Check on a long ingest, or confirm a job's real state independent of any client poller. |
| `read_onelake_json.ps1` | PowerShell | **Read a JSON file from the lakehouse `Files/`** via the OneLake DFS API. | Pull back diagnostic dumps a notebook wrote (e.g. `Files/_diag/e2e_result.json`) since headless jobs don't surface `display()`/stdout. |
| `e2e_testdata.py` | Python | **Seed / mutate / clean the E2E corpus in S3** and write the `manifest.json` ground truth the verify notebook asserts against. Defines the corpus `LAYOUT` (folders → ACL groups/users → file types/counts). | Generate or reset the ~100-file test corpus; edit `LAYOUT`/ACLs when changing test coverage. |
| `gen_testdocs.py` | Python | **Deterministic document builders** (multi-page PDFs with page markers, plus docx/pptx/xlsx/html/md, each with a known author). Imported by `e2e_testdata.py`. | You don't run this directly; edit it to change what a generated test file looks like. |
| `s3_rest.py` | Python | **Reference stdlib-only S3 client** (list/get over REST + AWS SigV4, no `boto3`). The function bodies are embedded verbatim into `nb_pipeline_01/02` for `source_mode=s3_direct`. | The source of truth for the pipeline's S3 code; test/iterate on SigV4 locally before regenerating notebooks. |
| `_dotenv.ps1` | PowerShell | **Shared helper** — loads `.env` into the process (real env vars win). Dot-sourced by the other `*.ps1`. | Not run directly. |

## Common usage

**Run the full E2E** (workspace/lakehouse from `.env`):

```powershell
pwsh ./scripts/run_e2e_test.ps1                 # regenerate + seed the corpus, then run
pwsh ./scripts/run_e2e_test.ps1 -SkipSeed       # reuse the corpus already in S3 (faster reruns)
```

**Run a single notebook headlessly:**

```powershell
pwsh ./scripts/run_fabric_nb.ps1 `
  -Path notebooks/nb_setup_03_create_search_index.ipynb `
  -DisplayName nb_setup_03_create_search_index
```

**Manage the test corpus directly** (without running the notebooks):

```powershell
.\.venv\Scripts\python.exe scripts/e2e_testdata.py seed      # reconcile corpus to canonical state in S3
.\.venv\Scripts\python.exe scripts/e2e_testdata.py mutate    # apply the incremental change set
.\.venv\Scripts\python.exe scripts/e2e_testdata.py cleanup   # delete only the generated (e2e/) keys
```

**Watch a running job / read a diagnostic file:**

```powershell
pwsh ./scripts/watch_job.ps1 -Follow
pwsh ./scripts/read_onelake_json.ps1 -RelPath '_diag/e2e_result.json' `
  -Workspace <ws-guid> -LakehouseGuid <lakehouse-guid>
```

> **Safety:** the E2E's reset step (`nb_ops_02_reset_clean`) is **destructive** — it empties the
> pipeline Delta tables and the Search index. Only run the E2E against a test/dev workspace. The
> corpus seeder is additive: it only touches keys under `testset/**/e2e/` and never deletes your
> pre-existing `testset/` objects.

See `../SETUP.md` for the full setup guide and `../PRODUCT_SPEC.md` for the architecture.
