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

function Get-AzVmTaskAppStateLinuxGuestScript {
    param(
        [string]$TaskName,
        [string]$RemoteZipPath,
        [string]$ManagerUser,
        [string]$AssistantUser
    )

    $template = @'
set -euo pipefail
zip_path='__REMOTE_ZIP_PATH__'
task_name='__TASK_NAME__'
manager_user='__MANAGER_USER__'
assistant_user='__ASSISTANT_USER__'
scratch_root="$(mktemp -d /tmp/az-vm-app-state.XXXXXX)"
cleanup() {
  rm -rf "$scratch_root"
  rm -f "$zip_path"
}
trap cleanup EXIT
python_bin=''
if command -v python3 >/dev/null 2>&1; then
  python_bin="$(command -v python3)"
elif command -v python >/dev/null 2>&1; then
  python_bin="$(command -v python)"
else
  echo 'WARNING: app-state-linux-skip => python interpreter was not found.'
  exit 3
fi
"$python_bin" - "$zip_path" "$scratch_root" "$task_name" "$manager_user" "$assistant_user" <<'PY'
import json
import os
import shutil
import sys
import zipfile

zip_path, scratch_root, task_name, manager_user, assistant_user = sys.argv[1:6]

def warn(message: str) -> None:
    print(f"WARNING: {message}")

def ensure_dir(path: str) -> None:
    if path:
        os.makedirs(path, exist_ok=True)

def copy_file(source_path: str, destination_path: str) -> bool:
    try:
        ensure_dir(os.path.dirname(destination_path))
        shutil.copy2(source_path, destination_path)
        return True
    except Exception as exc:
        warn(f"app-state-file-copy-skip => source={source_path}; destination={destination_path}; reason={exc}")
        return False

def copy_directory_contents(source_path: str, destination_path: str) -> bool:
    ensure_dir(destination_path)
    copied_any = False
    for child_name in sorted(os.listdir(source_path)):
        source_child = os.path.join(source_path, child_name)
        destination_child = os.path.join(destination_path, child_name)
        try:
            if os.path.isdir(source_child) and not os.path.islink(source_child):
                shutil.copytree(source_child, destination_child, dirs_exist_ok=True)
            else:
                ensure_dir(os.path.dirname(destination_child))
                shutil.copy2(source_child, destination_child)
            copied_any = True
        except Exception as exc:
            warn(f"app-state-directory-copy-skip => source={source_child}; destination={destination_path}; reason={exc}")
    return copied_any

with zipfile.ZipFile(zip_path) as archive:
    archive.extractall(scratch_root)

manifest_path = os.path.join(scratch_root, 'app-state.manifest.json')
if not os.path.exists(manifest_path):
    raise RuntimeError(f"App-state manifest was not found in expanded payload: {manifest_path}")

with open(manifest_path, 'r', encoding='utf-8') as handle:
    manifest = json.load(handle)

if str(manifest.get('taskName', '')).strip().lower() != task_name.strip().lower():
    raise RuntimeError(f"App-state manifest taskName '{manifest.get('taskName', '')}' does not match task '{task_name}'.")

profile_targets = []
seen_targets = set()
for label, user_name, profile_path in (
    ('manager', manager_user, f"/home/{manager_user}" if manager_user else ''),
    ('assistant', assistant_user, f"/home/{assistant_user}" if assistant_user else ''),
):
    if not profile_path or not os.path.isdir(profile_path):
        continue
    normalized_path = os.path.normpath(profile_path)
    if normalized_path in seen_targets:
        continue
    profile_targets.append((label, user_name, normalized_path))
    seen_targets.add(normalized_path)

def select_profile_targets(entry):
    target_profiles = [str(item).strip().lower() for item in entry.get('targetProfiles', []) if str(item).strip()]
    if not target_profiles:
        return profile_targets
    return [
        row for row in profile_targets
        if row[0].strip().lower() in target_profiles or (row[1] and row[1].strip().lower() in target_profiles)
    ]

machine_registry_imports = 0
user_registry_imports = 0
machine_directory_copies = 0
machine_file_copies = 0
profile_directory_copies = 0
profile_file_copies = 0

for entry in manifest.get('machineDirectories', []):
    source_path = os.path.join(scratch_root, str(entry.get('sourcePath', '')))
    destination_path = str(entry.get('destinationPath', '')).strip()
    if not os.path.isdir(source_path) or not destination_path:
        warn(f"app-state-machine-directory-skip => {source_path}")
        continue
    if copy_directory_contents(source_path, destination_path):
        machine_directory_copies += 1

for entry in manifest.get('machineFiles', []):
    source_path = os.path.join(scratch_root, str(entry.get('sourcePath', '')))
    destination_path = str(entry.get('destinationPath', '')).strip()
    if not os.path.isfile(source_path) or not destination_path:
        warn(f"app-state-machine-file-skip => {source_path}")
        continue
    if copy_file(source_path, destination_path):
        machine_file_copies += 1

for entry in manifest.get('profileDirectories', []):
    source_path = os.path.join(scratch_root, str(entry.get('sourcePath', '')))
    relative_destination_path = str(entry.get('relativeDestinationPath', '')).strip()
    if not os.path.isdir(source_path) or not relative_destination_path:
        warn(f"app-state-profile-directory-skip => {source_path}")
        continue
    for _, _, profile_root in select_profile_targets(entry):
        destination_path = os.path.join(profile_root, relative_destination_path)
        if copy_directory_contents(source_path, destination_path):
            profile_directory_copies += 1

for entry in manifest.get('profileFiles', []):
    source_path = os.path.join(scratch_root, str(entry.get('sourcePath', '')))
    relative_destination_path = str(entry.get('relativeDestinationPath', '')).strip()
    if not os.path.isfile(source_path) or not relative_destination_path:
        warn(f"app-state-profile-file-skip => {source_path}")
        continue
    for _, _, profile_root in select_profile_targets(entry):
        destination_path = os.path.join(profile_root, relative_destination_path)
        if copy_file(source_path, destination_path):
            profile_file_copies += 1

for entry in manifest.get('registryImports', []):
    source_path = os.path.join(scratch_root, str(entry.get('sourcePath', '')))
    if not os.path.exists(source_path):
        warn(f"app-state-registry-skip => {source_path}")
        continue
    warn(f"app-state-registry-skip => {source_path} => registry replay is ignored on linux")

print(
    'app-state-summary => task={0}; machine-registry={1}; user-registry={2}; machine-directories={3}; machine-files={4}; profile-directories={5}; profile-files={6}'.format(
        task_name,
        machine_registry_imports,
        user_registry_imports,
        machine_directory_copies,
        machine_file_copies,
        profile_directory_copies,
        profile_file_copies,
    )
)
print('app-state-replay-completed')
PY
'@

    $bashTaskName = [string]$TaskName.Replace("'", "'""'""'")
    $bashRemoteZipPath = [string]$RemoteZipPath.Replace("'", "'""'""'")
    $bashManagerUser = [string]$ManagerUser.Replace("'", "'""'""'")
    $bashAssistantUser = [string]$AssistantUser.Replace("'", "'""'""'")
    return ($template.
        Replace('__TASK_NAME__', $bashTaskName).
        Replace('__REMOTE_ZIP_PATH__', $bashRemoteZipPath).
        Replace('__MANAGER_USER__', $bashManagerUser).
        Replace('__ASSISTANT_USER__', $bashAssistantUser))
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

    $remoteZipPath = Get-AzVmTaskAppStateRemoteZipPath -TaskName $taskName
    try {
        Copy-AzVmAssetToVm -PySshPythonPath $PySshPythonPath -PySshClientPath $PySshClientPath -HostName $HostName -UserName $UserName -Password $Password -Port $Port -LocalPath ([string]$pluginInfo.ZipPath) -RemotePath $remoteZipPath -ConnectTimeoutSeconds $ConnectTimeoutSeconds
        $scriptText = ''
        if ($Platform -eq 'windows') {
            $guestHelperPath = [string]$pluginInfo.GuestHelperPath
            if ([string]::IsNullOrWhiteSpace([string]$guestHelperPath) -or -not (Test-Path -LiteralPath $guestHelperPath)) {
                Write-Warning ("App-state warning: {0} => guest helper was not found: {1}" -f [string]$taskName, [string]$guestHelperPath)
                return [pscustomobject]@{ Status = 'warning'; Warning = $true; Message = 'guest helper missing' }
            }

            Copy-AzVmAssetToVm -PySshPythonPath $PySshPythonPath -PySshClientPath $PySshClientPath -HostName $HostName -UserName $UserName -Password $Password -Port $Port -LocalPath $guestHelperPath -RemotePath 'C:/Windows/Temp/az-vm-app-state-guest.psm1' -ConnectTimeoutSeconds $ConnectTimeoutSeconds
            $scriptText = Get-AzVmTaskAppStateGuestScript -TaskName $taskName -RemoteZipPath $remoteZipPath -ManagerUser $ManagerUser -AssistantUser $AssistantUser
        }
        else {
            $scriptText = Get-AzVmTaskAppStateLinuxGuestScript -TaskName $taskName -RemoteZipPath $remoteZipPath -ManagerUser $ManagerUser -AssistantUser $AssistantUser
        }
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
