# az-vm

Unified Azure VM provisioning toolkit for Windows and Linux with one launcher:
- `az-vm.cmd`
- `az-vm.ps1`

It creates/updates Azure resource group + network + VM, runs guest init tasks, then runs guest update tasks task-by-task over persistent pyssh.

## Quick Start

### 1) Prerequisites
- Windows host, PowerShell 5.1+ or PowerShell 7+
- Azure CLI (`az`) and authenticated session (`az login`)
- Admin terminal (for `.cmd` launcher)

### 2) Create local config

```powershell
Copy-Item .env.example .env
```

Set at least:
- `VM_OS_TYPE=windows` or `VM_OS_TYPE=linux` (required in `--auto` mode)
- `VM_PASS` (strong password)

### 3) Run

```powershell
# interactive
.\az-vm.cmd create --windows

# unattended
.\az-vm.cmd create --auto --windows
.\az-vm.cmd create --auto --linux
```

## Commands
- `create`
  - create missing resources
  - supports step slicing: `--to-step`, `--from-step`, `--single-step`
- `update`
  - re-run create-or-update operations on existing resources
  - supports step slicing: `--to-step`, `--from-step`, `--single-step`
- `change`
  - no-parameter call starts interactive RG + VM + region + VM size picker flow
  - `--vm-size=<sku>`: in-place VM resize
  - `--vm-region=<region>`: snapshot-based region migration with target-side rollback cleanup
  - OS disk migration is supported in this flow (attached data disks must be handled separately)
  - supports combined use: region migration first, then size change
- `exec`
  - run one init or update task directly (`--init-task` / `--update-task`)
  - no-parameter call opens interactive persistent pyssh REPL session
  - optional scope: `--group=<resource-group>`
- `delete`
  - purge selected resources: `--target=group|network|vm|disk`
  - optional scope: `--group=<resource-group>`
  - non-interactive approval: `--yes`

## Help UX
- `--help`
  - quick global overview with command list, option summary, and quick examples
  - works as global flag (`az-vm --help`) and command flag (`az-vm create --help`)
- `help`
  - detailed command documentation with richer examples
  - supports topic filter:
    - `az-vm help`
    - `az-vm help create`
    - `az-vm help --command=change`

## Run Mode
- `interactive` (default)
- `--auto` / `-a`

## OS Selection
- CLI: `--windows` or `--linux`
- `.env`: `VM_OS_TYPE=windows|linux`
- interactive fallback when unresolved (default choice: windows)

Selection precedence:
1. CLI flag
2. `.env` value
3. interactive prompt

## Step Flow
1. Resolve config + VM OS type
2. Check region/image/VM size/disk compatibility
3. Resource group handling
4. Network provisioning (VNet/Subnet/NSG/PublicIP/NIC)
5. Load and prepare init task files
6. Load and prepare update task files
7. VM create/update
8. Guest execution
   - Init tasks (Windows + Linux): one-time on first VM creation with `az vm run-command` task-batch execution
   - update tasks: pyssh persistent session task-by-task
9. Print SSH/RDP details

## Task Catalog Layout

```text
linux/
  init/*.sh
  update/*.sh
windows/
  init/*.ps1
  init/disabled/*.ps1
  update/*.ps1
  update/disabled/*.ps1
```

Filename pattern is enforced:
- `NN-verb-topic.ext`
- 2-digit order + 2-5 English words (kebab-case)
- files under `disabled/` are discovered but ignored for execution

## Configuration
Use root `.env`.

Generic keys (shared):
- `SERVER_NAME`, `AZ_LOCATION`
- `NAMING_TEMPLATE_ACTIVE`, `RESOURCE_GROUP_TEMPLATE`
- `RESOURCE_GROUP`, `VNET_NAME`, `SUBNET_NAME`, `NSG_NAME`, `NSG_RULE_NAME`, `PUBLIC_IP_NAME`, `NIC_NAME`
- `VM_NAME`, `VM_IMAGE`, `VM_SIZE`, `VM_STORAGE_SKU`, `VM_DISK_NAME`, `VM_DISK_SIZE_GB`
- `VM_USER`, `VM_PASS`, `VM_ASSISTANT_USER`, `VM_ASSISTANT_PASS`
- `SSH_PORT`, `TCP_PORTS`
- `VM_INIT_TASK_DIR`, `VM_UPDATE_TASK_DIR`
- `TASK_OUTCOME_MODE=continue|strict`
- `SSH_MAX_RETRIES`, `PYSSH_CLIENT_PATH`

Windows execution notes:
- Windows Step 8 update flow is forced to strict mode (fail-fast).
- Windows update task execution uses single-attempt policy (no retry).
- Windows init runs only when the VM is newly created in the current run.

Optional platform fallback keys (used only when generic key is empty):
- `WIN_*`, `LIN_*`
  - examples: `WIN_VM_IMAGE`, `LIN_VM_IMAGE`, `WIN_VM_INIT_TASK_DIR`, `LIN_VM_UPDATE_TASK_DIR`

Naming notes:
- Active profile is `regional_v1`.
- Region code is resolved from Azure location (for example `austriaeast -> ate1`, `centralindia -> inc1`, `westus2 -> usw2`).
- Recommended template shape:
  - `RESOURCE_GROUP_TEMPLATE=rg-{SERVER_NAME}-{REGION_CODE}`
  - `VM_NAME_TEMPLATE=vm-{SERVER_NAME}-{REGION_CODE}-n{N}`
  - `VM_DISK_NAME_TEMPLATE=disk-{SERVER_NAME}-{REGION_CODE}-n{N}`
  - `VNET_NAME_TEMPLATE=net-{SERVER_NAME}-{REGION_CODE}-n{N}`

## Logs
One transcript file per run:
- `az-vm-log-ddMMMyy-HHmmss.txt`

## Connection Output
At Step 9:
- SSH commands for `manager` and `assistant`
- Windows flow also prints RDP commands for both users

## Development Notes
- Main orchestrator: `az-vm.ps1`
- Launcher: `az-vm.cmd`
- Compatibility tests:
  - `tests/ps-compat-smoke.ps1`
  - `tests/run-ps-compat-matrix.ps1`
  - `tests/run-quality-audit.ps1`
  - `tests/run-history-replay.ps1`

Audit commands:
- `powershell -File .\tests\run-quality-audit.ps1`
- `powershell -File .\tests\run-history-replay.ps1 -Days 2`
