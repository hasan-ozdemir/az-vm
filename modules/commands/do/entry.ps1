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
    $completionMessage = ''
    $finalSnapshot = $null

    switch ($action) {
        'start' {
            $desiredState = 'started'
            $completionMessage = ("Do completed: VM '{0}' in resource group '{1}' is now started." -f $vmName, $resourceGroup)
            Invoke-AzVmDoAzureAction `
                -ActionName $action `
                -ResourceGroup $resourceGroup `
                -VmName $vmName `
                -AzArguments @('vm','start','-g',$resourceGroup,'-n',$vmName,'-o','none','--only-show-errors') `
                -AzContext 'az vm start'
        }
        'restart' {
            $desiredState = 'started'
            $completionMessage = ("Do completed: VM '{0}' in resource group '{1}' is now restarted." -f $vmName, $resourceGroup)
            Invoke-AzVmDoAzureAction `
                -ActionName $action `
                -ResourceGroup $resourceGroup `
                -VmName $vmName `
                -AzArguments @('vm','restart','-g',$resourceGroup,'-n',$vmName,'-o','none','--only-show-errors') `
                -AzContext 'az vm restart'
        }
        'stop' {
            $desiredState = 'stopped'
            $completionMessage = ("Do completed: VM '{0}' in resource group '{1}' is now stopped." -f $vmName, $resourceGroup)
            Invoke-AzVmDoAzureAction `
                -ActionName $action `
                -ResourceGroup $resourceGroup `
                -VmName $vmName `
                -AzArguments @('vm','stop','-g',$resourceGroup,'-n',$vmName,'-o','none','--only-show-errors') `
                -AzContext 'az vm stop'
        }
        'deallocate' {
            $desiredState = 'deallocated'
            $completionMessage = ("Do completed: VM '{0}' in resource group '{1}' is now deallocated." -f $vmName, $resourceGroup)
            Invoke-AzVmDoAzureAction `
                -ActionName $action `
                -ResourceGroup $resourceGroup `
                -VmName $vmName `
                -AzArguments @('vm','deallocate','-g',$resourceGroup,'-n',$vmName,'-o','none','--only-show-errors') `
                -AzContext 'az vm deallocate'
        }
        'hibernate' {
            $desiredState = 'hibernated'
            $completionMessage = ("Do completed: VM '{0}' in resource group '{1}' is now hibernated." -f $vmName, $resourceGroup)
            Invoke-AzVmDoAzureAction `
                -ActionName $action `
                -ResourceGroup $resourceGroup `
                -VmName $vmName `
                -AzArguments @('vm','deallocate','-g',$resourceGroup,'-n',$vmName,'--hibernate','true','-o','none','--only-show-errors') `
                -AzContext 'az vm deallocate --hibernate'
        }
        'reapply' {
            $completionMessage = ("Do completed: VM '{0}' in resource group '{1}' was reapplied. Current status:" -f $vmName, $resourceGroup)
            Invoke-AzVmDoAzureAction `
                -ActionName $action `
                -ResourceGroup $resourceGroup `
                -VmName $vmName `
                -AzArguments @('vm','reapply','-g',$resourceGroup,'-n',$vmName,'-o','none','--only-show-errors') `
                -AzContext 'az vm reapply'
            $finalSnapshot = Get-AzVmVmLifecycleSnapshot -ResourceGroup $resourceGroup -VmName $vmName
        }
        default {
            throw ("Unsupported do action '{0}'." -f $action)
        }
    }

    if ($null -eq $finalSnapshot) {
        $finalSnapshot = Wait-AzVmDoLifecycleState -ResourceGroup $resourceGroup -VmName $vmName -DesiredState $desiredState -MaxAttempts 24 -DelaySeconds 10
    }
    if ($null -eq $finalSnapshot) {
        Throw-FriendlyError `
            -Detail ("VM '{0}' in resource group '{1}' did not reach expected '{2}' state after action '{3}'." -f $vmName, $resourceGroup, $desiredState, $action) `
            -Code 66 `
            -Summary ("VM action '{0}' did not reach the expected final state." -f $action) `
            -Hint "Check the VM status in Azure, run '--vm-action=status', then retry if needed."
    }

    Write-Host $completionMessage -ForegroundColor Green
    Write-AzVmDoStatusReport -Snapshot $finalSnapshot
}
