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

# Handles Copy-AzVmAssetFromVm.
function Copy-AzVmAssetFromVm {
    param(
        [string]$PySshPythonPath,
        [string]$PySshClientPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port,
        [string]$RemotePath,
        [string]$LocalPath,
        [int]$ConnectTimeoutSeconds = 30
    )

    if ([string]::IsNullOrWhiteSpace([string]$RemotePath)) {
        throw "Task asset remote path is empty."
    }
    if ([string]::IsNullOrWhiteSpace([string]$LocalPath)) {
        throw "Task asset local path is empty."
    }
    if ($ConnectTimeoutSeconds -lt 5) { $ConnectTimeoutSeconds = 5 }
    if ($ConnectTimeoutSeconds -gt 300) { $ConnectTimeoutSeconds = 300 }

    $localParent = Split-Path -Path $LocalPath -Parent
    if (-not [string]::IsNullOrWhiteSpace([string]$localParent) -and -not (Test-Path -LiteralPath $localParent)) {
        New-Item -Path $localParent -ItemType Directory -Force | Out-Null
    }

    $fetchArgs = @(
        [string]$PySshClientPath,
        "fetch",
        "--host", [string]$HostName,
        "--port", [string]$Port,
        "--user", [string]$UserName,
        "--password", [string]$Password,
        "--timeout", [string]$ConnectTimeoutSeconds,
        "--remote", [string]$RemotePath,
        "--local", [string]$LocalPath
    )

    Invoke-AzVmProcessWithRetry -FilePath $PySshPythonPath -Arguments $fetchArgs -Label ("pyssh fetch asset <- {0}" -f [string]$RemotePath) -MaxAttempts 1 | Out-Null
}
