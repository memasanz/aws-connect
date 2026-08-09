# Setup guide — S3 → Azure AI Search RAG pipeline on Microsoft Fabric

This guide walks you through standing up the pipeline **from scratch in your own Fabric
workspace**, start to finish. No prior context needed — follow it top to bottom. Set aside
about **45–60 minutes** for a first run.

By the end you'll have documents from an S3 bucket ingested into an Azure AI Search index,
chunked by page, embedded for vector search, and stamped with folder-based permissions
(`allowed_groups`, plus optional direct per-user grants in `allowed_users`) so your app can
security-trim results per user.

---

## 0. How the pieces fit (30-second tour)

```
   S3 bucket ──► nb_pipeline_01 (scan)  ──►  file_metadata (Delta)
   (your docs)        │                          │
                      ▼                          ▼
              nb_pipeline_02 (ingest): Document Intelligence → chunk by page →
              Azure OpenAI embeddings → Azure AI Search index (with allowed_groups + allowed_users)
                      │
              nb_pipeline_03 (acl_reconcile): re-stamp permissions when acls.json changes
```

Notebooks are named `nb_<role>_<NN>_<name>` so their job is obvious:

| Role | Notebooks | Run it… |
| --- | --- | --- |
| **setup** | `nb_setup_01_bootstrap`, `nb_setup_02_set_config`, `nb_setup_03_create_search_index` | once, at install |
| **pipeline** | `nb_pipeline_01_metadata_delta` (scan) → `nb_pipeline_02_ingest_to_index` (ingest) → `nb_pipeline_03_acl_reconcile` (permissions) | on a schedule / after ACL edits |
| **ops** | `nb_ops_01_status`, `nb_ops_02_reset_clean`, `nb_ops_03_e2e_verify`, `nb_ops_04_search_examples` | on demand |

---

## 1. What you need before you start

**Accounts & access**
- A **Microsoft Fabric** workspace where you can create a Lakehouse and import notebooks.
- An **Azure subscription** where you can create the resources in step 2 and assign roles.
- An **AWS S3 bucket** with the documents you want to index, plus an access key/secret that can
  read it (see step 4).

**Local tools (only needed if you want to run the automated E2E test from your machine)**
- **PowerShell 7+** (`pwsh`). PowerShell 5.1 has a bug that breaks some calls — use 7.
- Python 3.10+ with `boto3` (only for the optional E2E seeder `scripts/e2e_testdata.py`).

---

## 2. Create the Azure resources & assign roles

Auth is **hybrid**: Document Intelligence and Azure OpenAI use **keyless Entra** (Fabric mints tokens
via `notebookutils`, no keys stored); Azure AI Search uses an **admin key** read from Key Vault at
runtime (its token audience isn't issuable in Fabric).

### Option A — automated (recommended)

A Bicep template provisions everything in one shot. From a machine with the Azure CLI:

```powershell
az login
cd infra
./deploy.ps1 -ResourceGroup rg-aws-connect -Location eastus2
```

`infra/deploy.ps1` (see `infra/README.md`) creates a resource group and deploys `infra/main.bicep`,
which:

- Provisions **Key Vault**, **Document Intelligence**, **Azure OpenAI** + a `text-embedding-3-large`
  deployment, and **Azure AI Search** (RBAC/AAD data-plane enabled).
- Grants the **signed-in user** the three data-plane roles below **and** Key Vault secret *get*.
- Stores the Search **admin key** into Key Vault as `search-admin-key` for you, and adds a Key Vault
  public-network policy exemption so Fabric's `getSecret` works.
- Prints (and writes to `infra/deployment-outputs.json`) the `kv_name`, `doc_intelligence_endpoint`,
  `aoai_endpoint`, `aoai_embedding_deployment`, and `search_endpoint` values to paste into `config`.

After it finishes you still need to: add your **S3 keys** to Key Vault (step 3), and — if the identity
that *runs the Fabric notebooks* is different from the user who ran the deploy (e.g. a scheduled
pipeline's workspace identity) — grant **that** identity the same roles below.

### Option B — manual (or reference of required roles)

Create these once (any names you like), then assign the running identity the listed role:

| Resource | Why | Role to grant the identity running the notebooks |
| --- | --- | --- |
| **Azure AI Document Intelligence** | OCR / layout extraction | **Cognitive Services User** |
| **Azure OpenAI** with a `text-embedding-3-large` deployment | embeddings | **Cognitive Services OpenAI User** |
| **Azure AI Search** | the RAG index | **Search Index Data Contributor** (data plane) |
| **Azure Key Vault** | holds the S3 keys + Search admin key | **Key Vault Secrets User** (secret *get*) |

> The "identity running the notebooks" is whoever/whatever runs the Fabric jobs (your user for
> interactive runs, or the workspace identity for scheduled pipelines). Grant it all four roles.

**Important — Key Vault networking:** if your Key Vault has *public network access disabled*, Fabric's
`getSecret` will get a **403**. Either enable public access on the vault, or add a firewall exception
that lets Fabric reach it. (This one bites people — see Troubleshooting.)

---

## 3. Put your secrets in Key Vault

Create these secrets in your Key Vault (names are configurable in `config`, defaults shown):

| Secret name (default) | Value | Needed when |
| --- | --- | --- |
| `search-admin-key` | Azure AI Search **admin** key | always (auto-created by the Option A deploy) |
| `s3-access-key` | AWS access key id | only if `source_mode = s3_direct` |
| `s3-secret-key` | AWS secret access key | only if `source_mode = s3_direct` |

No secret values ever live in the repo or the `config` table — only the **secret names** do. If you
used the **Option A** Bicep deploy, `search-admin-key` is already populated — you only add the two S3
secrets here.

---

## 4. Choose how the pipeline reads S3

There are two source modes. Pick one and set `source_mode` in config accordingly.

- **`s3_direct`** (default, recommended) — **No shortcut needed.** The pipeline reads straight from
  S3 over REST + AWS **SigV4** (standard library only, no `boto3` in Fabric). Set `s3_endpoint_url`,
  `s3_region`, `s3_bucket`, `s3_prefix`, and put the S3 keys in Key Vault (step 3). **Watch the
  region** — the endpoint must match the bucket's region (e.g. `https://s3.us-east-2.amazonaws.com`),
  or S3 returns a redirect.
- **`s3_shortcut`** — In Fabric, create a **OneLake shortcut** under your Lakehouse's `Files/` that
  points at your S3 bucket (e.g. `Files/s3_mmx_bucket`). Set `shortcut_root` to that path. Fabric
  handles the S3 auth for the shortcut; you don't need the S3 keys in Key Vault.

Not sure which? `s3_direct` (the default) keeps everything in code and needs no shortcut — the
simplest path for locked-down or automated setups. Choose `s3_shortcut` if you prefer Fabric to
manage S3 auth via a shortcut.

---

## 5. First-time bootstrap checklist

Do these once, **in order**, to go from an empty workspace to a populated, secured index. Each item
links to the detailed step below.

- [ ] **① Create a Lakehouse** named `aws_connect_lh` in your Fabric workspace. *(The run scripts
      expect this exact name.)*
- [ ] **② Import the notebooks** (`notebooks/nb_*.ipynb`) into the workspace and attach them to that
      Lakehouse.
- [ ] **③ Assign Azure roles** to the running identity and **create the Key Vault secrets** (steps 2–3
      above) — do this before running anything that touches DI / Azure OpenAI / Search / S3.
- [ ] **④ Bootstrap tables:** run **`nb_setup_01_bootstrap`** → creates `config` + all Delta tables.
- [ ] **⑤ Set your config:** copy `nb_setup_02_set_config` → `_local_set_config` (gitignored), fill in
      your endpoints + `source_mode` + S3 settings + `search_index_name`, **Run All**.
- [ ] **⑥ Upload ACLs:** put your `acls.json` at `Files/acls/acls.json` (from `config/acls.example.json`).
- [ ] **⑦ Create the index:** run **`nb_setup_03_create_search_index`**.
- [ ] **⑧ First ingest:** run **`nb_pipeline_01_metadata_delta`** then **`nb_pipeline_02_ingest_to_index`**
      (set `backfill_mode=true` in `config` for the very first load).
- [ ] **⑨ Verify:** run **`nb_ops_01_status`** — confirm files are `complete` and the live Search count
      is non-zero. Optionally run the E2E test (section 8).

> **CLI shortcut (optional):** you can create the Lakehouse and run each notebook headlessly instead of
> clicking through Fabric. Create the Lakehouse with a `POST` to
> `https://api.fabric.microsoft.com/v1/workspaces/<ws-guid>/lakehouses` (body `{"displayName":"aws_connect_lh"}`),
> then run any notebook with
> `pwsh -Command "& { .\scripts\run_fabric_nb.ps1 -Path notebooks\nb_setup_01_bootstrap.ipynb -DisplayName nb_setup_01_bootstrap -Workspace <ws-guid> -Lakehouse <lakehouse-guid> }"`.

---

## 6. Install & configure (the details)

1. **Import the notebooks.** Upload every `notebooks/nb_*.ipynb` into your Fabric workspace and
   **attach them to a Lakehouse** (create one, e.g. `aws_connect_lh`). All notebooks read/write
   Delta tables in this Lakehouse.

2. **Bootstrap the tables.** Run **`nb_setup_01_bootstrap`**. It creates the `config` table (seeded
   with the defaults from the notebook's inline `DEFAULT_CONFIG`) and all the pipeline Delta tables.

3. **Point config at *your* endpoints — without committing them.** The committed
   **`nb_setup_02_set_config`** is a **template with placeholders only**. Copy it in Fabric to a
   notebook named `_local_set_config` (the `notebooks/_local_*.ipynb` pattern is **gitignored**), fill
   in your real DI / Azure OpenAI / Search endpoints, deployment names, `kv_name`, and your
   `source_mode` + S3 settings, then **Run All**. This writes your values into the `config` Delta
   table. A `MERGE` preserves your overrides across future `nb_setup_01` re-runs, so you only do this
   once. Real endpoints live **only** in the `config` table, never in git.

   Key config values to set (full list in the `DEFAULT_CONFIG` dict in `nb_setup_01_bootstrap`):
   - `source_mode` + (`shortcut_root`) **or** (`s3_endpoint_url`, `s3_region`, `s3_bucket`, `s3_prefix`)
   - `doc_intelligence_endpoint`, `aoai_endpoint`, `aoai_embedding_deployment`, `search_endpoint`
   - `search_index_name` (e.g. `docs-rag`), `kv_name`, and the `*_secret` names if you changed them

4. **Upload your ACL map.** Put your `acls.json` at `Files/acls/acls.json` in the Lakehouse (start
   from `config/acls.example.json`). This maps folders to the Entra group object-ids allowed to see
   them (see *ACL model* below). Files in folders **not** covered by the map are **skipped** (no
   permissions = not indexed) — that's intentional.

5. **Create the search index.** Run **`nb_setup_03_create_search_index`**. It creates/upgrades the
   Azure AI Search index (HNSW vector field + `allowed_groups` + metadata fields). Re-run only when
   the schema changes.

6. **Run the pipeline.**
   - **`nb_pipeline_01_metadata_delta`** — scans the source, detects new/changed/deleted files.
   - **`nb_pipeline_02_ingest_to_index`** — extracts, chunks by page, embeds, and pushes to Search.
   - Run them **in sequence** (`01` → `02`), never concurrently. For the very first load set
     `backfill_mode=true` in config. In production, chain them in a Fabric **Data pipeline**
     (`pl_ingest` = pipeline_01 → on success → pipeline_02) on a daily/hourly schedule.

7. **When you edit `acls.json` later**, run **`nb_pipeline_03_acl_reconcile`** to re-stamp
   `allowed_groups` on already-indexed chunks — **no re-OCR, no re-embedding**, just a fast
   permissions refresh.

That's it. Your index is populated and secured.

---

## 7. Verify & operate

- **Check status any time:** run **`nb_ops_01_status`** — queue breakdown, errors, throughput,
  throttling, and the live Search document count. Section 1b shows a live progress panel while an
  ingest run is in flight.
- **Query the index:** open **`nb_ops_04_search_examples`** for copy-paste patterns: keyword,
  filtered, **security-trimmed** (pass the caller's Entra group ids into the filter), vector, hybrid,
  and semantic search.

### ACL model (how security trimming works)
`acls.json` lists folders → allowed Entra group object-ids, resolved by **nearest ancestor** (a
subfolder entry overrides its parent). During ingest, every chunk is stamped with the resolved
`allowed_groups`. At query time your app passes the signed-in user's group ids into the Search filter
(`allowed_groups/any(g: search.in(g, '<comma-separated ids>'))`), so users only see what they're
allowed to. The index and trimming mechanics are under your control; Entra membership resolution
happens in your app.

---

## 8. (Optional) Run the automated end-to-end test

Want proof the whole thing works before trusting it? The repo ships a self-checking E2E test.

1. In Fabric, make sure `nb_ops_02_reset_clean`, `nb_ops_03_e2e_verify`, and the pipeline notebooks
   are imported and attached to your Lakehouse.
2. From your machine (PowerShell 7):
   ```powershell
   pwsh -Command "& { .\scripts\run_e2e_test.ps1 -Workspace <ws-guid> -Lakehouse <lakehouse-guid> }"
   ```
   It resets to a clean slate, seeds ~100 docs into S3 under `testset/`, runs a **baseline** ingest +
   verify, then **mutates** the corpus (modify/add/delete) and runs an **incremental** ingest +
   verify. `nb_ops_03_e2e_verify` asserts (PASS/FAIL): index↔Delta reconciliation, full page coverage,
   security trimming per group, and incremental correctness (only changes reprocessed, deletes purged).

> ⚠️ `nb_ops_02_reset_clean` is **destructive** — it empties the pipeline tables and the Search index.
> Only use it in a test/dev workspace.

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| `getSecret` returns **403** | Key Vault public network access disabled | Enable public access, or add a firewall exception so Fabric can reach the vault |
| Index stays **empty**, files show `error` with `Cannot convert … to Edm.DateTimeOffset` | (already fixed in `nb_pipeline_02`) naive timestamp rejected by Search | Ensure you're on the current notebooks; `last_modified` is normalized to tz-aware UTC before upload |
| S3 returns a **redirect** / wrong-region error (`s3_direct`) | `s3_endpoint_url` region ≠ bucket region | Set `s3_endpoint_url` to the bucket's region, e.g. `https://s3.us-east-2.amazonaws.com` |
| Files silently **skipped**, not indexed | Their folder isn't in `acls.json` (`no_acl`) | Add the folder → groups mapping to `Files/acls/acls.json` and re-run pipeline_01 → pipeline_02 |
| Search calls **401/403** | AI Search needs the admin key from Key Vault (Fabric can't mint a Search-audience token) | Put the admin key in `search-admin-key` and grant Key Vault secret *get* |
| Scripted run throws NullReference on a POST | Running under **PowerShell 5.1** | Use PowerShell 7 (`pwsh`) |
| A just-added/deleted S3 file isn't picked up | OneLake shortcut propagation lag (shortcut mode) | Re-run `nb_pipeline_01_metadata_delta` |

---

## 10. Where things live

- **Notebooks:** `notebooks/nb_<role>_<NN>_<name>.ipynb`
- **Config defaults / template:** `nb_setup_01_bootstrap` (inline `DEFAULT_CONFIG`), `notebooks/nb_setup_02_set_config.ipynb`
- **ACL example:** `config/acls.example.json`
- **Architecture & data model:** `PRODUCT_SPEC.md`
