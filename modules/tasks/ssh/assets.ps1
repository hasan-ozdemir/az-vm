# SSH task asset-copy helpers.

function ConvertTo-AzVmPowerShellSingleQuotedLiteral {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ($null -eq $Value) {
        return ''
    }

    return ([string]$Value).Replace("'", "''")
}

function Test-AzVmWindowsRemotePath {
    param(
        [string]$RemotePath
    )

    if ([string]::IsNullOrWhiteSpace([string]$RemotePath)) {
        return $false
    }

    return ([string]$RemotePath -match '^[A-Za-z]:[\\/]')
}

function Test-AzVmSftpNegotiationFailureText {
    param(
        [AllowNull()]
        [string]$MessageText
    )

    if ([string]::IsNullOrWhiteSpace([string]$MessageText)) {
        return $false
    }

    $value = [string]$MessageText
    foreach ($pattern in @(
        'EOF during negotiation',
        'subsystem request failed',
        'sftp',
        'open_sftp',
        'channel closed'
    )) {
        if ($value.IndexOf($pattern, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    return $false
}

function Invoke-AzVmRemotePowerShellExec {
    param(
        [string]$PySshPythonPath,
        [string]$PySshClientPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port,
        [string]$ScriptText,
        [string]$Label,
        [int]$TimeoutSeconds = 30
    )

    if ($TimeoutSeconds -lt 5) { $TimeoutSeconds = 5 }
    if ($TimeoutSeconds -gt 300) { $TimeoutSeconds = 300 }

    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes([string]$ScriptText))
    return (Invoke-AzVmProcessWithRetry `
        -FilePath $PySshPythonPath `
        -Arguments @(
            [string]$PySshClientPath,
            'exec',
            '--host', [string]$HostName,
            '--port', [string]$Port,
            '--user', [string]$UserName,
            '--password', [string]$Password,
            '--timeout', [string]$TimeoutSeconds,
            '--command', ('powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {0}' -f [string]$encodedCommand)
        ) `
        -Label $Label `
        -MaxAttempts 1)
}

function Copy-AzVmAssetToWindowsViaExec {
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

    $resolvedLocalPath = (Resolve-Path -LiteralPath $LocalPath).Path
    $fileBytes = [System.IO.File]::ReadAllBytes($resolvedLocalPath)
    $maxFallbackBytes = 1MB
    if ($fileBytes.Length -gt $maxFallbackBytes) {
        throw ("Windows SSH exec asset fallback supports files up to {0} bytes. '{1}' is {2} bytes." -f $maxFallbackBytes, $resolvedLocalPath, $fileBytes.Length)
    }

    $payloadBase64 = [Convert]::ToBase64String($fileBytes)
    $chunkSize = 1000
    $chunkCount = [Math]::Max(1, [int][Math]::Ceiling($payloadBase64.Length / [double]$chunkSize))
    $remoteTempBase64Path = ('C:/Windows/Temp/az-vm-upload-{0}.b64' -f ([guid]::NewGuid().ToString('N')))
    $escapedRemotePath = ConvertTo-AzVmPowerShellSingleQuotedLiteral -Value ([string]$RemotePath)
    $escapedTempPath = ConvertTo-AzVmPowerShellSingleQuotedLiteral -Value ([string]$remoteTempBase64Path)
    $prepScript = @(
        "`$destination = '$escapedRemotePath'"
        "`$tempBase64 = '$escapedTempPath'"
        "`$directory = [System.IO.Path]::GetDirectoryName(`$destination)"
        "if (-not [string]::IsNullOrWhiteSpace([string]`$directory)) {"
        "    [System.IO.Directory]::CreateDirectory(`$directory) | Out-Null"
        "}"
        "Remove-Item -LiteralPath `$tempBase64 -Force -ErrorAction SilentlyContinue"
        "Remove-Item -LiteralPath `$destination -Force -ErrorAction SilentlyContinue"
        "exit 0"
    ) -join "`n"
    Invoke-AzVmRemotePowerShellExec `
        -PySshPythonPath $PySshPythonPath `
        -PySshClientPath $PySshClientPath `
        -HostName $HostName `
        -UserName $UserName `
        -Password $Password `
        -Port $Port `
        -ScriptText $prepScript `
        -Label ("pyssh copy asset fallback prep -> {0}" -f [string]$RemotePath) `
        -TimeoutSeconds $ConnectTimeoutSeconds | Out-Null

    for ($offset = 0; $offset -lt $payloadBase64.Length; $offset += $chunkSize) {
        $chunkIndex = [int]($offset / $chunkSize) + 1
        $chunkLength = [Math]::Min($chunkSize, $payloadBase64.Length - $offset)
        $chunkText = $payloadBase64.Substring($offset, $chunkLength)
        $escapedChunkText = ConvertTo-AzVmPowerShellSingleQuotedLiteral -Value $chunkText
        $chunkScript = if ($offset -eq 0) {
            "[System.IO.File]::WriteAllText('$escapedTempPath', '$escapedChunkText', [System.Text.Encoding]::ASCII); exit 0"
        }
        else {
            "[System.IO.File]::AppendAllText('$escapedTempPath', '$escapedChunkText', [System.Text.Encoding]::ASCII); exit 0"
        }

        Invoke-AzVmRemotePowerShellExec `
            -PySshPythonPath $PySshPythonPath `
            -PySshClientPath $PySshClientPath `
            -HostName $HostName `
            -UserName $UserName `
            -Password $Password `
            -Port $Port `
            -ScriptText $chunkScript `
            -Label ("pyssh copy asset fallback chunk {0}/{1} -> {2}" -f $chunkIndex, $chunkCount, [string]$RemotePath) `
            -TimeoutSeconds $ConnectTimeoutSeconds | Out-Null
    }

    $finalizeScript = @(
        "`$destination = '$escapedRemotePath'"
        "`$tempBase64 = '$escapedTempPath'"
        "`$base64 = [System.IO.File]::ReadAllText(`$tempBase64, [System.Text.Encoding]::ASCII)"
        "`$bytes = [System.Convert]::FromBase64String(`$base64)"
        "[System.IO.File]::WriteAllBytes(`$destination, `$bytes)"
        "`$item = Get-Item -LiteralPath `$destination -ErrorAction Stop"
        "Write-Host ('asset-copy-ready length={0}' -f [int64]`$item.Length)"
        "Remove-Item -LiteralPath `$tempBase64 -Force -ErrorAction SilentlyContinue"
        "exit 0"
    ) -join "`n"
    Invoke-AzVmRemotePowerShellExec `
        -PySshPythonPath $PySshPythonPath `
        -PySshClientPath $PySshClientPath `
        -HostName $HostName `
        -UserName $UserName `
        -Password $Password `
        -Port $Port `
        -ScriptText $finalizeScript `
        -Label ("pyssh copy asset fallback finalize -> {0}" -f [string]$RemotePath) `
        -TimeoutSeconds $ConnectTimeoutSeconds | Out-Null
}

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

    try {
        Invoke-AzVmProcessWithRetry -FilePath $PySshPythonPath -Arguments $copyArgs -Label ("pyssh copy asset -> {0}" -f [string]$RemotePath) -MaxAttempts 2 | Out-Null
    }
    catch {
        $copyErrorText = [string]$_.Exception.Message
        if ((Test-AzVmWindowsRemotePath -RemotePath $RemotePath) -and (Test-AzVmSftpNegotiationFailureText -MessageText $copyErrorText)) {
            Write-Warning ("SFTP asset copy failed for '{0}'. Falling back to PowerShell exec transfer." -f [string]$RemotePath)
            Copy-AzVmAssetToWindowsViaExec `
                -PySshPythonPath $PySshPythonPath `
                -PySshClientPath $PySshClientPath `
                -HostName $HostName `
                -UserName $UserName `
                -Password $Password `
                -Port $Port `
                -LocalPath $LocalPath `
                -RemotePath $RemotePath `
                -ConnectTimeoutSeconds $ConnectTimeoutSeconds
            return
        }

        throw
    }
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
