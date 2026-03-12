$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-icloud-system"

$taskConfig = [ordered]@{
    TaskName = '131-install-icloud-system'
    ManagerUser = '__VM_ADMIN_USER__'
    ManagerPassword = '__VM_ADMIN_PASS__'
    HelperPath = 'C:\Windows\Temp\az-vm-interactive-session-helper.ps1'
    PortableWingetPath = 'C:\ProgramData\az-vm\tools\winget-x64\winget.exe'
    PackageId = '9PKTQ5699M62'
    PackageSource = 'msstore'
    DisplayNameFragments = @('icloud', 'appleinc.icloud')
    ExecutableName = 'iCloudHome.exe'
    InteractiveTaskSuffix = 'interactive-install'
    DeferredRunOnceName = 'AzVmInstallICloud'
    WaitTimeoutSeconds = 240
    StoreSessionErrorRegex = '(?i)0x80070520|logon session|microsoft store|msstore'
    ExecutableCandidates = @(
        'C:\Program Files\iCloud\iCloudHome.exe',
        'C:\Program Files (x86)\iCloud\iCloudHome.exe',
        'C:\Program Files\WindowsApps\AppleInc.iCloud_15.7.56.0_x64__nzyj5cx40ttqa\iCloud\iCloudHome.exe'
    )
}

$taskName = [string]$taskConfig.TaskName
$managerUser = [string]$taskConfig.ManagerUser
$managerPassword = [string]$taskConfig.ManagerPassword
$helperPath = [string]$taskConfig.HelperPath

if (-not (Test-Path -LiteralPath $helperPath)) {
    throw ("Interactive session helper was not found: {0}" -f $helperPath)
}

. $helperPath

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

function Test-ICloudInstalled {
    return ((-not [string]::IsNullOrWhiteSpace([string](Resolve-ICloudExe))) -or (Test-ICloudRegistration))
}

function Register-ICloudDeferredInstall {
    param([string]$WingetPath)

    $runOncePath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path -LiteralPath $runOncePath)) {
        New-Item -Path $runOncePath -Force | Out-Null
    }

    $commandValue = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "& ''{0}'' install --id {1} --source {2} --accept-source-agreements --accept-package-agreements --silent --disable-interactivity"' -f $WingetPath, ([string]$taskConfig.PackageId), ([string]$taskConfig.PackageSource))
    Set-ItemProperty -Path $runOncePath -Name ([string]$taskConfig.DeferredRunOnceName) -Value $commandValue -Type String
}

Refresh-SessionPath
$existingExe = Resolve-ICloudExe
if (-not [string]::IsNullOrWhiteSpace([string]$existingExe) -or (Test-ICloudRegistration)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$existingExe)) {
        Write-Host ("iCloud executable already exists: {0}" -f $existingExe)
    }
    else {
        Write-Host 'iCloud registration already exists. Skipping install.'
    }
    Write-Host "install-icloud-system-completed"
    Write-Host "Update task completed: install-icloud-system"
    return
}

$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    throw "winget command is not available."
}

Write-Host "Resolved winget executable: $wingetExe"

if (-not (Test-AzVmUserInteractiveDesktopReady -UserName $managerUser)) {
    Register-ICloudDeferredInstall -WingetPath $wingetExe
    Write-Warning "iCloud install requires an interactive desktop session. A RunOnce install was registered for the next interactive sign-in."
    Write-Host "install-icloud-system-deferred"
    Write-Host "Update task completed: install-icloud-system"
    return
}

    $workerTaskName = "{0}-{1}" -f $taskName, ([string]$taskConfig.InteractiveTaskSuffix)
    $paths = Get-AzVmInteractivePaths -TaskName $workerTaskName
$workerScript = @'
$ErrorActionPreference = "Stop"
$helperPath = "__HELPER_PATH__"
$resultPath = "__RESULT_PATH__"
$taskName = "__TASK_NAME__"
$packageId = "__PACKAGE_ID__"
$packageSource = "__PACKAGE_SOURCE__"

. $helperPath

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
    $portableCandidate = "__PORTABLE_WINGET_PATH__"
    if (Test-Path -LiteralPath $portableCandidate) {
        return [string]$portableCandidate
    }

    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        return [string]$cmd.Source
    }

    return ""
}

function Test-ICloudNameMatch {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return $false
    }

    $normalizedValue = $Value.Trim().ToLowerInvariant()
    foreach ($fragment in @('icloud', 'appleinc.icloud')) {
        if ($normalizedValue.Contains([string]$fragment)) {
            return $true
        }
    }

    return $false
}

function Test-ICloudInstalled {
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
$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    Write-AzVmInteractiveResult -ResultPath $resultPath -TaskName $taskName -Success $false -Summary 'winget command is not available.'
    exit 1
}

if (-not (Test-ICloudInstalled)) {
    $installOutput = @(& $wingetExe install --id $packageId --source $packageSource --accept-source-agreements --accept-package-agreements --silent --disable-interactivity 2>&1)
    $installExit = [int]$LASTEXITCODE
    $installText = [string]($installOutput | Out-String)
    if ($installExit -ne 0 -and $installExit -ne -1978335189) {
        Write-AzVmInteractiveResult -ResultPath $resultPath -TaskName $taskName -Success $false -Summary ("winget install failed with exit code {0}." -f $installExit) -Details @($installText)
        exit 1
    }
}

if (-not (Test-ICloudInstalled)) {
    Write-AzVmInteractiveResult -ResultPath $resultPath -TaskName $taskName -Success $false -Summary 'iCloud install could not be verified after interactive winget install.'
    exit 1
}

Write-AzVmInteractiveResult -ResultPath $resultPath -TaskName $taskName -Success $true -Summary 'iCloud is installed.'
'@

$workerScript = $workerScript.Replace('__HELPER_PATH__', $helperPath)
$workerScript = $workerScript.Replace('__RESULT_PATH__', [string]$paths.ResultPath)
$workerScript = $workerScript.Replace('__TASK_NAME__', $workerTaskName)
$workerScript = $workerScript.Replace('__PACKAGE_ID__', [string]$taskConfig.PackageId)
$workerScript = $workerScript.Replace('__PACKAGE_SOURCE__', [string]$taskConfig.PackageSource)
$workerScript = $workerScript.Replace('__PORTABLE_WINGET_PATH__', [string]$taskConfig.PortableWingetPath)

try {
    $null = Invoke-AzVmInteractiveDesktopAutomation `
        -TaskName $workerTaskName `
        -RunAsUser $managerUser `
        -RunAsPassword $managerPassword `
        -WorkerScriptText $workerScript `
        -WaitTimeoutSeconds ([int]$taskConfig.WaitTimeoutSeconds) `
        -RunAsMode 'interactiveToken'
}
catch {
    Refresh-SessionPath
    $existingExe = Resolve-ICloudExe
    if (-not [string]::IsNullOrWhiteSpace([string]$existingExe) -or (Test-ICloudRegistration)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$existingExe)) {
            Write-Host ("icloud-home-exe => {0}" -f $existingExe)
        }
        Write-Host "install-icloud-system-completed"
        Write-Host "Update task completed: install-icloud-system"
        return
    }

    $interactiveError = [string]$_.Exception.Message
    if ($interactiveError -match ([string]$taskConfig.StoreSessionErrorRegex)) {
        Register-ICloudDeferredInstall -WingetPath $wingetExe
        Write-Warning "iCloud install could not complete in the current session. A RunOnce install was registered for the next interactive sign-in."
        Write-Host "install-icloud-system-deferred"
        Write-Host "Update task completed: install-icloud-system"
        return
    }

    throw
}

Refresh-SessionPath
$installedExe = Resolve-ICloudExe
if ([string]::IsNullOrWhiteSpace([string]$installedExe) -and -not (Test-ICloudRegistration)) {
    Write-Host ("Running: winget list --id {0}" -f [string]$taskConfig.PackageId)
    $listOutput = & $wingetExe list --id ([string]$taskConfig.PackageId)
    $listText = [string]($listOutput | Out-String)
    if ([string]::IsNullOrWhiteSpace([string]$listText) -or -not ($listText.ToLowerInvariant().Contains('icloud'))) {
        throw "iCloud install could not be verified."
    }
}

if (-not [string]::IsNullOrWhiteSpace([string]$installedExe)) {
    Write-Host ("icloud-home-exe => {0}" -f $installedExe)
}

Write-Host "install-icloud-system-completed"
Write-Host "Update task completed: install-icloud-system"
