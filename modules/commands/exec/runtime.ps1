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

    $sshCommandTimeoutText = [string](Get-ConfigValue -Config $configMap -Key 'SSH_TASK_TIMEOUT_SECONDS' -DefaultValue ([string]$script:SshTaskTimeoutSeconds))
    $sshCommandTimeoutSeconds = $script:SshTaskTimeoutSeconds
    if ($sshCommandTimeoutText -match '^\d+$') { $sshCommandTimeoutSeconds = [int]$sshCommandTimeoutText }
    if ($sshCommandTimeoutSeconds -lt 30) { $sshCommandTimeoutSeconds = 30 }
    if ($sshCommandTimeoutSeconds -gt 7200) { $sshCommandTimeoutSeconds = 7200 }

    $script:SshConnectTimeoutSeconds = $sshConnectTimeoutSeconds
    $script:SshTaskTimeoutSeconds = $sshCommandTimeoutSeconds

    return [pscustomobject]@{
        RepoRoot = $repoRoot
        EnvFilePath = $envFilePath
        ConfigMap = $configMap
        ConfiguredPySshClientPath = $configuredPySshClientPath
        SshConnectTimeoutSeconds = $sshConnectTimeoutSeconds
        SshCommandTimeoutSeconds = $sshCommandTimeoutSeconds
    }
}

function ConvertTo-AzVmExecRemoteCommandText {
    param(
        [string]$CommandText,
        [string]$Platform,
        [bool]$Quiet = $false
    )

    $resolvedCommandText = [string]$CommandText
    if ([string]::IsNullOrWhiteSpace([string]$resolvedCommandText)) {
        return ''
    }

    if (-not [string]::Equals([string]$Platform, 'windows', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $resolvedCommandText
    }

    $trimmedCommandText = $resolvedCommandText.TrimStart()
    if ($trimmedCommandText -match '^(?i)(powershell|pwsh|cmd(?:\.exe)?)(?:\s|$)') {
        return $resolvedCommandText
    }

    $prefaceLines = @(
        ("$" + "ProgressPreference = 'SilentlyContinue'")
    )

    $commandBody = [string]$resolvedCommandText
    if ($Quiet) {
        $prefaceLines += ("$" + "InformationPreference = 'SilentlyContinue'")
        $commandBody = ("& {" + [Environment]::NewLine + [string]$resolvedCommandText + [Environment]::NewLine + "} 6>" + "$" + "null")
    }

    $wrappedCommandText = ((@($prefaceLines) -join [Environment]::NewLine) + [Environment]::NewLine + [string]$commandBody)
    $encodedBytes = [System.Text.Encoding]::Unicode.GetBytes($wrappedCommandText)
    $encodedCommand = [Convert]::ToBase64String($encodedBytes)
    return ("powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {0}" -f [string]$encodedCommand)
}
