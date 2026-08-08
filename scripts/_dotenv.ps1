<#
  Loads KEY=VALUE lines from a repo-root .env file into the current process environment,
  so the run_* scripts don't hardcode workspace/lakehouse GUIDs. Dot-source this from a
  script: `. (Join-Path $PSScriptRoot '_dotenv.ps1')`. Existing environment variables are
  NOT overwritten (real env wins over .env). See .env.example for the supported keys.
#>
$__repoRoot = Split-Path -Parent $PSScriptRoot
$__envFile  = Join-Path $__repoRoot '.env'
if (Test-Path $__envFile) {
  foreach ($__line in Get-Content $__envFile) {
    $__t = $__line.Trim()
    if (-not $__t -or $__t.StartsWith('#') -or -not $__t.Contains('=')) { continue }
    $__i = $__t.IndexOf('=')
    $__k = $__t.Substring(0, $__i).Trim()
    $__v = $__t.Substring($__i + 1).Trim().Trim('"').Trim("'")
    if (-not [Environment]::GetEnvironmentVariable($__k)) {
      [Environment]::SetEnvironmentVariable($__k, $__v)
    }
  }
}
