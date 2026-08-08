<#
  Helper: import a local .ipynb into Fabric (bound to aws_connect_lh), run it, poll to completion.
  Usage:  .\scripts\run_fabric_nb.ps1 -Path notebooks\nb_setup_01_bootstrap.ipynb -DisplayName nb_setup_01_bootstrap
  Prints the final job status. Reuses an existing item of the same displayName if present.
#>
param(
  [Parameter(Mandatory=$true)][string]$Path,
  [Parameter(Mandatory=$true)][string]$DisplayName,
  [string]$Workspace = 'ef1eda73-0a00-4ad0-80b2-5eccf9a98a5f',
  [string]$Lakehouse = '35f024b6-9a0e-44b0-9c3b-3a43260c8f51',
  [hashtable]$Parameters,
  [switch]$SkipRun
)
$ErrorActionPreference = 'Stop'
function Fab-Token { az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv }

$tok = Fab-Token
$hdr = @{ Authorization = "Bearer $tok"; 'Content-Type' = 'application/json' }

# Bind default lakehouse so /lakehouse/default and spark.table(config) resolve.
$dep = @{ default_lakehouse = $Lakehouse; default_lakehouse_name = 'aws_connect_lh'; default_lakehouse_workspace_id = $Workspace }
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
