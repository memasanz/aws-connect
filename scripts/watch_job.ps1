<#
  Monitor Fabric notebook JOB status (server-side, not a client poll) — no black box.

  The RunNotebook job instance keeps a real, server-side status (NotStarted / InProgress /
  Completed / Failed / Cancelled). This script reads it on demand, so you always know whether a
  job is still running regardless of whether any earlier poller is still watching.

  Usage:
    # show the latest few job instances for nb_pipeline_02 and their status/timings
    .\scripts\watch_job.ps1

    # follow the latest running job until it reaches a terminal state (Ctrl+C to stop watching;
    # the JOB keeps running server-side even if you stop watching)
    .\scripts\watch_job.ps1 -Follow

    # monitor a specific notebook item id
    .\scripts\watch_job.ps1 -Item <notebook-guid> -Follow
#>
param(
  [string]$Workspace = 'ef1eda73-0a00-4ad0-80b2-5eccf9a98a5f',
  [string]$Item = '16537330-dfda-4f35-a0b2-b90231c9ea4b',  # nb_pipeline_02_ingest_to_index
  [switch]$Follow,
  [int]$IntervalSec = 15
)
$ErrorActionPreference = 'Stop'
function Fab-Token { az account get-access-token --resource https://api.fabric.microsoft.com --query accessToken -o tsv }

function Get-Instances {
  $tok = Fab-Token
  $h = @{ Authorization = "Bearer $tok" }
  $r = Invoke-RestMethod -Method Get -Headers $h `
        -Uri "https://api.fabric.microsoft.com/v1/workspaces/$Workspace/items/$Item/jobs/instances"
  $r.value | Sort-Object startTimeUtc -Descending
}

Write-Host "Monitoring notebook item $Item in workspace $Workspace`n"
$all = Get-Instances
if (-not $all) { Write-Host 'No job instances found for this item yet.'; return }

$all | Select-Object -First 5 |
  Select-Object status,
    @{n='startedUtc';e={$_.startTimeUtc}},
    @{n='endedUtc';e={$_.endTimeUtc}},
    @{n='instanceId';e={$_.id}} |
  Format-Table -Auto | Out-String -Width 200 | Write-Host

$latest = $all | Select-Object -First 1
if ($latest.failureReason) {
  Write-Host "`nLatest failureReason:"; ($latest.failureReason | ConvertTo-Json -Depth 6) | Write-Host
}

if (-not $Follow) {
  Write-Host "`nLatest status: $($latest.status)  (use -Follow to tail until terminal)"
  return
}

$terminal = 'Completed','Failed','Cancelled','Deduped'
$start = Get-Date
while ($true) {
  $latest = (Get-Instances | Select-Object -First 1)
  $elapsed = [int]((Get-Date) - $start).TotalSeconds
  Write-Host ("[{0,5}s] {1}" -f $elapsed, $latest.status)
  if ($latest.status -in $terminal) {
    Write-Host "`nJob reached terminal state: $($latest.status)"
    if ($latest.failureReason) { ($latest.failureReason | ConvertTo-Json -Depth 6) | Write-Host }
    Write-Host "startedUtc=$($latest.startTimeUtc)  endedUtc=$($latest.endTimeUtc)"
    Write-Host "For in-job progress (processed/total, throughput, ETA) run nb_ops_01_status -> section 1b (run_progress)."
    break
  }
  Start-Sleep -Seconds $IntervalSec
}
