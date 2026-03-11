$ErrorActionPreference = "Stop"
Write-Host "Update task started: autologon-manager-user"

$vmAdminUser = "__VM_ADMIN_USER__"
$vmAdminPass = "__VM_ADMIN_PASS__"
$taskConfig = [ordered]@{
    WinlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    AutologonCandidates = @(
        'C:\ProgramData\chocolatey\lib\sysinternals\tools\Autologon.exe',
        'C:\ProgramData\chocolatey\lib\sysinternals\tools\Autologon64.exe',
        'C:\ProgramData\chocolatey\bin\Autologon.exe',
        'C:\ProgramData\chocolatey\bin\autologon.exe'
    )
}

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

function Test-PlaceholderValue {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return $true
    }

    $normalized = $Value.Trim().ToLowerInvariant()
    return (
        $normalized.Contains('change_me') -or
        $normalized.Contains('changeme') -or
        $normalized.Contains('replace_me') -or
        $normalized.Contains('set_me') -or
        $normalized.Contains('todo') -or
        $normalized.StartsWith('<') -or
        $normalized.EndsWith('>')
    )
}

function Resolve-AutologonExe {
    foreach ($candidate in @($taskConfig.AutologonCandidates)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }

        if (Test-Path -LiteralPath $candidate) {
            return [string]$candidate
        }
    }

    $chocoToolsDir = 'C:\ProgramData\chocolatey\lib\sysinternals\tools'
    if (Test-Path -LiteralPath $chocoToolsDir) {
        $match = Get-ChildItem -LiteralPath $chocoToolsDir -Filter 'Autologon*.exe' -File -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
        if ($match -and (Test-Path -LiteralPath $match.FullName)) {
            return [string]$match.FullName
        }
    }

    $cmd = Get-Command autologon -ErrorAction SilentlyContinue
    if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        return [string]$cmd.Source
    }

    return ''
}

if (-not ([System.Management.Automation.PSTypeName]'AzVmWin32LogonNative').Type) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class AzVmWin32LogonNative {
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool LogonUser(
        string lpszUsername,
        string lpszDomain,
        string lpszPassword,
        int dwLogonType,
        int dwLogonProvider,
        out IntPtr phToken
    );

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);
}
'@
}

function Assert-LocalCredentialValid {
    param(
        [string]$UserName,
        [string]$Password
    )

    $tokenHandle = [IntPtr]::Zero
    $logonOk = [AzVmWin32LogonNative]::LogonUser([string]$UserName, '.', [string]$Password, 2, 0, [ref]$tokenHandle)
    if ($tokenHandle -ne [IntPtr]::Zero) {
        [void][AzVmWin32LogonNative]::CloseHandle($tokenHandle)
    }

    if (-not $logonOk) {
        $win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw ("Local credential validation for user '{0}' failed with Win32 error {1}." -f [string]$UserName, $win32Error)
    }
}

function Get-AutologonState {
    $props = Get-ItemProperty -Path ([string]$taskConfig.WinlogonPath) -ErrorAction Stop
    $defaultDomainName = ''
    if ($props.PSObject.Properties.Match('DefaultDomainName').Count -gt 0) {
        $defaultDomainName = [string]$props.DefaultDomainName
    }

    $defaultPasswordPresent = $false
    if ($props.PSObject.Properties.Match('DefaultPassword').Count -gt 0) {
        $defaultPasswordPresent = -not [string]::IsNullOrWhiteSpace([string]$props.DefaultPassword)
    }

    return [pscustomobject]@{
        AutoAdminLogon = [string]$props.AutoAdminLogon
        DefaultUserName = [string]$props.DefaultUserName
        DefaultDomainName = [string]$defaultDomainName
        DefaultPasswordPresent = [bool]$defaultPasswordPresent
    }
}

function Assert-AutologonConfigured {
    param([string]$ExpectedUserName)

    $state = Get-AutologonState
    if (-not [string]::Equals([string]$state.AutoAdminLogon, '1', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Autologon verification failed: AutoAdminLogon is not enabled."
    }

    if (-not [string]::Equals([string]$state.DefaultUserName, [string]$ExpectedUserName, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Autologon verification failed: DefaultUserName '{0}' does not match '{1}'." -f [string]$state.DefaultUserName, [string]$ExpectedUserName)
    }

    if ([string]::IsNullOrWhiteSpace([string]$state.DefaultDomainName)) {
        throw "Autologon verification failed: DefaultDomainName is empty."
    }

    $expectedDomains = @('.', $env:COMPUTERNAME)
    $domainMatch = $false
    foreach ($expectedDomain in @($expectedDomains)) {
        if ([string]::Equals([string]$state.DefaultDomainName, [string]$expectedDomain, [System.StringComparison]::OrdinalIgnoreCase)) {
            $domainMatch = $true
            break
        }
    }

    if (-not $domainMatch) {
        throw ("Autologon verification failed: DefaultDomainName '{0}' does not match '.' or '{1}'." -f [string]$state.DefaultDomainName, [string]$env:COMPUTERNAME)
    }

    Write-Host ("autologon-state => AutoAdminLogon={0}; DefaultUserName={1}; DefaultDomainName={2}; DefaultPasswordPresent={3}" -f [string]$state.AutoAdminLogon, [string]$state.DefaultUserName, [string]$state.DefaultDomainName, [bool]$state.DefaultPasswordPresent)
}

if (Test-PlaceholderValue -Value $vmAdminUser) {
    throw "VM_ADMIN_USER is required and must not be empty or a placeholder."
}
if (Test-PlaceholderValue -Value $vmAdminPass) {
    throw "VM_ADMIN_PASS is required and must not be empty or a placeholder."
}

Refresh-SessionPath
$autologonExe = Resolve-AutologonExe
if ([string]::IsNullOrWhiteSpace([string]$autologonExe)) {
    throw "autologon.exe was not found. Ensure 108-install-sysinternals-suite completed successfully."
}

Assert-LocalCredentialValid -UserName $vmAdminUser -Password $vmAdminPass

Write-Host ("Resolved autologon executable: {0}" -f [string]$autologonExe)
Write-Host ("Running: {0} /accepteula {1} . <redacted>" -f [string]$autologonExe, [string]$vmAdminUser)
$autologonOutput = & $autologonExe /accepteula $vmAdminUser '.' $vmAdminPass 2>&1
$autologonExit = [int]$LASTEXITCODE
if ($autologonOutput) {
    $autologonOutput | ForEach-Object { Write-Host ([string]$_) }
}

if ($autologonExit -ne 0) {
    throw ("autologon exited with code {0}." -f $autologonExit)
}

Start-Sleep -Seconds 1
Assert-AutologonConfigured -ExpectedUserName $vmAdminUser

Write-Host "autologon-manager-user-completed"
Write-Host "Update task completed: autologon-manager-user"
