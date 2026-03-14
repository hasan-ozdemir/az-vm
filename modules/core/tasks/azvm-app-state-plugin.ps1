# Shared vm-update app-state plugin helpers.

function Initialize-AzVmAppStateZipSupport {
    if (-not ([System.Management.Automation.PSTypeName]'System.IO.Compression.ZipArchive').Type) {
        Add-Type -AssemblyName 'System.IO.Compression.FileSystem' -ErrorAction SilentlyContinue
        Add-Type -AssemblyName 'System.IO.Compression' -ErrorAction SilentlyContinue
    }
}

function Get-AzVmTaskStageRootDirectoryPath {
    param([psobject]$TaskBlock)

    if ($null -eq $TaskBlock) {
        return ''
    }

    $directoryPath = ''
    if ($TaskBlock.PSObject.Properties.Match('DirectoryPath').Count -gt 0) {
        $directoryPath = [string]$TaskBlock.DirectoryPath
    }
    $relativePath = ''
    if ($TaskBlock.PSObject.Properties.Match('RelativePath').Count -gt 0) {
        $relativePath = [string]$TaskBlock.RelativePath
    }

    if ([string]::IsNullOrWhiteSpace([string]$directoryPath)) {
        return ''
    }

    if ($relativePath.StartsWith('local/', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [string](Split-Path -Path $directoryPath -Parent)
    }

    return [string]$directoryPath
}

function Get-AzVmTaskAppStateRootDirectoryPath {
    param([psobject]$TaskBlock)

    $stageRoot = Get-AzVmTaskStageRootDirectoryPath -TaskBlock $TaskBlock
    if ([string]::IsNullOrWhiteSpace([string]$stageRoot)) {
        return ''
    }

    return (Join-Path $stageRoot 'app-states')
}

function Get-AzVmTaskAppStatePluginDirectoryPath {
    param([psobject]$TaskBlock)

    $appStateRoot = Get-AzVmTaskAppStateRootDirectoryPath -TaskBlock $TaskBlock
    $taskName = if ($null -ne $TaskBlock -and $TaskBlock.PSObject.Properties.Match('Name').Count -gt 0) { [string]$TaskBlock.Name } else { '' }
    if ([string]::IsNullOrWhiteSpace([string]$appStateRoot) -or [string]::IsNullOrWhiteSpace([string]$taskName)) {
        return ''
    }

    return (Join-Path $appStateRoot $taskName)
}

function Get-AzVmTaskAppStateZipPath {
    param([psobject]$TaskBlock)

    $pluginDirectory = Get-AzVmTaskAppStatePluginDirectoryPath -TaskBlock $TaskBlock
    if ([string]::IsNullOrWhiteSpace([string]$pluginDirectory)) {
        return ''
    }

    return (Join-Path $pluginDirectory 'app-state.zip')
}

function Get-AzVmAppStateGuestHelperPath {
    return (Join-Path $PSScriptRoot 'azvm-app-state-guest.psm1')
}

function Get-AzVmZipArchiveEntryByName {
    param(
        [object]$Archive,
        [string]$EntryName
    )

    if ($null -eq $Archive -or [string]::IsNullOrWhiteSpace([string]$EntryName)) {
        return $null
    }

    foreach ($entry in @($Archive.Entries)) {
        if ($null -eq $entry) {
            continue
        }

        if ([string]::Equals([string]$entry.FullName, [string]$EntryName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $entry
        }
    }

    return $null
}

function Get-AzVmTaskAppStateManifestFromZip {
    param(
        [string]$ZipPath,
        [string]$ExpectedTaskName
    )

    Initialize-AzVmAppStateZipSupport

    if ([string]::IsNullOrWhiteSpace([string]$ZipPath) -or -not (Test-Path -LiteralPath $ZipPath)) {
        throw ("App-state zip was not found: {0}" -f [string]$ZipPath)
    }

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        $manifestEntry = Get-AzVmZipArchiveEntryByName -Archive $archive -EntryName 'app-state.manifest.json'
        if ($null -eq $manifestEntry) {
            throw 'app-state.manifest.json was not found at the zip root.'
        }

        $reader = New-Object System.IO.StreamReader($manifestEntry.Open())
        try {
            $manifestText = [string]$reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        if ([string]::IsNullOrWhiteSpace([string]$manifestText)) {
            throw 'app-state.manifest.json is empty.'
        }

        $manifest = ConvertFrom-JsonCompat -InputObject $manifestText
        if ($null -eq $manifest) {
            throw 'app-state.manifest.json could not be parsed.'
        }

        $version = 0
        if ($manifest.PSObject.Properties.Match('version').Count -gt 0) {
            try {
                $version = [int]$manifest.version
            }
            catch {
                $version = 0
            }
        }
        if ($version -lt 1) {
            throw 'app-state manifest version must be >= 1.'
        }

        $taskName = ''
        if ($manifest.PSObject.Properties.Match('taskName').Count -gt 0) {
            $taskName = [string]$manifest.taskName
        }
        if ([string]::IsNullOrWhiteSpace([string]$taskName)) {
            throw 'app-state manifest taskName is required.'
        }
        if (-not [string]::Equals([string]$taskName, [string]$ExpectedTaskName, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ("app-state manifest taskName '{0}' does not match task '{1}'." -f [string]$taskName, [string]$ExpectedTaskName)
        }

        return [pscustomobject]@{
            Version = [int]$version
            TaskName = [string]$taskName
            Manifest = $manifest
        }
    }
    finally {
        if ($null -ne $archive) {
            $archive.Dispose()
        }
    }
}

function Get-AzVmTaskAppStatePluginInfo {
    param([psobject]$TaskBlock)

    $taskName = if ($null -ne $TaskBlock -and $TaskBlock.PSObject.Properties.Match('Name').Count -gt 0) { [string]$TaskBlock.Name } else { '' }
    $pluginDirectory = Get-AzVmTaskAppStatePluginDirectoryPath -TaskBlock $TaskBlock
    $zipPath = Get-AzVmTaskAppStateZipPath -TaskBlock $TaskBlock
    $guestHelperPath = Get-AzVmAppStateGuestHelperPath

    if ([string]::IsNullOrWhiteSpace([string]$pluginDirectory) -or [string]::IsNullOrWhiteSpace([string]$taskName)) {
        return [pscustomobject]@{
            TaskName = [string]$taskName
            PluginDirectory = [string]$pluginDirectory
            ZipPath = [string]$zipPath
            GuestHelperPath = [string]$guestHelperPath
            Status = 'invalid'
            Message = 'Task app-state plugin root could not be resolved.'
            Manifest = $null
        }
    }

    if (-not (Test-Path -LiteralPath $pluginDirectory)) {
        return [pscustomobject]@{
            TaskName = [string]$taskName
            PluginDirectory = [string]$pluginDirectory
            ZipPath = [string]$zipPath
            GuestHelperPath = [string]$guestHelperPath
            Status = 'missing-plugin'
            Message = 'no plugin'
            Manifest = $null
        }
    }

    if (-not (Test-Path -LiteralPath $zipPath)) {
        return [pscustomobject]@{
            TaskName = [string]$taskName
            PluginDirectory = [string]$pluginDirectory
            ZipPath = [string]$zipPath
            GuestHelperPath = [string]$guestHelperPath
            Status = 'missing-zip'
            Message = 'plugin folder exists but app-state.zip is missing'
            Manifest = $null
        }
    }

    try {
        $manifestInfo = Get-AzVmTaskAppStateManifestFromZip -ZipPath $zipPath -ExpectedTaskName $taskName
        return [pscustomobject]@{
            TaskName = [string]$taskName
            PluginDirectory = [string]$pluginDirectory
            ZipPath = [string]$zipPath
            GuestHelperPath = [string]$guestHelperPath
            Status = 'ready'
            Message = 'ready'
            Manifest = $manifestInfo.Manifest
        }
    }
    catch {
        return [pscustomobject]@{
            TaskName = [string]$taskName
            PluginDirectory = [string]$pluginDirectory
            ZipPath = [string]$zipPath
            GuestHelperPath = [string]$guestHelperPath
            Status = 'invalid'
            Message = [string]$_.Exception.Message
            Manifest = $null
        }
    }
}

function Get-AzVmTaskAppStateRemoteZipPath {
    param([string]$TaskName)

    $safeName = ([string]$TaskName -replace '[^A-Za-z0-9\-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace([string]$safeName)) {
        $safeName = 'task'
    }

    return ('C:/Windows/Temp/az-vm-app-state-{0}.zip' -f $safeName)
}

function Get-AzVmTaskAppStateGuestScript {
    param(
        [string]$TaskName,
        [string]$RemoteZipPath,
        [string]$ManagerUser,
        [string]$AssistantUser
    )

    $taskNameSafe = [string]$TaskName.Replace("'", "''")
    $remoteZipPathSafe = [string]$RemoteZipPath.Replace("'", "''")
    $managerUserSafe = [string]$ManagerUser.Replace("'", "''")
    $assistantUserSafe = [string]$AssistantUser.Replace("'", "''")

    return @"
`$ErrorActionPreference = 'Stop'
`$modulePath = 'C:\Windows\Temp\az-vm-app-state-guest.psm1'
if (-not (Test-Path -LiteralPath `$modulePath)) {
    throw ('Guest app-state helper was not found: {0}' -f `$modulePath)
}
Import-Module `$modulePath -Force -DisableNameChecking
`$result = Invoke-AzVmTaskAppStateReplay -ZipPath '$remoteZipPathSafe' -TaskName '$taskNameSafe' -ManagerUser '$managerUserSafe' -AssistantUser '$assistantUserSafe'
Write-Host ('app-state-summary => task={0}; machine-registry={1}; user-registry={2}; machine-directories={3}; machine-files={4}; profile-directories={5}; profile-files={6}' -f '$taskNameSafe', [int]`$result.MachineRegistryImports, [int]`$result.UserRegistryImports, [int]`$result.MachineDirectoryCopies, [int]`$result.MachineFileCopies, [int]`$result.ProfileDirectoryCopies, [int]`$result.ProfileFileCopies)
Write-Host 'app-state-replay-completed'
"@
}

function Invoke-AzVmTaskAppStatePostProcess {
    param(
        [ValidateSet('windows','linux')]
        [string]$Platform,
        [string]$RepoRoot,
        [psobject]$TaskBlock,
        [psobject]$Session,
        [string]$PySshPythonPath,
        [string]$PySshClientPath,
        [string]$HostName,
        [string]$UserName,
        [string]$Password,
        [string]$Port,
        [int]$ConnectTimeoutSeconds = 30,
        [int]$TimeoutSeconds = 180,
        [string]$ManagerUser = '',
        [string]$AssistantUser = ''
    )

    $pluginInfo = Get-AzVmTaskAppStatePluginInfo -TaskBlock $TaskBlock
    $taskName = [string]$pluginInfo.TaskName
    $taskShell = if ($Platform -eq 'windows') { 'powershell' } else { 'bash' }

    if ($pluginInfo.Status -eq 'missing-plugin') {
        Write-Host ("App-state skipped: {0} => no plugin" -f [string]$taskName)
        return [pscustomobject]@{ Status = 'skipped'; Warning = $false; Message = 'no plugin' }
    }
    if ($pluginInfo.Status -eq 'missing-zip') {
        Write-Host ("App-state skipped: {0} => no zip" -f [string]$taskName)
        return [pscustomobject]@{ Status = 'skipped'; Warning = $false; Message = 'no zip' }
    }
    if ($pluginInfo.Status -eq 'invalid') {
        Write-Warning ("App-state warning: {0} => {1}" -f [string]$taskName, [string]$pluginInfo.Message)
        return [pscustomobject]@{ Status = 'warning'; Warning = $true; Message = [string]$pluginInfo.Message }
    }
    if ($Platform -ne 'windows') {
        Write-Warning ("App-state warning: {0} => linux replay is not implemented yet; plugin was skipped." -f [string]$taskName)
        return [pscustomobject]@{ Status = 'warning'; Warning = $true; Message = 'linux replay is not implemented yet' }
    }

    $guestHelperPath = [string]$pluginInfo.GuestHelperPath
    if ([string]::IsNullOrWhiteSpace([string]$guestHelperPath) -or -not (Test-Path -LiteralPath $guestHelperPath)) {
        Write-Warning ("App-state warning: {0} => guest helper was not found: {1}" -f [string]$taskName, [string]$guestHelperPath)
        return [pscustomobject]@{ Status = 'warning'; Warning = $true; Message = 'guest helper missing' }
    }

    $remoteZipPath = Get-AzVmTaskAppStateRemoteZipPath -TaskName $taskName
    try {
        Copy-AzVmAssetToVm -PySshPythonPath $PySshPythonPath -PySshClientPath $PySshClientPath -HostName $HostName -UserName $UserName -Password $Password -Port $Port -LocalPath $guestHelperPath -RemotePath 'C:/Windows/Temp/az-vm-app-state-guest.psm1' -ConnectTimeoutSeconds $ConnectTimeoutSeconds
        Copy-AzVmAssetToVm -PySshPythonPath $PySshPythonPath -PySshClientPath $PySshClientPath -HostName $HostName -UserName $UserName -Password $Password -Port $Port -LocalPath ([string]$pluginInfo.ZipPath) -RemotePath $remoteZipPath -ConnectTimeoutSeconds $ConnectTimeoutSeconds
        $scriptText = Get-AzVmTaskAppStateGuestScript -TaskName $taskName -RemoteZipPath $remoteZipPath -ManagerUser $ManagerUser -AssistantUser $AssistantUser
        $scriptTimeout = $TimeoutSeconds
        if ($scriptTimeout -lt 60) { $scriptTimeout = 60 }
        if ($scriptTimeout -gt 600) { $scriptTimeout = 600 }
        $result = Invoke-AzVmSshTaskScript `
            -Session $Session `
            -PySshPythonPath $PySshPythonPath `
            -PySshClientPath $PySshClientPath `
            -HostName $HostName `
            -UserName $UserName `
            -Password $Password `
            -Port $Port `
            -Shell $taskShell `
            -TaskName ("{0} (app-state)" -f $taskName) `
            -TaskScript $scriptText `
            -TimeoutSeconds $scriptTimeout `
            -SkipRemoteCleanup
        if ($null -eq $result -or [int]$result.ExitCode -ne 0) {
            $exitCode = if ($null -ne $result -and $result.PSObject.Properties.Match('ExitCode').Count -gt 0) { [int]$result.ExitCode } else { -1 }
            Write-Warning ("App-state warning: {0} => replay exited with code {1}" -f [string]$taskName, $exitCode)
            return [pscustomobject]@{ Status = 'warning'; Warning = $true; Message = ("replay exited with code {0}" -f $exitCode) }
        }

        if ($result.PSObject.Properties.Match('Output').Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$result.Output)) {
            Write-Host ([string]$result.Output)
        }
        Write-Host ("App-state deployed: {0}" -f [string]$taskName)
        return [pscustomobject]@{ Status = 'deployed'; Warning = $false; Message = 'deployed' }
    }
    catch {
        Write-Warning ("App-state warning: {0} => {1}" -f [string]$taskName, $_.Exception.Message)
        return [pscustomobject]@{ Status = 'warning'; Warning = $true; Message = [string]$_.Exception.Message }
    }
}
