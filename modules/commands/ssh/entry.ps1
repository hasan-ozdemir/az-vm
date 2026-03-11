# SSH command entry.

# Handles Invoke-AzVmSshConnectCommand.
function Invoke-AzVmSshConnectCommand {
    param(
        [hashtable]$Options
    )

    if (Test-AzVmCliOptionPresent -Options $Options -Name 'test') {
        Invoke-AzVmSshConnectivityTest -Options $Options
        return
    }

    $runtime = Initialize-AzVmConnectionCommandContext -Options $Options -OperationName 'ssh'
    $sshExePath = Resolve-AzVmLocalExecutablePath -Candidates @('ssh.exe', (Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe')) -FriendlyName 'Windows OpenSSH'
    $targetText = ("{0}@{1}" -f [string]$runtime.SelectedUserName, [string]$runtime.ConnectionHost)
    $sshArgs = @('-p', [string]$runtime.VmSshPort, $targetText)

    Write-Host ("Launching SSH client for VM '{0}' in group '{1}'..." -f [string]$runtime.VmName, [string]$runtime.ResourceGroup) -ForegroundColor Cyan
    Write-Host ("SSH target: {0}" -f $targetText) -ForegroundColor DarkCyan
    Write-Host "Password entry will appear in the external SSH console window." -ForegroundColor Yellow
    Start-Process -FilePath $sshExePath -ArgumentList $sshArgs | Out-Null
}
