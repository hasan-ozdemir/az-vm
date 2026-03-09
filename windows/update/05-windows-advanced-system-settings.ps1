$ErrorActionPreference = "Stop"
Write-Host "Update task started: windows-advanced-system-settings"

function Set-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [Microsoft.Win32.RegistryValueKind]$Kind
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Kind -Force | Out-Null
}

function Assert-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$ExpectedValue
    )

    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
    $actualValue = $item.$Name
    if ([string]$actualValue -ne [string]$ExpectedValue) {
        throw ("Registry validation failed: {0}\{1} expected '{2}' but got '{3}'." -f $Path, $Name, $ExpectedValue, $actualValue)
    }
}

$visualEffectsPath = "Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects"
Set-RegistryValue -Path $visualEffectsPath -Name "VisualFXSetting" -Value 2 -Kind DWord
Write-Host "advanced-step-ok: visual-effects-best-performance"

$priorityControlPath = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\PriorityControl"
Set-RegistryValue -Path $priorityControlPath -Name "Win32PrioritySeparation" -Value 24 -Kind DWord
Write-Host "advanced-step-ok: processor-background-services"

$memoryManagementPath = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management"
Set-RegistryValue -Path $memoryManagementPath -Name "PagingFiles" -Value "C:\pagefile.sys 800 8192" -Kind MultiString
Set-RegistryValue -Path $memoryManagementPath -Name "ExistingPageFiles" -Value "\??\C:\pagefile.sys" -Kind MultiString
Set-RegistryValue -Path $memoryManagementPath -Name "TempPageFile" -Value 0 -Kind DWord
Write-Host "advanced-step-ok: custom-pagefile-800-8192"

bcdedit /timeout 0
if ($LASTEXITCODE -ne 0) {
    throw ("bcdedit /timeout failed with exit code {0}." -f $LASTEXITCODE)
}

$crashControlPath = "Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\CrashControl"
Set-RegistryValue -Path $crashControlPath -Name "CrashDumpEnabled" -Value 0 -Kind DWord
Set-RegistryValue -Path $crashControlPath -Name "AlwaysKeepMemoryDump" -Value 0 -Kind DWord
Set-RegistryValue -Path $crashControlPath -Name "LogEvent" -Value 0 -Kind DWord
Set-RegistryValue -Path $crashControlPath -Name "SendAlert" -Value 0 -Kind DWord
Write-Host "advanced-step-ok: boot-timeout-and-dump-off"

bcdedit /set "{current}" nx AlwaysOff
if ($LASTEXITCODE -ne 0) {
    throw ("bcdedit DEP change failed with exit code {0}." -f $LASTEXITCODE)
}
Write-Host "advanced-step-ok: dep-always-off"

Assert-RegistryValue -Path $visualEffectsPath -Name "VisualFXSetting" -ExpectedValue 2
Assert-RegistryValue -Path $priorityControlPath -Name "Win32PrioritySeparation" -ExpectedValue 24
Assert-RegistryValue -Path $memoryManagementPath -Name "TempPageFile" -ExpectedValue 0
Assert-RegistryValue -Path $crashControlPath -Name "CrashDumpEnabled" -ExpectedValue 0

Write-Host "windows-advanced-system-settings-completed"
Write-Host "Update task completed: windows-advanced-system-settings"
