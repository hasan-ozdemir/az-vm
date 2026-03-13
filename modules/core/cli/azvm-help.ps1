# Shared CLI help helpers.

# Handles Get-AzVmValidCommandList.
function Get-AzVmValidCommandList {
    return @('create', 'update', 'configure', 'group', 'show', 'do', 'task', 'move', 'resize', 'set', 'exec', 'ssh', 'rdp', 'delete', 'help')
}

# Handles Show-AzVmCommandHelpOverview.
function Show-AzVmCommandHelpOverview {
    Write-Host "az-vm quick help"
    Write-Host "Usage: az-vm <command> [--option] [--option=value]"
    Write-Host ""
    Write-Host "Commands (full details: az-vm help <command>):"
    Write-Host "  create  Create one fresh managed resource group and one fresh managed VM."
    Write-Host "  update  Update one existing managed VM in one existing managed resource group."
    Write-Host "  configure  Configure precheck/preview flow for a target resource group."
    Write-Host "  group   List/select managed resource groups for active context."
    Write-Host "  show    Print system and configuration dump for resource groups and VMs."
    Write-Host "  do      Apply one VM lifecycle action or print current VM state."
    Write-Host "  task    List discovered init/update tasks in real execution order."
    Write-Host "  move    Move an existing VM to another Azure region; expect a health-gated cutover that can take tens of minutes."
    Write-Host "  resize  Change VM size or expand the managed OS disk for an existing VM."
    Write-Host "  set     Apply hibernation and sync nested virtualization desired state."
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
    Write-Host "  -h, --help             Show this overview or command-specific help."
    Write-Host ""
    Write-Host "Step values for create/update:"
    Write-Host "  configure, group, network, vm-deploy, vm-init, vm-update, vm-summary"
    Write-Host ""
    Write-Host "Quick examples:"
    Write-Host "  az-vm -h"
    Write-Host "  az-vm --help"
    Write-Host "  az-vm create --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku>"
    Write-Host "  az-vm configure"
    Write-Host "  az-vm create --step-from=vm-init --linux"
    Write-Host "  az-vm update --auto --windows --group=<resource-group> --vm-name=<vm-name>"
    Write-Host "  az-vm group --list=<vm-name>"
    Write-Host "  az-vm group --select=<resource-group>"
    Write-Host "  az-vm do --vm-action=status --vm-name=<vm-name>"
    Write-Host "  az-vm do --vm-action=reapply --group=<resource-group> --vm-name=<vm-name>"
    Write-Host "  az-vm do --vm-action=hibernate-stop --group=<resource-group> --vm-name=<vm-name>"
    Write-Host "  az-vm do --vm-action=hibernate-deallocate --group=<resource-group> --vm-name=<vm-name>"
    Write-Host "  az-vm move --vm-region=swedencentral --group=<resource-group> --vm-name=<vm-name>"
    Write-Host "  az-vm resize --vm-size=Standard_B2as_v2 --group=<resource-group> --vm-name=<vm-name>"
    Write-Host "  az-vm set --hibernation=off --nested-virtualization=off --group=<resource-group> --vm-name=<vm-name>"
    Write-Host "  az-vm task --list --vm-update"
    Write-Host "  az-vm exec --update-task=10001 --group=<resource-group> --vm-name=<vm-name>"
    Write-Host "  az-vm ssh --vm-name=<vm-name>"
    Write-Host "  az-vm ssh --vm-name=<vm-name> --test"
    Write-Host "  az-vm rdp --vm-name=<vm-name> --user=assistant"
    Write-Host "  az-vm rdp --vm-name=<vm-name> --test"
    Write-Host "  az-vm show --group=<resource-group>"
    Write-Host "  az-vm delete --target=group --group=<resource-group> --yes"
    Write-Host ""
    Write-Host "Detailed docs:"
    Write-Host "  az-vm help"
    Write-Host "  az-vm do -h"
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
        Write-Host "  -h, --help"
        Write-Host ""
        Write-Host "Help usage:"
        Write-Host "  az-vm -h                            # quick overview"
        Write-Host "  az-vm --help                       # quick overview"
        Write-Host "  az-vm help                         # full command catalog"
        Write-Host "  az-vm create -h                    # one command details"
        Write-Host "  az-vm help create                  # one command details"
        Write-Host ""
        Write-Host "Command reference:"
        Write-Host "  create  : supports --step-to, --step-from, --step, explicit destructive rebuild flow, --vm-name, --vm-region, --vm-size"
        Write-Host "  update  : supports --step-to, --step-from, --step, --group, --vm-name"
        Write-Host "  configure  : configure precheck/preview for selected resource group"
        Write-Host "  group   : list/select active managed resource group"
        Write-Host "  show    : print system and configuration dump for resource groups and VMs"
        Write-Host "  do      : supports --group, --vm-name, --vm-action"
        Write-Host "  task    : supports --list, --vm-init, --vm-update, --disabled, --windows, --linux"
        Write-Host "  move    : supports --group, --vm-name, --vm-region"
        Write-Host "  resize  : supports --group, --vm-name, --vm-size, --disk-size, --expand, --shrink, --windows, --linux"
        Write-Host "  set     : supports --group, --vm-name, --hibernation, --nested-virtualization"
        Write-Host "  exec    : supports --group, --vm-name, --init-task, --update-task"
        Write-Host "  ssh     : supports --group, --vm-name, --user, --test"
        Write-Host "  rdp     : supports --group, --vm-name, --user, --test"
        Write-Host "  delete  : supports --target, --group, --yes"
        Write-Host ""
        Write-Host "Examples:"
        Write-Host "  az-vm create --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku>"
        Write-Host "  az-vm configure"
        Write-Host "  az-vm create --step=configure --linux"
        Write-Host "  az-vm update --auto --windows --group=<resource-group> --vm-name=<vm-name>"
        Write-Host "  az-vm group --list=<vm-name>"
        Write-Host "  az-vm group --select=<resource-group>"
        Write-Host "  az-vm do --vm-action=status --vm-name=<vm-name>"
        Write-Host "  az-vm do --vm-action=reapply --group=<resource-group> --vm-name=<vm-name>"
        Write-Host "  az-vm do --vm-action=hibernate-stop --group=<resource-group> --vm-name=<vm-name>"
        Write-Host "  az-vm do --vm-action=hibernate-deallocate --group=<resource-group> --vm-name=<vm-name>"
        Write-Host "  az-vm move --vm-region=swedencentral --group=<resource-group> --vm-name=<vm-name>"
        Write-Host "  az-vm resize --vm-size=Standard_B2as_v2 --group=<resource-group> --vm-name=<vm-name>"
        Write-Host "  az-vm set --hibernation=off --nested-virtualization=off --group=<resource-group> --vm-name=<vm-name>"
        Write-Host "  az-vm task --list --vm-init"
        Write-Host "  az-vm exec --init-task=01 --group=<resource-group> --vm-name=<vm-name>"
        Write-Host "  az-vm ssh --vm-name=<vm-name>"
        Write-Host "  az-vm ssh --vm-name=<vm-name> --test"
        Write-Host "  az-vm rdp --vm-name=<vm-name> --user=assistant"
        Write-Host "  az-vm rdp --vm-name=<vm-name> --test"
        Write-Host "  az-vm show --group=<resource-group>"
        Write-Host "  az-vm delete --target=vm --group=<resource-group> --yes"
        Write-Host ""
        Write-Host "For per-command docs: az-vm help <create|update|configure|group|show|do|task|move|resize|set|exec|ssh|rdp|delete>"
        return
    }

    if ($validCommands -notcontains $topicName) {
        Throw-FriendlyError `
            -Detail ("Unknown help topic '{0}'." -f $topicText) `
            -Code 2 `
            -Summary "Unknown help topic." `
            -Hint "Use az-vm help or az-vm help <create|update|configure|group|show|do|task|move|resize|set|exec|ssh|rdp|delete>."
    }

    switch ($topicName) {
        'create' {
            Write-Host "Command: create"
            Write-Host "Description: create one fresh managed resource group, one fresh managed VM, and then continue with vm-init/vm-update flow."
            Write-Host "Usage:"
            Write-Host "  az-vm create [--windows|--linux] [--perf]"
            Write-Host "  az-vm create [--windows|--linux] [--vm-name=<vm-name>] explicit destructive rebuild flow"
            Write-Host "  az-vm create --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku> [--perf]"
            Write-Host "  az-vm create --auto --linux --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku> [--perf]"
            Write-Host "  az-vm create --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku> explicit destructive rebuild flow [--perf]"
            Write-Host "  az-vm create --auto --linux --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku> explicit destructive rebuild flow [--perf]"
            Write-Host "  az-vm create --step-to=<step>"
            Write-Host "  az-vm create --step-from=<step>"
            Write-Host "  az-vm create --step=<step>"
            Write-Host "  az-vm create -h"
            Write-Host "  az-vm create --help"
            Write-Host "Steps: configure, group, network, vm-deploy, vm-init, vm-update, vm-summary"
            Write-Host "Examples:"
            Write-Host "  az-vm create --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku>"
            Write-Host "  az-vm create explicit destructive rebuild flow --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku>"
            Write-Host "  az-vm create --step=network --linux"
            Write-Host "  az-vm create --step-from=vm-deploy --step-to=vm-summary --perf"
            Write-Host "Notes: create always targets a fresh managed resource group and fresh managed resources. Interactive mode always shows configure first, proposes the next global gX name plus globally unique nX resource ids, and asks yes/no/cancel review checkpoints only for group, vm-deploy, vm-init, and vm-update. Auto mode requires an explicit platform plus --vm-name, --vm-region, and --vm-size. vm-summary always renders, even for partial step windows. Use explicit destructive rebuild flow only when you want a destructive recreate of the fresh target."
            return
        }
        'update' {
            Write-Host "Command: update"
            Write-Host "Description: re-run create-or-update operations against one existing managed VM in one existing managed resource group."
            Write-Host "Usage:"
            Write-Host "  az-vm update [--windows|--linux] [--group=<resource-group>] [--vm-name=<vm-name>] [--perf]"
            Write-Host "  az-vm update --auto --windows --group=<resource-group> --vm-name=<vm-name> [--perf]"
            Write-Host "  az-vm update --auto --linux --group=<resource-group> --vm-name=<vm-name> [--perf]"
            Write-Host "  az-vm update --step-to=<step>"
            Write-Host "  az-vm update --step-from=<step>"
            Write-Host "  az-vm update --step=<step>"
            Write-Host "  az-vm update -h"
            Write-Host "  az-vm update --help"
            Write-Host "Steps: configure, group, network, vm-deploy, vm-init, vm-update, vm-summary"
            Write-Host "Examples:"
            Write-Host "  az-vm update --group=<resource-group>"
            Write-Host "  az-vm update --auto --windows --group=<resource-group> --vm-name=<vm-name>"
            Write-Host "  az-vm update --step=vm-update --auto --windows --group=<resource-group> --vm-name=<vm-name>"
            Write-Host "  az-vm update --step-from=group --step-to=vm-init --perf"
            Write-Host "Notes: update requires an existing managed resource group and an existing managed VM. Interactive mode always shows configure first, selects only managed existing targets, and asks yes/no/cancel review checkpoints only for group, vm-deploy, vm-init, and vm-update. Invalid free-form group or VM values are rejected with a corrective hint. Auto mode requires an explicit platform plus --group and --vm-name. vm-summary always renders, even for partial step windows. Existing VMs are redeployed after Azure create-or-update."
            return
        }
        'configure' {
            Write-Host "Command: configure"
            Write-Host "Description: run configure precheck/preview for a target managed resource group."
            Write-Host "Usage:"
            Write-Host "  az-vm configure [--group=<resource-group>]"
            Write-Host "  az-vm configure -h"
            Write-Host "  az-vm configure --help"
            Write-Host "Examples:"
            Write-Host "  az-vm configure --group=<resource-group>"
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
            Write-Host "  az-vm group -h"
            Write-Host "  az-vm group --help"
            Write-Host "Examples:"
            Write-Host "  az-vm group --list=<vm-name>"
            Write-Host "  az-vm group --select=<resource-group>"
            Write-Host "  az-vm group --select="
            return
        }
        'show' {
            Write-Host "Command: show"
            Write-Host "Description: print a full system and configuration dump for app resource groups and VMs."
            Write-Host "Usage:"
            Write-Host "  az-vm show [--perf]"
            Write-Host "  az-vm show --group=<resource-group>"
            Write-Host "  az-vm show -h"
            Write-Host "  az-vm show --help"
            Write-Host "Examples:"
            Write-Host "  az-vm show"
            Write-Host "  az-vm show --group=<resource-group>"
            Write-Host "  az-vm show --perf"
            Write-Host "Notes: password-bearing .env values are redacted in the rendered report. When the VM is running, nested virtualization is shown from guest validation evidence."
            return
        }
        'do' {
            Write-Host "Command: do"
            Write-Host "Description: apply one VM lifecycle action or print the current VM lifecycle state."
            Write-Host "Usage:"
            Write-Host "  az-vm do [--group=<resource-group>] [--vm-name=<vm-name>] [--vm-action=<status|start|restart|stop|deallocate|hibernate-deallocate|hibernate-stop|reapply>] [--perf]"
            Write-Host "  az-vm do -h"
            Write-Host "  az-vm do --help"
            Write-Host "Examples:"
            Write-Host "  az-vm do"
            Write-Host "  az-vm do --vm-action=status --vm-name=<vm-name>"
            Write-Host "  az-vm do --vm-action=start --group=<resource-group> --vm-name=<vm-name>"
            Write-Host "  az-vm do --vm-action=reapply --group=<resource-group> --vm-name=<vm-name>"
            Write-Host "  az-vm do --vm-action=deallocate --group=<resource-group> --vm-name=<vm-name>"
            Write-Host "  az-vm do --vm-action=hibernate-stop --group=<resource-group> --vm-name=<vm-name>"
            Write-Host "  az-vm do --vm-action=hibernate-deallocate --group=<resource-group> --vm-name=<vm-name>"
            Write-Host "Notes: hibernate-stop uses SSH to run 'shutdown /h /f' inside a running VM and waits until the guest is no longer running without Azure deallocation. hibernate-deallocate uses Azure's deallocation-based hibernate path. Reapply calls 'az vm reapply' and then prints refreshed VM status; unlike the power actions, it remains available when provisioning is not currently succeeded. If target parameters are omitted, the command selects the managed group, VM, and action interactively."
            return
        }
        'task' {
            Write-Host "Command: task"
            Write-Host "Description: list discovered init/update tasks exactly as the runtime would order them."
            Write-Host "Usage:"
            Write-Host "  az-vm task --list [--vm-init] [--vm-update] [--disabled] [--windows|--linux] [--perf]"
            Write-Host "  az-vm task -h"
            Write-Host "  az-vm task --help"
            Write-Host "Examples:"
            Write-Host "  az-vm task --list"
            Write-Host "  az-vm task --list --vm-init"
            Write-Host "  az-vm task --list --vm-update --disabled --windows"
            Write-Host "Notes: the command scans tracked and local task trees, applies the same discovery rules used by init/update execution, and prints the real execution order or disabled inventory."
            return
        }
        'move' {
            Write-Host "Command: move"
            Write-Host "Description: move VM deployment to a target Azure region."
            Write-Host "Usage:"
            Write-Host "  az-vm move --group=<resource-group> --vm-name=<vm-name> --vm-region=<azure-region>"
            Write-Host "  az-vm move --group=<resource-group> --vm-name=<vm-name> --vm-region="
            Write-Host "  az-vm move -h"
            Write-Host "  az-vm move --help"
            Write-Host "Examples:"
            Write-Host "  az-vm move --group=<resource-group> --vm-name=<vm-name> --vm-region=swedencentral"
            Write-Host "  az-vm move --group=<resource-group> --vm-name=<vm-name> --vm-region="
            Write-Host "Notes: region move uses a deallocate -> snapshot-copy -> target rebuild -> target health-check -> old-group-delete flow with rollback safeguards."
            Write-Host "Timing: observed live reference for austriaeast -> swedencentral, Standard_D4as_v5, 127 GB OS disk is roughly 25-30 minutes; cross-region snapshot copy was the longest phase at about 17-19 minutes."
            Write-Host "Flow: validate source/target and safe-delete scope -> deallocate source VM -> create source snapshot and target copy -> wait for target snapshot Available/100% -> rebuild target network/disk/VM -> re-apply hibernation/start target -> run health gate -> delete old source group after cutover passes."
            return
        }
        'resize' {
            Write-Host "Command: resize"
            Write-Host "Description: resize VM SKU or expand the managed OS disk in the same region."
            Write-Host "Usage:"
            Write-Host "  az-vm resize [--group=<resource-group>] [--vm-name=<vm-name>] [--vm-size=<vm-sku>] [--windows|--linux] [--perf]"
            Write-Host "  az-vm resize [--group=<resource-group>] [--vm-name=<vm-name>] --disk-size=<number>gb|mb --expand [--windows|--linux] [--perf]"
            Write-Host "  az-vm resize [--group=<resource-group>] [--vm-name=<vm-name>] --disk-size=<number>gb|mb --shrink [--windows|--linux] [--perf]"
            Write-Host "  az-vm resize"
            Write-Host "  az-vm resize -h"
            Write-Host "  az-vm resize --help"
            Write-Host "Examples:"
            Write-Host "  az-vm resize --group=<resource-group> --vm-name=<vm-name> --vm-size=Standard_B2as_v5"
            Write-Host "  az-vm resize --group=<resource-group> --vm-name=<vm-name> --vm-size=Standard_D4as_v5"
            Write-Host "  az-vm resize --group=<resource-group> --vm-name=<vm-name> --disk-size=196gb --expand --windows"
            Write-Host "  az-vm resize --group=<resource-group> --vm-name=<vm-name> --disk-size=98304mb --expand"
            Write-Host "  az-vm resize --group=<resource-group> --vm-name=<vm-name> --disk-size=64gb --shrink"
            Write-Host "  az-vm resize"
            Write-Host "Notes: resize stays in the current region. --vm-size changes the VM SKU. --disk-size requires exactly one intent flag: --expand or --shrink. --disk-size with --expand performs a supported managed OS disk growth. --disk-size with --shrink is a non-mutating guidance path that explains Azure's OS disk shrink limits and lists supported alternatives. If resize values are omitted, the command selects the managed group, VM, and VM SKU interactively."
            return
        }
        'set' {
            Write-Host "Command: set"
            Write-Host "Description: apply hibernation changes and sync nested virtualization desired-state values back to .env."
            Write-Host "Usage:"
            Write-Host "  az-vm set --group=<resource-group> --vm-name=<vm-name> --hibernation=on|off"
            Write-Host "  az-vm set --group=<resource-group> --vm-name=<vm-name> --nested-virtualization=on|off"
            Write-Host "  az-vm set --group=<resource-group> --vm-name=<vm-name> --hibernation=on|off --nested-virtualization=on|off"
            Write-Host "  az-vm set -h"
            Write-Host "  az-vm set --help"
            Write-Host "Examples:"
            Write-Host "  az-vm set --group=<resource-group> --vm-name=<vm-name> --hibernation=off"
            Write-Host "  az-vm set --group=<resource-group> --vm-name=<vm-name> --nested-virtualization=off"
            Write-Host "Notes: hibernation is changed through Azure. Nested virtualization is governed by VM size/security type, so '--nested-virtualization=on' validates guest readiness on a running VM and '--nested-virtualization=off' only updates repo desired state. Successful updates persist RESOURCE_GROUP, VM_NAME, and the updated VM_ENABLE_* feature toggles to .env."
            return
        }
        'exec' {
            Write-Host "Command: exec"
            Write-Host "Description: execute a single init/update task or open interactive remote shell."
            Write-Host "Usage:"
            Write-Host "  az-vm exec [--group=<resource-group>] [--vm-name=<vm-name>] [--windows|--linux] [--perf]"
            Write-Host "  az-vm exec --init-task=<task-number> [--group=<resource-group>] [--vm-name=<vm-name>]"
            Write-Host "  az-vm exec --update-task=<task-number> [--group=<resource-group>] [--vm-name=<vm-name>]"
            Write-Host "  az-vm exec -h"
            Write-Host "  az-vm exec --help"
            Write-Host "Examples:"
            Write-Host "  az-vm exec --init-task=01 --group=<resource-group> --vm-name=<vm-name>"
            Write-Host "  az-vm exec --update-task=10001 --group=<resource-group> --vm-name=<vm-name> --windows"
            Write-Host "  az-vm exec --linux      # opens interactive remote shell session"
            Write-Host "Notes: use --vm-name for direct one-VM task execution without interactive VM selection."
            return
        }
        'ssh' {
            Write-Host "Command: ssh"
            Write-Host "Description: launch Windows OpenSSH client for a managed VM."
            Write-Host "Usage:"
            Write-Host "  az-vm ssh [--group=<resource-group>] [--vm-name=<vm-name>] [--user=manager|assistant] [--test] [--perf]"
            Write-Host "  az-vm ssh -h"
            Write-Host "  az-vm ssh --help"
            Write-Host "Examples:"
            Write-Host "  az-vm ssh --vm-name=<vm-name>"
            Write-Host "  az-vm ssh --group=<resource-group> --vm-name=<vm-name> --user=assistant"
            Write-Host "  az-vm ssh --group=<resource-group> --vm-name=<vm-name> --user=manager --test"
            Write-Host "Notes: the VM must already be running; password entry is handled in the external SSH console window. Use --test for a non-interactive SSH handshake check."
            return
        }
        'rdp' {
            Write-Host "Command: rdp"
            Write-Host "Description: launch mstsc for a managed Windows VM."
            Write-Host "Usage:"
            Write-Host "  az-vm rdp [--group=<resource-group>] [--vm-name=<vm-name>] [--user=manager|assistant] [--test] [--perf]"
            Write-Host "  az-vm rdp -h"
            Write-Host "  az-vm rdp --help"
            Write-Host "Examples:"
            Write-Host "  az-vm rdp --vm-name=<vm-name>"
            Write-Host "  az-vm rdp --group=<resource-group> --vm-name=<vm-name> --user=assistant"
            Write-Host "  az-vm rdp --group=<resource-group> --vm-name=<vm-name> --user=manager --test"
            Write-Host "Notes: the VM must already be running; credentials are staged with cmdkey before mstsc is launched. Use --test for a non-interactive RDP reachability check."
            return
        }
        'delete' {
            Write-Host "Command: delete"
            Write-Host "Description: purge selected resources from a resource group."
            Write-Host "Usage:"
            Write-Host "  az-vm delete --target=<group|network|vm|disk> [--group=<resource-group>] [--yes]"
            Write-Host "  az-vm delete -h"
            Write-Host "  az-vm delete --help"
            Write-Host "Examples:"
            Write-Host "  az-vm delete --target=group --group=<resource-group> --yes"
            Write-Host "  az-vm delete --target=vm --group=<resource-group> --yes"
            Write-Host "  az-vm delete --target=network --group=<resource-group> --yes"
            return
        }
        'help' {
            Write-Host "Command: help"
            Write-Host "Description: print detailed help pages."
            Write-Host "Usage:"
            Write-Host "  az-vm help"
            Write-Host "  az-vm help <command>"
            Write-Host "  az-vm -h"
            Write-Host "  az-vm --help"
            Write-Host "Examples:"
            Write-Host "  az-vm do -h"
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
