$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Host "Init task started: bootstrap-choco-system"

$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path -LiteralPath $chocoExe)) {
    Write-Host "Chocolatey not found. Installing..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1"))
}

$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path -LiteralPath $chocoExe)) {
    throw "Chocolatey setup could not be completed."
}

& $chocoExe feature enable -n allowGlobalConfirmation
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
    throw "choco feature enable allowGlobalConfirmation failed with exit code $LASTEXITCODE."
}

& $chocoExe --version
if ($LASTEXITCODE -ne 0) {
    throw "choco version check failed with exit code $LASTEXITCODE."
}

Write-Host "choco-ready"
Write-Host "Init task completed: bootstrap-choco-system"

