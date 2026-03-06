$ErrorActionPreference = "Stop"
Write-Host "Update task started: windows-ux-performance-tuning"

$managerUser = "__VM_USER__"
$assistantUser = "__ASSISTANT_USER__"
$targetUsers = @($managerUser, $assistantUser)
$notepadPath = Join-Path $env:WINDIR "System32\notepad.exe"
$textExtensions = @(".txt", ".log", ".ini", ".cfg", ".conf", ".csv", ".xml", ".json", ".yaml", ".yml", ".md", ".ps1", ".cmd", ".bat", ".reg", ".sql")

function Invoke-Tweak {
    param([string]$Name, [scriptblock]$Action)
    try {
        & $Action
        Write-Host "tweak-ok: $Name"
    }
    catch {
        Write-Warning "tweak-failed: $Name => $($_.Exception.Message)"
    }
}

function Set-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [Microsoft.Win32.RegistryValueKind]$Kind
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force
    }
    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Kind -Force
}

function Resolve-TargetHives {
    $targets = @(
        [pscustomobject]@{ Label = "CurrentUser"; HiveNative = "HKCU" }
    )

    foreach ($userName in @($targetUsers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        try {
            $localUser = Get-LocalUser -Name $userName -ErrorAction Stop
            $sid = [string]$localUser.SID.Value
            if (-not [string]::IsNullOrWhiteSpace($sid) -and (Test-Path -LiteralPath ("Registry::HKEY_USERS\\" + $sid))) {
                $targets += [pscustomobject]@{ Label = $userName; HiveNative = "HKU\\$sid" }
            }
        }
        catch {
            Write-Warning "Could not resolve user hive for '$userName': $($_.Exception.Message)"
        }
    }

    return @($targets | Select-Object -Unique HiveNative,Label)
}

function Apply-ExplorerUxToHive {
    param([string]$HiveNative, [string]$Label)

    $advanced = "Registry::$HiveNative\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-RegistryValue -Path $advanced -Name "LaunchTo" -Value 1 -Kind DWord
    Set-RegistryValue -Path $advanced -Name "Hidden" -Value 1 -Kind DWord
    Set-RegistryValue -Path $advanced -Name "ShowSuperHidden" -Value 1 -Kind DWord
    Set-RegistryValue -Path $advanced -Name "HideFileExt" -Value 0 -Kind DWord
    Set-RegistryValue -Path $advanced -Name "ShowInfoTip" -Value 0 -Kind DWord
    Set-RegistryValue -Path $advanced -Name "IconsOnly" -Value 1 -Kind DWord

    $allFoldersShell = "Registry::$HiveNative\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell"
    Set-RegistryValue -Path $allFoldersShell -Name "FolderType" -Value "NotSpecified" -Kind String
    Set-RegistryValue -Path $allFoldersShell -Name "LogicalViewMode" -Value 1 -Kind DWord
    Set-RegistryValue -Path $allFoldersShell -Name "Mode" -Value 4 -Kind DWord
    Set-RegistryValue -Path $allFoldersShell -Name "Sort" -Value "prop:System.ItemNameDisplay" -Kind String
    Set-RegistryValue -Path $allFoldersShell -Name "SortDirection" -Value 0 -Kind DWord
    Set-RegistryValue -Path $allFoldersShell -Name "GroupView" -Value 0 -Kind DWord

    $desktopBag = "Registry::$HiveNative\Software\Microsoft\Windows\Shell\Bags\1\Desktop"
    Set-RegistryValue -Path $desktopBag -Name "IconSize" -Value 48 -Kind DWord
    Set-RegistryValue -Path $desktopBag -Name "Sort" -Value "prop:System.ItemNameDisplay" -Kind String
    Set-RegistryValue -Path $desktopBag -Name "SortDirection" -Value 0 -Kind DWord
    Set-RegistryValue -Path $desktopBag -Name "GroupView" -Value 0 -Kind DWord
    Set-RegistryValue -Path $desktopBag -Name "FFlags" -Value 1075839525 -Kind DWord

    $ctxPath = "Registry::$HiveNative\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
    if (-not (Test-Path -LiteralPath $ctxPath)) {
        New-Item -Path $ctxPath -Force
    }
    Set-ItemProperty -Path $ctxPath -Name "(default)" -Value ""

    Write-Host "explorer-profile-ready: $Label"
}

Invoke-Tweak -Name "machine-rdp-speed-policies" -Action {
    $tsPolicy = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
    Set-RegistryValue -Path $tsPolicy -Name "fDisableWallpaper" -Value 1 -Kind DWord
    Set-RegistryValue -Path $tsPolicy -Name "fDisableFullWindowDrag" -Value 1 -Kind DWord
    Set-RegistryValue -Path $tsPolicy -Name "fDisableMenuAnims" -Value 1 -Kind DWord
    Set-RegistryValue -Path $tsPolicy -Name "fDisableThemes" -Value 1 -Kind DWord
    Set-RegistryValue -Path $tsPolicy -Name "fDisableCursorSetting" -Value 1 -Kind DWord
    Set-RegistryValue -Path $tsPolicy -Name "fDisableFontSmoothing" -Value 1 -Kind DWord
}

Invoke-Tweak -Name "machine-welcome-suppression" -Action {
    $oobePolicy = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\OOBE"
    Set-RegistryValue -Path $oobePolicy -Name "DisablePrivacyExperience" -Value 1 -Kind DWord

    $cloudContent = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
    Set-RegistryValue -Path $cloudContent -Name "DisableWindowsConsumerFeatures" -Value 1 -Kind DWord
    Set-RegistryValue -Path $cloudContent -Name "DisableConsumerAccountStateContent" -Value 1 -Kind DWord

    $systemPolicy = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    Set-RegistryValue -Path $systemPolicy -Name "EnableFirstLogonAnimation" -Value 0 -Kind DWord
}

Invoke-Tweak -Name "notepad-common-text-associations" -Action {
    $className = "AzVmTextFile"
    $classRoot = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$className"
    Set-RegistryValue -Path $classRoot -Name "(default)" -Value "Co VM Text File" -Kind String
    $commandPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$className\shell\open\command"
    Set-RegistryValue -Path $commandPath -Name "(default)" -Value ("`"$notepadPath`" `"%1`"") -Kind String

    foreach ($ext in @($textExtensions)) {
        $extPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Classes\$ext"
        Set-RegistryValue -Path $extPath -Name "(default)" -Value $className -Kind String
    }
}

Invoke-Tweak -Name "explorer-ux-for-target-hives" -Action {
    $targets = Resolve-TargetHives
    foreach ($target in @($targets)) {
        Apply-ExplorerUxToHive -HiveNative ([string]$target.HiveNative) -Label ([string]$target.Label)
    }
}

Write-Host "windows-ux-performance-tuning-completed"
Write-Host "Update task completed: windows-ux-performance-tuning"
