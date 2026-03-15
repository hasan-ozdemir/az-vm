# Shared CLI help helpers.

function Get-AzVmValidCommandList {
    return @('configure', 'create', 'update', 'list', 'show', 'do', 'task', 'connect', 'move', 'resize', 'set', 'exec', 'delete', 'help')
}

function Write-AzVmHelpLines {
    param([string[]]$Lines)

    foreach ($line in @($Lines)) {
        Write-Host $line
    }
}

function Show-AzVmCommandHelp {
    param(
        [string]$Topic = '',
        [switch]$Overview
    )

    if ($Overview) {
        Show-AzVmCommandHelpOverview
        return
    }

    Show-AzVmCommandHelpDetailed -Topic $Topic
}

function Show-AzVmCommandHelpOverview {
    Write-AzVmHelpLines @(
        'az-vm quick help'
        'Usage: az-vm <command> [--option value] [--option=value]'
        ''
        'Commands (full details: az-vm help <command>):'
        '  configure  Select one managed VM target and sync target-derived values into .env.'
        '  create     Create one fresh managed resource group and one fresh managed VM.'
        '  update     Update one existing managed VM in one existing managed resource group.'
        '  list       List managed resource groups and managed Azure resources by type.'
        '  show       Print system and configuration dump for resource groups and VMs.'
        '  do         Apply one VM lifecycle action or print current VM state.'
        '  task       List tasks, run one task, or save/restore one task app-state payload.'
        '  connect    Launch SSH or RDP client/test for a managed VM.'
        '  move       Move an existing VM to another Azure region.'
        '  resize     Change VM size or expand the managed OS disk for an existing VM.'
        '  set        Apply hibernation and sync nested virtualization desired state.'
        '  exec       Open an interactive SSH shell or run one remote command.'
        '  delete     Purge selected resources from a resource group.'
        '  help       Show detailed docs (all commands or one command).'
        ''
        'Global options:'
        '  --auto[=true|false]         Auto mode (create/update/delete only).'
        '  --perf[=true|false]         Print timing metrics.'
        '  --windows / --linux         Force VM platform where supported.'
        '  -g, --group                 Target resource group where required.'
        '  -v, --vm-name               Target VM name where required.'
        '  -s, --subscription-id       Target Azure subscription for Azure-touching commands.'
        '  -c, --command               Remote one-shot command text for exec.'
        '  -h, --help                  Show this overview or command-specific help.'
        "  Azure CLI sign-in via 'az login' is required for Azure-touching commands."
        ''
        'Quick examples:'
        '  az-vm create --auto --windows --vm-name <vm-name> --vm-region <azure-region> --vm-size <vm-sku>'
        '  az-vm update --auto --windows --group <resource-group> --vm-name <vm-name>'
        '  az-vm task --list --vm-update'
        '  az-vm task --run-vm-init 01 --group <resource-group> --vm-name <vm-name>'
        '  az-vm task --run-vm-update 10002 --group <resource-group> --vm-name <vm-name>'
        '  az-vm task --save-app-state --vm-update-task=115 --group <resource-group> --vm-name <vm-name>'
        '  az-vm task --restore-app-state --vm-update-task=115 --group <resource-group> --vm-name <vm-name>'
        '  az-vm exec --command "Get-Date" --group <resource-group> --vm-name <vm-name>'
        '  az-vm exec --group <resource-group> --vm-name <vm-name>'
        '  az-vm connect --ssh --vm-name <vm-name> --test'
        '  az-vm connect --rdp --vm-name <vm-name> --user assistant'
        '  az-vm do --vm-action=reapply --group <resource-group> --vm-name <vm-name>'
        '  az-vm delete --target group --group <resource-group> --yes'
    )
}

function Show-AzVmCommandHelpDetailed {
    param([string]$Topic)

    $validCommands = Get-AzVmValidCommandList
    $topicText = [string]$Topic
    $topicName = $topicText.Trim().ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($topicName)) {
        Write-AzVmHelpLines @(
            'az-vm detailed help'
            'Usage: az-vm <command> [--option value] [--option=value]'
            ''
            'Common options:'
            '  --auto[=true|false]      # create/update/delete only'
            '  --perf[=true|false]'
            '  --windows[=true|false]   # create/update/task/resize'
            '  --linux[=true|false]     # create/update/task/resize'
            '  -g, --group'
            '  -v, --vm-name'
            '  -s, --subscription-id'
            '  -c, --command'
            '  -h, --help'
            "  Azure CLI sign-in via 'az login' is required for Azure-touching commands."
            ''
            'Command reference:'
            '  configure  : read-only managed target selection and .env synchronization'
            '  create     : fresh-only managed deployment flow'
            '  update     : existing-managed-target maintenance flow'
            '  list       : managed inventory output'
            '  show       : system and configuration dump'
            '  do         : lifecycle and repair actions'
            '  task       : task list, isolated task runs, task app-state save/restore'
            '  connect    : connect --ssh / connect --rdp plus --test'
            '  move       : managed region move'
            '  resize     : VM-size or disk expand guidance'
            '  set        : hibernation and nested virtualization intent'
            '  exec       : remote command or interactive shell only'
            '  delete     : resource deletion by target scope'
            ''
            'For per-command docs: az-vm help <configure|create|update|list|show|do|task|connect|move|resize|set|exec|delete>'
        )
        return
    }

    if ($validCommands -notcontains $topicName) {
        Throw-FriendlyError `
            -Detail ("Unknown help topic '{0}'." -f $topicText) `
            -Code 2 `
            -Summary 'Unknown help topic.' `
            -Hint 'Use az-vm help or az-vm help <configure|create|update|list|show|do|task|connect|move|resize|set|exec|delete>.'
    }

    switch ($topicName) {
        'configure' {
            Write-AzVmHelpLines @(
                'Command: configure'
                'Description: select one existing managed VM target, read actual Azure state, and sync target-derived values into .env.'
                'Usage:'
                '  az-vm configure [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--windows|--linux] [--perf]'
                'Examples:'
                '  az-vm configure'
                '  az-vm configure --group <resource-group> --vm-name <vm-name> -s <subscription-guid>'
                'Notes: configure is Azure-read-only. It selects only az-vm-managed resource groups and existing VMs, validates --windows/--linux against the actual VM OS type, writes only target-derived .env values, and clears stale opposite-platform keys.'
            )
            return
        }
        'create' {
            Write-AzVmHelpLines @(
                'Command: create'
                'Description: create one fresh managed resource group, one fresh managed VM, and then continue with vm-init/vm-update flow.'
                'Usage:'
                '  az-vm create [--windows|--linux] [--subscription-id <subscription-id>] [--perf]'
                '  az-vm create --auto --windows --vm-name <vm-name> --vm-region <azure-region> --vm-size <vm-sku> [--subscription-id <subscription-id>] [--perf]'
                '  az-vm create --auto --linux --vm-name <vm-name> --vm-region <azure-region> --vm-size <vm-sku> [--subscription-id <subscription-id>] [--perf]'
                '  az-vm create --step <step> [--subscription-id <subscription-id>]'
                '  az-vm create --step-from <step> [--subscription-id <subscription-id>]'
                '  az-vm create --step-to <step> [--subscription-id <subscription-id>]'
                'Steps: configure, group, network, vm-deploy, vm-init, vm-update, vm-summary'
                'Examples:'
                '  az-vm create --auto --windows --vm-name <vm-name> --vm-region <azure-region> --vm-size <vm-sku> -s <subscription-guid>'
                '  az-vm create --step vm-update --linux'
                'Notes: create always targets a fresh managed resource group and fresh managed resources. Interactive mode prompts for Azure subscription when --subscription-id is omitted, asks for VM OS type first when --windows/--linux is omitted, proposes the next global gX name plus globally unique nX resource ids, and asks yes/no/cancel review checkpoints only for group, vm-deploy, vm-init, and vm-update. Auto mode requires an explicit platform plus --vm-name, --vm-region, and --vm-size. vm-summary always renders, even for partial step windows. For a destructive rebuild, run delete first and then create again.'
            )
            return
        }
        'update' {
            Write-AzVmHelpLines @(
                'Command: update'
                'Description: re-run create-or-update operations against one existing managed VM in one existing managed resource group.'
                'Usage:'
                '  az-vm update [--windows|--linux] [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--perf]'
                '  az-vm update --auto --windows --group <resource-group> --vm-name <vm-name> [--subscription-id <subscription-id>] [--perf]'
                '  az-vm update --auto --linux --group <resource-group> --vm-name <vm-name> [--subscription-id <subscription-id>] [--perf]'
                '  az-vm update --step <step> [--subscription-id <subscription-id>]'
                '  az-vm update --step-from <step> [--subscription-id <subscription-id>]'
                '  az-vm update --step-to <step> [--subscription-id <subscription-id>]'
                'Steps: configure, group, network, vm-deploy, vm-init, vm-update, vm-summary'
                'Examples:'
                '  az-vm update --group <resource-group>'
                '  az-vm update --auto --windows --group <resource-group> --vm-name <vm-name> -s <subscription-guid>'
                'Notes: update requires an existing managed resource group and an existing managed VM. Interactive mode prompts for Azure subscription when --subscription-id is omitted, selects only managed existing targets, and asks yes/no/cancel review checkpoints only for group, vm-deploy, vm-init, and vm-update. Auto mode requires an explicit platform plus --group and --vm-name. Existing VMs are redeployed after Azure create-or-update.'
            )
            return
        }
        'list' {
            Write-AzVmHelpLines @(
                'Command: list'
                'Description: print read-only managed inventory sections for az-vm-tagged resource groups and resources.'
                'Usage:'
                '  az-vm list [--type <group,vm,disk,vnet,subnet,nic,ip,nsg,nsg-rule>] [--group <resource-group>] [--subscription-id <subscription-id>] [--perf]'
                'Examples:'
                '  az-vm list'
                '  az-vm list --type group,vm -s <subscription-guid>'
                '  az-vm list --type nsg,nsg-rule --group <resource-group>'
                'Notes: list is Azure-read-only, supports --type and --group for managed inventory output, and keeps a deterministic managed-section order. --type uses comma-separated values. --group is an exact managed resource-group filter. Without --type, list prints all supported managed inventory sections in deterministic order.'
            )
            return
        }
        'show' {
            Write-AzVmHelpLines @(
                'Command: show'
                'Description: print a full system and configuration dump for app resource groups and VMs.'
                'Usage:'
                '  az-vm show [--subscription-id <subscription-id>] [--perf]'
                '  az-vm show --group <resource-group> [--subscription-id <subscription-id>]'
                'Examples:'
                '  az-vm show'
                '  az-vm show --group <resource-group> -s <subscription-guid>'
                'Notes: password-bearing .env values are redacted in the rendered report. When the VM is running, nested virtualization is shown from guest validation evidence.'
            )
            return
        }
        'do' {
            Write-AzVmHelpLines @(
                'Command: do'
                'Description: apply one VM lifecycle action or print the current VM lifecycle state.'
                'Usage:'
                '  az-vm do [--group <resource-group>] [--vm-name <vm-name>] [--vm-action=<status|start|restart|stop|deallocate|hibernate-deallocate|hibernate-stop|reapply>] [--subscription-id <subscription-id>] [--perf]'
                'Examples:'
                '  az-vm do --vm-action=status --vm-name <vm-name>'
                '  az-vm do --vm-action=reapply --group <resource-group> --vm-name <vm-name>'
                '  az-vm do --vm-action=hibernate-stop --group <resource-group> --vm-name <vm-name>'
                '  az-vm do --vm-action=hibernate-deallocate --group <resource-group> --vm-name <vm-name>'
                "Notes: hibernate-stop uses SSH to run 'shutdown /h /f' inside a running VM and waits until the guest is no longer running without Azure deallocation. hibernate-deallocate uses Azure's deallocation-based hibernate path. Reapply calls 'az vm reapply' and then prints refreshed VM status; unlike the power actions, it remains available when provisioning is not currently succeeded."
            )
            return
        }
        'task' {
            Write-AzVmHelpLines @(
                'Command: task'
                'Description: list discovered init/update tasks, run one task in isolation, or save/restore one task-owned app-state payload against a live VM.'
                'Usage:'
                '  az-vm task --list [--vm-init] [--vm-update] [--disabled] [--windows|--linux] [--perf]'
                '  az-vm task --run-vm-init <task-number|task-name> [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--windows|--linux] [--perf]'
                '  az-vm task --run-vm-update <task-number|task-name> [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--windows|--linux] [--perf]'
                '  az-vm task --save-app-state --vm-init-task <task-number|task-name> [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--windows|--linux] [--perf]'
                '  az-vm task --save-app-state --vm-update-task <task-number|task-name> [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--windows|--linux] [--perf]'
                '  az-vm task --restore-app-state --vm-init-task <task-number|task-name> [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--windows|--linux] [--perf]'
                '  az-vm task --restore-app-state --vm-update-task <task-number|task-name> [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--windows|--linux] [--perf]'
                'Examples:'
                '  az-vm task --list --vm-update'
                '  az-vm task --run-vm-init 01 --group <resource-group> --vm-name <vm-name>'
                '  az-vm task --run-vm-update 10002 --group <resource-group> --vm-name <vm-name>'
                '  az-vm task --save-app-state --vm-update-task=115 --group <resource-group> --vm-name <vm-name> -s <subscription-guid>'
                '  az-vm task --restore-app-state --vm-update-task=115 --group <resource-group> --vm-name <vm-name>'
                'Notes: --list is local-only and scans tracked plus local task trees with the same discovery rules used by init/update execution. --run-vm-init uses Azure run-command. --run-vm-update uses the SSH task runner. --save-app-state and --restore-app-state read or deploy only `.../<stage>/app-states/<task-name>/app-state.zip`. Save overwrites the zip in place and cleanly skips when no capture coverage exists. Restore fails cleanly when the requested zip is missing or invalid.'
            )
            return
        }
        'connect' {
            Write-AzVmHelpLines @(
                'Command: connect'
                'Description: launch Windows OpenSSH client or mstsc for a managed VM, or run connection tests without launching the client.'
                'Usage:'
                '  az-vm connect --ssh [--group <resource-group>] [--vm-name <vm-name>] [--user <manager|assistant>] [--test] [--subscription-id <subscription-id>] [--perf]'
                '  az-vm connect --rdp [--group <resource-group>] [--vm-name <vm-name>] [--user <manager|assistant>] [--test] [--subscription-id <subscription-id>] [--perf]'
                'Examples:'
                '  az-vm connect --ssh --vm-name <vm-name> -s <subscription-guid>'
                '  az-vm connect --ssh --group <resource-group> --vm-name <vm-name> --user assistant'
                '  az-vm connect --ssh --group <resource-group> --vm-name <vm-name> --user manager --test'
                '  az-vm connect --rdp --vm-name <vm-name> --user assistant'
                '  az-vm connect --rdp --group <resource-group> --vm-name <vm-name> --user manager --test'
                'Notes: the VM must already be running. connect --ssh uses Windows OpenSSH. connect --rdp uses cmdkey plus mstsc and is only available for Windows VMs. --test performs a non-interactive reachability/authentication check instead of launching the external client.'
            )
            return
        }
        'move' {
            Write-AzVmHelpLines @(
                'Command: move'
                'Description: move VM deployment to a target Azure region.'
                'Usage:'
                '  az-vm move --group <resource-group> --vm-name <vm-name> --vm-region <azure-region> [--subscription-id <subscription-id>]'
                'Examples:'
                '  az-vm move --group <resource-group> --vm-name <vm-name> --vm-region swedencentral -s <subscription-guid>'
                'Notes: region move uses a deallocate -> snapshot-copy -> target rebuild -> target health-check -> old-group-delete flow with rollback safeguards.'
            )
            return
        }
        'resize' {
            Write-AzVmHelpLines @(
                'Command: resize'
                'Description: resize VM SKU or expand the managed OS disk in the same region.'
                'Usage:'
                '  az-vm resize [--group <resource-group>] [--vm-name <vm-name>] [--vm-size <vm-sku>] [--subscription-id <subscription-id>] [--windows|--linux] [--perf]'
                '  az-vm resize [--group <resource-group>] [--vm-name <vm-name>] --disk-size <number>gb|mb --expand [--subscription-id <subscription-id>] [--windows|--linux] [--perf]'
                '  az-vm resize [--group <resource-group>] [--vm-name <vm-name>] --disk-size <number>gb|mb --shrink [--subscription-id <subscription-id>] [--windows|--linux] [--perf]'
                'Examples:'
                '  az-vm resize --group <resource-group> --vm-name <vm-name> --vm-size Standard_D4as_v5'
                '  az-vm resize --group <resource-group> --vm-name <vm-name> --disk-size 196gb --expand'
                '  az-vm resize --group <resource-group> --vm-name <vm-name> --disk-size 64gb --shrink'
                "Notes: resize stays in the current region. --vm-size changes the VM SKU. --disk-size requires exactly one intent flag: --expand or --shrink. --disk-size with --expand performs a supported managed OS disk growth. --disk-size with --shrink is a non-mutating guidance path that explains Azure's OS disk shrink limits and lists supported alternatives."
            )
            return
        }
        'set' {
            Write-AzVmHelpLines @(
                'Command: set'
                'Description: apply hibernation changes and sync nested virtualization desired-state values back to .env.'
                'Usage:'
                '  az-vm set --group <resource-group> --vm-name <vm-name> --hibernation on|off [--subscription-id <subscription-id>]'
                '  az-vm set --group <resource-group> --vm-name <vm-name> --nested-virtualization on|off [--subscription-id <subscription-id>]'
                '  az-vm set --group <resource-group> --vm-name <vm-name> --hibernation on|off --nested-virtualization on|off [--subscription-id <subscription-id>]'
                'Examples:'
                '  az-vm set --group <resource-group> --vm-name <vm-name> --hibernation off'
                '  az-vm set --group <resource-group> --vm-name <vm-name> --nested-virtualization off'
                'Notes: hibernation is changed through Azure. Nested virtualization is governed by VM size and security type, so --nested-virtualization on validates guest readiness on a running VM and --nested-virtualization off only updates repo desired state.'
            )
            return
        }
        'exec' {
            Write-AzVmHelpLines @(
                'Command: exec'
                'Description: open an interactive SSH shell on the target VM, or run one remote command over SSH.'
                'Usage:'
                '  az-vm exec [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--perf]'
                '  az-vm exec --command "<remote-command>" [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--perf]'
                '  az-vm exec -c "<remote-command>" [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--perf]'
                'Examples:'
                '  az-vm exec --group <resource-group> --vm-name <vm-name>'
                '  az-vm exec --command "Get-Date" --group <resource-group> --vm-name <vm-name>'
                '  az-vm exec -c "uname -a" --group <resource-group> --vm-name <vm-name>'
                'Notes: exec is SSH-only. When no --command is provided, it opens the interactive SSH shell for the actual target VM OS. When --command is provided, it runs one one-shot remote command and returns the exit result.'
            )
            return
        }
        'delete' {
            Write-AzVmHelpLines @(
                'Command: delete'
                'Description: purge selected resources from a managed resource group.'
                'Usage:'
                '  az-vm delete --target <group|network|vm|disk> [--group <resource-group>] [--subscription-id <subscription-id>] [--yes]'
                'Examples:'
                '  az-vm delete --target vm --group <resource-group> -s <subscription-guid>'
                '  az-vm delete --target group --group <resource-group> --yes'
                'Notes: delete is Azure-touching and writes CLI-provided --subscription-id into azure_subscription_id.'
            )
            return
        }
        'help' {
            Write-AzVmHelpLines @(
                'Command: help'
                "Description: show quick overview or one command's detailed usage."
                'Usage:'
                '  az-vm help'
                '  az-vm help <configure|create|update|list|show|do|task|connect|move|resize|set|exec|delete>'
                'Examples:'
                '  az-vm help'
                '  az-vm help create'
                '  az-vm help connect'
            )
            return
        }
    }
}
