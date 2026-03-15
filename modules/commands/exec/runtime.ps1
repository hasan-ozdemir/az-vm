# Exec command runtime helpers.

function Initialize-AzVmExecCommandRuntimeContext {
    param()

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $configuredPySshClientPath = [string](Get-ConfigValue -Config $configMap -Key 'PYSSH_CLIENT_PATH' -DefaultValue (Get-AzVmDefaultPySshClientPathText))

    $sshConnectTimeoutText = [string](Get-ConfigValue -Config $configMap -Key 'SSH_CONNECT_TIMEOUT_SECONDS' -DefaultValue ([string]$script:SshConnectTimeoutSeconds))
    $sshConnectTimeoutSeconds = $script:SshConnectTimeoutSeconds
    if ($sshConnectTimeoutText -match '^\d+$') { $sshConnectTimeoutSeconds = [int]$sshConnectTimeoutText }
    if ($sshConnectTimeoutSeconds -lt 5) { $sshConnectTimeoutSeconds = 5 }
    if ($sshConnectTimeoutSeconds -gt 300) { $sshConnectTimeoutSeconds = 300 }

    $script:SshConnectTimeoutSeconds = $sshConnectTimeoutSeconds

    return [pscustomobject]@{
        RepoRoot = $repoRoot
        EnvFilePath = $envFilePath
        ConfigMap = $configMap
        ConfiguredPySshClientPath = $configuredPySshClientPath
        SshConnectTimeoutSeconds = $sshConnectTimeoutSeconds
    }
}
