# VM deploy step orchestration.

# Handles Invoke-AzVmVmCreateStep.
function Invoke-AzVmVmCreateStep {
    param(
        [hashtable]$Context,
        [switch]$AutoMode,
        [switch]$UpdateMode,
        [ValidateSet("default","update","destructive rebuild")]
        [string]$ExecutionMode = "default",
        [scriptblock]$CreateVmAction
    )

    if (-not $CreateVmAction) {
        throw "CreateVmAction is required."
    }

    $resourceGroup = [string]$Context.ResourceGroup
    $effectiveMode = if ([string]::IsNullOrWhiteSpace([string]$ExecutionMode)) { "default" } else { [string]$ExecutionMode.Trim().ToLowerInvariant() }
    $vmName = [string]$Context.VmName
    Show-AzVmStepFirstUseValues `
        -StepLabel "Step 4/7 - VM create" `
        -Context $Context `
        -Keys @("ResourceGroup", "VmName", "VmImage", "VmSize", "VmStorageSku", "VmSecurityType", "VmEnableSecureBoot", "VmEnableVtpm", "VmDiskName", "VmDiskSize", "VmUser", "VmPass", "VmAssistantUser", "VmAssistantPass", "NIC") `
        -ExtraValues @{
            VmExecutionMode = $effectiveMode
        }

    $existingVM = az vm list `
        --resource-group $resourceGroup `
        --query "[?name=='$vmName'].name | [0]" `
        -o tsv `
        --only-show-errors 2>$null
    Assert-LastExitCode "az vm list"

    $hasExistingVm = -not [string]::IsNullOrWhiteSpace([string]$existingVM)
    $shouldDeleteVm = $false
    $shouldCreateVm = $true
    $vmDeletedInThisRun = $false
    if ($hasExistingVm) {
        Write-Host "VM '$vmName' exists in resource group '$resourceGroup'."

        switch ($effectiveMode) {
            "default" {
                $shouldCreateVm = $false
                Write-Host "Default mode: existing VM '$vmName' will be kept; create step is skipped." -ForegroundColor Yellow
            }
            "update" {
                Write-Host "Update mode: existing VM will be kept; az vm create will run in create-or-update mode." -ForegroundColor Yellow
            }
            "destructive rebuild" {
                if ($AutoMode) {
                    $shouldDeleteVm = $true
                    Write-Host "Auto mode: VM deletion was confirmed automatically."
                }
                else {
                    $shouldDeleteVm = Confirm-YesNo -PromptText "Are you sure you want to delete VM '$vmName'?" -DefaultYes $false
                }
            }
        }

        if ($shouldDeleteVm) {
            Write-Host "VM '$vmName' will be deleted..."
            Invoke-TrackedAction -Label "az vm delete --name $vmName --resource-group $resourceGroup --yes" -Action {
                az vm delete --name $vmName --resource-group $resourceGroup --yes -o table
                Assert-LastExitCode "az vm delete"
            } | Out-Null
            Write-Host "VM '$vmName' was deleted from resource group '$resourceGroup'."
            $vmDeletedInThisRun = $true
        }
        elseif ($effectiveMode -eq "destructive rebuild") {
            Write-Host "destructive rebuild mode: VM '$vmName' was not deleted by user choice; az vm create will run on existing VM." -ForegroundColor Yellow
        }
        elseif ($effectiveMode -ne "default") {
            Write-Host "VM '$vmName' was not deleted by user choice; continuing with az vm create on existing VM." -ForegroundColor Yellow
        }
    }
    else {
        Write-Host "VM '$vmName' is not present in resource group '$resourceGroup'. Creating..."
    }

    if (-not $shouldCreateVm) {
        return [pscustomobject]@{
            VmExistsBefore = [bool]$hasExistingVm
            VmDeleted = [bool]$vmDeletedInThisRun
            VmCreateInvoked = $false
            VmCreatedThisRun = $false
            VmId = ""
        }
    }

    $vmCreatedThisRun = (-not $hasExistingVm) -or $vmDeletedInThisRun
    $vmCreateJson = Invoke-TrackedAction -Label "az vm create --resource-group $resourceGroup --name $vmName" -Action {
        $result = & $CreateVmAction
        if ($LASTEXITCODE -ne 0) {
            $createExitCode = [int]$LASTEXITCODE
            $vmExistsAfterCreate = ""
            $shouldUseLongPresenceProbe = (($effectiveMode -in @("update","destructive rebuild")) -and $hasExistingVm)
            if (-not $shouldUseLongPresenceProbe) {
                throw "az vm create failed with exit code $createExitCode."
            }

            Write-Warning "az vm create returned a non-zero code; checking VM existence."
            $presenceProbeAttempts = if ($shouldUseLongPresenceProbe) { 12 } else { 3 }
            for ($presenceAttempt = 1; $presenceAttempt -le $presenceProbeAttempts; $presenceAttempt++) {
                $vmExistsAfterCreate = if (Test-AzVmAzResourceExists -AzArgs @("vm", "show", "-g", $resourceGroup, "-n", $vmName)) {
                    az vm show -g $resourceGroup -n $vmName --query "id" -o tsv --only-show-errors 2>$null
                }
                else {
                    ""
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$vmExistsAfterCreate)) {
                    break
                }

                if ($presenceAttempt -lt $presenceProbeAttempts) {
                    Write-Host ("VM existence probe attempt {0}/{1} did not resolve yet. Retrying in 10s..." -f $presenceAttempt, $presenceProbeAttempts) -ForegroundColor Yellow
                    Start-Sleep -Seconds 10
                }
            }

            if (-not [string]::IsNullOrWhiteSpace([string]$vmExistsAfterCreate)) {
                Write-Host "VM exists; details will be retrieved via az vm show -d."
                $result = az vm show -g $resourceGroup -n $vmName -d -o json --only-show-errors 2>$null
                Assert-LastExitCode "az vm show -d after vm create non-zero"
            }
            else {
                throw "az vm create failed with exit code $createExitCode."
            }
        }

        $result
    }

    $vmCreateObj = ConvertFrom-JsonCompat -InputObject $vmCreateJson
    if (-not $vmCreateObj.id) {
        throw "az vm create completed but VM id was not returned."
    }

    Write-Host "Printing az vm create output..."
    Write-Host $vmCreateJson

    $featureEnablementResult = Invoke-AzVmPostDeployFeatureEnablement -Context $Context -VmCreatedThisRun:$vmCreatedThisRun

    return [pscustomobject]@{
        VmExistsBefore = [bool]$hasExistingVm
        VmDeleted = [bool]$vmDeletedInThisRun
        VmCreateInvoked = $true
        VmCreatedThisRun = [bool]$vmCreatedThisRun
        VmId = [string]$vmCreateObj.id
        HibernationAttempted = [bool]$featureEnablementResult.HibernationAttempted
        HibernationEnabled = [bool]$featureEnablementResult.HibernationEnabled
        HibernationMessage = [string]$featureEnablementResult.HibernationMessage
        NestedAttempted = [bool]$featureEnablementResult.NestedAttempted
        NestedEnabled = [bool]$featureEnablementResult.NestedEnabled
        NestedMessage = [string]$featureEnablementResult.NestedMessage
    }
}
