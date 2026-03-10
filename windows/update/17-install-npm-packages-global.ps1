$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-npm-packages-global"

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
    throw "npm command was not found. NodeJS task must run before install-npm-packages-global."
}

function Test-GlobalNpmPackageInstalled {
    param([string]$PackageName)

    $packageOutput = npm -g list $PackageName --depth=0
    $packageExit = [int]$LASTEXITCODE
    $packageText = [string]($packageOutput | Out-String)
    return ($packageExit -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$packageText) -and $packageText.Contains($PackageName))
}

function Ensure-GlobalNpmPackage {
    param(
        [string]$PackageName,
        [string]$InstallSpec
    )

    if (Test-GlobalNpmPackageInstalled -PackageName $PackageName) {
        Write-Host ("Global npm package is already installed: {0}" -f $PackageName)
        return
    }

    Write-Host ("Running: npm -g install {0}" -f $InstallSpec)
    npm -g install $InstallSpec
    if ($LASTEXITCODE -ne 0) {
        throw ("npm install {0} failed with exit code {1}." -f $InstallSpec, $LASTEXITCODE)
    }

    if (-not (Test-GlobalNpmPackageInstalled -PackageName $PackageName)) {
        throw ("Global npm package '{0}' could not be verified after installation." -f $PackageName)
    }
}

Ensure-GlobalNpmPackage -PackageName "@openai/codex" -InstallSpec "@openai/codex@latest"
Ensure-GlobalNpmPackage -PackageName "@google/gemini-cli" -InstallSpec "@google/gemini-cli@latest"

Write-Host "install-npm-packages-global-completed"
Write-Host "Update task completed: install-npm-packages-global"
