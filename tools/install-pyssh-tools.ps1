param(
    [string]$ToolsRoot = (Join-Path $PSScriptRoot "pyssh")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ToolsRoot)) {
    New-Item -Path $ToolsRoot -ItemType Directory -Force | Out-Null
}

$vendorDir = Join-Path $ToolsRoot "vendor"
if (-not (Test-Path -LiteralPath $vendorDir)) {
    New-Item -Path $vendorDir -ItemType Directory -Force | Out-Null
}

Write-Host "Installing/upgrading Paramiko into tools/pyssh/vendor ..."
python -m pip install --upgrade --target $vendorDir paramiko | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Paramiko install failed."
}

$clientPath = Join-Path $ToolsRoot "ssh_client.py"
if (-not (Test-Path -LiteralPath $clientPath)) {
    throw "Expected SSH client script is missing: $clientPath"
}

Write-Host ""
Write-Host "Python SSH tools are ready:"
Get-ChildItem -Path $ToolsRoot -Force | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize
