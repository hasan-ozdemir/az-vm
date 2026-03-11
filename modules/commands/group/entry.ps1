# Group command entry.

# Handles Invoke-AzVmGroupCommand.
function Invoke-AzVmGroupCommand {
    param(
        [hashtable]$Options
    )

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $activeGroup = [string](Get-ConfigValue -Config $configMap -Key 'RESOURCE_GROUP' -DefaultValue '')
    $vmName = [string](Get-ConfigValue -Config $configMap -Key 'VM_NAME' -DefaultValue '')

    $hasList = Test-AzVmCliOptionPresent -Options $Options -Name 'list'
    $hasSelect = Test-AzVmCliOptionPresent -Options $Options -Name 'select'
    if ($hasList -and $hasSelect) {
        Throw-FriendlyError `
            -Detail "Options '--list' and '--select' cannot be used together." `
            -Code 2 `
            -Summary "Group command options are conflicting." `
            -Hint "Run list and select as separate commands."
    }

    if ($hasSelect) {
        $selectionRaw = [string](Get-AzVmCliOptionText -Options $Options -Name 'select')
        $selectedGroup = ''
        if ([string]::IsNullOrWhiteSpace([string]$selectionRaw)) {
            $selectedGroup = Select-AzVmResourceGroupInteractive -DefaultResourceGroup $activeGroup -VmName $vmName
        }
        else {
            $selectedGroup = $selectionRaw.Trim()
            $exists = az group exists -n $selectedGroup --only-show-errors
            Assert-LastExitCode "az group exists (group select)"
            if (-not [string]::Equals([string]$exists, "true", [System.StringComparison]::OrdinalIgnoreCase)) {
                Throw-FriendlyError `
                    -Detail ("Resource group '{0}' was not found." -f $selectedGroup) `
                    -Code 64 `
                    -Summary "Group select failed because target resource group was not found." `
                    -Hint "Select an existing managed resource group."
            }
            Assert-AzVmManagedResourceGroup -ResourceGroup $selectedGroup -OperationName 'group select'
        }

        Set-DotEnvValue -Path $envFilePath -Key 'RESOURCE_GROUP' -Value $selectedGroup
        $script:ConfigOverrides['RESOURCE_GROUP'] = $selectedGroup
        Write-Host ("Active resource group set to '{0}'." -f $selectedGroup) -ForegroundColor Green
        return
    }

    $filterRaw = if ($hasList) { [string](Get-AzVmCliOptionText -Options $Options -Name 'list') } else { '' }
    $filter = if ([string]::IsNullOrWhiteSpace([string]$filterRaw)) { '' } else { $filterRaw.Trim().ToLowerInvariant() }

    $rows = @()
    try {
        $rows = @(Get-AzVmManagedResourceGroupRows)
    }
    catch {
        Throw-FriendlyError `
            -Detail "Managed resource groups could not be listed." `
            -Code 64 `
            -Summary "Group list failed." `
            -Hint "Run az login and verify Azure access."
    }

    $names = @(
        ConvertTo-ObjectArrayCompat -InputObject $rows |
            ForEach-Object { [string]$_.name } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Sort-Object -Unique
    )
    if (-not [string]::IsNullOrWhiteSpace([string]$filter)) {
        $names = @(
            $names | Where-Object {
                ([string]$_).ToLowerInvariant().Contains($filter)
            }
        )
    }

    Write-Host "Managed resource groups (az-vm):" -ForegroundColor Cyan
    if (@($names).Count -eq 0) {
        Write-Host "- (none)"
        return
    }

    for ($i = 0; $i -lt $names.Count; $i++) {
        $name = [string]$names[$i]
        $label = if ([string]::Equals($name, $activeGroup, [System.StringComparison]::OrdinalIgnoreCase)) {
            "*{0}-{1}." -f ($i + 1), $name
        }
        else {
            "{0}-{1}." -f ($i + 1), $name
        }
        Write-Host $label
    }
}
