<#
.SYNOPSIS
  Deploys the Azure resources for the aws-connect Fabric ingestion solution and prints the
  config values to paste into the Fabric `config` table.

.DESCRIPTION
  Creates a resource group and deploys infra/main.bicep:
    - Key Vault (holds the AI Search admin key, auto-seeded; you add S3 keys later)
    - Document Intelligence
    - Azure OpenAI (Foundry) + text-embedding-3-large deployment
    - Azure AI Search (AAD/RBAC data-plane enabled)
  Auth is HYBRID: DI and Azure OpenAI are keyless (Fabric notebooks get an Entra token via
  notebookutils); Azure AI Search uses an admin key read from Key Vault at runtime. The bicep grants
  the signed-in user the data-plane RBAC roles (Cognitive Services User, Cognitive Services OpenAI
  User, Search Index Data Contributor) plus Key Vault secret get.

.EXAMPLE
  ./deploy.ps1 -ResourceGroup rg-aws-connect -Location eastus2
#>
param(
  [string]$ResourceGroup = 'rg-aws-connect',
  [string]$Location      = 'eastus2',
  [string]$BaseName      = 'awsconn'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

Write-Host "==> Signed-in user object id"
$oid = az ad signed-in-user show --query id -o tsv
if (-not $oid) { throw 'Could not resolve signed-in user object id. Run "az login" first.' }
Write-Host "    $oid"

Write-Host "==> Resource group $ResourceGroup ($Location)"
az group create -n $ResourceGroup -l $Location -o none

Write-Host "==> Deploying infra (this provisions billable resources: AI Search, AOAI, DI, KV)"
$out = az deployment group create `
  -g $ResourceGroup `
  -f (Join-Path $here 'main.bicep') `
  -p baseName=$BaseName adminObjectId=$oid location=$Location `
  --query properties.outputs -o json | ConvertFrom-Json

Write-Host ""
Write-Host "================ DEPLOYMENT COMPLETE ================"
Write-Host "Set these in the Fabric `config` table (nb_setup_01 seeds defaults you then override):"
Write-Host ""
Write-Host ("  kv_name                     = {0}" -f $out.kvName.value)
Write-Host ("  doc_intelligence_endpoint   = {0}" -f $out.diEndpoint.value)
Write-Host ("  aoai_endpoint               = {0}" -f $out.aoaiEndpoint.value)
Write-Host ("  aoai_embedding_deployment   = {0}" -f $out.embeddingDeployment.value)
Write-Host ("  search_endpoint             = {0}" -f $out.searchEndpoint.value)
Write-Host ""
Write-Host "Auth is hybrid: DI + Azure OpenAI are keyless (Entra tokens via notebookutils); AI Search"
Write-Host "uses an admin key stored in Key Vault ('search-admin-key', auto-seeded by this deploy)."
Write-Host "Data-plane RBAC roles granted to $oid by the deployment:"
Write-Host "  DI    -> Cognitive Services User"
Write-Host "  AOAI  -> Cognitive Services OpenAI User"
Write-Host "  Search-> Search Index Data Contributor"
Write-Host "Next: add your S3 keys to Key Vault ('s3-access-key' / 's3-secret-key') for s3_direct."
Write-Host "===================================================="
$cfg = [ordered]@{
  kv_name                   = $out.kvName.value
  doc_intelligence_endpoint = $out.diEndpoint.value
  aoai_endpoint             = $out.aoaiEndpoint.value
  aoai_embedding_deployment = $out.embeddingDeployment.value
  search_endpoint           = $out.searchEndpoint.value
}
$cfgPath = Join-Path $here 'deployment-outputs.json'
$cfg | ConvertTo-Json | Set-Content -Path $cfgPath -Encoding utf8
Write-Host "Wrote $cfgPath"
