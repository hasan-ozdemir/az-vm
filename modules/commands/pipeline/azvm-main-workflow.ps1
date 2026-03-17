# Create/update main pipeline review and barrier helpers.

function Write-AzVmMainBanner {
    param(
        [string]$CommandName,
        [string]$Mode,
        [string]$Platform,
        [psobject]$ActionPlan,
        [string]$LogPath,
        [string]$SubscriptionName = '',
        [string]$SubscriptionId = ''
    )

    $stepWindow = 'full'
    if ($null -ne $ActionPlan -and [string]$ActionPlan.Mode -ne 'full') {
        if ([string]::Equals([string]$ActionPlan.Mode, 'single', [System.StringComparison]::OrdinalIgnoreCase)) {
            $stepWindow = [string]$ActionPlan.Target
        }
        else {
            $stepWindow = ("{0}->{1}" -f [string]$ActionPlan.Start, [string]$ActionPlan.Target)
        }
    }

    Write-Host "az-vm" -ForegroundColor Cyan
    Write-Host ("- command: {0}" -f [string]$CommandName)
    Write-Host ("- mode: {0}" -f [string]$Mode)
    Write-Host ("- platform: {0}" -f [string]$Platform)
    if (-not [string]::IsNullOrWhiteSpace([string]$SubscriptionId)) {
        $subscriptionDisplay = if ([string]::IsNullOrWhiteSpace([string]$SubscriptionName)) { [string]$SubscriptionId } else { ("{0} ({1})" -f [string]$SubscriptionName, [string]$SubscriptionId) }
        Write-Host ("- subscription: {0}" -f $subscriptionDisplay)
    }
    Write-Host ("- steps: {0}" -f [string]$stepWindow)
    Write-Host ("- transcript: {0}" -f [System.IO.Path]::GetFileName([string]$LogPath))
}

function Get-AzVmReviewTaskRows {
    param(
        [string]$DirectoryPath,
        [ValidateSet('windows','linux')]
        [string]$Platform,
        [ValidateSet('init','update')]
        [string]$Stage,
        [hashtable]$Context
    )

    $catalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath $DirectoryPath -Platform $Platform -Stage $Stage
    $activeTemplates = @($catalog.ActiveTasks)
    $disabledTasks = @($catalog.DisabledTasks)
    $resolved = if (@($activeTemplates).Count -gt 0) {
        @(Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks $activeTemplates -Context $Context)
    }
    else {
        @()
    }

    return [pscustomobject]@{
        ActiveTasks = @($resolved)
        DisabledTasks = @($disabledTasks)
    }
}

function Show-AzVmTaskReviewRows {
    param(
        [string]$Title,
        [object[]]$TaskBlocks
    )

    Write-Host $Title -ForegroundColor Cyan
    if (@($TaskBlocks).Count -eq 0) {
        Write-Host "- (no active tasks)"
        return
    }

    foreach ($task in @($TaskBlocks)) {
        $priority = if ($task.PSObject.Properties.Match('Priority').Count -gt 0) { [int]$task.Priority } else { 1000 }
        $timeout = if ($task.PSObject.Properties.Match('TimeoutSeconds').Count -gt 0) { [int]$task.TimeoutSeconds } else { 180 }
        Write-Host ("- #{0} | {1} | priority={2} | timeout={3}s" -f [string]$task.TaskNumber, [string]$task.Name, $priority, $timeout)
    }
}

function Show-AzVmStepReview {
    param(
        [string]$Title,
        [System.Collections.IDictionary]$Values,
        [string]$TaskTitle,
        [object[]]$TaskBlocks
    )

    Write-Host ""
    Write-Host $Title -ForegroundColor DarkCyan
    if ($Values -and $Values.Count -gt 0) {
        $distinctValues = [ordered]@{}
        foreach ($key in @($Values.Keys)) {
            $normalizedKey = [string]$key
            $observed = Register-AzVmValueObservation -Key $normalizedKey -Value $Values[$key]
            if (-not [bool]$observed.ShouldPrint) {
                continue
            }

            $distinctValues[$normalizedKey] = [string]$observed.DisplayValue
        }

        if ($distinctValues.Count -gt 0) {
            Show-AzVmKeyValueList -Title 'Planned values:' -Values $distinctValues
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$TaskTitle)) {
        Show-AzVmTaskReviewRows -Title $TaskTitle -TaskBlocks $TaskBlocks
    }
}

function Stop-AzVmWorkflowCancelled {
    param(
        [string]$StageName,
        [string[]]$CompletedStages,
        [string[]]$SkippedStages
    )

    Write-Host ""
    Write-Host "Workflow cancelled by user." -ForegroundColor Yellow
    Write-Host ("Cancelled at: {0}" -f [string]$StageName)
    Write-Host ("Completed stages: {0}" -f (if (@($CompletedStages).Count -gt 0) { @($CompletedStages) -join ', ' } else { '(none)' }))
    Write-Host ("Skipped stages: {0}" -f (if (@($SkippedStages).Count -gt 0) { @($SkippedStages) -join ', ' } else { '(none)' }))

    Throw-FriendlyError `
        -Detail ("Workflow was cancelled before stage '{0}' executed." -f [string]$StageName) `
        -Code 0 `
        -Summary "Operation cancelled by user." `
        -Hint "Rerun the command when you want to continue from a review checkpoint."
}

function Invoke-AzVmReviewCheckpoint {
    param(
        [switch]$AutoMode,
        [string]$StageName,
        [System.Collections.IDictionary]$Values,
        [string]$TaskTitle,
        [object[]]$TaskBlocks,
        [string[]]$CompletedStages,
        [string[]]$SkippedStages
    )

    if ($AutoMode) {
        if ($TaskBlocks) {
            Show-AzVmStepReview -Title $StageName -Values @{} -TaskTitle $TaskTitle -TaskBlocks $TaskBlocks
        }
        Write-Host ("Auto mode: continuing with {0}." -f [string]$StageName) -ForegroundColor Cyan
        return 'yes'
    }

    Show-AzVmStepReview -Title $StageName -Values $Values -TaskTitle $TaskTitle -TaskBlocks $TaskBlocks
    return (Confirm-YesNoCancel -PromptText ("Continue with {0}?" -f [string]$StageName) -DefaultChoice 'yes')
}

function Invoke-AzVmPersistPendingSelections {
    param(
        [hashtable]$Context,
        [string]$EnvFilePath
    )

    if ($null -eq $Context) {
        return
    }

    $pendingMap = $null
    if ($Context.ContainsKey('PendingEnvUpdates')) {
        $pendingMap = $Context['PendingEnvUpdates']
    }
    if ($null -eq $pendingMap -or @($pendingMap.Keys).Count -eq 0) {
        return
    }

    Save-AzVmStep1ContextPersistenceMap -EnvFilePath $EnvFilePath -PersistMap $pendingMap
    $Context['PendingEnvUpdates'] = [ordered]@{}
    Write-Host "Saved selected configuration values to .env." -ForegroundColor Green
}

function Invoke-AzVmWorkflowRestartBarrier {
    param(
        [hashtable]$Context,
        [ValidateSet('after-vm-update')]
        [string]$Reason,
        [int]$SshConnectTimeoutSeconds = 5
    )

    $resourceGroup = [string]$Context.ResourceGroup
    $vmName = [string]$Context.VmName
    $sshPort = [int]$Context.SshPort

    $startMessage = ''
    $successMessage = ''
    $runningFailureSummary = ''
    $runningFailureHint = ''
    $hostFailureSummary = ''
    $hostFailureHint = ''
    $sshFailureSummary = ''
    $sshFailureHint = ''

    switch ($Reason) {
        'after-vm-update' {
            $startMessage = 'VM update requested a restart. Restarting VM before vm-summary...'
            $successMessage = 'VM restart after vm-update completed successfully.'
            $runningFailureSummary = 'VM could not be restarted after vm-update.'
            $runningFailureHint = 'Check the VM in Azure Portal and rerun update after the guest returns to running state.'
            $hostFailureSummary = 'VM restart after vm-update could not resolve SSH host.'
            $hostFailureHint = 'Verify the managed VM still has a public IP or FQDN.'
            $sshFailureSummary = 'VM restart after vm-update did not restore SSH connectivity.'
            $sshFailureHint = 'Verify guest startup health and rerun update after SSH becomes reachable.'
        }
    }

    Write-Host $startMessage -ForegroundColor Cyan
    Invoke-TrackedAction -Label ("az vm restart -g {0} -n {1}" -f $resourceGroup, $vmName) -Action {
        az vm restart -g $resourceGroup -n $vmName -o none --only-show-errors
        Assert-LastExitCode "az vm restart"
    } | Out-Null

    $running = Wait-AzVmVmPowerState -ResourceGroup $resourceGroup -VmName $vmName -DesiredPowerState "VM running" -MaxAttempts 36 -DelaySeconds 10
    if (-not $running) {
        Throw-FriendlyError `
            -Detail ("VM '{0}' did not return to running state after the workflow restart barrier." -f $vmName) `
            -Code 62 `
            -Summary $runningFailureSummary `
            -Hint $runningFailureHint
    }

    $vmRuntimeDetails = Get-AzVmVmDetails -Context $Context
    $sshHost = [string]$vmRuntimeDetails.VmFqdn
    if ([string]::IsNullOrWhiteSpace([string]$sshHost)) {
        $sshHost = [string]$vmRuntimeDetails.PublicIP
    }
    if ([string]::IsNullOrWhiteSpace([string]$sshHost)) {
        Throw-FriendlyError `
            -Detail "SSH host could not be resolved after the workflow restart barrier." `
            -Code 62 `
            -Summary $hostFailureSummary `
            -Hint $hostFailureHint
    }

    $sshReady = Wait-AzVmTcpPortReachable -HostName $sshHost -Port $sshPort -MaxAttempts 30 -DelaySeconds 10 -TimeoutSeconds $SshConnectTimeoutSeconds -Label 'ssh'
    if (-not $sshReady) {
        Throw-FriendlyError `
            -Detail ("SSH port {0} on '{1}' did not become reachable after the workflow restart barrier." -f $sshPort, $sshHost) `
            -Code 62 `
            -Summary $sshFailureSummary `
            -Hint $sshFailureHint
    }

    Write-Host $successMessage -ForegroundColor Green
}
