# Run-command task block replacement helpers.

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
        if ($taskBlock.PSObject.Properties.Match('RelativePath').Count -gt 0) {
            $relativePath = [string]$taskBlock.RelativePath
        }
        if ($taskBlock.PSObject.Properties.Match('DirectoryPath').Count -gt 0) {
            $directoryPath = [string]$taskBlock.DirectoryPath
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

            if ($taskName -in @('10003-configure-ux-windows', '10005-copy-settings-user', '126-install-be-my-eyes', '131-install-icloud-system')) {
                $repoRoot = Split-Path -Path (Split-Path -Path $directoryPath -Parent) -Parent
                $helperLocalPath = Join-Path $repoRoot 'tools\windows\az-vm-interactive-session-helper.ps1'
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
            AssetCopies = @($assetCopies)
            TimeoutSeconds = [int]$timeoutSeconds
            Priority = if ($taskBlock.PSObject.Properties.Match('Priority').Count -gt 0) { [int]$taskBlock.Priority } else { 0 }
            TaskType = if ($taskBlock.PSObject.Properties.Match('TaskType').Count -gt 0) { [string]$taskBlock.TaskType } else { '' }
            Source = if ($taskBlock.PSObject.Properties.Match('Source').Count -gt 0) { [string]$taskBlock.Source } else { '' }
            TaskNumber = if ($taskBlock.PSObject.Properties.Match('TaskNumber').Count -gt 0) { [int]$taskBlock.TaskNumber } else { 0 }
        }
    }

    return $resolvedBlocks
}
