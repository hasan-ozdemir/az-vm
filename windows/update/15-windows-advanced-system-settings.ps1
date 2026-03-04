$ErrorActionPreference = "Stop"

function Invoke-AdvancedWarn {
    param(
        [string]$Label,
        [scriptblock]$Action
    )

    try {
        & $Action
        Write-Output ("advanced-step-ok: {0}" -f $Label)
    }
    catch {
        Write-Warning ("advanced-step-failed: {0} => {1}" -f $Label, $_.Exception.Message)
    }
}

function Invoke-RegCmdWithAllowedExitCodes {
    param(
        [string]$CommandText,
        [int[]]$AllowedExitCodes = @(0)
    )

    if ([string]::IsNullOrWhiteSpace([string]$CommandText)) {
        throw "Registry command text is empty."
    }

    & cmd.exe /d /c $CommandText | Out-Null
    if ($AllowedExitCodes -notcontains [int]$LASTEXITCODE) {
        throw ("Registry command failed with exit code {0}: {1}" -f [int]$LASTEXITCODE, [string]$CommandText)
    }
}

function Set-DesktopIconSelection {
    param(
        [string]$HiveRoot
    )

    foreach ($viewKey in @("NewStartPanel", "ClassicStartMenu")) {
        $path = "{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\{1}" -f $HiveRoot, $viewKey
        $pathEscaped = ($path -replace '"', '\"')
        Invoke-RegCmdWithAllowedExitCodes -CommandText ("reg add `"" + $pathEscaped + "`" /v `"{59031a47-3f72-44a7-89c5-5595fe6b30ee}`" /t REG_DWORD /d 0 /f >nul 2>&1") # User Files
        Invoke-RegCmdWithAllowedExitCodes -CommandText ("reg add `"" + $pathEscaped + "`" /v `"{20D04FE0-3AEA-1069-A2D8-08002B30309D}`" /t REG_DWORD /d 0 /f >nul 2>&1") # This PC
        Invoke-RegCmdWithAllowedExitCodes -CommandText ("reg add `"" + $pathEscaped + "`" /v `"{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}`" /t REG_DWORD /d 0 /f >nul 2>&1") # Control Panel
        Invoke-RegCmdWithAllowedExitCodes -CommandText ("reg add `"" + $pathEscaped + "`" /v `"{645FF040-5081-101B-9F08-00AA002F954E}`" /t REG_DWORD /d 1 /f >nul 2>&1") # Recycle Bin hidden
    }
}

function Set-ClassicProfileVisualSettings {
    param(
        [string]$HiveRoot
    )

    Invoke-RegCmdWithAllowedExitCodes -CommandText ('reg delete "{0}\Control Panel\Desktop" /v Wallpaper /f >nul 2>&1' -f ($HiveRoot -replace '"', '\"')) -AllowedExitCodes @(0,1,2)
    Invoke-RegCmdWithAllowedExitCodes -CommandText ('reg add "{0}\Control Panel\Colors" /v Background /t REG_SZ /d "0 0 0" /f >nul 2>&1' -f ($HiveRoot -replace '"', '\"'))
    Invoke-RegCmdWithAllowedExitCodes -CommandText ('reg add "{0}\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" /v EnableTransparency /t REG_DWORD /d 0 /f >nul 2>&1' -f ($HiveRoot -replace '"', '\"'))
    Invoke-RegCmdWithAllowedExitCodes -CommandText ('reg add "{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ListviewAlphaSelect /t REG_DWORD /d 0 /f >nul 2>&1' -f ($HiveRoot -replace '"', '\"'))
    Invoke-RegCmdWithAllowedExitCodes -CommandText ('reg add "{0}\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAnimations /t REG_DWORD /d 0 /f >nul 2>&1' -f ($HiveRoot -replace '"', '\"'))
}

function Resolve-AdvancedTargetHives {
    # In non-interactive SSH sessions, loading other users' NTUSER.DAT can block on file locks.
    # Keep this task deterministic by applying only to the current user hive.
    return [pscustomobject]@{
        Targets = @("HKCU")
        Loaded = @()
    }
}

Invoke-AdvancedWarn -Label "desktop-icons-and-classic-ui-for-target-hives" -Action {
    $hiveState = Resolve-AdvancedTargetHives
    try {
        foreach ($hiveRoot in @($hiveState.Targets)) {
            Set-DesktopIconSelection -HiveRoot $hiveRoot
            Set-ClassicProfileVisualSettings -HiveRoot $hiveRoot
        }
    }
    finally {
        foreach ($loadedNative in @($hiveState.Loaded)) {
            & reg.exe unload $loadedNative | Out-Null
        }
    }
}

Invoke-AdvancedWarn -Label "visual-effects-best-performance" -Action {
    & reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" /v VisualFXSetting /t REG_DWORD /d 2 /f | Out-Null
}

Invoke-AdvancedWarn -Label "processor-background-services" -Action {
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\PriorityControl" /v Win32PrioritySeparation /t REG_DWORD /d 24 /f | Out-Null
}

Invoke-AdvancedWarn -Label "custom-pagefile-800-8192" -Action {
    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($computerSystem.AutomaticManagedPagefile) {
        Set-CimInstance -InputObject $computerSystem -Property @{ AutomaticManagedPagefile = $false } | Out-Null
    }

    $existingPageFiles = @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue)
    foreach ($existingPageFile in @($existingPageFiles)) {
        Remove-CimInstance -InputObject $existingPageFile -ErrorAction SilentlyContinue
    }

    try {
        New-CimInstance -ClassName Win32_PageFileSetting -Property @{
            Name = "C:\\pagefile.sys"
            InitialSize = [uint32]800
            MaximumSize = [uint32]8192
        } | Out-Null
    }
    catch {
        Invoke-RegCmdWithAllowedExitCodes -CommandText 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v PagingFiles /t REG_MULTI_SZ /d "C:\pagefile.sys 800 8192" /f >nul 2>&1'
        Invoke-RegCmdWithAllowedExitCodes -CommandText 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v ExistingPageFiles /t REG_MULTI_SZ /d "\??\C:\pagefile.sys" /f >nul 2>&1'
        Invoke-RegCmdWithAllowedExitCodes -CommandText 'reg add "HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" /v TempPageFile /t REG_DWORD /d 0 /f >nul 2>&1'
    }
}

Invoke-AdvancedWarn -Label "boot-timeout-and-dump-off" -Action {
    & bcdedit /timeout 0 | Out-Null
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v CrashDumpEnabled /t REG_DWORD /d 0 /f | Out-Null
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v AlwaysKeepMemoryDump /t REG_DWORD /d 0 /f | Out-Null
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v LogEvent /t REG_DWORD /d 0 /f | Out-Null
    & reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\CrashControl" /v SendAlert /t REG_DWORD /d 0 /f | Out-Null
}

Invoke-AdvancedWarn -Label "dep-always-off" -Action {
    & bcdedit /set "{current}" nx AlwaysOff | Out-Null
}

Invoke-AdvancedWarn -Label "refresh-user-visual-parameters" -Action {
    $rundllPath = Join-Path $env:WINDIR "System32\rundll32.exe"
    if (-not (Test-Path -LiteralPath $rundllPath)) {
        throw ("rundll32.exe was not found at '{0}'." -f $rundllPath)
    }

    $proc = Start-Process `
        -FilePath $rundllPath `
        -ArgumentList "user32.dll,UpdatePerUserSystemParameters" `
        -WindowStyle Hidden `
        -PassThru
    if (-not $proc.WaitForExit(15000)) {
        try { $proc.Kill() } catch { }
        Write-Warning "UpdatePerUserSystemParameters timed out and was terminated."
    }
}

Write-Output "windows-advanced-system-settings-completed"
