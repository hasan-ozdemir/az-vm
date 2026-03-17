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
        '  configure  Open the interactive .env editor and validate saved settings safely.'
        '  create     Create one fresh managed resource group and one fresh managed VM.'
        '  update     Update one existing managed VM in one existing managed resource group.'
        '  list       List managed resource groups and managed Azure resources by type.'
        '  show       Print system and configuration dump for resource groups and VMs.'
        '  do         Apply one VM lifecycle action or print current VM state.'
        '  task       List tasks, run one task, or save/restore one task app-state payload.'
        '  connect    Launch SSH or RDP client/test for a managed VM.'
        '  move       Move an existing VM to another Azure region.'
        '  resize     Change VM size or expand the managed OS disk for an existing VM.'
        '  set        Apply hibernation and validate or store nested virtualization settings.'
        '  exec       Open an interactive SSH shell or run one remote command.'
        '  delete     Purge selected resources from a resource group.'
        '  help       Show detailed docs (all commands or one command).'
        ''
        'Global options:'
        '  --version                  Print the current az-vm release version and exit.'
        '  --auto[=true|false]         Auto mode (create/update/delete only).'
        '  --perf[=true|false]         Print timing metrics.'
        '  --windows / --linux         Force VM platform where supported.'
        '  -g, --group                 Target resource group where required.'
        '  -v, --vm-name               Target VM name where required.'
        '  -s, --subscription-id       Target Azure subscription for Azure-touching commands.'
        '  -c, --command               Remote one-shot command text for exec.'
        '  -q, --quiet                 Exec-only quiet output mode for one-shot commands.'
        '  -h, --help                  Show this overview or command-specific help.'
        "  Azure CLI sign-in via 'az login' is required for Azure-touching commands."
        "  configure opens without az login; Azure-backed configure fields require az login to edit or verify."
        ''
        'Quick examples:'
        '  az-vm --version'
        '  az-vm create --auto'
        '  az-vm update --auto'
        '  az-vm task --list --vm-update'
        '  az-vm task --run-vm-init 01 --group <resource-group> --vm-name <vm-name>'
        '  az-vm task --run-vm-update 10002 --group <resource-group> --vm-name <vm-name>'
        '  az-vm task --save-app-state --vm-update-task=115 --group <resource-group> --vm-name <vm-name>'
        '  az-vm task --save-app-state --source=lm --user=.current. --vm-update-task=115 --windows'
        '  az-vm task --restore-app-state --target=lm --user=.current. --vm-update-task=115 --windows'
        '  az-vm exec --command "Get-Date" --group <resource-group> --vm-name <vm-name>'
        '  az-vm exec --group <resource-group> --vm-name <vm-name>'
        '  az-vm connect --ssh --vm-name <vm-name> --test'
        '  az-vm connect --rdp --vm-name <vm-name> --user assistant'
        '  az-vm do --vm-action=redeploy --group <resource-group> --vm-name <vm-name>'
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
            '  --version                # print the current az-vm release version and exit'
            '  --auto[=true|false]      # create/update/delete only'
            '  --perf[=true|false]'
            '  --windows[=true|false]   # create/update/task/resize'
            '  --linux[=true|false]     # create/update/task/resize'
            '  -g, --group'
            '  -v, --vm-name'
            '  -s, --subscription-id'
            '  -c, --command'
            '  -q, --quiet              # exec one-shot quiet output only'
            '  -h, --help'
            "  Azure CLI sign-in via 'az login' is required for Azure-touching commands."
            "  configure opens without az login; Azure-backed configure fields require az login to edit or verify."
            ''
            'Command reference:'
            '  configure  : interactive .env editor with validation and next-create preview'
            '  create     : fresh-only managed deployment flow'
            '  update     : existing-managed-target maintenance flow'
            '  list       : managed inventory output'
            '  show       : system and configuration dump'
            '  do         : lifecycle and repair actions'
            '  task       : task list, isolated task runs, task app-state save/restore'
            '  connect    : connect --ssh / connect --rdp plus --test'
            '  move       : managed region move'
            '  resize     : VM-size or disk expand guidance'
            '  set        : hibernation and nested virtualization settings'
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
                'Description: open the interactive .env editor, validate field values safely, preview the next create naming plan, and save the updated .env contract.'
                'Usage:'
                '  az-vm configure [--perf]'
                'Examples:'
                '  az-vm configure'
                'Notes: configure is interactive-only. It edits supported .env keys in sections, uses pickers for every finite or discoverable multi-option field, validates before save, stages changes in memory until final confirmation, and shows a next-create preview before writing .env. configure opens without az login, but Azure-backed fields become read-only and advise running az login when Azure validation is unavailable.'
            )
            return
        }
        'create' {
            Write-AzVmHelpLines @(
                'Command: create'
                'Description: create one fresh managed resource group, one fresh managed VM, and then continue with vm-init/vm-update flow.'
                'Usage:'
                '  az-vm create [--windows|--linux] [--subscription-id <subscription-id>] [--perf]'
                '  az-vm create --auto [--subscription-id <subscription-id>] [--perf]'
                '  az-vm create --auto --windows --vm-name <vm-name> --vm-region <azure-region> --vm-size <vm-sku> [--subscription-id <subscription-id>] [--perf]'
                '  az-vm create --auto --linux --vm-name <vm-name> --vm-region <azure-region> --vm-size <vm-sku> [--subscription-id <subscription-id>] [--perf]'
                '  az-vm create --step <step> [--subscription-id <subscription-id>]'
                '  az-vm create --step-from <step> [--subscription-id <subscription-id>]'
                '  az-vm create --step-to <step> [--subscription-id <subscription-id>]'
                'Steps: configure, group, network, vm-deploy, vm-init, vm-update, vm-summary'
                'Examples:'
                '  az-vm create --auto -s <subscription-guid>'
                '  az-vm create --auto --windows --vm-name <vm-name> --vm-region <azure-region> --vm-size <vm-sku> -s <subscription-guid>'
                '  az-vm create --step vm-update --linux'
                'Notes: create always targets a fresh managed resource group and fresh managed resources. Interactive mode prompts for Azure subscription when --subscription-id is omitted, asks for VM OS type first when --windows/--linux is omitted, proposes the next global gX name plus globally unique nX resource ids, and asks yes/no/cancel review checkpoints only for group, vm-deploy, vm-init, and vm-update. Auto mode runs from the fully resolved selection set: CLI overrides win, otherwise .env SELECTED_* values plus the platform VM defaults must resolve platform, VM name, Azure region, and VM size. Windows vm-update runs without a planned restart at Step 6 start, and any vm-update reboot request triggers one automatic restart before vm-summary. vm-summary always renders, even for partial step windows. For a destructive rebuild, run delete first and then create again.'
            )
            return
        }
        'update' {
            Write-AzVmHelpLines @(
                'Command: update'
                'Description: re-run create-or-update operations against one existing managed VM in one existing managed resource group.'
                'Usage:'
                '  az-vm update [--windows|--linux] [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--perf]'
                '  az-vm update --auto [--subscription-id <subscription-id>] [--perf]'
                '  az-vm update --auto --group <resource-group> --vm-name <vm-name> [--subscription-id <subscription-id>] [--perf]'
                '  az-vm update --step <step> [--subscription-id <subscription-id>]'
                '  az-vm update --step-from <step> [--subscription-id <subscription-id>]'
                '  az-vm update --step-to <step> [--subscription-id <subscription-id>]'
                'Steps: configure, group, network, vm-deploy, vm-init, vm-update, vm-summary'
                'Examples:'
                '  az-vm update --group <resource-group>'
                '  az-vm update --auto -s <subscription-guid>'
                '  az-vm update --auto --group <resource-group> --vm-name <vm-name> -s <subscription-guid>'
                'Notes: update requires an existing managed resource group and an existing managed VM. Interactive mode prompts for Azure subscription when --subscription-id is omitted, selects only managed existing targets, and asks yes/no/cancel review checkpoints only for group, vm-deploy, vm-init, and vm-update. Auto mode runs from the resolved managed target: CLI overrides win, otherwise .env SELECTED_RESOURCE_GROUP and SELECTED_VM_NAME are used, with single-VM auto-resolution still allowed when the selected group contains exactly one VM. Existing VMs are redeployed after Azure create-or-update. Windows vm-update runs without a planned restart at Step 6 start, and any vm-update reboot request triggers one automatic restart before vm-summary.'
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
                '  az-vm show --group <resource-group> [--vm-name <vm-name>] [--subscription-id <subscription-id>]'
                'Examples:'
                '  az-vm show'
                '  az-vm show --group <resource-group> --vm-name <vm-name> -s <subscription-guid>'
                'Notes: password-bearing .env values are redacted in the rendered report. When show can resolve exactly one managed VM target, it also prints a read-only target-derived configuration section using actual Azure state without writing .env. When the VM is running, nested virtualization is shown from guest validation evidence.'
            )
            return
        }
        'do' {
            Write-AzVmHelpLines @(
                'Command: do'
                'Description: apply one VM lifecycle action or print the current VM lifecycle state.'
                'Usage:'
                '  az-vm do [--group <resource-group>] [--vm-name <vm-name>] [--vm-action=<status|start|restart|stop|deallocate|hibernate-deallocate|hibernate-stop|reapply|redeploy>] [--subscription-id <subscription-id>] [--perf]'
                'Examples:'
                '  az-vm do --vm-action=status --vm-name <vm-name>'
                '  az-vm do --vm-action=reapply --group <resource-group> --vm-name <vm-name>'
                '  az-vm do --vm-action=redeploy --group <resource-group> --vm-name <vm-name>'
                '  az-vm do --vm-action=hibernate-stop --group <resource-group> --vm-name <vm-name>'
                '  az-vm do --vm-action=hibernate-deallocate --group <resource-group> --vm-name <vm-name>'
                "Notes: hibernate-stop uses SSH to run 'shutdown /h /f' inside a running VM and waits until the guest is no longer running without Azure deallocation. hibernate-deallocate uses Azure's deallocation-based hibernate path. Reapply calls 'az vm reapply' and then prints refreshed VM status; unlike the power actions, it remains available when provisioning is not currently succeeded. Redeploy calls 'az vm redeploy', waits for provisioning recovery, and restores the original started/stopped lifecycle state when Azure reports it deterministically."
            )
            return
        }
        'task' {
            Write-AzVmHelpLines @(
                'Command: task'
                'Description: list discovered init/update tasks, run one task in isolation, or save/restore one task-owned app-state payload against a VM or the local Windows machine.'
                'Usage:'
                '  az-vm task --list [--vm-init] [--vm-update] [--disabled] [--windows|--linux] [--perf]'
                '  az-vm task --run-vm-init <task-number|task-name> [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--windows|--linux] [--perf]'
                '  az-vm task --run-vm-update <task-number|task-name> [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--windows|--linux] [--perf]'
                '  az-vm task --save-app-state --vm-init-task <task-number|task-name> [--source <vm|lm>] [--user <.all.|.current.|user[,user...]>] [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--windows|--linux] [--perf]'
                '  az-vm task --save-app-state --vm-update-task <task-number|task-name> [--source <vm|lm>] [--user <.all.|.current.|user[,user...]>] [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--windows|--linux] [--perf]'
                '  az-vm task --restore-app-state --vm-init-task <task-number|task-name> [--target <vm|lm>] [--user <.all.|.current.|user[,user...]>] [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--windows|--linux] [--perf]'
                '  az-vm task --restore-app-state --vm-update-task <task-number|task-name> [--target <vm|lm>] [--user <.all.|.current.|user[,user...]>] [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--windows|--linux] [--perf]'
                'Examples:'
                '  az-vm task --list --vm-update'
                '  az-vm task --run-vm-init 01 --group <resource-group> --vm-name <vm-name>'
                '  az-vm task --run-vm-update 10002 --group <resource-group> --vm-name <vm-name>'
                '  az-vm task --save-app-state --vm-update-task=115 --group <resource-group> --vm-name <vm-name> -s <subscription-guid>'
                '  az-vm task --save-app-state --source=lm --user=.current. --vm-update-task=115 --windows'
                '  az-vm task --restore-app-state --target=lm --user=.current. --vm-update-task=115 --windows'
                '  az-vm task --restore-app-state --target=vm --user=assistant --vm-update-task=115 --group <resource-group> --vm-name <vm-name>'
                'Notes: --list is local-only and scans tracked plus local task trees with the same discovery rules used by init/update execution. --run-vm-init uses Azure run-command and replays the full guest transcript after each task completes. --run-vm-update uses the SSH task runner and streams guest stdout/stderr live. --save-app-state defaults to --source=vm and --restore-app-state defaults to --target=vm. Both default to --user=.all.. VM save/restore is SSH-based and remains limited to the managed manager/assistant profiles; vm-init app-state replay defers until SSH is ready. Local save/restore is Windows-host-only, reads or deploys only `<task-folder>/app-state/app-state.zip`, and writes a restore journal plus backup root before local replay.'
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
                'Description: apply hibernation changes and validate or store nested virtualization settings in .env.'
                'Usage:'
                '  az-vm set --group <resource-group> --vm-name <vm-name> --hibernation on|off [--subscription-id <subscription-id>]'
                '  az-vm set --group <resource-group> --vm-name <vm-name> --nested-virtualization on|off [--subscription-id <subscription-id>]'
                '  az-vm set --group <resource-group> --vm-name <vm-name> --hibernation on|off --nested-virtualization on|off [--subscription-id <subscription-id>]'
                'Examples:'
                '  az-vm set --group <resource-group> --vm-name <vm-name> --hibernation off'
                '  az-vm set --group <resource-group> --vm-name <vm-name> --nested-virtualization off'
                'Notes: hibernation is changed through Azure. Nested virtualization is governed by VM size and security type, so --nested-virtualization on validates guest readiness on a running VM and --nested-virtualization off saves the requested setting in .env because Azure does not expose a separate single-VM disable toggle.'
            )
            return
        }
        'exec' {
            Write-AzVmHelpLines @(
                'Command: exec'
                'Description: open an interactive SSH shell on the target VM, or run one remote command over SSH.'
                'Usage:'
                '  az-vm exec [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--perf]'
                '  az-vm exec --command "<remote-command>" [--quiet] [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--perf]'
                '  az-vm exec -c "<remote-command>" [-q] [--group <resource-group>] [--vm-name <vm-name>] [--subscription-id <subscription-id>] [--perf]'
                'Examples:'
                '  az-vm exec --group <resource-group> --vm-name <vm-name>'
                '  az-vm exec --command "Get-Date" --group <resource-group> --vm-name <vm-name>'
                '  az-vm exec --quiet --command "Get-Date" --group <resource-group> --vm-name <vm-name>'
                '  az-vm exec -c "uname -a" --group <resource-group> --vm-name <vm-name>'
                'Notes: exec is SSH-only. When no --command is provided, it opens the interactive SSH shell for the actual target VM OS. When --command is provided, it runs one one-shot remote command and returns the exit result. --quiet / -q is valid only together with --command / -c and prints only the remote command result.'
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
                'Notes: delete is Azure-touching and writes CLI-provided --subscription-id into SELECTED_AZURE_SUBSCRIPTION_ID.'
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
