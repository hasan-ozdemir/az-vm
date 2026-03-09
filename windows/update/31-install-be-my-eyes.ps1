$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-be-my-eyes"

$taskName = '31-install-be-my-eyes'
$managerUser = "__VM_ADMIN_USER__"
$managerPassword = "__VM_ADMIN_PASS__"
$helperPath = "C:\Windows\Temp\az-vm-interactive-session-helper.ps1"
$storeProductId = "9MSW46LTDWGF"

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

Refresh-SessionPath
if (Test-BeMyEyesInstalled) {
    Write-Host "install-be-my-eyes-completed"
    Write-Host "Update task completed: install-be-my-eyes"
    return
}

$workerTaskName = "{0}-manager-install" -f $taskName
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
    & $wingetExe install --id $storeProductId --source msstore --accept-source-agreements --accept-package-agreements --silent --disable-interactivity --force
    $installExit = [int]$LASTEXITCODE
    if ($installExit -ne 0 -and $installExit -ne -1978335189) {
        Write-AzVmInteractiveResult -ResultPath $resultPath -TaskName $taskName -Success $false -Summary ("winget install failed with exit code {0}." -f $installExit)
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

$null = Invoke-AzVmInteractiveDesktopAutomation `
    -TaskName $workerTaskName `
    -RunAsUser $managerUser `
    -RunAsPassword $managerPassword `
    -WorkerScriptText $workerScript `
    -WaitTimeoutSeconds 300

Refresh-SessionPath
if (-not (Test-BeMyEyesInstalled)) {
    throw "Be My Eyes install could not be verified."
}

Write-Host "install-be-my-eyes-completed"
Write-Host "Update task completed: install-be-my-eyes"
