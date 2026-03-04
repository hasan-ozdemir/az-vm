$ErrorActionPreference = "Stop"

$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) {
    Write-Warning "choco was not found. Extra package installs are skipped."
    Write-Output "choco-extra-packages-skipped"
    return
}

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) {
        $env:Path = $machinePath
    }
    else {
        $env:Path = "$machinePath;$userPath"
    }
}

function Install-ChocoPackageWarn {
    param(
        [string]$PackageId,
        [string]$InstallCommand,
        [string]$CommandName = "",
        [string]$PathHint = ""
    )

    Write-Output ("Running: {0}" -f $InstallCommand)
    & cmd.exe /d /c $InstallCommand | Out-Null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 2) {
        Write-Warning ("choco install failed for '{0}' with exit code {1}." -f $PackageId, $LASTEXITCODE)
        Refresh-SessionPath
        return
    }

    Refresh-SessionPath

    if (-not [string]::IsNullOrWhiteSpace($CommandName)) {
        if (Get-Command $CommandName -ErrorAction SilentlyContinue) {
            Write-Output ("Command check passed: {0}" -f $CommandName)
        }
        else {
            Write-Warning ("Command '{0}' was not found after '{1}' install." -f $CommandName, $PackageId)
        }
    }
    elseif (-not [string]::IsNullOrWhiteSpace($PathHint)) {
        if (Test-Path -LiteralPath $PathHint) {
            Write-Output ("Path check passed: {0}" -f $PathHint)
        }
        else {
            Write-Warning ("Path '{0}' was not found after '{1}' install." -f $PathHint, $PackageId)
        }
    }
}

Install-ChocoPackageWarn -PackageId "ollama" -InstallCommand "choco install ollama -y --no-progress" -CommandName "ollama"
Install-ChocoPackageWarn -PackageId "sysinternals" -InstallCommand "choco install sysinternals -y --no-progress" -PathHint "C:\ProgramData\chocolatey\lib\sysinternals\tools"
Install-ChocoPackageWarn -PackageId "powershell-core" -InstallCommand "choco install powershell-core -y --no-progress" -CommandName "pwsh"
Install-ChocoPackageWarn -PackageId "io-unlocker" -InstallCommand "choco install io-unlocker -y --no-progress" -PathHint "C:\ProgramData\chocolatey\lib\io-unlocker"
Install-ChocoPackageWarn -PackageId "gh" -InstallCommand "choco install gh -y --no-progress" -CommandName "gh"
Install-ChocoPackageWarn -PackageId "ffmpeg" -InstallCommand "choco install ffmpeg -y --no-progress" -CommandName "ffmpeg"
Install-ChocoPackageWarn -PackageId "7zip" -InstallCommand "choco install 7zip -y --no-progress" -CommandName "7z"
Install-ChocoPackageWarn -PackageId "azure-cli" -InstallCommand "choco install azure-cli -y --no-progress" -CommandName "az"

Write-Output "choco-extra-packages-completed"
