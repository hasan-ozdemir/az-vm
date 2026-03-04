$ErrorActionPreference = "Stop"

$managerUser = "__VM_USER__"
$assistantUser = "__ASSISTANT_USER__"
$targetUsers = @($managerUser, $assistantUser)
$notepadPath = Join-Path $env:WINDIR "System32\notepad.exe"
$textExtensions = @(
    ".txt", ".log", ".ini", ".cfg", ".conf", ".csv", ".xml", ".json",
    ".yaml", ".yml", ".md", ".ps1", ".cmd", ".bat", ".reg", ".sql"
)
$script:tweakWarnings = New-Object 'System.Collections.Generic.List[string]'
$loadedHives = New-Object 'System.Collections.Generic.List[string]'

function Invoke-Tweak {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    try {
        & $Action
        Write-Output ("tweak-ok: {0}" -f $Name)
    }
    catch {
        $message = if ($_.Exception) { $_.Exception.Message } else { [string]$_ }
        $entry = "{0} => {1}" -f $Name, $message
        Write-Warning $entry
        [void]$script:tweakWarnings.Add($entry)
    }
}

function Invoke-RegAdd {
    param(
        [string]$Path,
        [string]$Name = "",
        [string]$Type = "REG_SZ",
        [string]$Value = ""
    )

    $args = @("add", $Path, "/f")
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $args += "/ve"
    }
    else {
        $args += @("/v", $Name)
    }
    $hasExplicitData = -not ([string]::IsNullOrWhiteSpace($Name) -and [string]::IsNullOrWhiteSpace($Value))
    if ($hasExplicitData -and -not [string]::IsNullOrWhiteSpace($Type)) {
        $args += @("/t", $Type)
    }
    if ($hasExplicitData) {
        $args += @("/d", $Value)
    }

    $escapedArgs = @()
    foreach ($arg in @($args)) {
        $text = [string]$arg
        if ($text -match '\s') {
            $escapedArgs += ('"{0}"' -f ($text -replace '"', '\"'))
        }
        else {
            $escapedArgs += $text
        }
    }
    $cmdLine = ("reg {0} >nul 2>&1" -f ($escapedArgs -join " "))
    & cmd.exe /d /c $cmdLine | Out-Null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1 -and $LASTEXITCODE -ne 2) {
        throw ("reg add failed for path '{0}' name '{1}'." -f $Path, $Name)
    }
}

function Invoke-RegDelete {
    param(
        [string]$Path
    )

    $cmdLine = ('reg delete "{0}" /f >nul 2>&1' -f ($Path -replace '"', '\"'))
    & cmd.exe /d /c $cmdLine | Out-Null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1 -and $LASTEXITCODE -ne 2) {
        throw ("reg delete failed for path '{0}'." -f $Path)
    }
}

function Load-HiveIfPossible {
    param(
        [string]$Alias,
        [string]$NtUserPath
    )

    if ([string]::IsNullOrWhiteSpace($Alias) -or [string]::IsNullOrWhiteSpace($NtUserPath)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $NtUserPath)) {
        return $false
    }

    $hiveKey = "HKU\$Alias"
    $safeLoad = ('reg load "{0}" "{1}" >nul 2>&1' -f $hiveKey, $NtUserPath)
    & cmd.exe /d /c $safeLoad | Out-Null
    if ($LASTEXITCODE -eq 0) {
        [void]$script:loadedHives.Add($hiveKey)
        return $true
    }

    return $false
}

function Resolve-TargetHives {
    $targets = @()

    if (Load-HiveIfPossible -Alias "CoVmDefaultUser" -NtUserPath "C:\Users\Default\NTUSER.DAT") {
        $targets += [pscustomobject]@{
            Label = "DefaultUser"
            HiveNative = "HKU\CoVmDefaultUser"
        }
    }
    else {
        Write-Warning "Default user hive could not be loaded from C:\Users\Default\NTUSER.DAT."
    }

    foreach ($userName in @($targetUsers | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        try {
            $localUser = Get-LocalUser -Name $userName -ErrorAction Stop
            $sid = [string]$localUser.SID.Value
            if (-not [string]::IsNullOrWhiteSpace($sid) -and (Test-Path -LiteralPath ("Registry::HKEY_USERS\" + $sid))) {
                $targets += [pscustomobject]@{
                    Label = $userName
                    HiveNative = "HKU\$sid"
                }
                continue
            }

            $profilePath = ""
            if (-not [string]::IsNullOrWhiteSpace($sid)) {
                try {
                    $profilePath = [string](Get-ItemPropertyValue -Path ("Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\" + $sid) -Name "ProfileImagePath" -ErrorAction SilentlyContinue)
                }
                catch { }
            }
            if ([string]::IsNullOrWhiteSpace($profilePath)) {
                $profilePath = "C:\Users\$userName"
            }

            $ntUserPath = Join-Path $profilePath "NTUSER.DAT"
            $alias = "CoVmUser_" + $userName
            if (Load-HiveIfPossible -Alias $alias -NtUserPath $ntUserPath) {
                $targets += [pscustomobject]@{
                    Label = $userName
                    HiveNative = "HKU\$alias"
                }
            }
            else {
                Write-Output ("User hive could not be loaded for '{0}'. Profile may not be materialized yet." -f $userName)
            }
        }
        catch {
            Write-Warning ("Local user lookup failed for '{0}': {1}" -f $userName, $_.Exception.Message)
        }
    }

    return @($targets)
}

function Apply-ExplorerAndUxToUserHive {
    param(
        [string]$HiveNative,
        [string]$Label
    )

    Invoke-Tweak -Name ("explorer-advanced-{0}" -f $Label) -Action {
        $advanced = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        Invoke-RegAdd -Path $advanced -Name "LaunchTo" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $advanced -Name "Hidden" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $advanced -Name "ShowSuperHidden" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $advanced -Name "HideFileExt" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $advanced -Name "ShowInfoTip" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $advanced -Name "IconsOnly" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $advanced -Name "DisablePreviewDesktop" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $advanced -Name "TaskbarAnimations" -Type "REG_DWORD" -Value "0"
    }

    Invoke-Tweak -Name ("explorer-thumbnail-policy-{0}" -f $Label) -Action {
        $policyPath = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
        Invoke-RegAdd -Path $policyPath -Name "DisableThumbnails" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $policyPath -Name "NoThumbnailCache" -Type "REG_DWORD" -Value "1"
    }

    Invoke-Tweak -Name ("explorer-shellbags-{0}" -f $Label) -Action {
        $shellPath = "$HiveNative\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell"
        Invoke-RegAdd -Path $shellPath -Name "FolderType" -Type "REG_SZ" -Value "NotSpecified"
        Invoke-RegAdd -Path $shellPath -Name "LogicalViewMode" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $shellPath -Name "Mode" -Type "REG_DWORD" -Value "4"
        Invoke-RegAdd -Path $shellPath -Name "GroupView" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $shellPath -Name "Sort" -Type "REG_SZ" -Value "prop:System.ItemNameDisplay"
        Invoke-RegAdd -Path $shellPath -Name "SortDirection" -Type "REG_DWORD" -Value "0"
    }

    Invoke-Tweak -Name ("desktop-view-{0}" -f $Label) -Action {
        $desktopPath = "$HiveNative\Software\Microsoft\Windows\Shell\Bags\1\Desktop"
        Invoke-RegAdd -Path $desktopPath -Name "IconSize" -Type "REG_DWORD" -Value "48"
        Invoke-RegAdd -Path $desktopPath -Name "Sort" -Type "REG_SZ" -Value "prop:System.ItemNameDisplay"
        Invoke-RegAdd -Path $desktopPath -Name "SortDirection" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $desktopPath -Name "GroupView" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $desktopPath -Name "FFlags" -Type "REG_DWORD" -Value "1075839525"
    }

    Invoke-Tweak -Name ("control-panel-view-{0}" -f $Label) -Action {
        $controlPanelPath = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\Explorer\ControlPanel"
        Invoke-RegAdd -Path $controlPanelPath -Name "StartupPage" -Type "REG_DWORD" -Value "1"
        Invoke-RegAdd -Path $controlPanelPath -Name "AllItemsIconView" -Type "REG_DWORD" -Value "0"
    }

    Invoke-Tweak -Name ("context-menu-classic-{0}" -f $Label) -Action {
        $ctxPath = "$HiveNative\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
        Invoke-RegAdd -Path $ctxPath -Name "" -Type "REG_SZ" -Value ""
    }

    Invoke-Tweak -Name ("welcome-suppression-user-{0}" -f $Label) -Action {
        $cdm = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        Invoke-RegAdd -Path $cdm -Name "ContentDeliveryAllowed" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $cdm -Name "FeatureManagementEnabled" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $cdm -Name "OemPreInstalledAppsEnabled" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $cdm -Name "PreInstalledAppsEnabled" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $cdm -Name "PreInstalledAppsEverEnabled" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $cdm -Name "SilentInstalledAppsEnabled" -Type "REG_DWORD" -Value "0"
        Invoke-RegAdd -Path $cdm -Name "SystemPaneSuggestionsEnabled" -Type "REG_DWORD" -Value "0"
        foreach ($valueName in @(
            "SubscribedContent-310093Enabled",
            "SubscribedContent-338388Enabled",
            "SubscribedContent-338389Enabled",
            "SubscribedContent-338393Enabled",
            "SubscribedContent-353694Enabled",
            "SubscribedContent-353696Enabled",
            "SubscribedContent-353698Enabled",
            "SubscribedContent-353699Enabled",
            "SubscribedContent-353702Enabled",
            "SubscribedContent-353703Enabled"
        )) {
            Invoke-RegAdd -Path $cdm -Name $valueName -Type "REG_DWORD" -Value "0"
        }

        $privacyPath = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\Privacy"
        Invoke-RegAdd -Path $privacyPath -Name "TailoredExperiencesWithDiagnosticDataEnabled" -Type "REG_DWORD" -Value "0"
        $engagementPath = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement"
        Invoke-RegAdd -Path $engagementPath -Name "ScoobeSystemSettingEnabled" -Type "REG_DWORD" -Value "0"
        $adsPath = "$HiveNative\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo"
        Invoke-RegAdd -Path $adsPath -Name "Enabled" -Type "REG_DWORD" -Value "0"
    }
}

Invoke-Tweak -Name "machine-rdp-speed-policies" -Action {
    $tsPolicy = "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
    Invoke-RegAdd -Path $tsPolicy -Name "fDisableWallpaper" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $tsPolicy -Name "fDisableFullWindowDrag" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $tsPolicy -Name "fDisableMenuAnims" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $tsPolicy -Name "fDisableThemes" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $tsPolicy -Name "fDisableCursorSetting" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $tsPolicy -Name "fDisableFontSmoothing" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $tsPolicy -Name "ColorDepth" -Type "REG_DWORD" -Value "2"
}

Invoke-Tweak -Name "machine-welcome-suppression" -Action {
    $oobePolicy = "HKLM\SOFTWARE\Policies\Microsoft\Windows\OOBE"
    Invoke-RegAdd -Path $oobePolicy -Name "DisablePrivacyExperience" -Type "REG_DWORD" -Value "1"
    $cloudContent = "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent"
    Invoke-RegAdd -Path $cloudContent -Name "DisableWindowsConsumerFeatures" -Type "REG_DWORD" -Value "1"
    Invoke-RegAdd -Path $cloudContent -Name "DisableConsumerAccountStateContent" -Type "REG_DWORD" -Value "1"
    $systemPolicy = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    Invoke-RegAdd -Path $systemPolicy -Name "EnableFirstLogonAnimation" -Type "REG_DWORD" -Value "0"
    $oobeState = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE"
    Invoke-RegAdd -Path $oobeState -Name "PrivacyConsentStatus" -Type "REG_DWORD" -Value "1"
}

Invoke-Tweak -Name "machine-context-menu-classic" -Action {
    $ctxPath = "HKLM\SOFTWARE\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
    $safeCmd = ('reg add "{0}" /ve /f >nul 2>&1' -f ($ctxPath -replace '"', '\"'))
    & cmd.exe /d /c $safeCmd | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Output "machine-context-menu-classic skipped (key may be protected by ACL)."
    }
}

Invoke-Tweak -Name "machine-visual-effects-performance" -Action {
    $visualEffectsPath = "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"
    Invoke-RegAdd -Path $visualEffectsPath -Name "VisualFXSetting" -Type "REG_DWORD" -Value "2"
}

Invoke-Tweak -Name "power-maximum-performance" -Action {
    $ultimateGuid = "e9a42b02-d5df-448d-aa00-03f14749eb61"
    $highGuid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
    & powercfg /setactive $ultimateGuid | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & powercfg /setactive $highGuid | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Neither Ultimate nor High performance power scheme could be activated."
        }
    }

    foreach ($powerArgLine in @(
        "/change monitor-timeout-ac 0",
        "/change monitor-timeout-dc 0",
        "/change standby-timeout-ac 0",
        "/change standby-timeout-dc 0",
        "/change disk-timeout-ac 0",
        "/change disk-timeout-dc 0",
        "/change hibernate-timeout-ac 0",
        "/change hibernate-timeout-dc 0",
        "/setacvalueindex scheme_current SUB_PROCESSOR PROCTHROTTLEMIN 100",
        "/setacvalueindex scheme_current SUB_PROCESSOR PROCTHROTTLEMAX 100",
        "/setdcvalueindex scheme_current SUB_PROCESSOR PROCTHROTTLEMIN 100",
        "/setdcvalueindex scheme_current SUB_PROCESSOR PROCTHROTTLEMAX 100",
        "/hibernate off"
    )) {
        $powerArgs = @($powerArgLine -split " ")
        & powercfg @powerArgs | Out-Null
    }
}

Invoke-Tweak -Name "notepad-strict-legacy-removal" -Action {
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        $appxPackages = @(Get-AppxPackage -AllUsers | Where-Object {
            [string]$_.Name -like "Microsoft.WindowsNotepad*"
        })
        foreach ($pkg in @($appxPackages)) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            }
            catch {
                try {
                    Remove-AppxPackage -Package $pkg.PackageFullName -ErrorAction Stop
                }
                catch {
                    Write-Warning ("Remove-AppxPackage failed for {0}: {1}" -f $pkg.PackageFullName, $_.Exception.Message)
                }
            }
        }
    }

    if (Get-Command Get-AppxProvisionedPackage -ErrorAction SilentlyContinue) {
        $provisioned = @(Get-AppxProvisionedPackage -Online | Where-Object {
            [string]$_.DisplayName -like "Microsoft.WindowsNotepad*"
        })
        foreach ($prov in @($provisioned)) {
            try {
                Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Warning ("Remove-AppxProvisionedPackage failed for {0}: {1}" -f $prov.PackageName, $_.Exception.Message)
            }
        }
    }

    & dism.exe /online /Remove-Capability /CapabilityName:Microsoft.Windows.Notepad~~~~0.0.1.0 /NoRestart | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Output "DISM capability removal for Microsoft.Windows.Notepad was not completed."
    }

    if (-not (Test-Path -LiteralPath $notepadPath)) {
        throw ("Legacy notepad executable was not found at '{0}'." -f $notepadPath)
    }
}

Invoke-Tweak -Name "notepad-common-text-associations" -Action {
    $className = "CoVmTextFile"
    Invoke-RegAdd -Path ("HKLM\SOFTWARE\Classes\" + $className) -Name "" -Type "REG_SZ" -Value "Co VM Text File"
    Invoke-RegAdd -Path ("HKLM\SOFTWARE\Classes\" + $className + "\shell\open\command") -Name "" -Type "REG_SZ" -Value ("`"" + $notepadPath + "`" `"%1`"")
    & cmd.exe /d /c ("ftype {0}=`"{1}`" `"%1`"" -f $className, $notepadPath) | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "ftype command for CoVmTextFile failed."
    }

    foreach ($ext in @($textExtensions)) {
        Invoke-RegAdd -Path ("HKLM\SOFTWARE\Classes\" + $ext) -Name "" -Type "REG_SZ" -Value $className
        & cmd.exe /d /c ("assoc {0}={1}" -f $ext, $className) | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning ("assoc command failed for extension '{0}'." -f $ext)
        }
    }
}

$targetHives = @()
try {
    $targetHives = Resolve-TargetHives
    foreach ($targetHive in @($targetHives)) {
        $hiveNative = [string]$targetHive.HiveNative
        $label = [string]$targetHive.Label
        Apply-ExplorerAndUxToUserHive -HiveNative $hiveNative -Label $label

        Invoke-Tweak -Name ("text-association-userchoice-reset-{0}" -f $label) -Action {
            foreach ($ext in @($textExtensions)) {
                $userChoicePath = "{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\{1}\UserChoice" -f $hiveNative, $ext
                Invoke-RegDelete -Path $userChoicePath
                Invoke-RegAdd -Path ("{0}\Software\Classes\{1}" -f $hiveNative, $ext) -Name "" -Type "REG_SZ" -Value "CoVmTextFile"
            }
        }
    }
}
finally {
    foreach ($loadedHive in @($loadedHives)) {
        $safeUnload = ('reg unload "{0}" >nul 2>&1' -f $loadedHive)
        & cmd.exe /d /c $safeUnload | Out-Null
    }
}

if ($tweakWarnings.Count -gt 0) {
    Write-Warning ("windows-ux-performance-tuning completed with {0} warning(s)." -f $tweakWarnings.Count)
    foreach ($warnEntry in @($tweakWarnings)) {
        Write-Warning ("- " + $warnEntry)
    }
}
else {
    Write-Output "windows-ux-performance-tuning completed with no warnings."
}

Write-Output "windows-ux-tuning-ready"
