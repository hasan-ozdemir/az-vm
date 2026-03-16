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

function Get-AzVmFileSha256 {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path) -or -not (Test-Path -LiteralPath $Path)) {
        throw ("File was not found for SHA256 hashing: {0}" -f [string]$Path)
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead([string]$Path)
        try {
            $hashBytes = $sha256.ComputeHash($stream)
            return ([System.BitConverter]::ToString($hashBytes)).Replace('-', '').Trim().ToUpperInvariant()
        }
        finally {
            if ($null -ne $stream) { $stream.Dispose() }
        }
    }
    finally {
        if ($null -ne $sha256) { $sha256.Dispose() }
    }
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
        [string]$StdinFilePath = '',
        [long]$StdinFileOffsetBytes = 0,
        [long]$StdinFileLengthBytes = -1,
        [string]$Label,
        [int]$TimeoutSeconds = 30,
        [switch]$SuppressTrackedLogging
    )

    if ($TimeoutSeconds -lt 5) { $TimeoutSeconds = 5 }
    if ($TimeoutSeconds -gt 300) { $TimeoutSeconds = 300 }

    $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes([string]$ScriptText))
    $arguments = @(
        [string]$PySshClientPath,
        'exec',
        '--host', [string]$HostName,
        '--port', [string]$Port,
        '--user', [string]$UserName,
        '--password', [string]$Password,
        '--timeout', [string]$TimeoutSeconds,
        '--command', ('powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {0}' -f [string]$encodedCommand)
    )
    if (-not [string]::IsNullOrWhiteSpace([string]$StdinFilePath)) {
        $arguments += @('--stdin-file', [string]$StdinFilePath)
        if ($StdinFileOffsetBytes -gt 0) {
            $arguments += @('--stdin-file-offset', [string]$StdinFileOffsetBytes)
        }
        if ($StdinFileLengthBytes -ge 0) {
            $arguments += @('--stdin-file-length', [string]$StdinFileLengthBytes)
        }
    }
    return (Invoke-AzVmProcessWithRetry `
        -FilePath $PySshPythonPath `
        -Arguments $arguments `
        -Label $Label `
        -MaxAttempts 1 `
        -SuppressTrackedLogging:$SuppressTrackedLogging)
}

function Invoke-AzVmRemotePowerShellCommandTextExec {
    param(
        [string]$PySshPythonPath,
        [string]$PySshClientPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port,
        [string]$ScriptText,
        [string]$Label,
        [int]$TimeoutSeconds = 30,
        [switch]$SuppressTrackedLogging
    )

    if ($TimeoutSeconds -lt 5) { $TimeoutSeconds = 5 }
    if ($TimeoutSeconds -gt 300) { $TimeoutSeconds = 300 }

    $commandScriptText = ([string]$ScriptText).Replace('"', '""')
    $arguments = @(
        [string]$PySshClientPath,
        'exec',
        '--host', [string]$HostName,
        '--port', [string]$Port,
        '--user', [string]$UserName,
        '--password', [string]$Password,
        '--timeout', [string]$TimeoutSeconds,
        '--command', ('powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "{0}"' -f [string]$commandScriptText)
    )

    return (Invoke-AzVmProcessWithRetry `
        -FilePath $PySshPythonPath `
        -Arguments $arguments `
        -Label $Label `
        -MaxAttempts 1 `
        -SuppressTrackedLogging:$SuppressTrackedLogging)
}

function Get-AzVmWindowsRemoteFileMetadata {
    param(
        [string]$PySshPythonPath,
        [string]$PySshClientPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port,
        [string]$RemotePath,
        [int]$ConnectTimeoutSeconds = 30
    )

    $escapedRemotePath = ConvertTo-AzVmPowerShellSingleQuotedLiteral -Value ([string]$RemotePath)
    $metadataScript = @(
        "`$path = '$escapedRemotePath'"
        "if (-not (Test-Path -LiteralPath `$path)) {"
        "    Write-Host 'missing'"
        "    exit 0"
        "}"
        "`$item = Get-Item -LiteralPath `$path -ErrorAction Stop"
        "`$hash = ''"
        "try {"
        "    `$sha256 = [System.Security.Cryptography.SHA256]::Create()"
        "    try {"
        "        `$stream = [System.IO.File]::OpenRead(`$path)"
        "        try {"
        "            `$hashBytes = `$sha256.ComputeHash(`$stream)"
        "            `$hash = ([System.BitConverter]::ToString(`$hashBytes)).Replace('-', '')"
        "        }"
        "        finally {"
        "            if (`$null -ne `$stream) { `$stream.Dispose() }"
        "        }"
        "    }"
        "    finally {"
        "        if (`$null -ne `$sha256) { `$sha256.Dispose() }"
        "    }"
        "}"
        "catch { }"
        "Write-Host ('present length={0} sha256={1}' -f [int64]`$item.Length, [string]`$hash)"
        "exit 0"
    ) -join "`n"

    $result = Invoke-AzVmRemotePowerShellExec `
        -PySshPythonPath $PySshPythonPath `
        -PySshClientPath $PySshClientPath `
        -HostName $HostName `
        -UserName $UserName `
        -Password $Password `
        -Port $Port `
        -ScriptText $metadataScript `
        -Label ("pyssh inspect asset -> {0}" -f [string]$RemotePath) `
        -TimeoutSeconds $ConnectTimeoutSeconds `
        -SuppressTrackedLogging

    $outputText = [string]$result.Output
    $exists = $false
    $length = 0
    $sha256 = ''
    if ($outputText -match 'present\s+length=(\d+)\s+sha256=([A-Fa-f0-9]*)') {
        $exists = $true
        $length = [int64]$matches[1]
        $sha256 = ([string]$matches[2]).Trim().ToUpperInvariant()
    }

    return [pscustomobject]@{
        Exists = [bool]$exists
        Length = [int64]$length
        Sha256 = [string]$sha256
    }
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
    $fileInfo = Get-Item -LiteralPath $resolvedLocalPath -ErrorAction Stop
    $fileHash = Get-AzVmFileSha256 -Path $resolvedLocalPath
    $escapedRemotePath = ConvertTo-AzVmPowerShellSingleQuotedLiteral -Value ([string]$RemotePath)
    $stagingRemotePath = ('{0}.upload-{1}' -f [string]$RemotePath, ([guid]::NewGuid().ToString('N')))
    $escapedStagingRemotePath = ConvertTo-AzVmPowerShellSingleQuotedLiteral -Value ([string]$stagingRemotePath)
    $remoteMetadata = $null
    try {
        $remoteMetadata = Get-AzVmWindowsRemoteFileMetadata `
            -PySshPythonPath $PySshPythonPath `
            -PySshClientPath $PySshClientPath `
            -HostName $HostName `
            -UserName $UserName `
            -Password $Password `
            -Port $Port `
            -RemotePath $RemotePath `
            -ConnectTimeoutSeconds $ConnectTimeoutSeconds
    }
    catch { }

    if ($null -ne $remoteMetadata -and [bool]$remoteMetadata.Exists -and
        [int64]$remoteMetadata.Length -eq [int64]$fileInfo.Length -and
        -not [string]::IsNullOrWhiteSpace([string]$remoteMetadata.Sha256) -and
        [string]::Equals([string]$remoteMetadata.Sha256, [string]$fileHash, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host ("Task asset copy skipped: {0} -> {1} (cache hit, sha256={2})" -f [System.IO.Path]::GetFileName($resolvedLocalPath), [string]$RemotePath, [string]$fileHash.Substring(0, 12))
        return [pscustomobject]@{
            RemotePath = [string]$RemotePath
            Copied = $false
            Bytes = [int64]$fileInfo.Length
            ChunkCount = 0
            Sha256 = [string]$fileHash
        }
    }

    Write-Host ("Task asset copy started: {0} -> {1} (mode=windows-base64, bytes={2})" -f [System.IO.Path]::GetFileName($resolvedLocalPath), [string]$RemotePath, [int64]$fileInfo.Length)
    $transferWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $remoteBase64Path = ('{0}.b64' -f [string]$stagingRemotePath)
    $escapedRemoteBase64Path = ConvertTo-AzVmPowerShellSingleQuotedLiteral -Value ([string]$remoteBase64Path)
    $payloadBase64 = [System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($resolvedLocalPath))
    $chunkLength = 7500
    if ($chunkLength -lt 1024) { $chunkLength = 1024 }
    $chunkCount = [int][Math]::Max(1, [Math]::Ceiling(([double]$payloadBase64.Length) / [double]$chunkLength))
    $nextProgressSeconds = 15.0
    $chunkTimeoutSeconds = if ($chunkCount -gt 1) { [Math]::Max(90, $ConnectTimeoutSeconds) } else { [Math]::Max(30, $ConnectTimeoutSeconds) }
    $initializeScript = '$d=''' + $escapedRemoteBase64Path + ''';$p=Split-Path -Parent $d;if(-not [string]::IsNullOrWhiteSpace([string]$p)){New-Item -ItemType Directory -Path $p -Force|Out-Null};[IO.File]::WriteAllText($d,'''',[Text.Encoding]::ASCII)'
    Invoke-AzVmRemotePowerShellCommandTextExec `
        -PySshPythonPath $PySshPythonPath `
        -PySshClientPath $PySshClientPath `
        -HostName $HostName `
        -UserName $UserName `
        -Password $Password `
        -Port $Port `
        -ScriptText $initializeScript `
        -Label ("pyssh asset init -> {0}" -f [string]$RemotePath) `
        -TimeoutSeconds ([Math]::Max(30, $ConnectTimeoutSeconds)) `
        -SuppressTrackedLogging | Out-Null
    for ($chunkIndex = 0; $chunkIndex -lt $chunkCount; $chunkIndex++) {
        $offset = $chunkIndex * $chunkLength
        $currentChunkLength = [Math]::Min($chunkLength, ($payloadBase64.Length - $offset))
        $chunkText = $payloadBase64.Substring($offset, $currentChunkLength)
        $chunkSafe = ConvertTo-AzVmPowerShellSingleQuotedLiteral -Value ([string]$chunkText)
        $appendScript = "[IO.File]::AppendAllText('{0}','{1}',[Text.Encoding]::ASCII)" -f $escapedRemoteBase64Path, $chunkSafe
        Invoke-AzVmRemotePowerShellCommandTextExec `
            -PySshPythonPath $PySshPythonPath `
            -PySshClientPath $PySshClientPath `
            -HostName $HostName `
            -UserName $UserName `
            -Password $Password `
            -Port $Port `
            -ScriptText $appendScript `
            -Label ("pyssh asset chunk {0}/{1} -> {2}" -f ($chunkIndex + 1), $chunkCount, [string]$RemotePath) `
            -TimeoutSeconds $chunkTimeoutSeconds `
            -SuppressTrackedLogging | Out-Null

        if ($transferWatch.Elapsed.TotalSeconds -ge $nextProgressSeconds -and ($chunkIndex + 1) -lt $chunkCount) {
            $progressPercent = [int][Math]::Floor((($chunkIndex + 1) * 100.0) / $chunkCount)
            Write-Host ("Task asset copy progress: {0} -> {1} ({2}/{3} chunks, {4}%, {5:N1}s)" -f [System.IO.Path]::GetFileName($resolvedLocalPath), [string]$RemotePath, ($chunkIndex + 1), $chunkCount, $progressPercent, $transferWatch.Elapsed.TotalSeconds)
            $nextProgressSeconds += 15.0
        }
    }

    $finalizeScript = @(
        '$b=''' + $escapedRemoteBase64Path + ''''
        '$s=''' + $escapedStagingRemotePath + ''''
        '$d=''' + $escapedRemotePath + ''''
        '$t=[IO.File]::ReadAllText($b,[Text.Encoding]::ASCII)'
        '[IO.File]::WriteAllBytes($s,[Convert]::FromBase64String($t))'
        'Remove-Item -LiteralPath $b -Force -EA SilentlyContinue'
        'if(Test-Path -LiteralPath $d){Remove-Item -LiteralPath $d -Force -EA SilentlyContinue}'
        'Move-Item -LiteralPath $s -Destination $d -Force'
    ) -join ';'
    Invoke-AzVmRemotePowerShellCommandTextExec `
        -PySshPythonPath $PySshPythonPath `
        -PySshClientPath $PySshClientPath `
        -HostName $HostName `
        -UserName $UserName `
        -Password $Password `
        -Port $Port `
        -ScriptText $finalizeScript `
        -Label ("pyssh asset finalize -> {0}" -f [string]$RemotePath) `
        -TimeoutSeconds ([Math]::Max(30, $ConnectTimeoutSeconds)) `
        -SuppressTrackedLogging | Out-Null

    if ($transferWatch.IsRunning) {
        $transferWatch.Stop()
    }
    Write-Host ("Task asset copy completed: {0} -> {1} (mode=windows-base64, bytes={2}, chunks={3}, elapsed={4:N1}s)" -f [System.IO.Path]::GetFileName($resolvedLocalPath), [string]$RemotePath, [int64]$fileInfo.Length, $chunkCount, $transferWatch.Elapsed.TotalSeconds)

    return [pscustomobject]@{
        RemotePath = [string]$RemotePath
        Copied = $true
        Bytes = [int64]$fileInfo.Length
        ChunkCount = [int]$chunkCount
        Sha256 = [string]$fileHash
    }
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

    if (Test-AzVmWindowsRemotePath -RemotePath $RemotePath) {
        return (Copy-AzVmAssetToWindowsViaExec `
            -PySshPythonPath $PySshPythonPath `
            -PySshClientPath $PySshClientPath `
            -HostName $HostName `
            -UserName $UserName `
            -Password $Password `
            -Port $Port `
            -LocalPath $LocalPath `
            -RemotePath $RemotePath `
            -ConnectTimeoutSeconds $ConnectTimeoutSeconds)
    }

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

    Invoke-AzVmProcessWithRetry -FilePath $PySshPythonPath -Arguments $copyArgs -Label ("pyssh copy asset -> {0}" -f [string]$RemotePath) -MaxAttempts 2 | Out-Null
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
