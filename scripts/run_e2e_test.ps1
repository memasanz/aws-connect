<#
  run_e2e_test.ps1 — Sprint 10 end-to-end incremental + quality test orchestrator.

  Sequence:
    1. Upload config/acls.json  -> OneLake Files/acls/acls.json      (live ACLs for this run)
    2. seed ~100 docs to S3     (e2e_testdata.py seed) + manifest
    3. Upload manifest.json     -> OneLake Files/e2e/manifest.json
    4. nb_ops_02_reset_clean        (CONFIRM=true) — wipe Delta + Search index
    5. nb_pipeline_01_scan -> nb_pipeline_02_ingest                                     (baseline ingest)
    6. nb_ops_03_e2e_verify PHASE=baseline
    7. mutate S3                (e2e_testdata.py mutate) + manifest_after
    8. Upload manifest_after.json -> OneLake Files/e2e/manifest_after.json
    9. nb_pipeline_01_scan -> nb_pipeline_02_ingest                                     (incremental)
   10. nb_ops_03_e2e_verify PHASE=incremental
   11. Read Files/_diag/e2e_result.json and print PASS/FAIL

  Repeatable: step 2 reconciles the generated corpus to a canonical state each run, and step 4 wipes
  Delta+index, so re-running yields the same result. Pre-existing testset/ objects are never touched.

  Usage:  .\scripts\run_e2e_test.ps1
          .\scripts\run_e2e_test.ps1 -SkipSeed   # reuse the corpus already in S3
#>
param(
  [string]$Workspace,
  [string]$Lakehouse,
  [string]$Python,
  [string]$OutDir = '.e2e',
  [switch]$SkipSeed
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot '_dotenv.ps1')
if (-not $Workspace) { $Workspace = $env:FABRIC_WORKSPACE_ID }
if (-not $Lakehouse) { $Lakehouse = $env:FABRIC_LAKEHOUSE_ID }
if (-not $Python)    { $Python = if ($env:E2E_PYTHON) { $env:E2E_PYTHON } else { '.\.venv\Scripts\python.exe' } }
if (-not $Workspace -or -not $Lakehouse) {
  throw "Set FABRIC_WORKSPACE_ID and FABRIC_LAKEHOUSE_ID in .env (see .env.example) or pass -Workspace/-Lakehouse."
}
Set-Location $repo
$nb = Join-Path $repo 'notebooks'

function Storage-Token { az account get-access-token --resource https://storage.azure.com --query accessToken -o tsv }

function Upload-OneLake($localPath, $relPath) {
  # Create/overwrite a file in the lakehouse Files/ via the OneLake DFS REST API (create->append->flush).
  # Uses curl.exe (robust for PUT/PATCH on Windows PowerShell). DFS requires x-ms-version and an
  # explicit Content-Length: 0 on the zero-body create + flush calls.
  $tok = Storage-Token
  $base = "https://onelake.dfs.fabric.microsoft.com/$Workspace/$Lakehouse/Files/$relPath"
  $auth = "Authorization: Bearer $tok"; $ver = 'x-ms-version: 2023-11-03'
  $len = (Get-Item $localPath).Length
  & curl.exe -sS -f -o NUL -X PUT "$base`?resource=file" -H $auth -H $ver -H 'Content-Length: 0'
  if ($LASTEXITCODE -ne 0) { throw "OneLake create failed for $relPath" }
  & curl.exe -sS -f -o NUL -X PATCH "$base`?action=append`&position=0" -H $auth -H $ver `
      -H 'Content-Type: application/octet-stream' --data-binary "@$localPath"
  if ($LASTEXITCODE -ne 0) { throw "OneLake append failed for $relPath" }
  & curl.exe -sS -f -o NUL -X PATCH "$base`?action=flush`&position=$len" -H $auth -H $ver -H 'Content-Length: 0'
  if ($LASTEXITCODE -ne 0) { throw "OneLake flush failed for $relPath" }
  Write-Host "  uploaded -> Files/$relPath ($len bytes)"
}

function Run-Nb($file, $name, $params) {
  Write-Host "== run $name ==" -ForegroundColor Cyan
  $status = & (Join-Path $PSScriptRoot 'run_fabric_nb.ps1') -Path $file -DisplayName $name -Workspace $Workspace -Lakehouse $Lakehouse -Parameters $params
  $status = ($status | Select-Object -Last 1)
  if ($status -ne 'Completed') { throw "$name did not complete (status=$status)" }
}

Write-Host '### Sprint 10 E2E test ###' -ForegroundColor Green

# 1. Live ACLs
Write-Host '== upload ACLs ==' -ForegroundColor Cyan
Upload-OneLake (Join-Path $repo 'config\acls.json') 'acls/acls.json'

# 2-3. Seed corpus + manifest
if (-not $SkipSeed) {
  Write-Host '== seed S3 corpus ==' -ForegroundColor Cyan
  & $Python (Join-Path $PSScriptRoot 'e2e_testdata.py') seed --out $OutDir
  if ($LASTEXITCODE -ne 0) { throw 'seed failed' }
}
Upload-OneLake (Join-Path $repo "$OutDir\manifest.json") 'e2e/manifest.json'

# 4. Reset
Run-Nb (Join-Path $nb 'nb_ops_02_reset_clean.ipynb') 'nb_ops_02_reset_clean' @{ CONFIRM = $true }

# 5. Baseline ingest
Run-Nb (Join-Path $nb 'nb_pipeline_01_metadata_delta.ipynb')   'nb_pipeline_01_metadata_delta'   @{}
Run-Nb (Join-Path $nb 'nb_pipeline_02_ingest_to_index.ipynb') 'nb_pipeline_02_ingest_to_index' @{}

# 6. Verify baseline
Run-Nb (Join-Path $nb 'nb_ops_03_e2e_verify.ipynb') 'nb_ops_03_e2e_verify' @{ PHASE = 'baseline' }

# 7-8. Mutate + manifest_after
Write-Host '== mutate S3 corpus ==' -ForegroundColor Cyan
& $Python (Join-Path $PSScriptRoot 'e2e_testdata.py') mutate --out $OutDir
if ($LASTEXITCODE -ne 0) { throw 'mutate failed' }
Upload-OneLake (Join-Path $repo "$OutDir\manifest_after.json") 'e2e/manifest_after.json'

# 9. Incremental ingest
Run-Nb (Join-Path $nb 'nb_pipeline_01_metadata_delta.ipynb')   'nb_pipeline_01_metadata_delta'   @{}
Run-Nb (Join-Path $nb 'nb_pipeline_02_ingest_to_index.ipynb') 'nb_pipeline_02_ingest_to_index' @{}

# 10. Verify incremental
Run-Nb (Join-Path $nb 'nb_ops_03_e2e_verify.ipynb') 'nb_ops_03_e2e_verify' @{ PHASE = 'incremental' }

# 11. Report
Write-Host '== E2E result ==' -ForegroundColor Green
& (Join-Path $PSScriptRoot 'read_onelake_json.ps1') -RelPath '_diag/e2e_result.json' -Workspace $Workspace -LakehouseGuid $Lakehouse
Write-Host 'E2E test complete.' -ForegroundColor Green
