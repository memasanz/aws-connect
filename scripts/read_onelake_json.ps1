<#
  Read a JSON file from OneLake (lakehouse Files/) via the DFS REST endpoint.
  Used to pull back diagnostic dumps (e.g. Files/_diag/status.json) written by a Fabric notebook,
  since batch job runs do not surface display()/stdout.

  Usage: .\scripts\read_onelake_json.ps1 -RelPath _diag/status.json
#>
param(
  [string]$RelPath = '_diag/status.json',
  [string]$Workspace = 'ef1eda73-0a00-4ad0-80b2-5eccf9a98a5f',
  [string]$LakehouseGuid = '35f024b6-9a0e-44b0-9c3b-3a43260c8f51'
)
$ErrorActionPreference = 'Stop'
$tok = az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv
$uri = "https://onelake.dfs.fabric.microsoft.com/$Workspace/$LakehouseGuid/Files/$RelPath"
$r = Invoke-WebRequest -Method Get -Uri $uri -Headers @{ Authorization = "Bearer $tok" }
[Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
