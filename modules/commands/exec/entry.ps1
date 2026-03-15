# Exec command entry.

# Handles Invoke-AzVmExecCommand.
function Invoke-AzVmExecCommand {
    param(
        [hashtable]$Options
    )

    $runtime = Initialize-AzVmExecCommandRuntimeContext
    $target = Resolve-AzVmManagedVmTarget -Options $Options -ConfigMap $runtime.ConfigMap -OperationName 'exec'
    $selectedResourceGroup = [string]$target.ResourceGroup
    $selectedVmName = [string]$target.VmName
    $vmDetailContext = [ordered]@{
        ResourceGroup = $selectedResourceGroup
        VmName = $selectedVmName
        AzLocation = ''
        SshPort = [string](Get-ConfigValue -Config $runtime.ConfigMap -Key 'VM_SSH_PORT' -DefaultValue (Get-AzVmDefaultSshPortText))
    }

    $vmRuntimeDetails = Get-AzVmVmDetails -Context $vmDetailContext
    $sshHost = [string]$vmRuntimeDetails.VmFqdn
    if ([string]::IsNullOrWhiteSpace($sshHost)) {
        $sshHost = [string]$vmRuntimeDetails.PublicIP
    }
    if ([string]::IsNullOrWhiteSpace($sshHost)) {
        throw "Exec REPL could not resolve VM SSH host (FQDN/Public IP)."
    }

    $vmUser = [string](Get-ConfigValue -Config $runtime.ConfigMap -Key 'VM_ADMIN_USER' -DefaultValue '')
    $vmPass = [string](Get-ConfigValue -Config $runtime.ConfigMap -Key 'VM_ADMIN_PASS' -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace([string]$vmUser)) {
        Throw-FriendlyError `
            -Detail "VM admin user is missing for exec." `
            -Code 61 `
            -Summary "Exec requires VM admin credentials." `
            -Hint "Set VM_ADMIN_USER in .env before using exec."
    }
    if ([string]::IsNullOrWhiteSpace([string]$vmPass)) {
        Throw-FriendlyError `
            -Detail "VM admin password is missing for exec." `
            -Code 61 `
            -Summary "Exec requires VM admin credentials." `
            -Hint "Set VM_ADMIN_PASS in .env before using exec."
    }

    $vmJson = az vm show -g $selectedResourceGroup -n $selectedVmName -o json --only-show-errors
    Assert-LastExitCode "az vm show (exec repl)"
    $vmObject = ConvertFrom-JsonCompat -InputObject $vmJson
    $osType = [string]$vmObject.storageProfile.osDisk.osType
    $replPlatform = if ([string]::Equals($osType, 'Linux', [System.StringComparison]::OrdinalIgnoreCase)) { 'linux' } else { 'windows' }
    $shell = if ($replPlatform -eq 'linux') { 'bash' } else { 'powershell' }

    $pySsh = Ensure-AzVmPySshTools -RepoRoot (Get-AzVmRepoRoot) -ConfiguredPySshClientPath ([string]$runtime.ConfiguredPySshClientPath)
    $bootstrap = Initialize-AzVmSshHostKey `
        -PySshPythonPath ([string]$pySsh.PythonPath) `
        -PySshClientPath ([string]$pySsh.ClientPath) `
        -HostName $sshHost `
        -UserName $vmUser `
        -Password $vmPass `
        -Port ([string]$vmDetailContext.SshPort) `
        -ConnectTimeoutSeconds ([int]$runtime.SshConnectTimeoutSeconds)
    if (-not [string]::IsNullOrWhiteSpace([string]$bootstrap.Output)) {
        Write-Host ([string]$bootstrap.Output)
    }

    $commandText = [string](Get-AzVmCliOptionText -Options $Options -Name 'command')
    if (-not [string]::IsNullOrWhiteSpace([string]$commandText)) {
        $commandWatch = $null
        if ($script:PerfMode) {
            $commandWatch = [System.Diagnostics.Stopwatch]::StartNew()
        }

        $execArgs = @(
            [string]$pySsh.ClientPath,
            'exec',
            '--host', [string]$sshHost,
            '--port', [string]$vmDetailContext.SshPort,
            '--user', $vmUser,
            '--password', $vmPass,
            '--timeout', [string]$runtime.SshConnectTimeoutSeconds,
            '--command', [string]$commandText
        )

        & ([string]$pySsh.PythonPath) @execArgs
        $commandExitCode = [int]$LASTEXITCODE

        if ($null -ne $commandWatch -and $commandWatch.IsRunning) {
            $commandWatch.Stop()
            Write-AzVmPerfTiming -Category "exec" -Label "remote command" -Seconds $commandWatch.Elapsed.TotalSeconds
        }

        if ($commandExitCode -ne 0) {
            Throw-FriendlyError `
                -Detail ("Remote exec command ended with exit code {0}." -f $commandExitCode) `
                -Code 61 `
                -Summary "Remote exec command failed." `
                -Hint "Review remote command output and retry. Ensure SSH access remains healthy on the VM."
        }

        Write-Host ("Exec completed on VM '{0}'." -f $selectedVmName) -ForegroundColor Green
        return
    }

    Write-Host ("Interactive exec shell connected: {0}@{1}:{2} ({3})" -f $vmUser, $sshHost, [string]$vmDetailContext.SshPort, $shell) -ForegroundColor Green
    Write-Host "Type 'exit' in the remote shell to close the session." -ForegroundColor Cyan

    $shellWatch = $null
    if ($script:PerfMode) {
        $shellWatch = [System.Diagnostics.Stopwatch]::StartNew()
    }

    $shellArgs = @(
        [string]$pySsh.ClientPath,
        "shell",
        "--host", [string]$sshHost,
        "--port", [string]$vmDetailContext.SshPort,
        "--user", $vmUser,
        "--password", $vmPass,
        "--timeout", [string]$runtime.SshConnectTimeoutSeconds,
        "--reconnect-retries", "3",
        "--keepalive-seconds", "15",
        "--shell", [string]$shell
    )

    & ([string]$pySsh.PythonPath) @shellArgs
    $shellExitCode = [int]$LASTEXITCODE

    if ($null -ne $shellWatch -and $shellWatch.IsRunning) {
        $shellWatch.Stop()
        Write-AzVmPerfTiming -Category "exec" -Label "interactive shell session" -Seconds $shellWatch.Elapsed.TotalSeconds
    }

    if ($shellExitCode -ne 0) {
        Throw-FriendlyError `
            -Detail ("Interactive exec shell ended with exit code {0}." -f $shellExitCode) `
            -Code 61 `
            -Summary "Interactive exec shell failed." `
            -Hint "Review remote shell output and retry. Ensure SSH service remains available on the VM."
    }

    Write-Host "Exec REPL session closed." -ForegroundColor Green
}
