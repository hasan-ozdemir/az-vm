# SSH task asset-copy helpers.

# Handles Copy-AzVmAssetToVm.
function Copy-AzVmAssetToVm {
    param(
        [string]$PySshPythonPath,
        [string]$PySshClientPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port,
        [string]$LocalPath,
        [string]$RemotePath,
        [int]$ConnectTimeoutSeconds = 30
    )

    if ([string]::IsNullOrWhiteSpace([string]$LocalPath) -or -not (Test-Path -LiteralPath $LocalPath)) {
        throw ("Task asset was not found: {0}" -f $LocalPath)
    }
    if ([string]::IsNullOrWhiteSpace([string]$RemotePath)) {
        throw "Task asset remote path is empty."
    }
    if ($ConnectTimeoutSeconds -lt 5) { $ConnectTimeoutSeconds = 5 }
    if ($ConnectTimeoutSeconds -gt 300) { $ConnectTimeoutSeconds = 300 }

    $copyArgs = @(
        [string]$PySshClientPath,
        "copy",
        "--host", [string]$HostName,
        "--port", [string]$Port,
        "--user", [string]$UserName,
        "--password", [string]$Password,
        "--timeout", [string]$ConnectTimeoutSeconds,
        "--local", [string]$LocalPath,
        "--remote", [string]$RemotePath
    )

    Invoke-AzVmProcessWithRetry -FilePath $PySshPythonPath -Arguments $copyArgs -Label ("pyssh copy asset -> {0}" -f [string]$RemotePath) -MaxAttempts 1 | Out-Null
}
