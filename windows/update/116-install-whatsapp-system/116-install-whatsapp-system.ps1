$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-whatsapp-system"

Import-Module 'C:\Windows\Temp\az-vm-store-install-state.psm1' -Force -DisableNameChecking

$managerUser = '__VM_ADMIN_USER__'
$helperPath = 'C:\Windows\Temp\az-vm-interactive-session-helper.ps1'

$taskConfig = [ordered]@{
    TaskName = '116-install-whatsapp-system'
    PackageId = '9NKSQGP7F2NH'
    LegacyRunOnceName = 'AzVmInstallWhatsApp'
    WingetInstallTimeoutSeconds = 60
    LogTailLineCount = 20
}

if (-not (Test-Path -LiteralPath $helperPath)) {
    throw ("Interactive session helper was not found: {0}" -f $helperPath)
}

. $helperPath

function Resolve-WhatsAppAppId {
    if (-not (Get-Command Get-StartApps -ErrorAction SilentlyContinue)) {
        return ''
    }

    $startApps = @(Get-StartApps | Where-Object {
        $nameText = [string]$_.Name
        $appIdText = [string]$_.AppID
        if ([string]::IsNullOrWhiteSpace([string]$nameText) -and [string]::IsNullOrWhiteSpace([string]$appIdText)) {
            return $false
        }

        return (
            $nameText.ToLowerInvariant().Contains('whatsapp') -or
            $appIdText.ToLowerInvariant().Contains('whatsapp')
        )
    })

    foreach ($entry in @($startApps)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.AppID)) {
            return [string]$entry.AppID
        }
    }

    return ''
}

function Resolve-WhatsAppExecutable {
    $packages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {
        $pkgName = [string]$_.Name
        $pkgFamily = [string]$_.PackageFamilyName
        if ([string]::IsNullOrWhiteSpace([string]$pkgName) -and [string]::IsNullOrWhiteSpace([string]$pkgFamily)) {
            return $false
        }

        $pkgNameLower = $pkgName.ToLowerInvariant()
        $pkgFamilyLower = $pkgFamily.ToLowerInvariant()
        return ($pkgNameLower.Contains('whatsapp') -or $pkgFamilyLower.Contains('whatsapp'))
    })

    foreach ($package in @($packages)) {
        $installLocation = [string]$package.InstallLocation
        if ([string]::IsNullOrWhiteSpace([string]$installLocation)) {
            continue
        }

        foreach ($candidate in @(
            (Join-Path $installLocation 'WhatsApp.Root.exe'),
            (Join-Path $installLocation 'app\WhatsApp.exe'),
            (Join-Path $installLocation 'WhatsApp.exe')
        )) {
            if (Test-Path -LiteralPath $candidate) {
                return [string]$candidate
            }
        }
    }

    return ''
}

function Get-WhatsAppInstallState {
    param([string]$WingetExe)

    $resolvedExe = Resolve-WhatsAppExecutable
    if (-not [string]::IsNullOrWhiteSpace([string]$resolvedExe)) {
        return [pscustomobject]@{
            Healthy = $true
            LaunchKind = 'executable'
            LaunchTarget = [string]$resolvedExe
            DetectionSource = 'executable'
        }
    }

    $appId = Resolve-WhatsAppAppId
    if (-not [string]::IsNullOrWhiteSpace([string]$appId)) {
        return [pscustomobject]@{
            Healthy = $true
            LaunchKind = 'app-id'
            LaunchTarget = [string]$appId
            DetectionSource = 'app-id'
        }
    }

    $packages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object {
        ([string]$_.Name).ToLowerInvariant().Contains('whatsapp') -or
        ([string]$_.PackageFamilyName).ToLowerInvariant().Contains('whatsapp')
    })
    if (@($packages).Count -gt 0) {
        return [pscustomobject]@{
            Healthy = $false
            LaunchKind = 'package-only'
            LaunchTarget = [string]$packages[0].PackageFamilyName
            DetectionSource = 'package'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$WingetExe)) {
        Write-Host 'Running: winget list whatsapp'
        $listOutput = & $WingetExe list whatsapp
        $listText = [string]($listOutput | Out-String)
        if (-not [string]::IsNullOrWhiteSpace([string]$listText) -and $listText.ToLowerInvariant().Contains('whatsapp')) {
            return [pscustomobject]@{
                Healthy = $false
                LaunchKind = 'listed-only'
                LaunchTarget = 'winget-list'
                DetectionSource = 'winget'
            }
        }
    }

    return [pscustomobject]@{
        Healthy = $false
        LaunchKind = ''
        LaunchTarget = ''
        DetectionSource = 'none'
    }
}

function Get-LogTailText {
    param(
        [string]$Path,
        [int]$LineCount = 20
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path) -or -not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    try {
        $tailLines = @(Get-Content -LiteralPath $Path -Tail $LineCount -ErrorAction Stop)
        if (@($tailLines).Count -eq 0) {
            return ''
        }

        return ([string](($tailLines -join [Environment]::NewLine))).Trim()
    }
    catch {
        return ''
    }
}

function Invoke-ProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList,
        [int]$TimeoutSeconds = 60,
        [string]$Label = 'process'
    )

    $logRoot = Join-Path $env:TEMP 'az-vm-whatsapp'
    [void](New-Item -ItemType Directory -Path $logRoot -Force)
    $stamp = Get-Date -Format 'yyyyMMddHHmmss'
    $stdoutLog = Join-Path $logRoot ("{0}-{1}.stdout.log" -f $Label.Replace(' ', '-'), $stamp)
    $stderrLog = Join-Path $logRoot ("{0}-{1}.stderr.log" -f $Label.Replace(' ', '-'), $stamp)
    $process = Start-Process `
        -FilePath $FilePath `
        -ArgumentList $ArgumentList `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -PassThru

    $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
    if ($timedOut) {
        try {
            Stop-Process -Id ([int]$process.Id) -Force -ErrorAction Stop
        }
        catch {
        }
    }

    return [pscustomobject]@{
        TimedOut = [bool]$timedOut
        ExitCode = if ($timedOut) { 124 } else { [int]$process.ExitCode }
        StdoutLog = [string]$stdoutLog
        StderrLog = [string]$stderrLog
        StdoutText = [string](Get-LogTailText -Path $stdoutLog -LineCount ([int]$taskConfig.LogTailLineCount))
        StderrText = [string](Get-LogTailText -Path $stderrLog -LineCount ([int]$taskConfig.LogTailLineCount))
    }
}

Invoke-AzVmRefreshSessionPath
$wingetExe = Resolve-AzVmWingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    throw 'winget command is not available.'
}

Write-Host "Resolved winget executable: $wingetExe"
$existingState = Get-WhatsAppInstallState -WingetExe $wingetExe
if ([bool]$existingState.Healthy) {
    Remove-AzVmRunOnceEntry -Name ([string]$taskConfig.LegacyRunOnceName)
    $stateRecord = Write-AzVmStoreInstallState -TaskName ([string]$taskConfig.TaskName) -State installed -Summary ('WhatsApp is launch-ready via {0}.' -f [string]$existingState.DetectionSource) -PackageId ([string]$taskConfig.PackageId) -RunOnceName ([string]$taskConfig.LegacyRunOnceName) -LaunchKind ([string]$existingState.LaunchKind) -LaunchTarget ([string]$existingState.LaunchTarget)
    Write-AzVmStoreInstallStateStatusLine -TaskName ([string]$taskConfig.TaskName) -StateRecord $stateRecord
    Write-Host 'install-whatsapp-system-completed'
    Write-Host 'Update task completed: install-whatsapp-system'
    return
}

if (Test-AzVmRunOnceEntryPresent -Name ([string]$taskConfig.LegacyRunOnceName)) {
    Remove-AzVmRunOnceEntry -Name ([string]$taskConfig.LegacyRunOnceName)
    Write-Host 'store-install-cleanup => task=116-install-whatsapp-system; removed-stale-run-once=True'
}

if (-not (Test-AzVmUserInteractiveDesktopReady -UserName $managerUser)) {
    Remove-AzVmRunOnceEntry -Name ([string]$taskConfig.LegacyRunOnceName)
    $stateRecord = Write-AzVmStoreInstallState -TaskName ([string]$taskConfig.TaskName) -State skipped -Summary 'WhatsApp install is deferred until the manager interactive desktop session is ready.' -PackageId ([string]$taskConfig.PackageId) -RunOnceName ([string]$taskConfig.LegacyRunOnceName) -LaunchKind ([string]$existingState.LaunchKind) -LaunchTarget ([string]$existingState.LaunchTarget)
    Write-AzVmStoreInstallStateStatusLine -TaskName ([string]$taskConfig.TaskName) -StateRecord $stateRecord
    Write-Host 'WhatsApp install is deferred because the manager interactive desktop session is not ready yet. Skipping without warning.'
    Write-Host 'install-whatsapp-system-skipped'
    Write-Host 'Update task completed: install-whatsapp-system'
    return
}

Write-Host 'Running: winget install --id 9NKSQGP7F2NH --source msstore --accept-source-agreements --accept-package-agreements --silent --disable-interactivity'
$installResult = Invoke-ProcessWithTimeout `
    -FilePath $wingetExe `
    -ArgumentList @('install', '--id', ([string]$taskConfig.PackageId), '--source', 'msstore', '--accept-source-agreements', '--accept-package-agreements', '--silent', '--disable-interactivity') `
    -TimeoutSeconds ([int]$taskConfig.WingetInstallTimeoutSeconds) `
    -Label 'winget-install-whatsapp-system'
$installExit = [int]$installResult.ExitCode
$installTextParts = @()
if (-not [string]::IsNullOrWhiteSpace([string]$installResult.StdoutText)) {
    $installTextParts += [string]$installResult.StdoutText
}
if (-not [string]::IsNullOrWhiteSpace([string]$installResult.StderrText)) {
    $installTextParts += [string]$installResult.StderrText
}
$installText = [string](($installTextParts -join [Environment]::NewLine)).Trim()
if (-not [string]::IsNullOrWhiteSpace([string]$installText)) {
    Write-Host $installText.TrimEnd()
}

Invoke-AzVmRefreshSessionPath
$postInstallState = Get-WhatsAppInstallState -WingetExe $wingetExe
if ([bool]$postInstallState.Healthy) {
    Remove-AzVmRunOnceEntry -Name ([string]$taskConfig.LegacyRunOnceName)
    $stateRecord = Write-AzVmStoreInstallState -TaskName ([string]$taskConfig.TaskName) -State installed -Summary ('WhatsApp is launch-ready via {0}.' -f [string]$postInstallState.DetectionSource) -PackageId ([string]$taskConfig.PackageId) -RunOnceName ([string]$taskConfig.LegacyRunOnceName) -LaunchKind ([string]$postInstallState.LaunchKind) -LaunchTarget ([string]$postInstallState.LaunchTarget)
    Write-AzVmStoreInstallStateStatusLine -TaskName ([string]$taskConfig.TaskName) -StateRecord $stateRecord
    Write-Host 'install-whatsapp-system-completed'
    Write-Host 'Update task completed: install-whatsapp-system'
    return
}

$canDefer = Test-AzVmStoreInstallNeedsInteractiveCompletion -MessageText $installText -TimedOut ([bool]$installResult.TimedOut)
if ($canDefer) {
    Remove-AzVmRunOnceEntry -Name ([string]$taskConfig.LegacyRunOnceName)
    $summary = if ([bool]$installResult.TimedOut) { 'WhatsApp install exceeded the bounded noninteractive wait and no next-boot follow-up was scheduled.' } else { 'WhatsApp install requires an interactive Store-capable session and no next-boot follow-up was scheduled.' }
    $stateRecord = Write-AzVmStoreInstallState -TaskName ([string]$taskConfig.TaskName) -State degraded -Summary $summary -PackageId ([string]$taskConfig.PackageId) -RunOnceName ([string]$taskConfig.LegacyRunOnceName) -LaunchKind ([string]$postInstallState.LaunchKind) -LaunchTarget ([string]$postInstallState.LaunchTarget)
    Write-AzVmStoreInstallStateStatusLine -TaskName ([string]$taskConfig.TaskName) -StateRecord $stateRecord
    throw 'WhatsApp install requires an interactive Store-capable session and cannot be deferred to a later boot.'
}

if ($installExit -ne 0 -and $installExit -ne -1978335189) {
    $stateRecord = Write-AzVmStoreInstallState -TaskName ([string]$taskConfig.TaskName) -State degraded -Summary ("WhatsApp install failed with exit code {0}." -f $installExit) -PackageId ([string]$taskConfig.PackageId) -RunOnceName ([string]$taskConfig.LegacyRunOnceName) -LaunchKind ([string]$postInstallState.LaunchKind) -LaunchTarget ([string]$postInstallState.LaunchTarget)
    Write-AzVmStoreInstallStateStatusLine -TaskName ([string]$taskConfig.TaskName) -StateRecord $stateRecord
    throw ("winget install whatsapp failed with exit code {0}. stdoutLog={1}; stderrLog={2}" -f $installExit, [string]$installResult.StdoutLog, [string]$installResult.StderrLog)
}

$stateRecord = Write-AzVmStoreInstallState -TaskName ([string]$taskConfig.TaskName) -State degraded -Summary ('WhatsApp is present but not yet launch-ready via a stable executable or AppID ({0}).' -f [string]$postInstallState.DetectionSource) -PackageId ([string]$taskConfig.PackageId) -RunOnceName ([string]$taskConfig.LegacyRunOnceName) -LaunchKind ([string]$postInstallState.LaunchKind) -LaunchTarget ([string]$postInstallState.LaunchTarget)
Write-AzVmStoreInstallStateStatusLine -TaskName ([string]$taskConfig.TaskName) -StateRecord $stateRecord
throw 'WhatsApp install could not be verified.'

