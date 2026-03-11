# RDP command entry.

# Handles Invoke-AzVmRdpConnectCommand.
function Invoke-AzVmRdpConnectCommand {
    param(
        [hashtable]$Options
    )

    if (Test-AzVmCliOptionPresent -Options $Options -Name 'test') {
        Invoke-AzVmRdpConnectivityTest -Options $Options
        return
    }

    $runtime = Initialize-AzVmConnectionCommandContext -Options $Options -OperationName 'rdp'
    if (-not [string]::Equals(([string]$runtime.OsType).Trim(), 'Windows', [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-FriendlyError `
            -Detail ("VM '{0}' reports osType '{1}', so RDP launch is not supported." -f [string]$runtime.VmName, [string]$runtime.OsType) `
            -Code 66 `
            -Summary "RDP command is only available for Windows VMs." `
            -Hint "Use the ssh command for Linux VMs, or target a Windows VM."
    }

    $cmdKeyPath = Resolve-AzVmLocalExecutablePath -Candidates @((Join-Path $env:SystemRoot 'System32\cmdkey.exe'), 'cmdkey.exe') -FriendlyName 'Windows Credential Manager'
    $mstscPath = Resolve-AzVmLocalExecutablePath -Candidates @((Join-Path $env:SystemRoot 'System32\mstsc.exe'), 'mstsc.exe') -FriendlyName 'Remote Desktop Connection'
    $credentialTarget = ("TERMSRV/{0}" -f [string]$runtime.ConnectionHost)
    $rdpUserName = (".\{0}" -f [string]$runtime.SelectedUserName)
    $cmdKeyArgs = @("/generic:$credentialTarget", "/user:$rdpUserName", "/pass:$([string]$runtime.SelectedPassword)")

    Write-Host ("Staging RDP credentials for VM '{0}' in group '{1}'..." -f [string]$runtime.VmName, [string]$runtime.ResourceGroup) -ForegroundColor Cyan
    $cmdKeyProcess = Start-Process -FilePath $cmdKeyPath -ArgumentList $cmdKeyArgs -Wait -PassThru -WindowStyle Hidden
    if ($null -eq $cmdKeyProcess -or [int]$cmdKeyProcess.ExitCode -ne 0) {
        $exitCode = if ($null -eq $cmdKeyProcess) { -1 } else { [int]$cmdKeyProcess.ExitCode }
        Throw-FriendlyError `
            -Detail ("cmdkey failed while staging credentials for target '{0}' (exit={1})." -f $credentialTarget, $exitCode) `
            -Code 66 `
            -Summary "RDP credential staging failed." `
            -Hint "Verify local Windows credential manager access and retry."
    }

    Write-Host ("Launching mstsc for {0}:{1}..." -f [string]$runtime.ConnectionHost, [string]$runtime.VmRdpPort) -ForegroundColor Cyan
    Start-Process -FilePath $mstscPath -ArgumentList @("/v:{0}:{1}" -f [string]$runtime.ConnectionHost, [string]$runtime.VmRdpPort) | Out-Null
}
