$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-codex-app"

Import-Module 'C:\Windows\Temp\az-vm-store-install-state.psm1' -Force -DisableNameChecking

$managerUser = '__VM_ADMIN_USER__'
$helperPath = 'C:\Windows\Temp\az-vm-interactive-session-helper.ps1'
$taskName = '117-install-codex-app'
$packageId = 'codex'
$legacyRunOnceName = 'AzVmInstallCodexApp'

if (-not (Test-Path -LiteralPath $helperPath)) {
    throw ("Interactive session helper was not found: {0}" -f $helperPath)
}

. $helperPath

function Get-CodexPackages {
    $allPackages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
    if (@($allPackages).Count -eq 0) {
        return @()
    }

    return @(
        $allPackages | Where-Object {
            $pkgName = [string]$_.Name
            $pkgFamily = [string]$_.PackageFamilyName
            if ([string]::IsNullOrWhiteSpace([string]$pkgName) -and [string]::IsNullOrWhiteSpace([string]$pkgFamily)) {
                return $false
            }

            $pkgNameLower = $pkgName.ToLowerInvariant()
            $pkgFamilyLower = $pkgFamily.ToLowerInvariant()
            return (
                $pkgNameLower.Contains('openai.codex') -or
                $pkgFamilyLower.Contains('openai.codex') -or
                $pkgNameLower.Contains('codex') -or
                $pkgFamilyLower.Contains('codex')
            )
        }
    )
}

function Resolve-CodexExecutable {
    $preferredCandidate = Join-Path $env:ProgramFiles 'WindowsApps\OpenAI.Codex_26.306.996.0_x64__2p2nqsd0c76g0\app\Codex.exe'
    if (Test-Path -LiteralPath $preferredCandidate) {
        return [string]$preferredCandidate
    }

    foreach ($package in @(Get-CodexPackages)) {
        $installLocation = [string]$package.InstallLocation
        if ([string]::IsNullOrWhiteSpace([string]$installLocation)) {
            continue
        }

        foreach ($candidate in @(
            (Join-Path $installLocation 'app\Codex.exe'),
            (Join-Path $installLocation 'Codex.exe')
        )) {
            if (Test-Path -LiteralPath $candidate) {
                return [string]$candidate
            }
        }
    }

    return ''
}

function Resolve-CodexAppId {
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
            $nameText.ToLowerInvariant().Contains('codex') -or
            $appIdText.ToLowerInvariant().Contains('openai.codex') -or
            $appIdText.ToLowerInvariant().Contains('codex')
        )
    })

    foreach ($entry in @($startApps)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.AppID)) {
            return [string]$entry.AppID
        }
    }

    return ''
}

function Get-CodexInstallState {
    param([string]$WingetExe)

    $codexExe = Resolve-CodexExecutable
    if (-not [string]::IsNullOrWhiteSpace([string]$codexExe)) {
        return [pscustomobject]@{
            Healthy = $true
            LaunchKind = 'executable'
            LaunchTarget = [string]$codexExe
            DetectionSource = 'executable'
        }
    }

    $codexAppId = Resolve-CodexAppId
    if (-not [string]::IsNullOrWhiteSpace([string]$codexAppId)) {
        return [pscustomobject]@{
            Healthy = $true
            LaunchKind = 'app-id'
            LaunchTarget = [string]$codexAppId
            DetectionSource = 'app-id'
        }
    }

    $packages = @(Get-CodexPackages)
    if (@($packages).Count -gt 0) {
        return [pscustomobject]@{
            Healthy = $false
            LaunchKind = 'package-only'
            LaunchTarget = [string]$packages[0].PackageFamilyName
            DetectionSource = 'package'
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$WingetExe)) {
        Write-Host 'Running: winget list codex'
        $listOutput = & $WingetExe list codex
        $listText = [string]($listOutput | Out-String)
        if (-not [string]::IsNullOrWhiteSpace([string]$listText)) {
            $normalizedList = $listText.ToLowerInvariant()
            if ($normalizedList.Contains('codex') -or $normalizedList.Contains('openai')) {
                return [pscustomobject]@{
                    Healthy = $false
                    LaunchKind = 'listed-only'
                    LaunchTarget = 'winget-list'
                    DetectionSource = 'winget'
                }
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

Invoke-AzVmRefreshSessionPath
$wingetExe = Resolve-AzVmWingetExe
if ([string]::IsNullOrWhiteSpace([string]$wingetExe)) {
    throw 'winget command is not available.'
}

Write-Host "Resolved winget executable: $wingetExe"
$existingState = Get-CodexInstallState -WingetExe $wingetExe
if ([bool]$existingState.Healthy) {
    Remove-AzVmRunOnceEntry -Name $legacyRunOnceName
    $stateRecord = Write-AzVmStoreInstallState -TaskName $taskName -State installed -Summary ('Codex app is launch-ready via {0}.' -f [string]$existingState.DetectionSource) -PackageId $packageId -RunOnceName $legacyRunOnceName -LaunchKind ([string]$existingState.LaunchKind) -LaunchTarget ([string]$existingState.LaunchTarget)
    Write-AzVmStoreInstallStateStatusLine -TaskName $taskName -StateRecord $stateRecord
    Write-Host 'Existing Codex app installation is already healthy. Skipping winget install.'
    Write-Host 'install-codex-app-completed'
    Write-Host 'Update task completed: install-codex-app'
    return
}

if (Test-AzVmRunOnceEntryPresent -Name $legacyRunOnceName) {
    Remove-AzVmRunOnceEntry -Name $legacyRunOnceName
    Write-Host 'store-install-cleanup => task=117-install-codex-app; removed-stale-run-once=True'
}

if (-not (Test-AzVmUserInteractiveDesktopReady -UserName $managerUser)) {
    Remove-AzVmRunOnceEntry -Name $legacyRunOnceName
    $stateRecord = Write-AzVmStoreInstallState -TaskName $taskName -State skipped -Summary 'Codex app install is deferred until the manager interactive desktop session is ready.' -PackageId $packageId -RunOnceName $legacyRunOnceName -LaunchKind ([string]$existingState.LaunchKind) -LaunchTarget ([string]$existingState.LaunchTarget)
    Write-AzVmStoreInstallStateStatusLine -TaskName $taskName -StateRecord $stateRecord
    Write-Host 'Codex app install is deferred because the manager interactive desktop session is not ready yet. Skipping without warning.'
    Write-Host 'install-codex-app-skipped'
    Write-Host 'Update task completed: install-codex-app'
    return
}

Write-Host 'Running: winget install codex -s msstore --accept-source-agreements --accept-package-agreements --silent --disable-interactivity'
$installOutput = & $wingetExe install codex -s msstore --accept-source-agreements --accept-package-agreements --silent --disable-interactivity
$installExit = [int]$LASTEXITCODE
$installText = [string]($installOutput | Out-String)
if (-not [string]::IsNullOrWhiteSpace([string]$installText)) {
    Write-Host $installText.TrimEnd()
}

Invoke-AzVmRefreshSessionPath
$postInstallState = Get-CodexInstallState -WingetExe $wingetExe
if ([bool]$postInstallState.Healthy) {
    Remove-AzVmRunOnceEntry -Name $legacyRunOnceName
    $stateRecord = Write-AzVmStoreInstallState -TaskName $taskName -State installed -Summary ('Codex app is launch-ready via {0}.' -f [string]$postInstallState.DetectionSource) -PackageId $packageId -RunOnceName $legacyRunOnceName -LaunchKind ([string]$postInstallState.LaunchKind) -LaunchTarget ([string]$postInstallState.LaunchTarget)
    Write-AzVmStoreInstallStateStatusLine -TaskName $taskName -StateRecord $stateRecord
    Write-Host 'install-codex-app-completed'
    Write-Host 'Update task completed: install-codex-app'
    return
}

if (Test-AzVmStoreInstallNeedsInteractiveCompletion -MessageText $installText) {
    Remove-AzVmRunOnceEntry -Name $legacyRunOnceName
    $stateRecord = Write-AzVmStoreInstallState -TaskName $taskName -State degraded -Summary 'Codex app install requires an interactive Store-capable session; no next-boot follow-up was scheduled.' -PackageId $packageId -RunOnceName $legacyRunOnceName -LaunchKind ([string]$postInstallState.LaunchKind) -LaunchTarget ([string]$postInstallState.LaunchTarget)
    Write-AzVmStoreInstallStateStatusLine -TaskName $taskName -StateRecord $stateRecord
    throw 'Codex app install requires an interactive Store-capable session and cannot be deferred to a later boot.'
}

if ($installExit -ne 0 -and $installExit -ne -1978335189) {
    $stateRecord = Write-AzVmStoreInstallState -TaskName $taskName -State degraded -Summary ("Codex app install failed with exit code {0}." -f $installExit) -PackageId $packageId -RunOnceName $legacyRunOnceName -LaunchKind ([string]$postInstallState.LaunchKind) -LaunchTarget ([string]$postInstallState.LaunchTarget)
    Write-AzVmStoreInstallStateStatusLine -TaskName $taskName -StateRecord $stateRecord
    throw "winget install codex failed with exit code $installExit."
}

$stateRecord = Write-AzVmStoreInstallState -TaskName $taskName -State degraded -Summary ('Codex app is present but not yet launch-ready via a stable executable or AppID ({0}).' -f [string]$postInstallState.DetectionSource) -PackageId $packageId -RunOnceName $legacyRunOnceName -LaunchKind ([string]$postInstallState.LaunchKind) -LaunchTarget ([string]$postInstallState.LaunchTarget)
Write-AzVmStoreInstallStateStatusLine -TaskName $taskName -StateRecord $stateRecord
throw 'Codex app install could not be verified.'

