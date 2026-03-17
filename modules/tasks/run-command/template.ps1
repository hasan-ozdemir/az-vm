# Run-command task block replacement helpers.

function Resolve-AzVmTaskRepoRootFromPath {
    param([string]$StartPath)

    if ([string]::IsNullOrWhiteSpace([string]$StartPath)) {
        return ''
    }

    $cursor = [string]$StartPath
    if (Test-Path -LiteralPath $cursor -PathType Leaf) {
        $cursor = [string](Split-Path -Path $cursor -Parent)
    }

    while (-not [string]::IsNullOrWhiteSpace([string]$cursor)) {
        if (Test-Path -LiteralPath (Join-Path $cursor 'az-vm.ps1')) {
            return [string]$cursor
        }

        $parent = [string](Split-Path -Path $cursor -Parent)
        if ([string]::IsNullOrWhiteSpace([string]$parent) -or [string]::Equals([string]$parent, [string]$cursor, [System.StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        $cursor = $parent
    }

    return ''
}

# Handles Apply-AzVmTaskBlockReplacements.
function Apply-AzVmTaskBlockReplacements {
    param(
        [object[]]$TaskBlocks,
        [hashtable]$Replacements
    )

    if (-not $TaskBlocks) {
        return @()
    }

    $resolvedBlocks = @()
    foreach ($taskBlock in $TaskBlocks) {
        $taskName = [string]$taskBlock.Name
        $taskScript = [string]$taskBlock.Script
        $relativePath = ''
        $directoryPath = ''
        $taskRootPath = ''
        $taskMetadataPath = ''
        $stageRootDirectoryPath = ''
        if ($taskBlock.PSObject.Properties.Match('RelativePath').Count -gt 0) {
            $relativePath = [string]$taskBlock.RelativePath
        }
        if ($taskBlock.PSObject.Properties.Match('DirectoryPath').Count -gt 0) {
            $directoryPath = [string]$taskBlock.DirectoryPath
        }
        if ($taskBlock.PSObject.Properties.Match('TaskRootPath').Count -gt 0) {
            $taskRootPath = [string]$taskBlock.TaskRootPath
        }
        if ($taskBlock.PSObject.Properties.Match('TaskMetadataPath').Count -gt 0) {
            $taskMetadataPath = [string]$taskBlock.TaskMetadataPath
        }
        if ($taskBlock.PSObject.Properties.Match('StageRootDirectoryPath').Count -gt 0) {
            $stageRootDirectoryPath = [string]$taskBlock.StageRootDirectoryPath
        }
        $timeoutSeconds = 180
        if ($taskBlock.PSObject.Properties.Match('TimeoutSeconds').Count -gt 0) {
            $timeoutSeconds = Get-AzVmTaskTimeoutSeconds -TaskBlock $taskBlock -DefaultTimeoutSeconds 180
        }
        $assetSpecs = @()
        if ($taskBlock.PSObject.Properties.Match('AssetSpecs').Count -gt 0 -and $null -ne $taskBlock.AssetSpecs) {
            $assetSpecs = @(ConvertTo-ObjectArrayCompat -InputObject $taskBlock.AssetSpecs)
        }

        if ($Replacements) {
            foreach ($key in $Replacements.Keys) {
                $token = "__{0}__" -f [string]$key
                $value = [string]$Replacements[$key]
                $taskScript = $taskScript.Replace($token, $value)
            }
        }

        $assetCopies = @()
        if (-not [string]::IsNullOrWhiteSpace([string]$directoryPath)) {
            foreach ($assetSpec in @($assetSpecs)) {
                $assetLocalPath = [string]$assetSpec.LocalPath
                $assetRemotePath = [string]$assetSpec.RemotePath
                if ($Replacements) {
                    foreach ($key in $Replacements.Keys) {
                        $token = "__{0}__" -f [string]$key
                        $value = [string]$Replacements[$key]
                        $assetLocalPath = $assetLocalPath.Replace($token, $value)
                        $assetRemotePath = $assetRemotePath.Replace($token, $value)
                    }
                }

                if (-not [System.IO.Path]::IsPathRooted($assetLocalPath)) {
                    $assetLocalPath = Join-Path $directoryPath ($assetLocalPath.Replace('/', '\'))
                }
                if (-not (Test-Path -LiteralPath $assetLocalPath)) {
                    throw ("Task asset was not found for '{0}': {1}" -f $taskName, $assetLocalPath)
                }

                $assetCopies += [pscustomobject]@{
                    LocalPath = [string](Resolve-Path -LiteralPath $assetLocalPath).Path
                    RemotePath = [string]$assetRemotePath
                }
            }

            if ($taskName -in @('10004-configure-ux-windows', '10005-copy-settings-user', '113-install-be-my-eyes', '120-install-icloud-system')) {
                $repoRoot = Resolve-AzVmTaskRepoRootFromPath -StartPath $directoryPath
                if ([string]::IsNullOrWhiteSpace([string]$repoRoot)) {
                    throw ("Repo root could not be resolved for task '{0}' from '{1}'." -f $taskName, $directoryPath)
                }
                $helperLocalPath = Join-Path $repoRoot 'tools\scripts\az-vm-interactive-session-helper.ps1'
                if (-not (Test-Path -LiteralPath $helperLocalPath)) {
                    throw ("Interactive session helper was not found for '{0}': {1}" -f $taskName, $helperLocalPath)
                }

                $assetCopies += [pscustomobject]@{
                    LocalPath = [string](Resolve-Path -LiteralPath $helperLocalPath).Path
                    RemotePath = 'C:/Windows/Temp/az-vm-interactive-session-helper.ps1'
                }
            }
        }

        $resolvedBlocks += [pscustomobject]@{
            Name = $taskName
            Script = $taskScript
            RelativePath = $relativePath
            DirectoryPath = $directoryPath
            TaskRootPath = $taskRootPath
            TaskMetadataPath = $taskMetadataPath
            StageRootDirectoryPath = $stageRootDirectoryPath
            AssetCopies = @($assetCopies)
            TimeoutSeconds = [int]$timeoutSeconds
            Priority = if ($taskBlock.PSObject.Properties.Match('Priority').Count -gt 0) { [int]$taskBlock.Priority } else { 0 }
            TaskType = if ($taskBlock.PSObject.Properties.Match('TaskType').Count -gt 0) { [string]$taskBlock.TaskType } else { '' }
            Source = if ($taskBlock.PSObject.Properties.Match('Source').Count -gt 0) { [string]$taskBlock.Source } else { '' }
            TaskNumber = if ($taskBlock.PSObject.Properties.Match('TaskNumber').Count -gt 0) { [int]$taskBlock.TaskNumber } else { 0 }
            AppStateSpec = if ($taskBlock.PSObject.Properties.Match('AppStateSpec').Count -gt 0) { $taskBlock.AppStateSpec } else { $null }
            DependsOn = if ($taskBlock.PSObject.Properties.Match('DependsOn').Count -gt 0) { @($taskBlock.DependsOn) } else { @() }
            ObservedDurationSeconds = if ($taskBlock.PSObject.Properties.Match('ObservedDurationSeconds').Count -gt 0) { [double]$taskBlock.ObservedDurationSeconds } else { [double]::PositiveInfinity }
        }
    }

    return $resolvedBlocks
}
