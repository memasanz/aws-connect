# Infrastructure

Deployment scripts for the Azure resources the Fabric ingestion solution needs.

## Authentication model — keyless (Entra ID)

This subscription enforces `disableLocalAuth=true` on Cognitive Services via an Azure Policy
(Modify effect), so **API keys are not usable** — attempting to list/use them is blocked and any
manual override reverts. The solution therefore uses **keyless Entra ID auth** end-to-end:

- The Fabric notebooks authenticate with `azure-identity`'s `DefaultAzureCredential`.
- `main.bicep` grants the notebook-running identity the required **data-plane RBAC roles**:

  | Service | Role | Role ID |
  | --- | --- | --- |
  | Document Intelligence | Cognitive Services User | `a97b65f3-24c7-4388-baec-2e87618e0e56` |
  | Azure OpenAI | Cognitive Services OpenAI User | `5e0bd9bd-7b93-4f28-af87-19fc36ad61bd` |
  | Azure AI Search | Search Index Data Contributor | `8ebe5a00-799e-43f5-93ac-243d3dce84a7` |

- Azure AI Search is provisioned with `authOptions.aadOrApiKey` + `aadAuthFailureMode=http403`
  so it accepts Entra tokens.

No service keys are stored anywhere.

## What gets deployed (`main.bicep`)

| Resource | Purpose |
| --- | --- |
| **Key Vault** | Retained for any non-service secrets. No service keys are stored (keyless auth). |
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
