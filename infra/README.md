# Infrastructure

Deployment scripts for the Azure resources the Fabric ingestion solution needs.

## What gets deployed (`main.bicep`)

| Resource | Purpose |
| --- | --- |
| **Key Vault** | Stores the DI / Azure OpenAI / AI Search keys as secrets. The Fabric notebooks read them via `mssparkutils.credentials.getSecret`. |
| **Document Intelligence** (`FormRecognizer`, S0) | Extracts text + page numbers from documents. |
| **Azure OpenAI** (Foundry, S0) + `text-embedding-3-large` deployment | Vectorizes chunks. |
| **Azure AI Search** (`basic`) | Stores vectorized chunks + `allowed_groups` for security-trimmed RAG. |

Service keys are pulled at deploy time and written into Key Vault as
`doc-intelligence-key`, `aoai-key`, and `search-admin-key`.

## Deploy

```powershell
az login
cd infra
./deploy.ps1 -ResourceGroup rg-aws-connect -Location eastus2
```

The script grants the signed-in user secret `get/list/set` on the vault (the identity that runs the
Fabric notebooks interactively), deploys the Bicep, and prints the values to set in the Fabric
`config` table. It also writes `deployment-outputs.json` (git-ignored).

> **Cost note:** AI Search `basic`, Azure OpenAI, and Document Intelligence are billable. Tear down
> with `az group delete -n rg-aws-connect` when finished.

## Region

Defaults to `eastus2` because `text-embedding-3-large` and Document Intelligence `prebuilt-layout`
are both available there. Change `-Location` only to a region that offers all three services.

## Feeding config into Fabric

After deploy, set these in the `config` delta table (overriding `nb_00` seeds):
`kv_name`, `doc_intelligence_endpoint`, `aoai_endpoint`, `aoai_embedding_deployment`,
`search_endpoint`. The `kv_*_secret` names already match the vault secrets above.
