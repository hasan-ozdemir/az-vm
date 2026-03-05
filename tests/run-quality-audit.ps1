param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [switch]$SkipMatrix,
    [switch]$SkipHelpSmoke
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$results = @()

function Add-AuditResult {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail
    )

    $script:results += [pscustomobject]@{
        Name = $Name
        Passed = $Passed
        Detail = $Detail
    }
}

function Invoke-AuditStep {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    try {
        . $Action
        Add-AuditResult -Name $Name -Passed $true -Detail "ok"
        Write-Host ("[PASS] {0}" -f $Name) -ForegroundColor Green
    }
    catch {
        Add-AuditResult -Name $Name -Passed $false -Detail $_.Exception.Message
        Write-Host ("[FAIL] {0}: {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
    }
}

Invoke-AuditStep -Name "PowerShell parse (*.ps1)" -Action {
    $parseErrors = @()
    Get-ChildItem -Path $RepoRoot -Recurse -File -Filter *.ps1 | ForEach-Object {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            $first = $errors[0]
            $parseErrors += ("{0}:{1}: {2}" -f $_.FullName, $first.Extent.StartLineNumber, $first.Message)
        }
    }
    if ($parseErrors.Count -gt 0) {
        throw ($parseErrors -join "; ")
    }
}

Invoke-AuditStep -Name "Linux shell syntax (bash -n)" -Action {
    $linuxRoot = Join-Path $RepoRoot "linux"
    if (-not (Test-Path -LiteralPath $linuxRoot)) {
        Write-Host "linux directory was not found. Linux shell syntax check skipped." -ForegroundColor Yellow
        return
    }

    $wsl = Get-Command wsl -ErrorAction SilentlyContinue
    if (-not $wsl) {
        throw "WSL is not available."
    }

    $failed = @()
    Get-ChildItem -Path $linuxRoot -Recurse -File -Filter *.sh | ForEach-Object {
        $fullPath = (Resolve-Path -LiteralPath $_.FullName).Path
        $wslPath = '/mnt/' + $fullPath.Substring(0,1).ToLowerInvariant() + '/' + ($fullPath.Substring(3) -replace '\\','/')
        & $wsl.Source bash -n $wslPath
        if ($LASTEXITCODE -ne 0) {
            $failed += $fullPath
        }
    }

    if ($failed.Count -gt 0) {
        throw ("bash -n failed for: {0}" -f ($failed -join ", "))
    }
}

Invoke-AuditStep -Name "Python syntax (tools/pyssh/ssh_client.py)" -Action {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) {
        throw "python command was not found."
    }

    $clientPath = Join-Path $RepoRoot "tools\pyssh\ssh_client.py"
    if (-not (Test-Path -LiteralPath $clientPath)) {
        Write-Host "ssh_client.py was not found. Python syntax check skipped." -ForegroundColor Yellow
        return
    }

    & $python.Source -m py_compile $clientPath
    if ($LASTEXITCODE -ne 0) {
        throw "python -m py_compile failed."
    }
}

if (-not $SkipHelpSmoke) {
    Invoke-AuditStep -Name "CLI help smoke" -Action {
        $scriptPath = Join-Path $RepoRoot "az-vm.ps1"
        $ps = Get-Command powershell.exe -ErrorAction SilentlyContinue
        if (-not $ps) {
            throw "powershell.exe was not found."
        }

        $cases = @(
            @("--help"),
            @("help"),
            @("help","create"),
            @("create","--help"),
            @("delete","--help")
        )

        foreach ($case in $cases) {
            $out = & $ps.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath @case 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ("help smoke failed for args: {0}" -f ($case -join " "))
            }
            $joined = (@($out) | ForEach-Object { [string]$_ }) -join "`n"
            if ([string]::IsNullOrWhiteSpace($joined)) {
                throw ("help smoke returned empty output for args: {0}" -f ($case -join " "))
            }
        }
    }
}

if (-not $SkipMatrix) {
    Invoke-AuditStep -Name "PS compatibility matrix" -Action {
        $matrixPath = Join-Path $RepoRoot "tests\run-ps-compat-matrix.ps1"
        & powershell -NoProfile -ExecutionPolicy Bypass -File $matrixPath -RepoRoot $RepoRoot
        if ($LASTEXITCODE -ne 0) {
            throw "run-ps-compat-matrix.ps1 failed."
        }
    }
}

Write-Host ""
Write-Host "Quality audit summary:" -ForegroundColor Cyan
$results | ForEach-Object {
    $status = if ($_.Passed) { "PASS" } else { "FAIL" }
    Write-Host ("- [{0}] {1}: {2}" -f $status, $_.Name, $_.Detail)
}

$failedCount = @($results | Where-Object { -not $_.Passed }).Count
if ($failedCount -gt 0) {
    exit 1
}
