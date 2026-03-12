$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-be-my-eyes"

$taskConfig = [ordered]@{
    TaskName = '126-install-be-my-eyes'
    ManagerUser = '__VM_ADMIN_USER__'
    ManagerPassword = '__VM_ADMIN_PASS__'
    HelperPath = 'C:\Windows\Temp\az-vm-interactive-session-helper.ps1'
    PortableWingetPath = 'C:\ProgramData\az-vm\tools\winget-x64\winget.exe'
    StoreProductId = '9MSW46LTDWGF'
    InteractiveTaskSuffix = 'interactive-install'
    DeferredRunOnceName = 'AzVmInstallBeMyEyes'
    WaitTimeoutSeconds = 240
    StoreSessionErrorRegex = '(?i)0x80070520|logon session|microsoft store|msstore'
}

$taskName = [string]$taskConfig.TaskName
$managerUser = [string]$taskConfig.ManagerUser
$managerPassword = [string]$taskConfig.ManagerPassword
$helperPath = [string]$taskConfig.HelperPath
$storeProductId = [string]$taskConfig.StoreProductId

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

    return ""
}

function Test-BeMyEyesInstalled {
    $startApps = @()
    if (Get-Command Get-StartApps -ErrorAction SilentlyContinue) {
        $startApps = @(Get-StartApps | Where-Object { ([string]$_.Name).ToLowerInvariant().Contains("be my eyes") })
    }
    if (@($startApps).Count -gt 0) {
        return $true
    }

    $packages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {
        ([string]$_.Name).ToLowerInvariant().Contains("bemyeyes") -or
        ([string]$_.Name).ToLowerInvariant().Contains("be my eyes") -or
        ([string]$_.PackageFamilyName).ToLowerInvariant().Contains("bemyeyes")
    })
    if (@($packages).Count -gt 0) {
        return $true
    }

    return $false
}

function Register-BeMyEyesDeferredInstall {
    param([string]$WingetPath)

    $runOncePath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path -LiteralPath $runOncePath)) {
        New-Item -Path $runOncePath -Force | Out-Null
    }

    $commandValue = ('powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command "& ''{0}'' install --id {1} --source msstore --accept-source-agreements --accept-package-agreements --silent --disable-interactivity"' -f $WingetPath, $storeProductId)
    Set-ItemProperty -Path $runOncePath -Name ([string]$taskConfig.DeferredRunOnceName) -Value $commandValue -Type String
}

Refresh-SessionPath
if (Test-BeMyEyesInstalled) {
    Write-Host "install-be-my-eyes-completed"
    Write-Host "Update task completed: install-be-my-eyes"
    return
}

$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    throw "winget command is not available."
}

$workerTaskName = "{0}-{1}" -f $taskName, ([string]$taskConfig.InteractiveTaskSuffix)
$paths = Get-AzVmInteractivePaths -TaskName $workerTaskName
$workerScript = @'
$ErrorActionPreference = "Stop"
$helperPath = "__HELPER_PATH__"
$resultPath = "__RESULT_PATH__"
$taskName = "__TASK_NAME__"
$storeProductId = "__STORE_PRODUCT_ID__"

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

function Test-BeMyEyesInstalled {
    $startApps = @()
    if (Get-Command Get-StartApps -ErrorAction SilentlyContinue) {
        $startApps = @(Get-StartApps | Where-Object { ([string]$_.Name).ToLowerInvariant().Contains("be my eyes") })
    }
    if (@($startApps).Count -gt 0) {
        return $true
    }

    $packages = @(Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object {
        ([string]$_.Name).ToLowerInvariant().Contains("bemyeyes") -or
        ([string]$_.Name).ToLowerInvariant().Contains("be my eyes") -or
        ([string]$_.PackageFamilyName).ToLowerInvariant().Contains("bemyeyes")
    })
    return (@($packages).Count -gt 0)
}

Refresh-SessionPath
$wingetExe = Resolve-WingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    Write-AzVmInteractiveResult -ResultPath $resultPath -TaskName $taskName -Success $false -Summary 'winget command is not available.'
    exit 1
}

if (-not (Test-BeMyEyesInstalled)) {
    $installOutput = @(& $wingetExe install --id $storeProductId --source msstore --accept-source-agreements --accept-package-agreements --silent --disable-interactivity 2>&1)
    $installExit = [int]$LASTEXITCODE
    $installText = [string]($installOutput | Out-String)
    if ($installExit -ne 0 -and $installExit -ne -1978335189) {
        Write-AzVmInteractiveResult -ResultPath $resultPath -TaskName $taskName -Success $false -Summary ("winget install failed with exit code {0}." -f $installExit) -Details @($installText)
        exit 1
    }
}

if (-not (Test-BeMyEyesInstalled)) {
    $listText = [string]((& $wingetExe list --id $storeProductId --source msstore | Out-String))
    if ([string]::IsNullOrWhiteSpace([string]$listText) -or -not $listText.ToLowerInvariant().Contains('be my eyes')) {
        Write-AzVmInteractiveResult -ResultPath $resultPath -TaskName $taskName -Success $false -Summary 'Be My Eyes install could not be verified after interactive winget install.'
        exit 1
    }
}

Write-AzVmInteractiveResult -ResultPath $resultPath -TaskName $taskName -Success $true -Summary 'Be My Eyes is installed.'
'@

$workerScript = $workerScript.Replace('__HELPER_PATH__', $helperPath)
$workerScript = $workerScript.Replace('__RESULT_PATH__', [string]$paths.ResultPath)
$workerScript = $workerScript.Replace('__TASK_NAME__', $workerTaskName)
$workerScript = $workerScript.Replace('__STORE_PRODUCT_ID__', $storeProductId)
$workerScript = $workerScript.Replace('__PORTABLE_WINGET_PATH__', [string]$taskConfig.PortableWingetPath)

if (-not (Test-AzVmUserInteractiveDesktopReady -UserName $managerUser)) {
    Register-BeMyEyesDeferredInstall -WingetPath $wingetExe
    Write-Warning "Be My Eyes install requires an interactive desktop session. A RunOnce install was registered for the next interactive sign-in."
    Write-Host "install-be-my-eyes-deferred"
    Write-Host "Update task completed: install-be-my-eyes"
    return
}

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
    if (Test-BeMyEyesInstalled) {
        Write-Host "install-be-my-eyes-completed"
        Write-Host "Update task completed: install-be-my-eyes"
        return
    }

    $interactiveError = [string]$_.Exception.Message
    if ($interactiveError -match ([string]$taskConfig.StoreSessionErrorRegex)) {
        Register-BeMyEyesDeferredInstall -WingetPath $wingetExe
        Write-Warning "Be My Eyes install could not complete in the current session. A RunOnce install was registered for the next interactive sign-in."
        Write-Host "install-be-my-eyes-deferred"
        Write-Host "Update task completed: install-be-my-eyes"
        return
    }

    throw
}

Refresh-SessionPath
if (-not (Test-BeMyEyesInstalled)) {
    throw "Be My Eyes install could not be verified."
}

Write-Host "install-be-my-eyes-completed"
Write-Host "Update task completed: install-be-my-eyes"
