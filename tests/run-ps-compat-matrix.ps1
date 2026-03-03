param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$testScript = Join-Path $PSScriptRoot "ps-compat-smoke.ps1"
if (-not (Test-Path -LiteralPath $testScript)) {
    throw "Compatibility smoke script was not found: $testScript"
}

$targets = @(
    @{
        Label = "Windows PowerShell 5.1"
        Exe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    },
    @{
        Label = "PowerShell 7+"
        Exe = "pwsh.exe"
    }
)

$failedTargets = @()
foreach ($target in $targets) {
    $label = [string]$target.Label
    $exe = [string]$target.Exe

    Write-Host ""
    Write-Host ("=== Running compatibility matrix target: {0} ===" -f $label) -ForegroundColor Cyan

    $cmd = Get-Command $exe -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Host ("Target shell is not installed or not reachable: {0}" -f $exe) -ForegroundColor Yellow
        $failedTargets += $label
        continue
    }

    & $cmd.Source -NoProfile -ExecutionPolicy Bypass -File $testScript -RepoRoot $RepoRoot
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-Host ("Target failed: {0} (exit={1})" -f $label, $exitCode) -ForegroundColor Red
        $failedTargets += $label
    }
    else {
        Write-Host ("Target passed: {0}" -f $label) -ForegroundColor Green
    }
}

if ($failedTargets.Count -gt 0) {
    Write-Host ""
    Write-Host ("Compatibility matrix failed for: {0}" -f ($failedTargets -join ", ")) -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Compatibility matrix passed on all targets." -ForegroundColor Green
