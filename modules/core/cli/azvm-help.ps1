# Shared CLI help helpers.

# Handles Get-AzVmValidCommandList.
function Get-AzVmValidCommandList {
    return @('create', 'update', 'configure', 'list', 'show', 'do', 'task', 'move', 'resize', 'set', 'exec', 'ssh', 'rdp', 'delete', 'help')
}

# Handles Show-AzVmCommandHelpOverview.
function Show-AzVmCommandHelpOverview {
    Write-Host "az-vm quick help"
    Write-Host "Usage: az-vm <command> [--option] [--option=value]"
    Write-Host ""
    Write-Host "Commands (full details: az-vm help <command>):"
    Write-Host "  create  Create one fresh managed resource group and one fresh managed VM."
    Write-Host "  update  Update one existing managed VM in one existing managed resource group."
    Write-Host "  configure  Select one managed VM target and sync target-derived values into .env."
    Write-Host "  list    List managed resource groups and managed Azure resources by type."
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
    Write-Host "  -s, --subscription-id  Target Azure subscription for Azure-touching commands."
    Write-Host "  -h, --help             Show this overview or command-specific help."
    Write-Host "  Azure CLI sign-in via 'az login' is required for all Azure-touching commands."
    Write-Host ""
    Write-Host "Step values for create/update:"
    Write-Host "  configure, group, network, vm-deploy, vm-init, vm-update, vm-summary"
    Write-Host ""
    Write-Host "Quick examples:"
    Write-Host "  az-vm -h"
    Write-Host "  az-vm --help"
    Write-Host "  az-vm create --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku>"
    Write-Host "  az-vm configure --vm-name=<vm-name>"
    Write-Host "  az-vm create --step-from=vm-init --linux"
    Write-Host "  az-vm update --auto --windows --group=<resource-group> --vm-name=<vm-name>"
    Write-Host "  az-vm list --type=group,vm"
    Write-Host "  az-vm list --type=nsg,nsg-rule --group=<resource-group>"
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
    Write-Host "  az-vm help list"
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
        Write-Host "  -s, --subscription-id    # all Azure-touching commands except task/help"
        Write-Host "  -h, --help"
        Write-Host "  Azure CLI sign-in via 'az login' is required for all Azure-touching commands."
        Write-Host ""
        Write-Host "Help usage:"
        Write-Host "  az-vm -h                            # quick overview"
        Write-Host "  az-vm --help                       # quick overview"
        Write-Host "  az-vm help                         # full command catalog"
        Write-Host "  az-vm create -h                    # one command details"
        Write-Host "  az-vm help create                  # one command details"
        Write-Host ""
        Write-Host "Command reference:"
        Write-Host "  create  : supports --subscription-id, --step-to, --step-from, --step, explicit destructive rebuild flow, --vm-name, --vm-region, --vm-size"
        Write-Host "  update  : supports --subscription-id, --step-to, --step-from, --step, --group, --vm-name"
        Write-Host "  configure  : select one managed VM target and sync target-derived values into .env"
        Write-Host "  list    : supports --type and --group for managed inventory output, plus --subscription-id"
        Write-Host "  show    : supports --subscription-id and prints system/configuration dump for resource groups and VMs"
        Write-Host "  do      : supports --subscription-id, --group, --vm-name, --vm-action"
        Write-Host "  task    : supports --list, --vm-init, --vm-update, --disabled, --windows, --linux"
        Write-Host "  move    : supports --subscription-id, --group, --vm-name, --vm-region"
        Write-Host "  resize  : supports --subscription-id, --group, --vm-name, --vm-size, --disk-size, --expand, --shrink, --windows, --linux"
        Write-Host "  set     : supports --subscription-id, --group, --vm-name, --hibernation, --nested-virtualization"
        Write-Host "  exec    : supports --subscription-id, --group, --vm-name, --init-task, --update-task"
        Write-Host "  ssh     : supports --subscription-id, --group, --vm-name, --user, --test"
        Write-Host "  rdp     : supports --subscription-id, --group, --vm-name, --user, --test"
        Write-Host "  delete  : supports --subscription-id, --target, --group, --yes"
        Write-Host ""
        Write-Host "Examples:"
        Write-Host "  az-vm create --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku> -s <subscription-guid>"
        Write-Host "  az-vm configure --vm-name=<vm-name> --subscription-id=<subscription-guid>"
        Write-Host "  az-vm create --step=configure --linux"
        Write-Host "  az-vm update --auto --windows --group=<resource-group> --vm-name=<vm-name>"
        Write-Host "  az-vm list --type=group,vm --subscription-id=<subscription-guid>"
        Write-Host "  az-vm list --type=nsg,nsg-rule --group=<resource-group>"
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
        Write-Host "For per-command docs: az-vm help <create|update|configure|list|show|do|task|move|resize|set|exec|ssh|rdp|delete>"
        return
    }

    if ($validCommands -notcontains $topicName) {
        Throw-FriendlyError `
            -Detail ("Unknown help topic '{0}'." -f $topicText) `
            -Code 2 `
            -Summary "Unknown help topic." `
            -Hint "Use az-vm help or az-vm help <create|update|configure|list|show|do|task|move|resize|set|exec|ssh|rdp|delete>."
    }

    switch ($topicName) {
        'create' {
            Write-Host "Command: create"
            Write-Host "Description: create one fresh managed resource group, one fresh managed VM, and then continue with vm-init/vm-update flow."
            Write-Host "Usage:"
        Write-Host "  az-vm create [--windows|--linux] [--subscription-id=<subscription-id>] [--perf]"
        Write-Host "  az-vm create [--windows|--linux] [--subscription-id=<subscription-id>] [--vm-name=<vm-name>] explicit destructive rebuild flow"
        Write-Host "  az-vm create --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku> [--subscription-id=<subscription-id>] [--perf]"
        Write-Host "  az-vm create --auto --linux --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku> [--subscription-id=<subscription-id>] [--perf]"
        Write-Host "  az-vm create --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku> explicit destructive rebuild flow [--subscription-id=<subscription-id>] [--perf]"
        Write-Host "  az-vm create --auto --linux --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku> explicit destructive rebuild flow [--subscription-id=<subscription-id>] [--perf]"
        Write-Host "  az-vm create --step-to=<step> [--subscription-id=<subscription-id>]"
        Write-Host "  az-vm create --step-from=<step> [--subscription-id=<subscription-id>]"
        Write-Host "  az-vm create --step=<step> [--subscription-id=<subscription-id>]"
            Write-Host "  az-vm create -h"
            Write-Host "  az-vm create --help"
            Write-Host "Steps: configure, group, network, vm-deploy, vm-init, vm-update, vm-summary"
            Write-Host "Examples:"
            Write-Host "  az-vm create --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku> -s <subscription-guid>"
            Write-Host "  az-vm create explicit destructive rebuild flow --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku> --subscription-id=<subscription-guid>"
            Write-Host "  az-vm create --step=network --linux"
            Write-Host "  az-vm create --step-from=vm-deploy --step-to=vm-summary --perf"
            Write-Host "Notes: create always targets a fresh managed resource group and fresh managed resources. Azure CLI sign-in via 'az login' is required. Interactive mode always shows configure first, prompts for Azure subscription when --subscription-id is omitted, asks for VM OS type first when --windows/--linux is omitted, proposes the next global gX name plus globally unique nX resource ids, and asks yes/no/cancel review checkpoints only for group, vm-deploy, vm-init, and vm-update. Auto mode requires an explicit platform plus --vm-name, --vm-region, and --vm-size. CLI --subscription-id writes azure_subscription_id to .env. vm-summary always renders, even for partial step windows. Use explicit destructive rebuild flow only when you want a destructive recreate of the fresh target."
            return
        }
        'update' {
            Write-Host "Command: update"
            Write-Host "Description: re-run create-or-update operations against one existing managed VM in one existing managed resource group."
            Write-Host "Usage:"
            Write-Host "  az-vm update [--windows|--linux] [--group=<resource-group>] [--vm-name=<vm-name>] [--subscription-id=<subscription-id>] [--perf]"
            Write-Host "  az-vm update --auto --windows --group=<resource-group> --vm-name=<vm-name> [--subscription-id=<subscription-id>] [--perf]"
            Write-Host "  az-vm update --auto --linux --group=<resource-group> --vm-name=<vm-name> [--subscription-id=<subscription-id>] [--perf]"
            Write-Host "  az-vm update --step-to=<step> [--subscription-id=<subscription-id>]"
            Write-Host "  az-vm update --step-from=<step> [--subscription-id=<subscription-id>]"
            Write-Host "  az-vm update --step=<step> [--subscription-id=<subscription-id>]"
            Write-Host "  az-vm update -h"
            Write-Host "  az-vm update --help"
            Write-Host "Steps: configure, group, network, vm-deploy, vm-init, vm-update, vm-summary"
            Write-Host "Examples:"
            Write-Host "  az-vm update --group=<resource-group>"
            Write-Host "  az-vm update --auto --windows --group=<resource-group> --vm-name=<vm-name> -s <subscription-guid>"
            Write-Host "  az-vm update --step=vm-update --auto --windows --group=<resource-group> --vm-name=<vm-name>"
            Write-Host "  az-vm update --step-from=group --step-to=vm-init --perf"
            Write-Host "Notes: update requires an existing managed resource group and an existing managed VM. Azure CLI sign-in via 'az login' is required. Interactive mode always shows configure first, prompts for Azure subscription when --subscription-id is omitted, selects only managed existing targets, and asks yes/no/cancel review checkpoints only for group, vm-deploy, vm-init, and vm-update. Invalid free-form group or VM values are rejected with a corrective hint. Auto mode requires an explicit platform plus --group and --vm-name. CLI --subscription-id writes azure_subscription_id to .env. vm-summary always renders, even for partial step windows. Existing VMs are redeployed after Azure create-or-update."
            return
        }
        'configure' {
            Write-Host "Command: configure"
            Write-Host "Description: select one existing managed VM target, read actual Azure state, and sync target-derived values into .env."
            Write-Host "Usage:"
            Write-Host "  az-vm configure [--group=<resource-group>] [--vm-name=<vm-name>] [--subscription-id=<subscription-id>] [--windows|--linux] [--perf]"
            Write-Host "  az-vm configure -h"
            Write-Host "  az-vm configure --help"
            Write-Host "Examples:"
            Write-Host "  az-vm configure"
            Write-Host "  az-vm configure --group=<resource-group> --vm-name=<vm-name> --subscription-id=<subscription-guid>"
            Write-Host "  az-vm configure --vm-name=<vm-name>"
            Write-Host "Notes: configure is read-only against Azure. Azure CLI sign-in via 'az login' is required. It selects only az-vm-managed resource groups and existing VMs, validates --windows/--linux against the actual VM OS type, writes only target-derived .env values, clears stale opposite-platform keys, and prints a compact diff plus skipped unreadable feature keys. CLI --subscription-id writes azure_subscription_id to .env."
            return
        }
        'list' {
            Write-Host "Command: list"
            Write-Host "Description: print read-only managed inventory sections for az-vm-tagged resource groups and resources."
            Write-Host "Usage:"
            Write-Host "  az-vm list [--type=<group,vm,disk,vnet,subnet,nic,ip,nsg,nsg-rule>] [--group=<resource-group>] [--subscription-id=<subscription-id>] [--perf]"
            Write-Host "  az-vm list -h"
            Write-Host "  az-vm list --help"
            Write-Host "Examples:"
            Write-Host "  az-vm list"
            Write-Host "  az-vm list --type=group,vm -s <subscription-guid>"
            Write-Host "  az-vm list --type=nsg,nsg-rule --group=<resource-group>"
            Write-Host "Notes: list is Azure-read-only. Azure CLI sign-in via 'az login' is required. --type uses comma-separated values. --group is an exact managed resource-group filter. Without --type, list prints all supported managed inventory sections in deterministic order. CLI --subscription-id writes azure_subscription_id to .env."
            return
        }
        'show' {
            Write-Host "Command: show"
            Write-Host "Description: print a full system and configuration dump for app resource groups and VMs."
            Write-Host "Usage:"
            Write-Host "  az-vm show [--subscription-id=<subscription-id>] [--perf]"
            Write-Host "  az-vm show --group=<resource-group> [--subscription-id=<subscription-id>]"
            Write-Host "  az-vm show -h"
            Write-Host "  az-vm show --help"
            Write-Host "Examples:"
            Write-Host "  az-vm show"
            Write-Host "  az-vm show --group=<resource-group> --subscription-id=<subscription-guid>"
            Write-Host "  az-vm show --perf"
            Write-Host "Notes: Azure CLI sign-in via 'az login' is required. Password-bearing .env values are redacted in the rendered report. When the VM is running, nested virtualization is shown from guest validation evidence. CLI --subscription-id writes azure_subscription_id to .env."
            return
        }
        'do' {
            Write-Host "Command: do"
            Write-Host "Description: apply one VM lifecycle action or print the current VM lifecycle state."
            Write-Host "Usage:"
            Write-Host "  az-vm do [--group=<resource-group>] [--vm-name=<vm-name>] [--vm-action=<status|start|restart|stop|deallocate|hibernate-deallocate|hibernate-stop|reapply>] [--subscription-id=<subscription-id>] [--perf]"
            Write-Host "  az-vm do -h"
            Write-Host "  az-vm do --help"
            Write-Host "Examples:"
            Write-Host "  az-vm do"
            Write-Host "  az-vm do --vm-action=status --vm-name=<vm-name> -s <subscription-guid>"
            Write-Host "  az-vm do --vm-action=start --group=<resource-group> --vm-name=<vm-name>"
            Write-Host "  az-vm do --vm-action=reapply --group=<resource-group> --vm-name=<vm-name>"
            Write-Host "  az-vm do --vm-action=deallocate --group=<resource-group> --vm-name=<vm-name>"
            Write-Host "  az-vm do --vm-action=hibernate-stop --group=<resource-group> --vm-name=<vm-name>"
            Write-Host "  az-vm do --vm-action=hibernate-deallocate --group=<resource-group> --vm-name=<vm-name>"
            Write-Host "Notes: Azure CLI sign-in via 'az login' is required. hibernate-stop uses SSH to run 'shutdown /h /f' inside a running VM and waits until the guest is no longer running without Azure deallocation. hibernate-deallocate uses Azure's deallocation-based hibernate path. Reapply calls 'az vm reapply' and then prints refreshed VM status; unlike the power actions, it remains available when provisioning is not currently succeeded. If target parameters are omitted, the command selects the managed group, VM, and action interactively. CLI --subscription-id writes azure_subscription_id to .env."
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
            Write-Host "  az-vm move --group=<resource-group> --vm-name=<vm-name> --vm-region=<azure-region> [--subscription-id=<subscription-id>]"
            Write-Host "  az-vm move --group=<resource-group> --vm-name=<vm-name> --vm-region= [--subscription-id=<subscription-id>]"
            Write-Host "  az-vm move -h"
            Write-Host "  az-vm move --help"
            Write-Host "Examples:"
            Write-Host "  az-vm move --group=<resource-group> --vm-name=<vm-name> --vm-region=swedencentral -s <subscription-guid>"
            Write-Host "  az-vm move --group=<resource-group> --vm-name=<vm-name> --vm-region="
            Write-Host "Notes: Azure CLI sign-in via 'az login' is required. Region move uses a deallocate -> snapshot-copy -> target rebuild -> target health-check -> old-group-delete flow with rollback safeguards. CLI --subscription-id writes azure_subscription_id to .env."
            Write-Host "Timing: observed live reference for austriaeast -> swedencentral, Standard_D4as_v5, 127 GB OS disk is roughly 25-30 minutes; cross-region snapshot copy was the longest phase at about 17-19 minutes."
            Write-Host "Flow: validate source/target and safe-delete scope -> deallocate source VM -> create source snapshot and target copy -> wait for target snapshot Available/100% -> rebuild target network/disk/VM -> re-apply hibernation/start target -> run health gate -> delete old source group after cutover passes."
            return
        }
        'resize' {
            Write-Host "Command: resize"
            Write-Host "Description: resize VM SKU or expand the managed OS disk in the same region."
            Write-Host "Usage:"
            Write-Host "  az-vm resize [--group=<resource-group>] [--vm-name=<vm-name>] [--vm-size=<vm-sku>] [--subscription-id=<subscription-id>] [--windows|--linux] [--perf]"
            Write-Host "  az-vm resize [--group=<resource-group>] [--vm-name=<vm-name>] --disk-size=<number>gb|mb --expand [--subscription-id=<subscription-id>] [--windows|--linux] [--perf]"
            Write-Host "  az-vm resize [--group=<resource-group>] [--vm-name=<vm-name>] --disk-size=<number>gb|mb --shrink [--subscription-id=<subscription-id>] [--windows|--linux] [--perf]"
            Write-Host "  az-vm resize"
            Write-Host "  az-vm resize -h"
            Write-Host "  az-vm resize --help"
            Write-Host "Examples:"
            Write-Host "  az-vm resize --group=<resource-group> --vm-name=<vm-name> --vm-size=Standard_B2as_v5 -s <subscription-guid>"
            Write-Host "  az-vm resize --group=<resource-group> --vm-name=<vm-name> --vm-size=Standard_D4as_v5"
            Write-Host "  az-vm resize --group=<resource-group> --vm-name=<vm-name> --disk-size=196gb --expand --windows"
            Write-Host "  az-vm resize --group=<resource-group> --vm-name=<vm-name> --disk-size=98304mb --expand"
            Write-Host "  az-vm resize --group=<resource-group> --vm-name=<vm-name> --disk-size=64gb --shrink"
            Write-Host "  az-vm resize"
            Write-Host "Notes: Azure CLI sign-in via 'az login' is required. Resize stays in the current region. --vm-size changes the VM SKU. --disk-size requires exactly one intent flag: --expand or --shrink. --disk-size with --expand performs a supported managed OS disk growth. --disk-size with --shrink is a non-mutating guidance path that explains Azure's OS disk shrink limits and lists supported alternatives. If resize values are omitted, the command selects the managed group, VM, and VM SKU interactively. CLI --subscription-id writes azure_subscription_id to .env."
            return
        }
        'set' {
            Write-Host "Command: set"
            Write-Host "Description: apply hibernation changes and sync nested virtualization desired-state values back to .env."
            Write-Host "Usage:"
            Write-Host "  az-vm set --group=<resource-group> --vm-name=<vm-name> --hibernation=on|off [--subscription-id=<subscription-id>]"
            Write-Host "  az-vm set --group=<resource-group> --vm-name=<vm-name> --nested-virtualization=on|off [--subscription-id=<subscription-id>]"
            Write-Host "  az-vm set --group=<resource-group> --vm-name=<vm-name> --hibernation=on|off --nested-virtualization=on|off [--subscription-id=<subscription-id>]"
            Write-Host "  az-vm set -h"
            Write-Host "  az-vm set --help"
            Write-Host "Examples:"
            Write-Host "  az-vm set --group=<resource-group> --vm-name=<vm-name> --hibernation=off -s <subscription-guid>"
            Write-Host "  az-vm set --group=<resource-group> --vm-name=<vm-name> --nested-virtualization=off"
            Write-Host "Notes: Azure CLI sign-in via 'az login' is required. Hibernation is changed through Azure. Nested virtualization is governed by VM size/security type, so '--nested-virtualization=on' validates guest readiness on a running VM and '--nested-virtualization=off' only updates repo desired state. Successful updates persist RESOURCE_GROUP, VM_NAME, and the updated VM_ENABLE_* feature toggles to .env. CLI --subscription-id writes azure_subscription_id to .env."
            return
        }
        'exec' {
            Write-Host "Command: exec"
            Write-Host "Description: execute a single init/update task or open interactive remote shell."
            Write-Host "Usage:"
            Write-Host "  az-vm exec [--group=<resource-group>] [--vm-name=<vm-name>] [--subscription-id=<subscription-id>] [--windows|--linux] [--perf]"
            Write-Host "  az-vm exec --init-task=<task-number> [--group=<resource-group>] [--vm-name=<vm-name>] [--subscription-id=<subscription-id>]"
            Write-Host "  az-vm exec --update-task=<task-number> [--group=<resource-group>] [--vm-name=<vm-name>] [--subscription-id=<subscription-id>]"
            Write-Host "  az-vm exec -h"
            Write-Host "  az-vm exec --help"
            Write-Host "Examples:"
            Write-Host "  az-vm exec --init-task=01 --group=<resource-group> --vm-name=<vm-name> -s <subscription-guid>"
            Write-Host "  az-vm exec --update-task=10001 --group=<resource-group> --vm-name=<vm-name> --windows"
            Write-Host "  az-vm exec --linux      # opens interactive remote shell session"
            Write-Host "Notes: Azure CLI sign-in via 'az login' is required. Use --vm-name for direct one-VM task execution without interactive VM selection. CLI --subscription-id writes azure_subscription_id to .env."
            return
        }
        'ssh' {
            Write-Host "Command: ssh"
            Write-Host "Description: launch Windows OpenSSH client for a managed VM."
            Write-Host "Usage:"
            Write-Host "  az-vm ssh [--group=<resource-group>] [--vm-name=<vm-name>] [--user=manager|assistant] [--test] [--subscription-id=<subscription-id>] [--perf]"
            Write-Host "  az-vm ssh -h"
            Write-Host "  az-vm ssh --help"
            Write-Host "Examples:"
            Write-Host "  az-vm ssh --vm-name=<vm-name> -s <subscription-guid>"
            Write-Host "  az-vm ssh --group=<resource-group> --vm-name=<vm-name> --user=assistant"
            Write-Host "  az-vm ssh --group=<resource-group> --vm-name=<vm-name> --user=manager --test"
            Write-Host "Notes: Azure CLI sign-in via 'az login' is required. The VM must already be running; password entry is handled in the external SSH console window. Use --test for a non-interactive SSH handshake check. CLI --subscription-id writes azure_subscription_id to .env."
            return
        }
        'rdp' {
            Write-Host "Command: rdp"
            Write-Host "Description: launch mstsc for a managed Windows VM."
            Write-Host "Usage:"
            Write-Host "  az-vm rdp [--group=<resource-group>] [--vm-name=<vm-name>] [--user=manager|assistant] [--test] [--subscription-id=<subscription-id>] [--perf]"
            Write-Host "  az-vm rdp -h"
            Write-Host "  az-vm rdp --help"
            Write-Host "Examples:"
            Write-Host "  az-vm rdp --vm-name=<vm-name> -s <subscription-guid>"
            Write-Host "  az-vm rdp --group=<resource-group> --vm-name=<vm-name> --user=assistant"
            Write-Host "  az-vm rdp --group=<resource-group> --vm-name=<vm-name> --user=manager --test"
            Write-Host "Notes: Azure CLI sign-in via 'az login' is required. The VM must already be running; credentials are staged with cmdkey before mstsc is launched. Use --test for a non-interactive RDP reachability check. CLI --subscription-id writes azure_subscription_id to .env."
            return
        }
        'delete' {
            Write-Host "Command: delete"
            Write-Host "Description: purge selected resources from a resource group."
            Write-Host "Usage:"
            Write-Host "  az-vm delete --target=<group|network|vm|disk> [--group=<resource-group>] [--subscription-id=<subscription-id>] [--yes]"
            Write-Host "  az-vm delete -h"
            Write-Host "  az-vm delete --help"
            Write-Host "Examples:"
            Write-Host "  az-vm delete --target=group --group=<resource-group> --yes -s <subscription-guid>"
            Write-Host "  az-vm delete --target=vm --group=<resource-group> --yes"
            Write-Host "  az-vm delete --target=network --group=<resource-group> --yes"
            Write-Host "Notes: Azure CLI sign-in via 'az login' is required. CLI --subscription-id writes azure_subscription_id to .env."
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
