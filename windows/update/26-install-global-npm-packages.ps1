$ErrorActionPreference = "Stop"
# AZ_VM_TASK_TIMEOUT_SECONDS=1800
Write-Host "Update task started: install-global-npm-packages"

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path -LiteralPath $refreshEnvCmd) {
        cmd.exe /d /c "`"$refreshEnvCmd`""
    }

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) {
        $env:Path = $machinePath
    }
    else {
        $env:Path = "$machinePath;$userPath"
    }
}

Refresh-SessionPath

if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw "npm command was not found. NodeJS task must run before install-global-npm-packages."
}

Write-Host "Running: npm -g install @openai/codex@latest"
npm -g install @openai/codex@latest
if ($LASTEXITCODE -ne 0) {
    throw "npm install @openai/codex@latest failed with exit code $LASTEXITCODE."
}

Write-Host "Running: npm -g install @google/gemini-cli@latest"
npm -g install @google/gemini-cli@latest
if ($LASTEXITCODE -ne 0) {
    throw "npm install @google/gemini-cli@latest failed with exit code $LASTEXITCODE."
}

Write-Host "Running: npm -g list --depth=0"
$npmList = npm -g list --depth=0
$npmListText = [string]($npmList | Out-String)
if ([string]::IsNullOrWhiteSpace($npmListText) -or -not $npmListText.Contains("@openai/codex")) {
    throw "Global npm package '@openai/codex' was not found in npm global list."
}
if ([string]::IsNullOrWhiteSpace($npmListText) -or -not $npmListText.Contains("@google/gemini-cli")) {
    throw "Global npm package '@google/gemini-cli' was not found in npm global list."
}

Write-Host "install-global-npm-packages-completed"
Write-Host "Update task completed: install-global-npm-packages"
