# UI connection runtime helpers.

# Handles Test-AzVmLocalWindowsHost.
function Test-AzVmLocalWindowsHost {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

# Handles Resolve-AzVmConnectionRoleName.
function Resolve-AzVmConnectionRoleName {
    param(
        [hashtable]$Options
    )

    $roleRaw = [string](Get-AzVmCliOptionText -Options $Options -Name 'user')
    if ([string]::IsNullOrWhiteSpace([string]$roleRaw)) {
        return 'manager'
    }

    $role = $roleRaw.Trim().ToLowerInvariant()
    if ($role -notin @('manager','assistant')) {
        Throw-FriendlyError `
            -Detail ("Unsupported connection user '{0}'." -f $roleRaw) `
            -Code 66 `
            -Summary "Connection user is invalid." `
            -Hint "Use --user=manager or --user=assistant."
    }

    return $role
}

# Handles Resolve-AzVmConnectionPortText.
function Resolve-AzVmConnectionPortText {
    param(
        [hashtable]$ConfigMap,
        [string]$Key,
        [string]$DefaultValue,
        [string]$Label
    )

    $rawValue = [string](Get-ConfigValue -Config $ConfigMap -Key $Key -DefaultValue $DefaultValue)
    $portText = $rawValue.Trim()
    if (-not ($portText -match '^\d+$')) {
        Throw-FriendlyError `
            -Detail ("Config value '{0}' is invalid for {1}: '{2}'." -f $Key, $Label, $rawValue) `
            -Code 66 `
            -Summary ("{0} port is invalid." -f $Label) `
            -Hint ("Set {0} to a numeric TCP port value in .env." -f $Key)
    }

    return $portText
}

# Handles Assert-AzVmConnectionVmRunning.
function Assert-AzVmConnectionVmRunning {
    param(
        [string]$OperationName,
        [psobject]$Snapshot
    )

    if ([string]::Equals([string]$Snapshot.NormalizedState, 'started', [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    $commandLabel = ([string]$OperationName).ToUpperInvariant()
    Throw-FriendlyError `
        -Detail ("The {0} command cannot launch because VM '{1}' in resource group '{2}' is not running. {3}" -f $OperationName, [string]$Snapshot.VmName, [string]$Snapshot.ResourceGroup, (Format-AzVmVmLifecycleSummaryText -Snapshot $Snapshot)) `
        -Code 66 `
        -Summary ("{0} requires the VM to be running." -f $commandLabel) `
        -Hint ("Start the VM with 'az-vm do --vm-action=start --group={0} --vm-name={1}' and retry." -f [string]$Snapshot.ResourceGroup, [string]$Snapshot.VmName)
}

# Handles Resolve-AzVmConnectionCredentials.
function Resolve-AzVmConnectionCredentials {
    param(
        [string]$RoleName,
        [hashtable]$ConfigMap,
        [string]$EnvFilePath
    )

    $role = [string]$RoleName
    $userKey = ''
    $passwordKey = ''
    $defaultUserName = ''
    switch ($role) {
        'assistant' {
            $userKey = 'VM_ASSISTANT_USER'
            $passwordKey = 'VM_ASSISTANT_PASS'
            $defaultUserName = 'assistant'
        }
        default {
            $role = 'manager'
            $userKey = 'VM_ADMIN_USER'
            $passwordKey = 'VM_ADMIN_PASS'
            $defaultUserName = 'manager'
        }
    }

    $resolvedUserName = [string](Get-ConfigValue -Config $ConfigMap -Key $userKey -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace([string]$resolvedUserName)) {
        $enteredUserName = Read-Host ("Enter username for {0} connection (default={1})" -f $role, $defaultUserName)
        if ([string]::IsNullOrWhiteSpace([string]$enteredUserName)) {
            $enteredUserName = $defaultUserName
        }
        $resolvedUserName = $enteredUserName.Trim()
        Set-DotEnvValue -Path $EnvFilePath -Key $userKey -Value $resolvedUserName
        $ConfigMap[$userKey] = $resolvedUserName
    }

    $resolvedPassword = [string](Get-ConfigValue -Config $ConfigMap -Key $passwordKey -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace([string]$resolvedPassword)) {
        $securePassword = Read-Host ("Enter password for {0} connection user '{1}'" -f $role, $resolvedUserName) -AsSecureString
        $resolvedPassword = [System.Net.NetworkCredential]::new('', $securePassword).Password
        if ([string]::IsNullOrWhiteSpace([string]$resolvedPassword)) {
            Throw-FriendlyError `
                -Detail ("Password input for role '{0}' was empty." -f $role) `
                -Code 66 `
                -Summary "Connection password is required." `
                -Hint ("Enter a non-empty password for {0} and retry." -f $role)
        }
        Set-DotEnvValue -Path $EnvFilePath -Key $passwordKey -Value $resolvedPassword
        $ConfigMap[$passwordKey] = $resolvedPassword
    }

    return [pscustomobject]@{
        Role = $role
        UserName = $resolvedUserName
        Password = $resolvedPassword
    }
}

# Handles Resolve-AzVmLocalExecutablePath.
function Resolve-AzVmLocalExecutablePath {
    param(
        [string[]]$Candidates,
        [string]$FriendlyName
    )

    foreach ($candidate in @($Candidates)) {
        $candidateText = [string]$candidate
        if ([string]::IsNullOrWhiteSpace([string]$candidateText)) {
            continue
        }

        if ([System.IO.Path]::IsPathRooted($candidateText)) {
            if (Test-Path -LiteralPath $candidateText) {
                return (Resolve-Path -LiteralPath $candidateText).Path
            }
            continue
        }

        $command = Get-Command $candidateText -ErrorAction SilentlyContinue
        if ($command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
            return [string]$command.Source
        }
    }

    Throw-FriendlyError `
        -Detail ("Local executable for {0} was not found." -f $FriendlyName) `
        -Code 66 `
        -Summary ("{0} client is not available on this machine." -f $FriendlyName) `
        -Hint ("Install or expose the required executable for {0}, then retry." -f $FriendlyName)
}

# Handles Initialize-AzVmConnectionCommandContext.
function Initialize-AzVmConnectionCommandContext {
    param(
        [hashtable]$Options,
        [string]$OperationName
    )

    if (-not (Test-AzVmLocalWindowsHost)) {
        Throw-FriendlyError `
            -Detail ("The {0} command is only supported on Windows operator machines." -f $OperationName) `
            -Code 66 `
            -Summary "Local client launch is not supported on this operating system." `
            -Hint "Run this command from Windows."
    }

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $target = Resolve-AzVmManagedVmTarget -Options $Options -ConfigMap $configMap -OperationName $OperationName
    $lifecycleWaitResult = Wait-AzVmProvisioningReadyOrRepair -ResourceGroup ([string]$target.ResourceGroup) -VmName ([string]$target.VmName)
    if (-not [bool]$lifecycleWaitResult.Ready) {
        $failedSnapshot = $lifecycleWaitResult.Snapshot
        Throw-FriendlyError `
            -Detail ("The {0} command cannot continue because VM '{1}' in resource group '{2}' did not return to provisioning succeeded. {3}" -f $OperationName, [string]$target.VmName, [string]$target.ResourceGroup, (Format-AzVmVmLifecycleSummaryText -Snapshot $failedSnapshot)) `
            -Code 66 `
            -Summary ("{0} requires a healthy VM provisioning state." -f ([string]$OperationName).ToUpperInvariant()) `
            -Hint "Wait for provisioning to recover, or inspect Azure activity logs if the automatic redeploy repair did not resolve the issue."
    }

    $lifecycleSnapshot = $lifecycleWaitResult.Snapshot
    Assert-AzVmConnectionVmRunning -OperationName $OperationName -Snapshot $lifecycleSnapshot
    $vmSshPort = Resolve-AzVmConnectionPortText -ConfigMap $configMap -Key 'VM_SSH_PORT' -DefaultValue (Get-AzVmDefaultSshPortText) -Label 'SSH'
    $vmRdpPort = Resolve-AzVmConnectionPortText -ConfigMap $configMap -Key 'VM_RDP_PORT' -DefaultValue (Get-AzVmDefaultRdpPortText) -Label 'RDP'
    $logicalRole = Resolve-AzVmConnectionRoleName -Options $Options
    $credentials = Resolve-AzVmConnectionCredentials -RoleName $logicalRole -ConfigMap $configMap -EnvFilePath $envFilePath

    $context = [ordered]@{
        ResourceGroup = [string]$target.ResourceGroup
        VmName = [string]$target.VmName
        AzLocation = ''
        VmUser = [string](Get-ConfigValue -Config $configMap -Key 'VM_ADMIN_USER' -DefaultValue '')
        VmPass = [string](Get-ConfigValue -Config $configMap -Key 'VM_ADMIN_PASS' -DefaultValue '')
        VmAssistantUser = [string](Get-ConfigValue -Config $configMap -Key 'VM_ASSISTANT_USER' -DefaultValue '')
        VmAssistantPass = [string](Get-ConfigValue -Config $configMap -Key 'VM_ASSISTANT_PASS' -DefaultValue '')
        SshPort = [string]$vmSshPort
        RdpPort = [string]$vmRdpPort
    }

    if ($logicalRole -eq 'manager') {
        $context.VmUser = [string]$credentials.UserName
        $context.VmPass = [string]$credentials.Password
    }
    else {
        $context.VmAssistantUser = [string]$credentials.UserName
        $context.VmAssistantPass = [string]$credentials.Password
    }

    $vmRuntimeDetails = Get-AzVmVmDetails -Context $context
    $resolvedHost = [string]$vmRuntimeDetails.VmFqdn
    if ([string]::IsNullOrWhiteSpace([string]$resolvedHost)) {
        $resolvedHost = [string]$vmRuntimeDetails.PublicIP
    }
    if ([string]::IsNullOrWhiteSpace([string]$resolvedHost)) {
        Throw-FriendlyError `
            -Detail ("Neither FQDN nor public IP could be resolved for VM '{0}'." -f [string]$target.VmName) `
            -Code 66 `
            -Summary ("{0} command could not resolve a connection host." -f $OperationName) `
            -Hint "Ensure the VM has a public endpoint and Azure can return VM runtime details."
    }

    $osType = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$lifecycleSnapshot.OsType)) {
        $osType = [string]$lifecycleSnapshot.OsType
    }
    if ($vmRuntimeDetails.VmDetails -and $vmRuntimeDetails.VmDetails.storageProfile -and $vmRuntimeDetails.VmDetails.storageProfile.osDisk) {
        $osType = [string]$vmRuntimeDetails.VmDetails.storageProfile.osDisk.osType
    }

    return [pscustomobject]@{
        EnvFilePath = $envFilePath
        ConfigMap = $configMap
        Context = $context
        ResourceGroup = [string]$target.ResourceGroup
        VmName = [string]$target.VmName
        ConnectionHost = $resolvedHost
        LifecycleSnapshot = $lifecycleSnapshot
        VmRuntimeDetails = $vmRuntimeDetails
        OsType = $osType
        SelectedRole = [string]$credentials.Role
        SelectedUserName = [string]$credentials.UserName
        SelectedPassword = [string]$credentials.Password
        VmSshPort = [string]$vmSshPort
        VmRdpPort = [string]$vmRdpPort
    }
}

# Handles Resolve-AzVmConnectionPortNumber.
function Resolve-AzVmConnectionPortNumber {
    param(
        [string]$PortText,
        [string]$PortLabel
    )

    $resolvedPort = 0
    if (-not [int]::TryParse([string]$PortText, [ref]$resolvedPort) -or $resolvedPort -lt 1 -or $resolvedPort -gt 65535) {
        Throw-FriendlyError `
            -Detail ("{0} port value '{1}' is invalid." -f [string]$PortLabel, [string]$PortText) `
            -Code 66 `
            -Summary ("{0} port configuration is invalid." -f [string]$PortLabel) `
            -Hint ("Set a valid {0} port in .env and retry." -f [string]$PortLabel)
    }

    return [int]$resolvedPort
}

# Handles Test-AzVmConnectionIdentityOutputMatchesUser.
function Test-AzVmConnectionIdentityOutputMatchesUser {
    param(
        [string]$ExpectedUserName,
        [string]$OutputText
    )

    $expected = [string]$ExpectedUserName
    $expected = $expected.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace([string]$expected)) {
        return $false
    }

    $output = [string]$OutputText
    $output = $output.Replace(([string][char]0), '')
    $lines = @(
        $output -split "(\r?\n)+" |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )

    foreach ($line in @($lines)) {
        $candidate = [string]$line
        $candidate = $candidate.Trim().ToLowerInvariant()
        if ([string]::Equals($candidate, $expected, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }

        if ($candidate -match ('(^|[\\/@]){0}$' -f [regex]::Escape($expected))) {
            return $true
        }
    }

    return $false
}

# Handles Invoke-AzVmSshConnectivityTest.
function Invoke-AzVmSshConnectivityTest {
    param(
        [hashtable]$Options
    )

    $runtime = Initialize-AzVmConnectionCommandContext -Options $Options -OperationName 'ssh'
    $sshPort = Resolve-AzVmConnectionPortNumber -PortText ([string]$runtime.VmSshPort) -PortLabel 'SSH'
    $sshReachable = Wait-AzVmTcpPortReachable -HostName ([string]$runtime.ConnectionHost) -Port $sshPort -MaxAttempts 6 -DelaySeconds 5 -TimeoutSeconds 5 -Label 'ssh'
    if (-not $sshReachable) {
        Throw-FriendlyError `
            -Detail ("SSH port {0} was not reachable on host '{1}' for VM '{2}'." -f $sshPort, [string]$runtime.ConnectionHost, [string]$runtime.VmName) `
            -Code 66 `
            -Summary "SSH connectivity test failed." `
            -Hint "Check guest SSH service readiness, NSG rules, firewall state, and the configured VM_SSH_PORT."
    }

    $repoRoot = Get-AzVmRepoRoot
    $configuredPySshClientPath = [string](Get-ConfigValue -Config $runtime.ConfigMap -Key 'PYSSH_CLIENT_PATH' -DefaultValue '')
    $pySshTools = Ensure-AzVmPySshTools -RepoRoot $repoRoot -ConfiguredPySshClientPath $configuredPySshClientPath
    $sshRetryText = [string](Get-ConfigValue -Config $runtime.ConfigMap -Key 'SSH_MAX_RETRIES' -DefaultValue '3')
    $sshMaxAttempts = Resolve-AzVmSshRetryCount -RetryText $sshRetryText -DefaultValue 3
    $connectTimeoutText = [string](Get-ConfigValue -Config $runtime.ConfigMap -Key 'SSH_CONNECT_TIMEOUT_SECONDS' -DefaultValue '30')
    $connectTimeoutSeconds = 30
    if (-not [int]::TryParse($connectTimeoutText, [ref]$connectTimeoutSeconds) -or $connectTimeoutSeconds -lt 5) {
        $connectTimeoutSeconds = 30
    }
    if ($connectTimeoutSeconds -gt 300) {
        $connectTimeoutSeconds = 300
    }

    $result = Invoke-AzVmProcessWithRetry `
        -FilePath ([string]$pySshTools.PythonPath) `
        -Arguments @(
            [string]$pySshTools.ClientPath,
            'exec',
            '--host', [string]$runtime.ConnectionHost,
            '--port', [string]$runtime.VmSshPort,
            '--user', [string]$runtime.SelectedUserName,
            '--password', [string]$runtime.SelectedPassword,
            '--timeout', [string]$connectTimeoutSeconds,
            '--command', 'whoami'
        ) `
        -Label ("pyssh ssh test -> {0}@{1}:{2}" -f [string]$runtime.SelectedUserName, [string]$runtime.ConnectionHost, [string]$runtime.VmSshPort) `
        -MaxAttempts $sshMaxAttempts `
        -AllowFailure

    if ([int]$result.ExitCode -ne 0) {
        Throw-FriendlyError `
            -Detail ("SSH test command returned exit code {0}. Output: {1}" -f [int]$result.ExitCode, [string]$result.Output) `
            -Code 66 `
            -Summary "SSH connectivity test failed." `
            -Hint "Check the VM credentials, SSH service readiness, and pyssh connectivity from the operator machine."
    }

    if (-not (Test-AzVmConnectionIdentityOutputMatchesUser -ExpectedUserName ([string]$runtime.SelectedUserName) -OutputText ([string]$result.Output))) {
        Throw-FriendlyError `
            -Detail ("SSH test output did not confirm the expected user '{0}'. Output: {1}" -f [string]$runtime.SelectedUserName, [string]$result.Output) `
            -Code 66 `
            -Summary "SSH connectivity test failed." `
            -Hint "Verify the selected SSH user and VM credentials, then retry."
    }

    Write-Host ("SSH test passed for '{0}@{1}:{2}'." -f [string]$runtime.SelectedUserName, [string]$runtime.ConnectionHost, [string]$runtime.VmSshPort) -ForegroundColor Green
}

# Handles Invoke-AzVmRdpConnectivityTest.
function Invoke-AzVmRdpConnectivityTest {
    param(
        [hashtable]$Options
    )

    $runtime = Initialize-AzVmConnectionCommandContext -Options $Options -OperationName 'rdp'
    if (-not [string]::Equals(([string]$runtime.OsType).Trim(), 'Windows', [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-FriendlyError `
            -Detail ("VM '{0}' reports osType '{1}', so RDP launch is not supported." -f [string]$runtime.VmName, [string]$runtime.OsType) `
            -Code 66 `
            -Summary "RDP command is only available for Windows VMs." `
            -Hint "Use the ssh command for Linux VMs, or target a Windows VM."
    }

    $rdpPort = Resolve-AzVmConnectionPortNumber -PortText ([string]$runtime.VmRdpPort) -PortLabel 'RDP'
    $rdpReachable = Wait-AzVmTcpPortReachable -HostName ([string]$runtime.ConnectionHost) -Port $rdpPort -MaxAttempts 6 -DelaySeconds 5 -TimeoutSeconds 5 -Label 'rdp'
    if (-not $rdpReachable) {
        Throw-FriendlyError `
            -Detail ("RDP port {0} was not reachable on host '{1}' for VM '{2}'." -f $rdpPort, [string]$runtime.ConnectionHost, [string]$runtime.VmName) `
            -Code 66 `
            -Summary "RDP connectivity test failed." `
            -Hint "Check guest RDP service readiness, NSG rules, firewall state, and the configured VM_RDP_PORT."
    }

    Write-Host ("RDP test passed for '{0}:{1}'." -f [string]$runtime.ConnectionHost, [string]$runtime.VmRdpPort) -ForegroundColor Green
}
