$ErrorActionPreference = "Stop"
Write-Host "Update task started: windows-ux-performance-tuning"

$taskName = '04-windows-ux-performance-tuning'
$managerUser = "__VM_ADMIN_USER__"
$managerPassword = "__VM_ADMIN_PASS__"
$notepadPath = Join-Path $env:WINDIR "System32\notepad.exe"
$helperPath = "C:\Windows\Temp\az-vm-interactive-session-helper.ps1"
$textExtensions = @(".txt", ".log", ".ini", ".cfg", ".conf", ".csv", ".xml", ".json", ".yaml", ".yml", ".md", ".ps1", ".cmd", ".bat", ".reg", ".sql")

if (-not (Test-Path -LiteralPath $helperPath)) {
    throw ("Interactive session helper was not found: {0}" -f $helperPath)
}

. $helperPath

function Assert-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$ExpectedValue
    )

    if ([string]::IsNullOrWhiteSpace([string]$Name) -or [string]::Equals([string]$Name, '(default)', [System.StringComparison]::OrdinalIgnoreCase)) {
        $actualValue = [string](Get-Item -Path $Path -ErrorAction Stop).GetValue('')
    }
    else {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        $actualValue = $item.$Name
    }

    if ([string]$actualValue -ne [string]$ExpectedValue) {
        throw ("Registry validation failed: {0}\{1} expected '{2}' but got '{3}'." -f $Path, $Name, $ExpectedValue, $actualValue)
    }
}

function Clear-DesktopEntries {
    param(
        [string]$UserName
    )

    if ([string]::IsNullOrWhiteSpace([string]$UserName)) {
        return
    }

    $desktopPath = Join-Path ("C:\Users\" + $UserName) "Desktop"
    if (-not (Test-Path -LiteralPath $desktopPath)) {
        Write-Host ("desktop-cleanup-skip: profile not found for {0}" -f $UserName)
        return
    }

    Get-ChildItem -LiteralPath $desktopPath -Force -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.PSIsContainer) {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop
        }
        else {
            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
        }
    }

    Write-Host ("desktop-cleanup-ok: {0}" -f $UserName)
}

$tsPolicy = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
Set-AzVmRegistryValue -Path $tsPolicy -Name "fDisableWallpaper" -Value 1 -Kind DWord
Set-AzVmRegistryValue -Path $tsPolicy -Name "fDisableFullWindowDrag" -Value 1 -Kind DWord
Set-AzVmRegistryValue -Path $tsPolicy -Name "fDisableMenuAnims" -Value 1 -Kind DWord
Set-AzVmRegistryValue -Path $tsPolicy -Name "fDisableThemes" -Value 1 -Kind DWord
Set-AzVmRegistryValue -Path $tsPolicy -Name "fDisableCursorSetting" -Value 1 -Kind DWord
Set-AzVmRegistryValue -Path $tsPolicy -Name "fDisableFontSmoothing" -Value 1 -Kind DWord

$oobePolicy = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\OOBE"
Set-AzVmRegistryValue -Path $oobePolicy -Name "DisablePrivacyExperience" -Value 1 -Kind DWord

$cloudContent = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
Set-AzVmRegistryValue -Path $cloudContent -Name "DisableWindowsConsumerFeatures" -Value 1 -Kind DWord
Set-AzVmRegistryValue -Path $cloudContent -Name "DisableConsumerAccountStateContent" -Value 1 -Kind DWord

$systemPolicy = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
Set-AzVmRegistryValue -Path $systemPolicy -Name "EnableFirstLogonAnimation" -Value 0 -Kind DWord

$className = "AzVmTextFile"
$classRoot = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$className"
Set-AzVmRegistryValue -Path $classRoot -Name "(default)" -Value "Co VM Text File" -Kind String
$commandPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$className\shell\open\command"
Set-AzVmRegistryValue -Path $commandPath -Name "(default)" -Value ("`"$notepadPath`" `"%1`"") -Kind String

foreach ($ext in @($textExtensions)) {
    $extPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$ext"
    Set-AzVmRegistryValue -Path $extPath -Name "(default)" -Value $className -Kind String
}

Clear-DesktopEntries -UserName $managerUser

Assert-RegistryValue -Path $tsPolicy -Name "fDisableWallpaper" -ExpectedValue 1
Assert-RegistryValue -Path $cloudContent -Name "DisableWindowsConsumerFeatures" -ExpectedValue 1
Assert-RegistryValue -Path $systemPolicy -Name "EnableFirstLogonAnimation" -ExpectedValue 0
Assert-RegistryValue -Path $commandPath -Name "(default)" -ExpectedValue ("`"$notepadPath`" `"%1`"")

$paths = Get-AzVmInteractivePaths -TaskName $taskName
$workerScript = @'
$ErrorActionPreference = "Stop"
$helperPath = "__HELPER_PATH__"
$resultPath = "__RESULT_PATH__"
$taskName = "__TASK_NAME__"

. $helperPath

$details = New-Object 'System.Collections.Generic.List[string]'

function Add-Detail {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace([string]$Text)) {
        return
    }

    [void]$details.Add([string]$Text)
    Write-Host ([string]$Text)
}

function Assert-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$ExpectedValue
    )

    if ([string]::IsNullOrWhiteSpace([string]$Name) -or [string]::Equals([string]$Name, '(default)', [System.StringComparison]::OrdinalIgnoreCase)) {
        $actualValue = [string](Get-Item -Path $Path -ErrorAction Stop).GetValue('')
    }
    else {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        $actualValue = $item.$Name
    }

    if ([string]$actualValue -ne [string]$ExpectedValue) {
        throw ("Registry validation failed: {0}\{1} expected '{2}' but got '{3}'." -f $Path, $Name, $ExpectedValue, $actualValue)
    }
}

function Write-Utf8JsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $parentPath = Split-Path -Path $Path -Parent
    Ensure-AzVmDirectory -Path $parentPath
    $jsonText = [string]($Value | ConvertTo-Json -Depth 20)
    [System.IO.File]::WriteAllText($Path, $jsonText, (New-Object System.Text.UTF8Encoding($false)))
}

function Ensure-TaskManagerFullViewSetting {
    $settingsPath = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\TaskManager\settings.json'
    $settings = $null

    if (Test-Path -LiteralPath $settingsPath) {
        $settings = Get-Content -LiteralPath $settingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    else {
        $settings = [pscustomobject]@{}
    }

    if ($settings.PSObject.Properties.Match('SmallView').Count -eq 0) {
        $settings | Add-Member -NotePropertyName 'SmallView' -NotePropertyValue $false
    }
    else {
        $settings.SmallView = $false
    }

    Write-Utf8JsonFile -Path $settingsPath -Value $settings
    $writtenSettings = Get-Content -LiteralPath $settingsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($writtenSettings.PSObject.Properties.Match('SmallView').Count -eq 0 -or [bool]$writtenSettings.SmallView) {
        throw "Task Manager settings.json did not persist SmallView=false."
    }

    Add-Detail ("task-manager-settings-store: {0}" -f $settingsPath)
    Add-Detail 'task-manager-settings-small-view-false'
}

try {
    powercfg.exe /hibernate on
    if ($LASTEXITCODE -ne 0) {
        throw ("powercfg /hibernate on failed with exit code {0}." -f $LASTEXITCODE)
    }

    $flyoutPath = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings'
    Set-AzVmRegistryValue -Path $flyoutPath -Name 'ShowHibernateOption' -Value 1 -Kind DWord
    Set-AzVmRegistryValue -Path $flyoutPath -Name 'ShowSleepOption' -Value 1 -Kind DWord

    $advanced = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-AzVmRegistryValue -Path $advanced -Name 'LaunchTo' -Value 1 -Kind DWord
    Set-AzVmRegistryValue -Path $advanced -Name 'Hidden' -Value 1 -Kind DWord
    Set-AzVmRegistryValue -Path $advanced -Name 'ShowSuperHidden' -Value 1 -Kind DWord
    Set-AzVmRegistryValue -Path $advanced -Name 'HideFileExt' -Value 0 -Kind DWord
    Set-AzVmRegistryValue -Path $advanced -Name 'ShowInfoTip' -Value 0 -Kind DWord
    Set-AzVmRegistryValue -Path $advanced -Name 'IconsOnly' -Value 1 -Kind DWord
    Set-AzVmRegistryValue -Path $advanced -Name 'AutoArrange' -Value 1 -Kind DWord
    Set-AzVmRegistryValue -Path $advanced -Name 'SnapToGrid' -Value 1 -Kind DWord

    $controlPanel = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel'
    Set-AzVmRegistryValue -Path $controlPanel -Name 'AllItemsIconView' -Value 1 -Kind DWord
    Set-AzVmRegistryValue -Path $controlPanel -Name 'StartupPage' -Value 1 -Kind DWord

    $operationStatus = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\OperationStatusManager'
    Set-AzVmRegistryValue -Path $operationStatus -Name 'EnthusiastMode' -Value 1 -Kind DWord

    $keyboard = 'Registry::HKEY_CURRENT_USER\Control Panel\Keyboard'
    Set-AzVmRegistryValue -Path $keyboard -Name 'KeyboardDelay' -Value '0' -Kind String

    $desktopIconRoots = @(
        'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel',
        'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\ClassicStartMenu'
    )
    foreach ($desktopIconRoot in @($desktopIconRoots)) {
        Set-AzVmRegistryValue -Path $desktopIconRoot -Name '{59031a47-3f72-44a7-89c5-5595fe6b30ee}' -Value 0 -Kind DWord
        Set-AzVmRegistryValue -Path $desktopIconRoot -Name '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' -Value 0 -Kind DWord
        Set-AzVmRegistryValue -Path $desktopIconRoot -Name '{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}' -Value 0 -Kind DWord
        Set-AzVmRegistryValue -Path $desktopIconRoot -Name '{645FF040-5081-101B-9F08-00AA002F954E}' -Value 1 -Kind DWord
    }

    $currentUserShellRoot = 'Registry::HKEY_CURRENT_USER\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell'
    foreach ($staleNode in @('BagMRU', 'Bags')) {
        $stalePath = Join-Path $currentUserShellRoot $staleNode
        if (Test-Path -LiteralPath $stalePath) {
            Remove-Item -LiteralPath $stalePath -Recurse -Force -ErrorAction Stop
        }
    }

    $legacyDesktopBagsRoot = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\Shell\Bags'
    if (Test-Path -LiteralPath $legacyDesktopBagsRoot) {
        Remove-Item -LiteralPath $legacyDesktopBagsRoot -Recurse -Force -ErrorAction Stop
    }

    $allFoldersShell = 'Registry::HKEY_CURRENT_USER\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell'
    Set-AzVmRegistryValue -Path $allFoldersShell -Name 'FolderType' -Value 'NotSpecified' -Kind String
    Set-AzVmRegistryValue -Path $allFoldersShell -Name 'LogicalViewMode' -Value 1 -Kind DWord
    Set-AzVmRegistryValue -Path $allFoldersShell -Name 'Mode' -Value 4 -Kind DWord
    Set-AzVmRegistryValue -Path $allFoldersShell -Name 'Sort' -Value 'prop:System.ItemNameDisplay' -Kind String
    Set-AzVmRegistryValue -Path $allFoldersShell -Name 'SortDirection' -Value 0 -Kind DWord
    Set-AzVmRegistryValue -Path $allFoldersShell -Name 'GroupView' -Value 0 -Kind DWord

    $desktopBag = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\Shell\Bags\1\Desktop'
    Set-AzVmRegistryValue -Path $desktopBag -Name 'IconSize' -Value 48 -Kind DWord
    Set-AzVmRegistryValue -Path $desktopBag -Name 'Sort' -Value 'prop:System.ItemNameDisplay' -Kind String
    Set-AzVmRegistryValue -Path $desktopBag -Name 'SortDirection' -Value 0 -Kind DWord
    Set-AzVmRegistryValue -Path $desktopBag -Name 'GroupView' -Value 0 -Kind DWord
    Set-AzVmRegistryValue -Path $desktopBag -Name 'FFlags' -Value 1075839525 -Kind DWord

    $contextMenuPath = 'Registry::HKEY_CURRENT_USER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32'
    Set-AzVmRegistryValue -Path $contextMenuPath -Name '(default)' -Value '' -Kind String

    Ensure-TaskManagerFullViewSetting

    Assert-RegistryValue -Path $flyoutPath -Name 'ShowHibernateOption' -ExpectedValue 1
    Assert-RegistryValue -Path $advanced -Name 'LaunchTo' -ExpectedValue 1
    Assert-RegistryValue -Path $advanced -Name 'HideFileExt' -ExpectedValue 0
    Assert-RegistryValue -Path $advanced -Name 'AutoArrange' -ExpectedValue 1
    Assert-RegistryValue -Path $advanced -Name 'SnapToGrid' -ExpectedValue 1
    Assert-RegistryValue -Path $controlPanel -Name 'AllItemsIconView' -ExpectedValue 1
    Assert-RegistryValue -Path $controlPanel -Name 'StartupPage' -ExpectedValue 1
    Assert-RegistryValue -Path $operationStatus -Name 'EnthusiastMode' -ExpectedValue 1
    Assert-RegistryValue -Path $keyboard -Name 'KeyboardDelay' -ExpectedValue '0'
    Assert-RegistryValue -Path $allFoldersShell -Name 'FolderType' -ExpectedValue 'NotSpecified'
    Assert-RegistryValue -Path $allFoldersShell -Name 'Mode' -ExpectedValue 4
    Assert-RegistryValue -Path $allFoldersShell -Name 'LogicalViewMode' -ExpectedValue 1
    Assert-RegistryValue -Path $allFoldersShell -Name 'GroupView' -ExpectedValue 0
    Assert-RegistryValue -Path $desktopBag -Name 'Sort' -ExpectedValue 'prop:System.ItemNameDisplay'
    Assert-RegistryValue -Path $desktopBag -Name 'SortDirection' -ExpectedValue 0
    Assert-RegistryValue -Path $desktopBag -Name 'GroupView' -ExpectedValue 0

    Add-Detail 'hibernate-option-visible'
    Add-Detail 'explorer-group-none-default'
    Add-Detail 'explorer-details-view-default'
    Add-Detail 'desktop-sort-name-auto-arrange-grid'
    Add-Detail 'control-panel-small-icons'
    Add-Detail 'copy-dialog-show-more-details'
    Add-Detail 'task-manager-more-details'
    Add-Detail 'keyboard-repeat-delay-fastest'

    Write-AzVmInteractiveResult -ResultPath $resultPath -TaskName $taskName -Success $true -Summary 'Windows UX tuning applied and validated for manager.' -Details @($details)
}
catch {
    $message = [string]$_.Exception.Message
    Add-Detail ("ux-worker-error: {0}" -f $message)
    Write-AzVmInteractiveResult -ResultPath $resultPath -TaskName $taskName -Success $false -Summary $message -Details @($details)
    throw
}
'@

$workerScript = $workerScript.Replace('__HELPER_PATH__', $helperPath)
$workerScript = $workerScript.Replace('__RESULT_PATH__', [string]$paths.ResultPath)
$workerScript = $workerScript.Replace('__TASK_NAME__', $taskName)

$null = Invoke-AzVmInteractiveDesktopAutomation `
    -TaskName $taskName `
    -ManagerUser $managerUser `
    -ManagerPassword $managerPassword `
    -WorkerScriptText $workerScript `
    -WaitTimeoutSeconds 300

Write-Host "windows-ux-performance-tuning-completed"
Write-Host "Update task completed: windows-ux-performance-tuning"
