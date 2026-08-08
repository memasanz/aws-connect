<#
  Helper: import a local .ipynb into Fabric (bound to the configured lakehouse), run it, poll to completion.
  Usage:  .\scripts\run_fabric_nb.ps1 -Path notebooks\nb_setup_01_bootstrap.ipynb -DisplayName nb_setup_01_bootstrap
  Workspace/Lakehouse come from the repo-root .env (FABRIC_WORKSPACE_ID / FABRIC_LAKEHOUSE_ID /
  FABRIC_LAKEHOUSE_NAME) unless overridden with -Workspace/-Lakehouse. See .env.example.
  Prints the final job status. Reuses an existing item of the same displayName if present.
#>
param(
  [Parameter(Mandatory=$true)][string]$Path,
  [Parameter(Mandatory=$true)][string]$DisplayName,
  [string]$Workspace,
  [string]$Lakehouse,
  [string]$LakehouseName,
  [hashtable]$Parameters,
  [switch]$SkipRun
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_dotenv.ps1')
if (-not $Workspace)     { $Workspace = $env:FABRIC_WORKSPACE_ID }
if (-not $Lakehouse)     { $Lakehouse = $env:FABRIC_LAKEHOUSE_ID }
if (-not $LakehouseName) { $LakehouseName = if ($env:FABRIC_LAKEHOUSE_NAME) { $env:FABRIC_LAKEHOUSE_NAME } else { 'aws_connect_lh' } }
if (-not $Workspace -or -not $Lakehouse) {
  throw "Set FABRIC_WORKSPACE_ID and FABRIC_LAKEHOUSE_ID in .env (see .env.example) or pass -Workspace/-Lakehouse."
}
function Fab-Token { az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv }

$tok = Fab-Token
$hdr = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }

# Bind default lakehouse so /lakehouse/default and spark.table(config) resolve.
$dep = @{ default_lakehouse = $Lakehouse; default_lakehouse_name = $LakehouseName; default_lakehouse_workspace_id = $Workspace }
$j = Get-Content -Raw $Path | ConvertFrom-Json
$j.metadata | Add-Member -NotePropertyName dependencies -NotePropertyValue @{ lakehouse = $dep } -Force
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($j | ConvertTo-Json -Depth 50 -Compress)))

# Find existing item id (update) or create new.
$items = Invoke-RestMethod -Method Get -Uri "https://api.fabric.microsoft.com/v1/workspaces/$Workspace/notebooks" -Headers @{Authorization="Bearer $tok"}
$existing = $items.value | Where-Object displayName -eq $DisplayName | Select-Object -First 1
$partBody = @{ definition = @{ format = 'ipynb'; parts = @(@{ path = 'notebook-content.ipynb'; payload = $b64; payloadType = 'InlineBase64' }) } } | ConvertTo-Json -Depth 10

if ($existing) {
  $id = $existing.id
  Invoke-WebRequest -Method Post -Uri "https://api.fabric.microsoft.com/v1/workspaces/$Workspace/notebooks/$id/updateDefinition" -Headers $hdr -Body $partBody | Out-Null
  Write-Host "updated $DisplayName ($id)"
} else {
  $createBody = @{ displayName = $DisplayName; definition = @{ format = 'ipynb'; parts = @(@{ path = 'notebook-content.ipynb'; payload = $b64; payloadType = 'InlineBase64' }) } } | ConvertTo-Json -Depth 10
  Invoke-WebRequest -Method Post -Uri "https://api.fabric.microsoft.com/v1/workspaces/$Workspace/notebooks" -Headers $hdr -Body $createBody | Out-Null
  Start-Sleep -Seconds 12
  $items = Invoke-RestMethod -Method Get -Uri "https://api.fabric.microsoft.com/v1/workspaces/$Workspace/notebooks" -Headers @{Authorization="Bearer $tok"}
  $id = ($items.value | Where-Object displayName -eq $DisplayName | Select-Object -First 1).id
  Write-Host "created $DisplayName ($id)"
}

if ($SkipRun) { return }

# Build job body; include typed parameters if supplied (notebook needs a 'parameters'-tagged cell).
$runBody = '{}'
if ($Parameters -and $Parameters.Count -gt 0) {
  $p = @{}
  foreach ($k in $Parameters.Keys) {
    $v = $Parameters[$k]
    $type = if ($v -is [bool]) { 'bool' } elseif ($v -is [int]) { 'int' } else { 'string' }
    $p[$k] = @{ value = $v; type = $type }
  }
  $runBody = @{ executionData = @{ parameters = $p } } | ConvertTo-Json -Depth 8
  Write-Host "params: $runBody"
}

$tok = Fab-Token
$hdr = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }
$resp = Invoke-WebRequest -Method Post -Uri "https://api.fabric.microsoft.com/v1/workspaces/$Workspace/items/$id/jobs/instances?jobType=RunNotebook" -Headers $hdr -Body $runBody
$loc = [string]$resp.Headers['Location']
for ($i = 0; $i -lt 60; $i++) {
  Start-Sleep -Seconds 12
  $tok = Fab-Token
  $r = Invoke-RestMethod -Method Get -Uri $loc -Headers @{Authorization = "Bearer $tok"}
  Write-Host ("[{0}] {1}" -f $i, $r.status)
  if ($r.status -in 'Completed','Failed','Cancelled') {
    if ($r.failureReason) { $r.failureReason | ConvertTo-Json -Depth 6 }
    return $r.status
  }
}
Write-Host 'TIMEOUT'
