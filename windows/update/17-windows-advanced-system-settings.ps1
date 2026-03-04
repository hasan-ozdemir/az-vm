$ErrorActionPreference = "Stop"
Write-Host "Update task started: windows-advanced-system-settings"

function Invoke-Advanced {
    param([string]$Label, [scriptblock]$Action)
    try {
        & $Action
        Write-Host "advanced-step-ok: $Label"
    }
    catch {
        Write-Warning "advanced-step-failed: $Label => $($_.Exception.Message)"
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

function Set-MasterVolumeMax {
    $source = @"
using System;
using System.Runtime.InteropServices;

[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
    int RegisterControlChangeNotify(IntPtr pNotify);
    int UnregisterControlChangeNotify(IntPtr pNotify);
    int GetChannelCount(out uint pnChannelCount);
    int SetMasterVolumeLevel(float fLevelDB, Guid pguidEventContext);
    int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
    int GetMasterVolumeLevel(out float pfLevelDB);
    int GetMasterVolumeLevelScalar(out float pfLevel);
    int SetChannelVolumeLevel(uint nChannel, float fLevelDB, Guid pguidEventContext);
    int SetChannelVolumeLevelScalar(uint nChannel, float fLevel, Guid pguidEventContext);
    int GetChannelVolumeLevel(uint nChannel, out float pfLevelDB);
    int GetChannelVolumeLevelScalar(uint nChannel, out float pfLevel);
    int SetMute(bool bMute, Guid pguidEventContext);
    int GetMute(out bool pbMute);
    int GetVolumeStepInfo(out uint pnStep, out uint pnStepCount);
    int VolumeStepUp(Guid pguidEventContext);
    int VolumeStepDown(Guid pguidEventContext);
    int QueryHardwareSupport(out uint pdwHardwareSupportMask);
    int GetVolumeRange(out float pflVolumeMindB, out float pflVolumeMaxdB, out float pflVolumeIncrementdB);
}

[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
    int NotImpl1();
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice ppDevice);
}

[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
    int Activate(ref Guid id, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object interfacePointer);
}

[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
class MMDeviceEnumeratorComObject { }

public static class VolumeControl {
    public static void SetMasterVolume(float level) {
        var enumerator = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
        IMMDevice device;
        Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0, 1, out device));
        object epvObj;
        var epvGuid = typeof(IAudioEndpointVolume).GUID;
        Marshal.ThrowExceptionForHR(device.Activate(ref epvGuid, 23, IntPtr.Zero, out epvObj));
        var epv = (IAudioEndpointVolume)epvObj;
        Marshal.ThrowExceptionForHR(epv.SetMasterVolumeLevelScalar(level, Guid.Empty));
        Marshal.ThrowExceptionForHR(epv.SetMute(false, Guid.Empty));
    }
}
"@

    if (-not ("VolumeControl" -as [type])) {
        Add-Type -TypeDefinition $source -Language CSharp
    }

    [VolumeControl]::SetMasterVolume([single]1.0)
}

function Resolve-Hives {
    $targets = @([pscustomobject]@{ Label = "CurrentUser"; Hive = "HKCU" })
    foreach ($userName in @("__VM_USER__", "__ASSISTANT_USER__")) {
        if ([string]::IsNullOrWhiteSpace([string]$userName)) { continue }
        try {
            $sid = [string](Get-LocalUser -Name $userName -ErrorAction Stop).SID.Value
            if (-not [string]::IsNullOrWhiteSpace($sid) -and (Test-Path -LiteralPath ("Registry::HKEY_USERS\\" + $sid))) {
                $targets += [pscustomobject]@{ Label = $userName; Hive = "HKU\\$sid" }
            }
        }
        catch {
            Write-Warning "Could not resolve hive for '$userName': $($_.Exception.Message)"
        }
    }
    return @($targets | Select-Object -Unique Hive,Label)
}

function Apply-ExplorerDesktopProfile {
    param([string]$Hive, [string]$Label)

    $allFoldersShell = "Registry::$Hive\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell"
    Set-RegistryValue -Path $allFoldersShell -Name "LogicalViewMode" -Value 1 -Kind DWord   # Details
    Set-RegistryValue -Path $allFoldersShell -Name "Mode" -Value 4 -Kind DWord              # Details mode
    Set-RegistryValue -Path $allFoldersShell -Name "Sort" -Value "prop:System.ItemNameDisplay" -Kind String
    Set-RegistryValue -Path $allFoldersShell -Name "SortDirection" -Value 0 -Kind DWord
    Set-RegistryValue -Path $allFoldersShell -Name "GroupView" -Value 0 -Kind DWord         # Group none
    Set-RegistryValue -Path $allFoldersShell -Name "IconSize" -Value 48 -Kind DWord         # medium fallback

    $desktopBag = "Registry::$Hive\Software\Microsoft\Windows\Shell\Bags\1\Desktop"
    Set-RegistryValue -Path $desktopBag -Name "IconSize" -Value 48 -Kind DWord
    Set-RegistryValue -Path $desktopBag -Name "Sort" -Value "prop:System.ItemNameDisplay" -Kind String
    Set-RegistryValue -Path $desktopBag -Name "SortDirection" -Value 0 -Kind DWord
    Set-RegistryValue -Path $desktopBag -Name "GroupView" -Value 0 -Kind DWord
    Set-RegistryValue -Path $desktopBag -Name "FFlags" -Value 1075839525 -Kind DWord

    $advanced = "Registry::$Hive\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-RegistryValue -Path $advanced -Name "AutoArrange" -Value 1 -Kind DWord
    Set-RegistryValue -Path $advanced -Name "SnapToGrid" -Value 1 -Kind DWord
    Set-RegistryValue -Path $advanced -Name "IconsOnly" -Value 1 -Kind DWord

    Write-Host "profile-view-ready: $Label"
}

Invoke-Advanced -Label "desktop-icons-selection" -Action {
    foreach ($viewKey in @("NewStartPanel", "ClassicStartMenu")) {
        $path = "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\$viewKey"
        Set-RegistryValue -Path $path -Name "{59031a47-3f72-44a7-89c5-5595fe6b30ee}" -Value 0 -Kind DWord # User Files
        Set-RegistryValue -Path $path -Name "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" -Value 0 -Kind DWord # This PC
        Set-RegistryValue -Path $path -Name "{5399E694-6CE5-4D6C-8FCE-1D8870FDCBA0}" -Value 0 -Kind DWord # Control Panel
        Set-RegistryValue -Path $path -Name "{645FF040-5081-101B-9F08-00AA002F954E}" -Value 1 -Kind DWord # Recycle Bin hidden
    }
}

Invoke-Advanced -Label "explorer-and-desktop-view" -Action {
    foreach ($target in @(Resolve-Hives)) {
        Apply-ExplorerDesktopProfile -Hive ([string]$target.Hive) -Label ([string]$target.Label)
    }
}

Invoke-Advanced -Label "visual-effects-best-performance" -Action {
    Set-RegistryValue -Path "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 2 -Kind DWord
}

Invoke-Advanced -Label "processor-background-services" -Action {
    Set-RegistryValue -Path "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\PriorityControl" -Name "Win32PrioritySeparation" -Value 24 -Kind DWord
}

Invoke-Advanced -Label "custom-pagefile-800-8192" -Action {
    Set-RegistryValue -Path "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "PagingFiles" -Value "C:\\pagefile.sys 800 8192" -Kind MultiString
    Set-RegistryValue -Path "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "ExistingPageFiles" -Value "\\??\\C:\\pagefile.sys" -Kind MultiString
    Set-RegistryValue -Path "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" -Name "TempPageFile" -Value 0 -Kind DWord
}

Invoke-Advanced -Label "boot-timeout-and-dump-off" -Action {
    bcdedit /timeout 0
    if ($LASTEXITCODE -ne 0) { throw "bcdedit /timeout failed with exit code $LASTEXITCODE." }

    Set-RegistryValue -Path "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\CrashControl" -Name "CrashDumpEnabled" -Value 0 -Kind DWord
    Set-RegistryValue -Path "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\CrashControl" -Name "AlwaysKeepMemoryDump" -Value 0 -Kind DWord
    Set-RegistryValue -Path "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\CrashControl" -Name "LogEvent" -Value 0 -Kind DWord
    Set-RegistryValue -Path "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\CrashControl" -Name "SendAlert" -Value 0 -Kind DWord
}

Invoke-Advanced -Label "dep-always-off" -Action {
    bcdedit /set "{current}" nx AlwaysOff
    if ($LASTEXITCODE -ne 0) { throw "bcdedit DEP change failed with exit code $LASTEXITCODE." }
}

Invoke-Advanced -Label "set-volume-max" -Action {
    Set-MasterVolumeMax
}

Invoke-Advanced -Label "refresh-user-visual-parameters" -Action {
    $rundllPath = Join-Path $env:WINDIR "System32\rundll32.exe"
    if (Test-Path -LiteralPath $rundllPath) {
        Start-Process -FilePath $rundllPath -ArgumentList "user32.dll,UpdatePerUserSystemParameters" -WindowStyle Hidden -Wait
    }
}

Write-Host "windows-advanced-system-settings-completed"
Write-Host "Update task completed: windows-advanced-system-settings"
