$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-icloud-system"

$taskConfig = [ordered]@{
    PortableWingetPath = 'C:\ProgramData\az-vm\tools\winget-x64\winget.exe'
    PackageId = '9PKTQ5699M62'
    PackageSource = 'msstore'
    DisplayNameFragments = @('icloud', 'appleinc.icloud')
    ExecutableName = 'iCloudHome.exe'
    ExecutableCandidates = @(
        'C:\Program Files\iCloud\iCloudHome.exe',
        'C:\Program Files (x86)\iCloud\iCloudHome.exe',
        'C:\Program Files\WindowsApps\AppleInc.iCloud_15.7.56.0_x64__nzyj5cx40ttqa\iCloud\iCloudHome.exe'
    )
}

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path -LiteralPath $refreshEnvCmd) {
        cmd.exe /d /c "`"$refreshEnvCmd`"" | Out-Null
    }

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace([string]$userPath)) {
        $env:Path = $machinePath
    }
    else {
        $env:Path = "$machinePath;$userPath"
    }
}

function Resolve-WingetExe {
    $portableCandidate = [string]$taskConfig.PortableWingetPath
    if (Test-Path -LiteralPath $portableCandidate) {
        return [string]$portableCandidate
    }

    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        return [string]$cmd.Source
    }

    return ''
}

function Test-ICloudNameMatch {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return $false
    }

    $normalizedValue = $Value.Trim().ToLowerInvariant()
    foreach ($fragment in @($taskConfig.DisplayNameFragments)) {
        $normalizedFragment = [string]$fragment
        if ([string]::IsNullOrWhiteSpace([string]$normalizedFragment)) {
            continue
        }

        if ($normalizedValue.Contains($normalizedFragment.Trim().ToLowerInvariant())) {
            return $true
        }
    }

    return $false
}

function Resolve-ICloudExeFromAppxPackage {
    $packages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {
        Test-ICloudNameMatch -Value ([string]$_.Name) -or
        Test-ICloudNameMatch -Value ([string]$_.PackageFamilyName)
    })

    foreach ($package in @($packages)) {
        $installLocation = [string]$package.InstallLocation
        if ([string]::IsNullOrWhiteSpace([string]$installLocation) -or -not (Test-Path -LiteralPath $installLocation)) {
            continue
        }

        $directCandidate = Join-Path $installLocation ('iCloud\' + [string]$taskConfig.ExecutableName)
        if (Test-Path -LiteralPath $directCandidate) {
            return [string]$directCandidate
        }

        $flatCandidate = Join-Path $installLocation ([string]$taskConfig.ExecutableName)
        if (Test-Path -LiteralPath $flatCandidate) {
            return [string]$flatCandidate
        }

        $match = Get-ChildItem -LiteralPath $installLocation -Filter ([string]$taskConfig.ExecutableName) -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($match -and (Test-Path -LiteralPath $match.FullName)) {
            return [string]$match.FullName
        }
    }

    return ''
}

function Resolve-ICloudExe {
    $appxResolved = Resolve-ICloudExeFromAppxPackage
    if (-not [string]::IsNullOrWhiteSpace([string]$appxResolved)) {
        return [string]$appxResolved
    }

    $command = Get-Command ([string]$taskConfig.ExecutableName) -ErrorAction SilentlyContinue
    if ($command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source) -and (Test-Path -LiteralPath ([string]$command.Source))) {
        return [string]$command.Source
    }

    foreach ($candidate in @($taskConfig.ExecutableCandidates)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }

        if (Test-Path -LiteralPath $candidate) {
            return [string]$candidate
        }
    }

    return ''
}

function Test-ICloudRegistration {
    $startApps = @()
    if (Get-Command Get-StartApps -ErrorAction SilentlyContinue) {
        $startApps = @(Get-StartApps | Where-Object { Test-ICloudNameMatch -Value ([string]$_.Name) })
    }

    $packages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {
        Test-ICloudNameMatch -Value ([string]$_.Name) -or
        Test-ICloudNameMatch -Value ([string]$_.PackageFamilyName)
    })

    return (@($startApps).Count -gt 0 -or @($packages).Count -gt 0)
}

Refresh-SessionPath
$existingExe = Resolve-ICloudExe
if (-not [string]::IsNullOrWhiteSpace([string]$existingExe)) {
    Write-Host ("iCloud executable already exists: {0}" -f $existingExe)
    Write-Host "install-icloud-system-completed"
    Write-Host "Update task completed: install-icloud-system"
    return
}

$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    throw "winget command is not available."
}

Write-Host "Resolved winget executable: $wingetExe"
Write-Host ("Running: winget install --id {0} --source {1} --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --force" -f [string]$taskConfig.PackageId, [string]$taskConfig.PackageSource)
& $wingetExe install --id ([string]$taskConfig.PackageId) --source ([string]$taskConfig.PackageSource) --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --force
$installExit = [int]$LASTEXITCODE
if ($installExit -ne 0 -and $installExit -ne -1978335189) {
    throw ("winget install {0} failed with exit code {1}." -f [string]$taskConfig.PackageId, $installExit)
}

Refresh-SessionPath
$installedExe = Resolve-ICloudExe
if ([string]::IsNullOrWhiteSpace([string]$installedExe)) {
    Write-Host ("Running: winget list --id {0}" -f [string]$taskConfig.PackageId)
    $listOutput = & $wingetExe list --id ([string]$taskConfig.PackageId)
    $listText = [string]($listOutput | Out-String)
    if ([string]::IsNullOrWhiteSpace([string]$listText) -or -not ($listText.ToLowerInvariant().Contains('icloud'))) {
        if (-not (Test-ICloudRegistration)) {
            throw "iCloud install could not be verified."
        }
    }

    $installedExe = Resolve-ICloudExe
}

if (-not [string]::IsNullOrWhiteSpace([string]$installedExe)) {
    Write-Host ("icloud-home-exe => {0}" -f $installedExe)
}

Write-Host "install-icloud-system-completed"
Write-Host "Update task completed: install-icloud-system"
