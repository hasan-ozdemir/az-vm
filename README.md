# az-vm

Unified Azure VM provisioning toolkit for Windows and Linux with one launcher:
- `az-vm.cmd`
- `az-vm.ps1`

It creates/updates Azure resource group + network + VM, runs guest init tasks, then runs guest update tasks task-by-task over persistent pyssh.

## Architecture

`az-vm.ps1` now acts as an entrypoint and loads domain modules from `modules/`:
- `modules/core/` shared runtime helpers
- `modules/config/` env/config resolution
- `modules/azure/` Azure API/CLI resource operations
- `modules/platform/` guest/OS specific helpers
- `modules/tasks/` run-command + pyssh task execution
- `modules/ui/` picker/help/output flows
- `modules/commands/` orchestration and command handlers

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
- `VM_ADMIN_PASS` (strong password)

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
- `config`
  - interactive configuration flow up to resource-group preview
  - runs Step 1 + Step 2 + Step 3 preview and exits without resource mutation
  - writes selected values to `.env` for subsequent `create` runs
- `move`
  - move VM to target region (snapshot-based region migration with rollback cleanup)
  - parameterized usage: `--group=<resource-group> --vm=<vm-name> --vm-region=<region>`
  - interactive target region picker when `--vm-region=` is empty
- `resize`
  - in-place VM size update
  - parameterized usage: `--group=<resource-group> --vm=<vm-name> --vm-size=<sku>`
  - interactive VM size picker when `--vm-size=` is empty
- `set`
  - apply VM feature flags
  - supports: `--hibernation=on|off`, `--nested-virtualization=on|off`
  - parameterized usage: `--group=<resource-group> --vm=<vm-name>`
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
    - `az-vm help move`

## Run Mode
- `interactive` (default)
- `--auto` / `-a`
- `--auto` applies to `create`, `update`, and `delete` commands.

## OS Selection
- CLI: `--windows` or `--linux`
- `.env`: `VM_OS_TYPE=windows|linux`
- interactive selection when unresolved (default choice: windows)

Selection precedence:
1. CLI flag
2. `.env` value
3. interactive prompt

## Step Flow
1. `config`: resolve config + VM OS type + compatibility checks
2. `group`: resource group handling
3. `network`: VNet/Subnet/NSG/PublicIP/NIC
4. `vm-deploy`: VM create/update
5. `vm-init`: guest init tasks via `az vm run-command` (task-batch)
6. `vm-update`: guest update tasks via persistent pyssh session (task-by-task)
7. `vm-summary`: print SSH/RDP details

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
- `VM_NAME`, `AZ_LOCATION`
- `NAMING_TEMPLATE_ACTIVE`, `RESOURCE_GROUP_TEMPLATE`
- `RESOURCE_GROUP`, `VNET_NAME`, `SUBNET_NAME`, `NSG_NAME`, `NSG_RULE_NAME`, `PUBLIC_IP_NAME`, `NIC_NAME`
- `VM_IMAGE`, `VM_SIZE`, `VM_STORAGE_SKU`, `VM_DISK_NAME`, `VM_DISK_SIZE_GB`
- `VM_ADMIN_USER`, `VM_ADMIN_PASS`, `VM_ASSISTANT_USER`, `VM_ASSISTANT_PASS`
- `SSH_PORT`, `TCP_PORTS`
- `TASK_OUTCOME_MODE=continue|strict`
- `SSH_MAX_RETRIES`, `PYSSH_CLIENT_PATH`

Windows execution notes:
- Windows `vm-update` flow is forced to strict mode (fail-fast).
- Windows update task execution uses single-attempt policy (no retry).
- Windows init runs only when the VM is newly created in the current run.

Optional platform-specific keys (used only when generic key is empty):
- `WIN_*`, `LIN_*`
  - examples: `WIN_VM_IMAGE`, `LIN_VM_IMAGE`, `WIN_VM_INIT_TASK_DIR`, `LIN_VM_INIT_TASK_DIR`, `WIN_VM_UPDATE_TASK_DIR`, `LIN_VM_UPDATE_TASK_DIR`

Task catalog selection:
1. `WIN_VM_INIT_TASK_DIR` / `WIN_VM_UPDATE_TASK_DIR` for Windows
2. `LIN_VM_INIT_TASK_DIR` / `LIN_VM_UPDATE_TASK_DIR` for Linux
3. built-in defaults (`windows/init`, `windows/update`, `linux/init`, `linux/update`)

Naming notes:
- Active profile is `regional_v1`.
- Region code is resolved from Azure location (for example `austriaeast -> ate1`, `centralindia -> inc1`, `westus2 -> usw2`).
- `VM_NAME` is the primary naming seed and the actual Azure VM name.
- Recommended template shape:
  - `RESOURCE_GROUP_TEMPLATE=rg-{VM_NAME}-{REGION_CODE}-g{N}`
  - `VM_DISK_NAME_TEMPLATE=disk-{VM_NAME}-{REGION_CODE}-n{N}`
  - `VNET_NAME_TEMPLATE=net-{VM_NAME}-{REGION_CODE}-n{N}`

## Logs
One transcript file per run:
- `az-vm-log-ddMMMyy-HHmmss.txt`

## Connection Output
At `vm-summary`:
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
