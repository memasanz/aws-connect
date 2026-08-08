# Infrastructure

Deployment scripts for the Azure resources the Fabric ingestion solution needs.

## Authentication model — hybrid (keyless Entra + one Key Vault secret)

This subscription enforces `disableLocalAuth=true` on Cognitive Services via an Azure Policy
(Modify effect), so **their API keys are not usable**. Azure AI Search is *not* under that policy but
Fabric cannot mint a Search-audience Entra token, so the solution uses a **hybrid** model:

- **Document Intelligence & Azure OpenAI** — keyless Entra. In Fabric the notebooks obtain a token
  via `notebookutils.credentials.getToken(...)`; `main.bicep` grants the notebook-running identity
  the required **data-plane RBAC roles**:

  | Service | Role | Role ID |
  | --- | --- | --- |
  | Document Intelligence | Cognitive Services User | `a97b65f3-24c7-4388-baec-2e87618e0e56` |
  | Azure OpenAI | Cognitive Services OpenAI User | `5e0bd9bd-7b93-4f28-af87-19fc36ad61bd` |
  | Azure AI Search | Search Index Data Contributor | `8ebe5a00-799e-43f5-93ac-243d3dce84a7` |

- **Azure AI Search** — an **admin key** stored in Key Vault (`search-admin-key`), read at runtime
  via `getSecret`. Search is still provisioned with `authOptions.aadOrApiKey` +
  `aadAuthFailureMode=http403`.
- **S3 (source)** — for `source_mode=s3_direct`, the AWS access/secret keys live in Key Vault
  (`s3-access-key` / `s3-secret-key`); you add those yourself after deploy.

Only the Search admin key and the S3 keys live in Key Vault; no Cognitive Services keys are stored.

## What gets deployed (`main.bicep`)

| Resource | Purpose |
| --- | --- |
| **Key Vault** | Holds the AI Search admin key (auto-seeded) + your S3 keys. Includes a public-network policy exemption so Fabric `getSecret` works. |
| **Document Intelligence** (`FormRecognizer`, S0) | Extracts text + page numbers from documents. |
| **Azure OpenAI** (Foundry, S0) + `text-embedding-3-large` deployment | Vectorizes chunks. |
| **Azure AI Search** (`basic`, RBAC-enabled) | Stores vectorized chunks + `allowed_groups` for security-trimmed RAG. |

## Deploy

```powershell
az login
cd infra
./deploy.ps1 -ResourceGroup rg-aws-connect -Location eastus2
```

The script resolves the signed-in user's object id, deploys the Bicep (which grants that identity the
data-plane roles above and Key Vault `get/list/set`), and prints the values to set in the Fabric
`config` table. It also writes `deployment-outputs.json` (git-ignored).

> **Cost note:** AI Search `basic`, Azure OpenAI, and Document Intelligence are billable. Tear down
> with `az group delete -n rg-aws-connect` when finished.

## Regions

- **Cognitive Services + Key Vault** default to `eastus2` (`-Location`): `text-embedding-3-large`
  and Document Intelligence `prebuilt-layout` are both available there.
- **Azure AI Search** deploys to a separate `searchLocation` (default `westus3`) because `eastus2`
  can be out of Search capacity. Cross-region calls between the services are fine.

## Feeding config into Fabric

After deploy, set these in the `config` delta table (overriding `nb_setup_01` seeds):
`kv_name`, `doc_intelligence_endpoint`, `aoai_endpoint`, `aoai_embedding_deployment`,
`search_endpoint`.
