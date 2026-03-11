# Do command entry.

# Handles Invoke-AzVmDoCommand.
function Invoke-AzVmDoCommand {
    param(
        [hashtable]$Options
    )

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $target = Resolve-AzVmManagedVmTarget -Options $Options -ConfigMap $configMap -OperationName 'do'
    $action = Resolve-AzVmDoActionName -RawValue ([string](Get-AzVmCliOptionText -Options $Options -Name 'vm-action')) -AllowEmpty
    $snapshot = Get-AzVmVmLifecycleSnapshot -ResourceGroup ([string]$target.ResourceGroup) -VmName ([string]$target.VmName)

    if ([string]::IsNullOrWhiteSpace([string]$action)) {
        $action = Read-AzVmDoActionInteractive -Snapshot $snapshot
    }

    if ($action -eq 'status') {
        Write-AzVmDoStatusReport -Snapshot $snapshot
        return
    }

    Assert-AzVmDoActionAllowed -ActionName $action -Snapshot $snapshot

    $resourceGroup = [string]$target.ResourceGroup
    $vmName = [string]$target.VmName
    $desiredState = ''
    $successVerb = ''

    switch ($action) {
        'start' {
            $desiredState = 'started'
            $successVerb = 'started'
            Invoke-AzVmDoAzureAction `
                -ActionName $action `
                -ResourceGroup $resourceGroup `
                -VmName $vmName `
                -AzArguments @('vm','start','-g',$resourceGroup,'-n',$vmName,'-o','none','--only-show-errors') `
                -AzContext 'az vm start'
        }
        'restart' {
            $desiredState = 'started'
            $successVerb = 'restarted'
            Invoke-AzVmDoAzureAction `
                -ActionName $action `
                -ResourceGroup $resourceGroup `
                -VmName $vmName `
                -AzArguments @('vm','restart','-g',$resourceGroup,'-n',$vmName,'-o','none','--only-show-errors') `
                -AzContext 'az vm restart'
        }
        'stop' {
            $desiredState = 'stopped'
            $successVerb = 'stopped'
            Invoke-AzVmDoAzureAction `
                -ActionName $action `
                -ResourceGroup $resourceGroup `
                -VmName $vmName `
                -AzArguments @('vm','stop','-g',$resourceGroup,'-n',$vmName,'-o','none','--only-show-errors') `
                -AzContext 'az vm stop'
        }
        'deallocate' {
            $desiredState = 'deallocated'
            $successVerb = 'deallocated'
            Invoke-AzVmDoAzureAction `
                -ActionName $action `
                -ResourceGroup $resourceGroup `
                -VmName $vmName `
                -AzArguments @('vm','deallocate','-g',$resourceGroup,'-n',$vmName,'-o','none','--only-show-errors') `
                -AzContext 'az vm deallocate'
        }
        'hibernate' {
            $desiredState = 'hibernated'
            $successVerb = 'hibernated'
            Invoke-AzVmDoAzureAction `
                -ActionName $action `
                -ResourceGroup $resourceGroup `
                -VmName $vmName `
                -AzArguments @('vm','deallocate','-g',$resourceGroup,'-n',$vmName,'--hibernate','true','-o','none','--only-show-errors') `
                -AzContext 'az vm deallocate --hibernate'
        }
        default {
            throw ("Unsupported do action '{0}'." -f $action)
        }
    }

    $finalSnapshot = Wait-AzVmDoLifecycleState -ResourceGroup $resourceGroup -VmName $vmName -DesiredState $desiredState -MaxAttempts 24 -DelaySeconds 10
    if ($null -eq $finalSnapshot) {
        Throw-FriendlyError `
            -Detail ("VM '{0}' in resource group '{1}' did not reach expected '{2}' state after action '{3}'." -f $vmName, $resourceGroup, $desiredState, $action) `
            -Code 66 `
            -Summary ("VM action '{0}' did not reach the expected final state." -f $action) `
            -Hint "Check the VM status in Azure, run '--vm-action=status', then retry if needed."
    }

    Write-Host ("Do completed: VM '{0}' in resource group '{1}' is now {2}." -f $vmName, $resourceGroup, $successVerb) -ForegroundColor Green
    Write-AzVmDoStatusReport -Snapshot $finalSnapshot
}
