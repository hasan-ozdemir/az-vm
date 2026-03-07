$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-microsoft-vscode"

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

function Resolve-WingetExe {
    $portableCandidate = "C:\ProgramData\az-vm\tools\winget-x64\winget.exe"
    if (Test-Path -LiteralPath $portableCandidate) {
        return [string]$portableCandidate
    }

    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        return [string]$cmd.Source
    }

    return ""
}

function Resolve-CodeExecutable {
    $command = Get-Command code -ErrorAction SilentlyContinue
    if ($command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
        return [string]$command.Source
    }

    foreach ($candidate in @(
        "C:\Program Files\Microsoft VS Code\Code.exe",
        "C:\Users\__VM_ADMIN_USER__\AppData\Local\Programs\Microsoft VS Code\Code.exe",
        "C:\Users\__ASSISTANT_USER__\AppData\Local\Programs\Microsoft VS Code\Code.exe"
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return [string]$candidate
        }
    }

    return ""
}

Refresh-SessionPath
$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    throw "winget command is not available."
}

Write-Host "Resolved winget executable: $wingetExe"
Write-Host "Running: winget install vscode --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --force"
& $wingetExe install vscode --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --force
$installExit = [int]$LASTEXITCODE
if ($installExit -ne 0 -and $installExit -ne -1978335189) {
    throw "winget install vscode failed with exit code $installExit."
}

Refresh-SessionPath
$codeExe = Resolve-CodeExecutable
if ([string]::IsNullOrWhiteSpace([string]$codeExe)) {
    Write-Host "Running: winget list vscode"
    $listOutput = & $wingetExe list vscode
    $listText = [string]($listOutput | Out-String)
    if ([string]::IsNullOrWhiteSpace($listText) -or -not $listText.ToLowerInvariant().Contains("vscode")) {
        throw "Visual Studio Code install could not be verified."
    }
}

Write-Host "install-microsoft-vscode-completed"
Write-Host "Update task completed: install-microsoft-vscode"
