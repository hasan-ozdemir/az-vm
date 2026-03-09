# Imported runtime region: test-core.

# Handles Invoke-Step.
function Invoke-Step {
    param(
        [string] $prompt,
        [scriptblock] $Action
    )

    function Publish-NewStepVariables {
        param(
            [object[]]$BeforeVariables,
            [object[]]$AfterVariables
        )

        $beforeNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($beforeVar in $BeforeVariables) {
            [void]$beforeNames.Add([string]$beforeVar.Name)
        }

        foreach ($var in $AfterVariables) {
            $varName = [string]$var.Name
            if ($beforeNames.Contains($varName)) {
                continue
            }

            if (($var.Options -band [System.Management.Automation.ScopedItemOptions]::Constant) -ne 0) {
                continue
            }

            try {
                Set-Variable -Name $varName -Value $var.Value -Scope Script -Force -ErrorAction Stop
            }
            catch {
                # Skip transient or restricted variables safely.
            }
        }
    }

    $before = @(Get-Variable)
    if ($script:AutoMode) {
        Write-Host "$prompt (mode: auto)" -ForegroundColor Cyan
        $stepWatch = [System.Diagnostics.Stopwatch]::StartNew()
        . $Action
        if ($stepWatch.IsRunning) { $stepWatch.Stop() }
        if ($script:PerfMode) {
            Write-AzVmPerfTiming -Category "step" -Label ("{0} [mode:auto]" -f $prompt) -Seconds $stepWatch.Elapsed.TotalSeconds
        }
        $after = @(Get-Variable)
        Publish-NewStepVariables -BeforeVariables $before -AfterVariables $after
        return
    }
    do {
        $response = Read-Host "$prompt (mode: interactive) (yes/no)?"
    } until ($response -match '^[yYnN]$')
    if ($response -match '^[yY]$') {
        $stepWatch = [System.Diagnostics.Stopwatch]::StartNew()
        . $Action
        if ($stepWatch.IsRunning) { $stepWatch.Stop() }
        if ($script:PerfMode) {
            Write-AzVmPerfTiming -Category "step" -Label ("{0} [mode:interactive]" -f $prompt) -Seconds $stepWatch.Elapsed.TotalSeconds
        }
        $after = @(Get-Variable)
        Publish-NewStepVariables -BeforeVariables $before -AfterVariables $after
    }
    else {
        Write-Host "Skipping this step." -ForegroundColor Cyan
    }
}

# Handles Confirm-YesNo.
function Confirm-YesNo {
    param(
        [string]$PromptText,
        [bool]$DefaultYes = $false
    )

    $hintText = if ($DefaultYes) { " [Y/n]" } else { " [y/N]" }
    while ($true) {
        $raw = Read-Host ($PromptText + $hintText)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $DefaultYes
        }

        $value = $raw.Trim().ToLowerInvariant()
        if ($value -eq "y" -or $value -eq "yes") {
            return $true
        }
        if ($value -eq "n" -or $value -eq "no") {
            return $false
        }

        Write-Host "Please answer yes or no." -ForegroundColor Yellow
    }
}

# Handles Invoke-TrackedAction.
function Invoke-TrackedAction {
    param(
        [string]$Label,
        [scriptblock]$Action
    )

    if ([string]::IsNullOrWhiteSpace($Label)) {
        $Label = "action"
    }

    $isAzLabel = ([string]$Label).TrimStart().ToLowerInvariant().StartsWith("az ")
    Write-Host ("running: {0}" -f $Label) -ForegroundColor DarkCyan
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    if ($isAzLabel) {
        $script:PerfSuppressAzTimingDepth = [int]$script:PerfSuppressAzTimingDepth + 1
    }
    try {
        $result = . $Action
        if ($null -ne $result) {
            return $result
        }
    }
    finally {
        if ($isAzLabel) {
            $script:PerfSuppressAzTimingDepth = [Math]::Max(0, ([int]$script:PerfSuppressAzTimingDepth - 1))
        }
        if ($watch.IsRunning) {
            $watch.Stop()
        }
        Write-Host ("finished: {0} ({1:N1}s)" -f $Label, $watch.Elapsed.TotalSeconds) -ForegroundColor DarkCyan
        if ($script:PerfMode) {
            $category = if ($isAzLabel) { "az" } else { "action" }
            Write-AzVmPerfTiming -Category $category -Label $Label -Seconds $watch.Elapsed.TotalSeconds
        }
    }
}

# Handles Assert-LastExitCode.
function Assert-LastExitCode {
    param(
        [string]$Context
    )
    if ($LASTEXITCODE -ne 0) {
        throw "$Context failed with exit code $LASTEXITCODE."
    }
}

# Handles Throw-FriendlyError.
function Throw-FriendlyError {
    param(
        [string]$Detail,
        [int]$Code,
        [string]$Summary,
        [string]$Hint
    )

    $ex = [System.Exception]::new($Detail)
    $ex.Data["ExitCode"] = $Code
    $ex.Data["Summary"] = $Summary
    $ex.Data["Hint"] = $Hint
    throw $ex
}

# Handles Remove-AzVmMoveCollectionArtifacts.
function Remove-AzVmMoveCollectionArtifacts {
    param(
        [string]$ResourceGroup,
        [string]$CollectionName,
        [string]$Reason = 'cleanup requested'
    )

    if ([string]::IsNullOrWhiteSpace([string]$ResourceGroup) -or [string]::IsNullOrWhiteSpace([string]$CollectionName)) {
        return
    }

    Write-Host ("Cleanup started for move collection '{0}'. Reason: {1}" -f $CollectionName, $Reason) -ForegroundColor Yellow

    $moveResourceIdsText = az resource-mover move-resource list -g $ResourceGroup --move-collection-name $CollectionName --query "[].id" -o tsv --only-show-errors 2>$null
    $moveResourceIds = @()
    if ($LASTEXITCODE -eq 0) {
        $moveResourceIds = @((Convert-AzVmCliTextToTokens -Text $moveResourceIdsText) | Select-Object -Unique)
    }

    if ($moveResourceIds.Count -gt 0) {
        Invoke-TrackedAction -Label ("az resource-mover move-collection discard --name {0}" -f $CollectionName) -Action {
            $discardArgs = @("resource-mover", "move-collection", "discard", "-g", $ResourceGroup, "-n", $CollectionName, "--validate-only", "false", "--input-type", "MoveResourceId", "--move-resources")
            $discardArgs += $moveResourceIds
            $discardArgs += @("-o", "none", "--only-show-errors")
            az @discardArgs 2>$null
        } | Out-Null
        Start-Sleep -Seconds 3

        Invoke-TrackedAction -Label ("az resource-mover move-collection bulk-remove --name {0}" -f $CollectionName) -Action {
            $bulkRemoveArgs = @("resource-mover", "move-collection", "bulk-remove", "-g", $ResourceGroup, "-n", $CollectionName, "--validate-only", "false", "--input-type", "MoveResourceId", "--move-resources")
            $bulkRemoveArgs += $moveResourceIds
            $bulkRemoveArgs += @("-o", "none", "--only-show-errors")
            az @bulkRemoveArgs 2>$null
        } | Out-Null
        Start-Sleep -Seconds 3
    }

    $moveResourceNamesText = az resource-mover move-resource list -g $ResourceGroup --move-collection-name $CollectionName --query "[].name" -o tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0) {
        $moveResourceNames = @((Convert-AzVmCliTextToTokens -Text $moveResourceNamesText) | Select-Object -Unique)
        foreach ($moveResourceName in @($moveResourceNames)) {
            if ([string]::IsNullOrWhiteSpace([string]$moveResourceName)) { continue }
            Invoke-TrackedAction -Label ("az resource-mover move-resource delete --name {0}" -f $moveResourceName) -Action {
                az resource-mover move-resource delete -g $ResourceGroup --move-collection-name $CollectionName -n $moveResourceName --yes -o none --only-show-errors 2>$null
            } | Out-Null
        }
    }

    $subscriptionId = az account show --query id -o tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$subscriptionId)) {
        $deleteUri = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Migrate/moveCollections/$CollectionName"
        Invoke-TrackedAction -Label ("az rest delete move-collection --name {0}" -f $CollectionName) -Action {
            az rest --method delete --uri $deleteUri --url-parameters api-version=2024-08-01 -o none --only-show-errors 2>$null
        } | Out-Null
    }
    else {
        Invoke-TrackedAction -Label ("az resource-mover move-collection delete --name {0}" -f $CollectionName) -Action {
            az resource-mover move-collection delete -g $ResourceGroup -n $CollectionName --yes -o none --only-show-errors 2>$null
        } | Out-Null
    }

    az resource-mover move-collection show -g $ResourceGroup -n $CollectionName -o none --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("Cleanup could not fully delete move collection '{0}'. Please remove it manually." -f $CollectionName) -ForegroundColor Yellow
    }
    else {
        Write-Host ("Cleanup completed for move collection '{0}'." -f $CollectionName) -ForegroundColor Green
    }
}

# Handles Get-AzVmManagedMoveCollections.
function Get-AzVmManagedMoveCollections {
    param(
        [string]$ResourceGroup,
        [string]$SourceRegion,
        [string]$TargetRegion,
        [string]$CollectionPrefix
    )

    if ([string]::IsNullOrWhiteSpace([string]$ResourceGroup)) {
        return @()
    }

    $collectionsJson = az resource-mover move-collection list -g $ResourceGroup -o json --only-show-errors 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$collectionsJson)) {
        return @()
    }

    $collections = @((ConvertFrom-JsonCompat -InputObject $collectionsJson))
    return @(
        $collections |
            Where-Object {
                [string]::Equals(([string]$_.properties.sourceRegion), $SourceRegion, [System.StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals(([string]$_.properties.targetRegion), $TargetRegion, [System.StringComparison]::OrdinalIgnoreCase) -and
                ([string]$_.name).ToLowerInvariant().StartsWith(([string]$CollectionPrefix).ToLowerInvariant())
            } |
            Select-Object -ExpandProperty name -Unique
    )
}

# Handles Convert-AzVmCliTextToTokens.
function Convert-AzVmCliTextToTokens {
    param(
        [object]$Text
    )

    $parts = @()
    if ($Text -is [System.Array]) {
        foreach ($entry in @($Text)) {
            $parts += [string]$entry
        }
    }
    elseif ($null -ne $Text) {
        $parts += [string]$Text
    }

    $joined = ($parts -join "`n")
    return @(
        [regex]::Split([string]$joined, '\s+') |
            ForEach-Object { [string]$_ } |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
}

# Handles Get-AzVmValidCommandList.
function Get-AzVmValidCommandList {
    return @('create', 'update', 'configure', 'group', 'show', 'do', 'move', 'resize', 'set', 'exec', 'ssh', 'rdp', 'delete', 'help')
}

# Handles Show-AzVmCommandHelpOverview.
function Show-AzVmCommandHelpOverview {
    Write-Host "az-vm quick help"
    Write-Host "Usage: az-vm <command> [--option] [--option=value]"
    Write-Host ""
    Write-Host "Commands (full details: az-vm help <command>):"
    Write-Host "  create  Create a new managed resource group and run VM init/update flow."
    Write-Host "  update  Re-run create-or-update operations on existing resources."
    Write-Host "  configure  Configure precheck/preview flow for a target resource group."
    Write-Host "  group   List/select managed resource groups for active context."
    Write-Host "  show    Print system and configuration dump for resource groups and VMs."
    Write-Host "  do      Apply one VM power action or print current VM state."
    Write-Host "  move    Move an existing VM to another Azure region."
    Write-Host "  resize  Change VM size for an existing VM in-place."
    Write-Host "  set     Apply VM feature flags (hibernation, nested virtualization)."
    Write-Host "  exec    Run one init/update task or open interactive remote shell."
    Write-Host "  ssh     Launch Windows OpenSSH client for a managed VM."
    Write-Host "  rdp     Launch mstsc for a managed Windows VM."
    Write-Host "  delete  Purge selected resources from a resource group."
    Write-Host "  help    Show detailed docs (all commands or one command)."
    Write-Host ""
    Write-Host "Global options:"
    Write-Host "  --auto[=true|false]    Auto mode (create/update/delete only)."
    Write-Host "  --perf[=true|false]    Print timing metrics."
    Write-Host "  --windows / --linux    Force VM platform (create/update/exec/resize)."
    Write-Host "  --help                 Show this overview or command-specific help."
    Write-Host ""
    Write-Host "Step values for create/update:"
    Write-Host "  configure, group, network, vm-deploy, vm-init, vm-update, vm-summary"
    Write-Host ""
    Write-Host "Quick examples:"
    Write-Host "  az-vm --help"
    Write-Host "  az-vm create --auto --windows"
    Write-Host "  az-vm configure"
    Write-Host "  az-vm create --from-step=vm-init --linux"
    Write-Host "  az-vm update --single-step=network --auto"
    Write-Host "  az-vm group --list=examplevm"
    Write-Host "  az-vm group --select=rg-examplevm-ate1-g1"
    Write-Host "  az-vm do --vm-action=status --vm-name=examplevm"
    Write-Host "  az-vm do --vm-action=hibernate --group=rg-examplevm-ate1-g1 --vm-name=examplevm"
    Write-Host "  az-vm move --vm-region=swedencentral --group=rg-examplevm-ate1-g1 --vm-name=examplevm"
    Write-Host "  az-vm resize --vm-size=Standard_B2as_v2 --group=rg-examplevm-ate1-g1 --vm-name=examplevm"
    Write-Host "  az-vm set --hibernation=off --nested-virtualization=off --group=rg-examplevm-ate1-g1 --vm-name=examplevm"
    Write-Host "  az-vm exec --update-task=01 --group=rg-examplevm-ate1-g1 --vm-name=examplevm"
    Write-Host "  az-vm ssh --vm-name=examplevm"
    Write-Host "  az-vm rdp --vm-name=examplevm --user=assistant"
    Write-Host "  az-vm show --group=rg-examplevm-ate1-g1"
    Write-Host "  az-vm delete --target=group --group=rg-examplevm-ate1-g1 --yes"
    Write-Host ""
    Write-Host "Detailed docs:"
    Write-Host "  az-vm help"
    Write-Host "  az-vm help create"
    Write-Host "  az-vm help group"
    Write-Host "  az-vm help move"
}

# Handles Show-AzVmCommandHelpDetailed.
function Show-AzVmCommandHelpDetailed {
    param(
        [string]$Topic
    )

    $validCommands = Get-AzVmValidCommandList
    $topicText = [string]$Topic
    $topicName = $topicText.Trim().ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($topicName)) {
        Write-Host "az-vm detailed help"
        Write-Host "Usage: az-vm <command> [--option] [--option=value]"
        Write-Host ""
        Write-Host "Common options:"
        Write-Host "  --auto[=true|false]      # create/update/delete only"
        Write-Host "  --perf[=true|false]"
        Write-Host "  --windows[=true|false]   # create/update/exec/resize only"
        Write-Host "  --linux[=true|false]     # create/update/exec/resize only"
        Write-Host "  --help"
        Write-Host ""
        Write-Host "Help usage:"
        Write-Host "  az-vm --help                       # quick overview"
        Write-Host "  az-vm help                         # full command catalog"
        Write-Host "  az-vm help create                  # one command details"
        Write-Host ""
        Write-Host "Command reference:"
        Write-Host "  create  : supports --to-step, --from-step, --single-step"
        Write-Host "  update  : supports --to-step, --from-step, --single-step"
        Write-Host "  configure  : configure precheck/preview for selected resource group"
        Write-Host "  group   : list/select active managed resource group"
        Write-Host "  show    : print system and configuration dump for resource groups and VMs"
        Write-Host "  do      : supports --group, --vm-name, --vm-action"
        Write-Host "  move    : supports --group, --vm-name, --vm-region"
        Write-Host "  resize  : supports --group, --vm-name, --vm-size, --windows, --linux"
        Write-Host "  set     : supports --group, --vm-name, --hibernation, --nested-virtualization"
        Write-Host "  exec    : supports --group, --vm-name, --init-task, --update-task"
        Write-Host "  ssh     : supports --group, --vm-name, --user"
        Write-Host "  rdp     : supports --group, --vm-name, --user"
        Write-Host "  delete  : supports --target, --group, --yes"
        Write-Host ""
        Write-Host "Examples:"
        Write-Host "  az-vm create --auto --windows"
        Write-Host "  az-vm configure"
        Write-Host "  az-vm create --single-step=configure --linux"
        Write-Host "  az-vm update --to-step=vm-init --auto"
        Write-Host "  az-vm group --list=examplevm"
        Write-Host "  az-vm group --select=rg-examplevm-ate1-g1"
        Write-Host "  az-vm do --vm-action=status --vm-name=examplevm"
        Write-Host "  az-vm do --vm-action=hibernate --group=rg-examplevm-ate1-g1 --vm-name=examplevm"
        Write-Host "  az-vm move --vm-region=swedencentral --group=rg-examplevm-ate1-g1 --vm-name=examplevm"
        Write-Host "  az-vm resize --vm-size=Standard_B2as_v2 --group=rg-examplevm-ate1-g1 --vm-name=examplevm"
        Write-Host "  az-vm set --hibernation=off --nested-virtualization=off --group=rg-examplevm-ate1-g1 --vm-name=examplevm"
        Write-Host "  az-vm exec --init-task=01 --group=rg-examplevm-ate1-g1 --vm-name=examplevm"
        Write-Host "  az-vm ssh --vm-name=examplevm"
        Write-Host "  az-vm rdp --vm-name=examplevm --user=assistant"
        Write-Host "  az-vm show --group=rg-examplevm-ate1-g1"
        Write-Host "  az-vm delete --target=vm --group=rg-examplevm-ate1-g1 --yes"
        Write-Host ""
        Write-Host "For per-command docs: az-vm help <create|update|configure|group|show|do|move|resize|set|exec|ssh|rdp|delete>"
        return
    }

    if ($validCommands -notcontains $topicName) {
        Throw-FriendlyError `
            -Detail ("Unknown help topic '{0}'." -f $topicText) `
            -Code 2 `
            -Summary "Unknown help topic." `
            -Hint "Use az-vm help or az-vm help <create|update|configure|group|show|do|move|resize|set|exec|ssh|rdp|delete>."
    }

    switch ($topicName) {
        'create' {
            Write-Host "Command: create"
            Write-Host "Description: create a new managed resource group and continue with VM init/update flow."
            Write-Host "Usage:"
            Write-Host "  az-vm create [--auto] [--windows|--linux] [--vm-name=<vm-name>] [--perf]"
            Write-Host "  az-vm create --to-step=<step>"
            Write-Host "  az-vm create --from-step=<step>"
            Write-Host "  az-vm create --single-step=<step>"
            Write-Host "  az-vm create --help"
            Write-Host "Steps: configure, group, network, vm-deploy, vm-init, vm-update, vm-summary"
            Write-Host "Examples:"
            Write-Host "  az-vm create --auto --windows"
            Write-Host "  az-vm create --auto --windows --vm-name=examplevm"
            Write-Host "  az-vm create --single-step=network --linux"
            Write-Host "  az-vm create --from-step=vm-deploy --to-step=vm-summary --perf"
            return
        }
        'update' {
            Write-Host "Command: update"
            Write-Host "Description: re-run create-or-update operations against existing resources."
            Write-Host "Usage:"
            Write-Host "  az-vm update [--auto] [--windows|--linux] [--group=<resource-group>] [--vm-name=<vm-name>] [--perf]"
            Write-Host "  az-vm update --to-step=<step>"
            Write-Host "  az-vm update --from-step=<step>"
            Write-Host "  az-vm update --single-step=<step>"
            Write-Host "  az-vm update --help"
            Write-Host "Steps: configure, group, network, vm-deploy, vm-init, vm-update, vm-summary"
            Write-Host "Examples:"
            Write-Host "  az-vm update --auto --windows"
            Write-Host "  az-vm update --group=rg-examplevm-ate1-g1"
            Write-Host "  az-vm update --auto --group=rg-examplevm-ate1-g1 --vm-name=examplevm"
            Write-Host "  az-vm update --single-step=vm-update --auto --windows"
            Write-Host "  az-vm update --from-step=group --to-step=vm-init --perf"
            return
        }
        'configure' {
            Write-Host "Command: configure"
            Write-Host "Description: run configure precheck/preview for a target managed resource group."
            Write-Host "Usage:"
            Write-Host "  az-vm configure [--group=<resource-group>]"
            Write-Host "  az-vm configure --help"
            Write-Host "Examples:"
            Write-Host "  az-vm configure --group=rg-examplevm-ate1-g1"
            Write-Host "Notes: this command does not create/update/delete Azure resources."
            return
        }
        'group' {
            Write-Host "Command: group"
            Write-Host "Description: list/select managed resource groups and set active group."
            Write-Host "Usage:"
            Write-Host "  az-vm group"
            Write-Host "  az-vm group --list"
            Write-Host "  az-vm group --list=<filter>"
            Write-Host "  az-vm group --select=<resource-group>"
            Write-Host "  az-vm group --select="
            Write-Host "  az-vm group --help"
            Write-Host "Examples:"
            Write-Host "  az-vm group --list=examplevm"
            Write-Host "  az-vm group --select=rg-examplevm-ate1-g1"
            Write-Host "  az-vm group --select="
            return
        }
        'show' {
            Write-Host "Command: show"
            Write-Host "Description: print a full system and configuration dump for app resource groups and VMs."
            Write-Host "Usage:"
            Write-Host "  az-vm show [--perf]"
            Write-Host "  az-vm show --group=<resource-group>"
            Write-Host "  az-vm show --help"
            Write-Host "Examples:"
            Write-Host "  az-vm show"
            Write-Host "  az-vm show --group=rg-examplevm-ate1-g1"
            Write-Host "  az-vm show --perf"
            return
        }
        'do' {
            Write-Host "Command: do"
            Write-Host "Description: apply one VM power action or print the current VM lifecycle state."
            Write-Host "Usage:"
            Write-Host "  az-vm do [--group=<resource-group>] [--vm-name=<vm-name>] [--vm-action=<status|start|restart|stop|deallocate|hibernate>] [--perf]"
            Write-Host "  az-vm do --help"
            Write-Host "Examples:"
            Write-Host "  az-vm do"
            Write-Host "  az-vm do --vm-action=status --vm-name=examplevm"
            Write-Host "  az-vm do --vm-action=start --group=rg-examplevm-ate1-g1 --vm-name=examplevm"
            Write-Host "  az-vm do --vm-action=deallocate --group=rg-examplevm-ate1-g1 --vm-name=examplevm"
            Write-Host "  az-vm do --vm-action=hibernate --group=rg-examplevm-ate1-g1 --vm-name=examplevm"
            Write-Host "Notes: Azure hibernation deallocates the VM; use stop to keep the VM provisioned. If target parameters are omitted, the command selects the managed group, VM, and action interactively."
            return
        }
        'move' {
            Write-Host "Command: move"
            Write-Host "Description: move VM deployment to a target Azure region."
            Write-Host "Usage:"
            Write-Host "  az-vm move --group=<resource-group> --vm-name=<vm-name> --vm-region=<azure-region>"
            Write-Host "  az-vm move --group=<resource-group> --vm-name=<vm-name> --vm-region="
            Write-Host "  az-vm move --help"
            Write-Host "Examples:"
            Write-Host "  az-vm move --group=rg-examplevm-ate1-g1 --vm-name=examplevm --vm-region=swedencentral"
            Write-Host "  az-vm move --group=rg-examplevm-ate1-g1 --vm-name=examplevm --vm-region="
            Write-Host "Notes: region move uses a deallocate -> snapshot-copy -> target-health-check -> old-group-delete flow with rollback safeguards."
            return
        }
        'resize' {
            Write-Host "Command: resize"
            Write-Host "Description: resize VM SKU in the same region."
            Write-Host "Usage:"
            Write-Host "  az-vm resize [--group=<resource-group>] [--vm-name=<vm-name>] [--vm-size=<vm-sku>] [--windows|--linux] [--perf]"
            Write-Host "  az-vm resize [--group=<resource-group>] [--vm-name=<vm-name>] --vm-size="
            Write-Host "  az-vm resize"
            Write-Host "  az-vm resize --help"
            Write-Host "Examples:"
            Write-Host "  az-vm resize --group=rg-examplevm-ate1-g1 --vm-name=examplevm --vm-size=Standard_B2as_v5"
            Write-Host "  az-vm resize --group=rg-examplevm-ate1-g1 --vm-name=examplevm --vm-size=Standard_D4as_v5"
            Write-Host "  az-vm resize --group=rg-examplevm-ate1-g1 --vm-name=examplevm --vm-size=Standard_D4as_v5 --windows"
            Write-Host "  az-vm resize"
            Write-Host "Notes: resize stays in the current region; if values are omitted, the command selects the managed group, VM, and SKU interactively."
            return
        }
        'set' {
            Write-Host "Command: set"
            Write-Host "Description: apply VM feature settings."
            Write-Host "Usage:"
            Write-Host "  az-vm set --group=<resource-group> --vm-name=<vm-name> --hibernation=on|off"
            Write-Host "  az-vm set --group=<resource-group> --vm-name=<vm-name> --nested-virtualization=on|off"
            Write-Host "  az-vm set --group=<resource-group> --vm-name=<vm-name> --hibernation=on|off --nested-virtualization=on|off"
            Write-Host "  az-vm set --help"
            Write-Host "Examples:"
            Write-Host "  az-vm set --group=rg-examplevm-ate1-g1 --vm-name=examplevm --hibernation=off"
            Write-Host "  az-vm set --group=rg-examplevm-ate1-g1 --vm-name=examplevm --nested-virtualization=off"
            return
        }
        'exec' {
            Write-Host "Command: exec"
            Write-Host "Description: execute a single init/update task or open interactive remote shell."
            Write-Host "Usage:"
            Write-Host "  az-vm exec [--group=<resource-group>] [--vm-name=<vm-name>] [--windows|--linux] [--perf]"
            Write-Host "  az-vm exec --init-task=<NN> [--group=<resource-group>] [--vm-name=<vm-name>]"
            Write-Host "  az-vm exec --update-task=<NN> [--group=<resource-group>] [--vm-name=<vm-name>]"
            Write-Host "  az-vm exec --help"
            Write-Host "Examples:"
            Write-Host "  az-vm exec --init-task=01 --group=rg-examplevm-ate1-g1 --vm-name=examplevm"
            Write-Host "  az-vm exec --update-task=15 --group=rg-examplevm-ate1-g1 --vm-name=examplevm --windows"
            Write-Host "  az-vm exec --linux      # opens interactive remote shell session"
            Write-Host "Notes: use --vm-name for direct one-VM task execution without interactive VM selection."
            return
        }
        'ssh' {
            Write-Host "Command: ssh"
            Write-Host "Description: launch Windows OpenSSH client for a managed VM."
            Write-Host "Usage:"
            Write-Host "  az-vm ssh [--group=<resource-group>] [--vm-name=<vm-name>] [--user=manager|assistant] [--perf]"
            Write-Host "  az-vm ssh --help"
            Write-Host "Examples:"
            Write-Host "  az-vm ssh --vm-name=examplevm"
            Write-Host "  az-vm ssh --group=rg-examplevm-ate1-g1 --vm-name=examplevm --user=assistant"
            Write-Host "Notes: the VM must already be running; password entry is handled in the external SSH console window."
            return
        }
        'rdp' {
            Write-Host "Command: rdp"
            Write-Host "Description: launch mstsc for a managed Windows VM."
            Write-Host "Usage:"
            Write-Host "  az-vm rdp [--group=<resource-group>] [--vm-name=<vm-name>] [--user=manager|assistant] [--perf]"
            Write-Host "  az-vm rdp --help"
            Write-Host "Examples:"
            Write-Host "  az-vm rdp --vm-name=examplevm"
            Write-Host "  az-vm rdp --group=rg-examplevm-ate1-g1 --vm-name=examplevm --user=assistant"
            Write-Host "Notes: the VM must already be running; credentials are staged with cmdkey before mstsc is launched."
            return
        }
        'delete' {
            Write-Host "Command: delete"
            Write-Host "Description: purge selected resources from a resource group."
            Write-Host "Usage:"
            Write-Host "  az-vm delete --target=<group|network|vm|disk> [--group=<resource-group>] [--yes]"
            Write-Host "  az-vm delete --help"
            Write-Host "Examples:"
            Write-Host "  az-vm delete --target=group --group=rg-examplevm-ate1-g1 --yes"
            Write-Host "  az-vm delete --target=vm --group=rg-examplevm-ate1-g1 --yes"
            Write-Host "  az-vm delete --target=network --group=rg-examplevm-ate1-g1 --yes"
            return
        }
        'help' {
            Write-Host "Command: help"
            Write-Host "Description: print detailed help pages."
            Write-Host "Usage:"
            Write-Host "  az-vm help"
            Write-Host "  az-vm help <command>"
            Write-Host "  az-vm --help"
            Write-Host "Examples:"
            Write-Host "  az-vm help create"
            Write-Host "  az-vm help configure"
            Write-Host "  az-vm help do"
            Write-Host "  az-vm help ssh"
            Write-Host "  az-vm --help"
            return
        }
    }
}

# Handles Show-AzVmCommandHelp.
function Show-AzVmCommandHelp {
    param(
        [switch]$Overview,
        [string]$Topic
    )

    if ($Overview) {
        Show-AzVmCommandHelpOverview
        return
    }

    Show-AzVmCommandHelpDetailed -Topic $Topic
}

# Handles Parse-AzVmCliArguments.
function Parse-AzVmCliArguments {
    param(
        [string]$CommandToken,
        [string[]]$RawArgs
    )

    $rawCommand = if ($null -eq $CommandToken) { '' } else { [string]$CommandToken }
    $remaining = @()
    if (-not [string]::IsNullOrWhiteSpace($rawCommand) -and $rawCommand.StartsWith('-')) {
        $remaining += $rawCommand
        $rawCommand = ''
    }
    $remaining += @($RawArgs)

    $validCommands = Get-AzVmValidCommandList

    $normalizedArgs = @()
    for ($i = 0; $i -lt @($remaining).Count; $i++) {
        $rawArgText = if ($null -eq $remaining[$i]) { '' } else { [string]$remaining[$i] }
        if ([string]::IsNullOrWhiteSpace($rawArgText)) {
            continue
        }

        if (-not $rawArgText.StartsWith('-') -or $rawArgText.StartsWith('--')) {
            $normalizedArgs += $rawArgText
            continue
        }

        if ($rawArgText -match '^-g=(.+)$') {
            $normalizedArgs += ("--group={0}" -f [string]$Matches[1])
            continue
        }
        if ($rawArgText -eq '-g') {
            if (($i + 1) -ge @($remaining).Count) {
                Throw-FriendlyError `
                    -Detail "Option '-g' requires a value." `
                    -Code 2 `
                    -Summary "Invalid option format." `
                    -Hint "Use '-g <resource-group>' or '--group=<resource-group>'."
            }

            $nextArgText = if ($null -eq $remaining[$i + 1]) { '' } else { [string]$remaining[$i + 1] }
            if ([string]::IsNullOrWhiteSpace([string]$nextArgText) -or $nextArgText.StartsWith('-')) {
                Throw-FriendlyError `
                    -Detail "Option '-g' requires a value." `
                    -Code 2 `
                    -Summary "Invalid option format." `
                    -Hint "Use '-g <resource-group>' or '--group=<resource-group>'."
            }

            $normalizedArgs += ("--group={0}" -f $nextArgText)
            $i++
            continue
        }

        if ($rawArgText -eq '-y') {
            $normalizedArgs += "--yes=true"
            continue
        }

        if ($rawArgText -eq '-a') {
            $normalizedArgs += "--auto=true"
            continue
        }

        Throw-FriendlyError `
            -Detail ("Unsupported short option format '{0}'." -f $rawArgText) `
            -Code 2 `
            -Summary "Invalid option format." `
            -Hint "Supported short options: -g, -y, -a. Use long options for others."
    }

    $options = @{}
    $positionals = @()
    foreach ($arg in @($normalizedArgs)) {
        $text = if ($null -eq $arg) { '' } else { [string]$arg }
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        if ($text.StartsWith('--')) {
            $body = $text.Substring(2)
            if ([string]::IsNullOrWhiteSpace($body)) {
                continue
            }

            $name = $body
            $value = $true
            $eqIndex = $body.IndexOf('=')
            if ($eqIndex -ge 0) {
                $name = $body.Substring(0, $eqIndex)
                $value = $body.Substring($eqIndex + 1)
            }

            $nameKey = [string]$name
            $nameKey = $nameKey.Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($nameKey)) {
                continue
            }

            $options[$nameKey] = $value
            continue
        }

        $positionals += $text
    }

    $command = ''
    if (-not [string]::IsNullOrWhiteSpace($rawCommand)) {
        $command = $rawCommand.Trim().ToLowerInvariant()
        if ($validCommands -notcontains $command) {
            Throw-FriendlyError `
                -Detail ("Unknown command '{0}'." -f $rawCommand) `
                -Code 2 `
                -Summary "Unknown command." `
                -Hint "Use one command: create | update | configure | group | show | do | move | resize | set | exec | ssh | rdp | delete | help."
        }
    }
    elseif ($options.ContainsKey('help')) {
        $command = 'help'
    }
    else {
        Throw-FriendlyError `
            -Detail "No command was provided." `
            -Code 2 `
            -Summary "Command is required." `
            -Hint "Use one command: create | update | configure | group | show | do | move | resize | set | exec | ssh | rdp | delete | help. Example: az-vm create --auto"
    }

    $helpTopic = ''
    if ($command -eq 'help') {
        if ($positionals.Count -gt 1) {
            Throw-FriendlyError `
                -Detail ("Too many help topics were provided: {0}" -f ($positionals -join ', ')) `
                -Code 2 `
                -Summary "Too many help topic arguments were provided." `
                -Hint "Use only one help topic. Example: az-vm help create"
        }

        $positionalTopic = ''
        if ($positionals.Count -eq 1) {
            $positionalTopic = [string]$positionals[0]
            $positionalTopic = $positionalTopic.Trim().ToLowerInvariant()
        }

        if (-not [string]::IsNullOrWhiteSpace($positionalTopic)) {
            $helpTopic = $positionalTopic
        }
    }
    else {
        if ($positionals.Count -gt 0) {
            Throw-FriendlyError `
                -Detail ("Unexpected positional argument(s): {0}" -f ($positionals -join ', ')) `
                -Code 2 `
                -Summary "Unexpected arguments were provided." `
                -Hint "Use only --option or --option=value syntax after the command."
        }
    }

    return [pscustomobject]@{
        Command = $command
        Options = $options
        HelpTopic = $helpTopic
    }
}

# Handles Get-AzVmCliOptionRaw.
function Get-AzVmCliOptionRaw {
    param(
        [hashtable]$Options,
        [string]$Name
    )

    if ($null -eq $Options) {
        return $null
    }

    $key = [string]$Name
    if ([string]::IsNullOrWhiteSpace($key)) {
        return $null
    }

    $key = $key.Trim().ToLowerInvariant()
    if ($Options.ContainsKey($key)) {
        return $Options[$key]
    }

    return $null
}

# Handles Test-AzVmCliOptionPresent.
function Test-AzVmCliOptionPresent {
    param(
        [hashtable]$Options,
        [string]$Name
    )

    if ($null -eq $Options) {
        return $false
    }

    $key = [string]$Name
    if ([string]::IsNullOrWhiteSpace($key)) {
        return $false
    }

    return $Options.ContainsKey($key.Trim().ToLowerInvariant())
}

# Handles Convert-AzVmCliValueToBool.
function Convert-AzVmCliValueToBool {
    param(
        [string]$OptionName,
        [object]$RawValue
    )

    if ($RawValue -is [bool]) {
        return [bool]$RawValue
    }

    $text = [string]$RawValue
    $trimmed = $text.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $true
    }
    if ($trimmed -in @('1','true','yes','y','on')) {
        return $true
    }
    if ($trimmed -in @('0','false','no','n','off')) {
        return $false
    }

    Throw-FriendlyError `
        -Detail ("Option '--{0}' received invalid boolean value '{1}'." -f $OptionName, $text) `
        -Code 2 `
        -Summary "Invalid boolean option value." `
        -Hint ("Use '--{0}' or '--{0}=true|false'." -f $OptionName)
}

# Handles Get-AzVmCliOptionBool.
function Get-AzVmCliOptionBool {
    param(
        [hashtable]$Options,
        [string]$Name,
        [bool]$DefaultValue = $false
    )

    if (-not (Test-AzVmCliOptionPresent -Options $Options -Name $Name)) {
        return [bool]$DefaultValue
    }

    $raw = Get-AzVmCliOptionRaw -Options $Options -Name $Name
    return (Convert-AzVmCliValueToBool -OptionName $Name -RawValue $raw)
}

# Handles Get-AzVmCliOptionText.
function Get-AzVmCliOptionText {
    param(
        [hashtable]$Options,
        [string]$Name
    )

    if (-not (Test-AzVmCliOptionPresent -Options $Options -Name $Name)) {
        return $null
    }

    $raw = Get-AzVmCliOptionRaw -Options $Options -Name $Name
    if ($raw -is [bool]) {
        if ([bool]$raw) {
            return ''
        }

        return $null
    }

    return [string]$raw
}

# Handles Get-AzVmActionOrder.
function Get-AzVmActionOrder {
    return @('configure', 'group', 'network', 'vm-deploy', 'vm-init', 'vm-update', 'vm-summary')
}

# Handles Resolve-AzVmActionValue.
function Resolve-AzVmActionValue {
    param(
        [string]$OptionName,
        [string]$RawValue
    )

    $text = if ($null -eq $RawValue) { '' } else { [string]$RawValue }
    $normalized = $text.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        Throw-FriendlyError `
            -Detail ("Option '--{0}' requires a value." -f $OptionName) `
            -Code 2 `
            -Summary "Step option value is missing." `
            -Hint ("Use '--{0}=configure|group|network|vm-deploy|vm-init|vm-update|vm-summary'." -f $OptionName)
    }

    $allowed = Get-AzVmActionOrder
    if ($allowed -notcontains $normalized) {
        Throw-FriendlyError `
            -Detail ("Option '--{0}' received invalid value '{1}'." -f $OptionName, $RawValue) `
            -Code 2 `
            -Summary "Invalid step option value." `
            -Hint ("Valid values: {0}" -f ($allowed -join ', '))
    }

    return $normalized
}

# Handles Resolve-AzVmActionPlan.
function Resolve-AzVmActionPlan {
    param(
        [string]$CommandName,
        [hashtable]$Options
    )

    $order = Get-AzVmActionOrder
    $supportsActionOptions = ($CommandName -in @('create', 'update'))
    $hasFrom = Test-AzVmCliOptionPresent -Options $Options -Name 'from-step'
    $hasTo = Test-AzVmCliOptionPresent -Options $Options -Name 'to-step'
    $hasSingle = Test-AzVmCliOptionPresent -Options $Options -Name 'single-step'

    if (-not $supportsActionOptions -and ($hasFrom -or $hasTo -or $hasSingle)) {
        Throw-FriendlyError `
            -Detail ("Step options are not supported for command '{0}'." -f $CommandName) `
            -Code 2 `
            -Summary "Unsupported command option." `
            -Hint "Use --from-step/--to-step/--single-step only with create or update."
    }

    if ($hasSingle -and ($hasFrom -or $hasTo)) {
        Throw-FriendlyError `
            -Detail "Option '--single-step' cannot be combined with '--from-step' or '--to-step'." `
            -Code 2 `
            -Summary "Conflicting step options were provided." `
            -Hint "Use --single-step alone, or use --from-step/--to-step as a range."
    }

    if (-not $hasFrom -and -not $hasTo -and -not $hasSingle) {
        return [pscustomobject]@{
            Mode = 'full'
            Target = 'vm-summary'
            Actions = @($order)
        }
    }

    if ($hasSingle) {
        $singleTarget = Resolve-AzVmActionValue -OptionName 'single-step' -RawValue ([string](Get-AzVmCliOptionText -Options $Options -Name 'single-step'))
        return [pscustomobject]@{
            Mode = 'single'
            Target = $singleTarget
            Actions = @($singleTarget)
        }
    }

    $fromStep = if ($hasFrom) {
        Resolve-AzVmActionValue -OptionName 'from-step' -RawValue ([string](Get-AzVmCliOptionText -Options $Options -Name 'from-step'))
    }
    else {
        [string]$order[0]
    }
    $toStep = if ($hasTo) {
        Resolve-AzVmActionValue -OptionName 'to-step' -RawValue ([string](Get-AzVmCliOptionText -Options $Options -Name 'to-step'))
    }
    else {
        [string]$order[$order.Count - 1]
    }

    $fromIndex = [array]::IndexOf($order, $fromStep)
    $toIndex = [array]::IndexOf($order, $toStep)
    if ($fromIndex -lt 0 -or $toIndex -lt 0) {
        throw ("Step range '{0}' -> '{1}' could not be mapped." -f $fromStep, $toStep)
    }
    if ($fromIndex -gt $toIndex) {
        Throw-FriendlyError `
            -Detail ("Option '--from-step={0}' is after '--to-step={1}'." -f $fromStep, $toStep) `
            -Code 2 `
            -Summary "Invalid step range." `
            -Hint "Provide a forward step range where from-step is before or equal to to-step."
    }

    $actions = @()
    for ($i = $fromIndex; $i -le $toIndex; $i++) {
        $actions += [string]$order[$i]
    }

    return [pscustomobject]@{
        Mode = 'range'
        Target = $toStep
        Start = $fromStep
        Actions = @($actions)
    }
}

# Handles Test-AzVmActionIncluded.
function Test-AzVmActionIncluded {
    param(
        [psobject]$ActionPlan,
        [string]$ActionName
    )

    if ($null -eq $ActionPlan) {
        return $false
    }

    $name = if ($null -eq $ActionName) { '' } else { [string]$ActionName.Trim().ToLowerInvariant() }
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $false
    }

    return (@($ActionPlan.Actions) -contains $name)
}

# Handles ConvertFrom-JsonCompat.
function ConvertFrom-JsonCompat {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [string]) {
        $text = [string]$InputObject
        if ([string]::IsNullOrWhiteSpace($text)) {
            return $null
        }
        return ($text | ConvertFrom-Json)
    }

    if ($InputObject -is [System.Array]) {
        if ($InputObject.Length -eq 0) {
            return @()
        }

        $first = $InputObject[0]
        if ($first -is [string]) {
            $joined = (($InputObject | ForEach-Object { [string]$_ }) -join "`n")
            if ([string]::IsNullOrWhiteSpace($joined)) {
                return $null
            }
            return ($joined | ConvertFrom-Json)
        }

        return $InputObject
    }

    $asText = [string]$InputObject
    $trimmed = $asText.TrimStart()
    if ($trimmed.StartsWith("{") -or $trimmed.StartsWith("[")) {
        return ($asText | ConvertFrom-Json)
    }

    return $InputObject
}

# Handles ConvertFrom-JsonArrayCompat.
function ConvertFrom-JsonArrayCompat {
    param(
        [Parameter(Mandatory = $true)]
        [object]$InputObject
    )

    $parsed = ConvertFrom-JsonCompat -InputObject $InputObject
    $result = @()
    if ($null -eq $parsed) {
        $result = @()
    }
    elseif ($parsed -is [System.Array]) {
        $result = @($parsed)
    }
    else {
        $result = @($parsed)
    }

    return $result
}

# Handles ConvertTo-ObjectArrayCompat.
function ConvertTo-ObjectArrayCompat {
    param(
        [Parameter(Mandatory = $false)]
        [object]$InputObject
    )

    $result = @()

    if ($null -eq $InputObject) {
        $result = @()
    }
    elseif ($InputObject -is [System.Array]) {
        $result = @($InputObject)
    }
    elseif ($InputObject -is [string] -or $InputObject -is [char]) {
        $result = @([string]$InputObject)
    }
    elseif ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $result = @($InputObject)
    }
    else {
        $result = @($InputObject)
    }

    return $result
}

# Handles Write-TextFileNormalized.
function Write-TextFileNormalized {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [AllowNull()]
        [string]$Content,
        [ValidateSet("utf8NoBom", "ascii")]
        [string]$Encoding = "utf8NoBom",
        [ValidateSet("lf", "crlf", "preserve")]
        [string]$LineEnding = "preserve",
        [switch]$EnsureTrailingNewline
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "Write-TextFileNormalized requires a valid file path."
    }

    $parent = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if ($null -eq $Content) {
        $Content = ""
    }
    $text = [string]$Content

    switch ($LineEnding) {
        "lf" {
            $text = $text -replace "`r`n", "`n"
            $text = $text -replace "`r", "`n"
        }
        "crlf" {
            $text = $text -replace "`r`n", "`n"
            $text = $text -replace "`r", "`n"
            $text = $text -replace "`n", "`r`n"
        }
    }

    if ($EnsureTrailingNewline) {
        $targetEnding = if ($LineEnding -eq "crlf") { "`r`n" } else { "`n" }
        if (-not $text.EndsWith($targetEnding)) {
            $text += $targetEnding
        }
    }

    $encodingObject = switch ($Encoding) {
        "utf8NoBom" { New-Object System.Text.UTF8Encoding($false) }
        "ascii" { [System.Text.Encoding]::ASCII }
        default { New-Object System.Text.UTF8Encoding($false) }
    }

    [System.IO.File]::WriteAllText($Path, $text, $encodingObject)
}
