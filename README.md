# az-vm

`az-vm` is a unified Azure VM provisioning and lifecycle toolkit for Windows and Linux. It gives one operator-facing entrypoint for provisioning, updating, inspecting, connecting to, repairing, resizing, moving, and deleting managed Azure VMs with deterministic task execution and explicit validation before mutation.

## Table Of Contents
- [Why az-vm Exists](#why-az-vm-exists)
  - [What It Does](#what-it-does)
  - [Problems It Solves](#problems-it-solves)
  - [Who It Is For](#who-it-is-for)
  - [When To Use It](#when-to-use-it)
  - [When Not To Use It](#when-not-to-use-it)
- [Quick Start](#quick-start)
  - [Prerequisites](#prerequisites)
  - [Repository Layout](#repository-layout)
  - [First Configuration Pass](#first-configuration-pass)
  - [First End-To-End Run](#first-end-to-end-run)
  - [Daily Operator Shortcuts](#daily-operator-shortcuts)
- [Core Mental Model](#core-mental-model)
  - [One Entrypoint, Two Platforms](#one-entrypoint-two-platforms)
  - [Top-Level Orchestration Steps](#top-level-orchestration-steps)
  - [Init Tasks Versus Update Tasks](#init-tasks-versus-update-tasks)
  - [Interactive Versus Auto Mode](#interactive-versus-auto-mode)
  - [Naming And Managed Resource Rules](#naming-and-managed-resource-rules)
- [Architecture From Zero To Hero](#architecture-from-zero-to-hero)
  - [Entrypoints And Runtime Modules](#entrypoints-and-runtime-modules)
  - [Configuration Resolution](#configuration-resolution)
  - [Task Catalog Model](#task-catalog-model)
  - [Windows And Linux Execution Model](#windows-and-linux-execution-model)
  - [End-To-End Create And Update Flow](#end-to-end-create-and-update-flow)
  - [Safety Model And Failure Handling](#safety-model-and-failure-handling)
  - [Documentation, History, And Release Discipline](#documentation-history-and-release-discipline)
- [Configuration Guide](#configuration-guide)
  - [Runtime Precedence](#runtime-precedence)
  - [High-Value `.env` Keys](#high-value-env-keys)
  - [Platform-Specific Settings](#platform-specific-settings)
  - [Connection And Task Settings](#connection-and-task-settings)
- [Command Guide](#command-guide)
  - [Global Options](#global-options)
  - [`configure`](#configure)
  - [`create`](#create)
  - [`update`](#update)
  - [`group`](#group)
  - [`show`](#show)
  - [`do`](#do)
  - [`exec`](#exec)
  - [`ssh`](#ssh)
  - [`rdp`](#rdp)
  - [`move`](#move)
  - [`resize`](#resize)
  - [`set`](#set)
  - [`delete`](#delete)
  - [`help`](#help)
- [Task Authoring And Execution](#task-authoring-and-execution)
  - [Catalog Ownership](#catalog-ownership)
  - [Task Naming Rules](#task-naming-rules)
  - [Timeouts, Priority, And Enable Flags](#timeouts-priority-and-enable-flags)
  - [Direct Task Execution With `exec`](#direct-task-execution-with-exec)
- [Practical Operating Scenarios](#practical-operating-scenarios)
  - [Provision A New Windows VM](#provision-a-new-windows-vm)
  - [Rerun Update Tasks On An Existing VM](#rerun-update-tasks-on-an-existing-vm)
  - [Resize In Place](#resize-in-place)
  - [Move To Another Region](#move-to-another-region)
  - [Inspect And Control Power State](#inspect-and-control-power-state)
  - [Connect With SSH Or RDP](#connect-with-ssh-or-rdp)
- [Troubleshooting Guide](#troubleshooting-guide)
  - [Validation Failures](#validation-failures)
  - [Task Failures](#task-failures)
  - [Connection Failures](#connection-failures)
  - [Move And Resize Expectations](#move-and-resize-expectations)
- [Developer Workflow](#developer-workflow)
  - [Branching And Local Hooks](#branching-and-local-hooks)
  - [Quality Gates](#quality-gates)
  - [Documentation Contract](#documentation-contract)
  - [Prompt History Rule](#prompt-history-rule)
- [Documentation Set](#documentation-set)
- [License And Sponsorship](#license-and-sponsorship)

## Why az-vm Exists

### What It Does
- Provisions Azure infrastructure for one managed Windows or Linux VM from one orchestrator.
- Applies deterministic guest initialization and guest update task catalogs.
- Gives operators lifecycle commands for status, start, restart, stop, deallocate, hibernate, move, resize, connect, inspect, and delete flows.
- Keeps command wording, configuration behavior, and execution semantics as parallel as possible across Windows and Linux.

### Problems It Solves
- Eliminates ad hoc VM setup drift caused by one-off portal changes and manual guest tweaking.
- Replaces hidden or implicit guest scripts with explicit, catalog-driven task ordering and timeouts.
- Reduces unsafe Azure mutations by validating names, regions, SKUs, image values, and state before mutating resources.
- Gives one repeatable operator workflow for create, update, repair, inspect, connect, and cutover work.
- Captures repo behavior, release notes, and development decisions in the same repository instead of splitting them across chat history and tribal knowledge.

### Who It Is For
- Operators who want reproducible Azure VM environments without rebuilding the full stack by hand every time.
- Maintainers who need Windows and Linux parity under one command surface.
- Developers who want infrastructure, guest tasks, and operator workflows documented together.
- Small teams that value pragmatic automation, explicit state, and readable PowerShell over opaque orchestration layers.

### When To Use It
- When one managed VM per flow is the main unit of operation.
- When you need repeatable Windows or Linux workstation/server-like environments in Azure.
- When you need deterministic reruns of guest-side tasks after provisioning.
- When move, resize, hibernation, and isolated task reruns need to stay operator-friendly.

### When Not To Use It
- When you need large-scale fleet orchestration across many VMs at once.
- When you want a generic IaC module library rather than one opinionated operator toolkit.
- When you want a broad public open-source license with unrestricted commercial use.

## Quick Start

### Prerequisites
- Windows host with PowerShell and the Azure CLI available.
- Azure subscription access with permission to create, update, and delete compute and networking resources.
- Local Git for the repo workflow and hook support.
- Python available when the repo-managed pyssh helper is needed.

### Repository Layout
- `az-vm.cmd`: elevated launcher for Windows operators.
- `az-vm.ps1`: unified orchestrator entrypoint.
- `modules/`: core runtime, UI/runtime logic, orchestration helpers, and task helpers.
- `windows/init/`, `windows/update/`: Windows task directories plus catalog JSON files.
- `linux/init/`, `linux/update/`: Linux task directories plus catalog JSON files.
- `tools/`: pyssh helper, scripts, Windows helper assets, and git-hook toggles.
- `tests/`: local quality and contract checks.
- `docs/prompt-history.md`: English-normalized historical ledger of completed prompt/summary pairs.

### First Configuration Pass
1. Copy `.env.example` to `.env`.
2. Set the minimum values:
   - `VM_OS_TYPE`
   - `VM_NAME`
   - `AZ_LOCATION`
   - `VM_ADMIN_USER`, `VM_ADMIN_PASS`
   - platform-specific image and size keys as needed
3. Optionally set `company_name` to control the default Google Chrome `--profile-directory` used by repo-managed Windows public desktop web shortcuts.

### First End-To-End Run
```powershell
.\az-vm.cmd configure
.\az-vm.cmd create --auto --windows
.\az-vm.cmd do --vm-action=status --vm-name=examplevm
.\az-vm.cmd rdp --vm-name=examplevm
```

### Daily Operator Shortcuts
```powershell
.\az-vm.cmd show --group=rg-examplevm-sec1-g1
.\az-vm.cmd do --vm-action=start --group=rg-examplevm-sec1-g1 --vm-name=examplevm
.\az-vm.cmd exec --update-task=27 --group=rg-examplevm-sec1-g1 --vm-name=examplevm --windows
.\az-vm.cmd resize --group=rg-examplevm-sec1-g1 --vm-name=examplevm --vm-size=Standard_D4as_v5 --windows
```

## Core Mental Model

### One Entrypoint, Two Platforms
`az-vm.ps1` is the only orchestrator. Windows and Linux are treated as two platform flavors of the same operator model. Differences are allowed only where the guest OS or Azure platform requirements genuinely differ.

### Top-Level Orchestration Steps
`az-vm` uses these top-level steps:
1. `configure`
2. `group`
3. `network`
4. `vm-deploy`
5. `vm-init`
6. `vm-update`
7. `vm-summary`

`create` and `update` can run the full chain or a selected window of steps by using `--from-step`, `--to-step`, or `--single-step`.

### Init Tasks Versus Update Tasks
- `vm-init` is Azure Run Command driven and is used for early guest bootstrap.
- `vm-update` is pyssh driven and is used for richer task-by-task update flows after the VM is reachable.
- Both stages use catalog JSON files as the source of truth for ordering, timeout, and enable/disable state.

### Interactive Versus Auto Mode
- Interactive mode is the default and prompts when required values are missing.
- `--auto` is for unattended `create`, `update`, and `delete` flows.
- Operator commands such as `show`, `do`, `ssh`, and `rdp` stay direct and do not require `--auto`.

### Naming And Managed Resource Rules
- `VM_NAME` is the single naming seed.
- Managed names are template-driven and deterministic.
- Regional uniqueness is suffix-based and explicit.
- Runtime code validates names before Azure mutation.

## Architecture From Zero To Hero

### Entrypoints And Runtime Modules
- `az-vm.cmd` exists to give Windows operators a simple launcher path.
- `az-vm.ps1` loads the runtime modules and dispatches the command surface.
- `modules/core/` defines shared contracts, parsing helpers, help text, naming logic, and catalog behavior.
- `modules/ui/` contains operator-oriented runtime behavior, prompts, status output, and command dispatch decisions.
- `modules/commands/` and `modules/tasks/` hold orchestration and task-specific runtime support.

### Configuration Resolution
Runtime precedence is:
1. CLI override
2. `.env`
3. hard-coded default

This matters because:
- command-line overrides are the safest way to test one change without rewriting local defaults
- `.env.example` is the committed contract
- `.env` remains local and untracked

### Task Catalog Model
Each task directory has a catalog JSON file that owns:
- execution priority
- enable/disable state
- timeout per task

The runtime never auto-writes or auto-syncs catalog files. Missing entries fall back to:
- `priority=1000`
- `enabled=true`
- `timeout=180`

### Windows And Linux Execution Model
- Windows and Linux use the same overall orchestration sequence.
- The guest execution language differs by platform:
  - Windows tasks are PowerShell
  - Linux tasks are shell scripts
- Connection and task transport differ by stage:
  - Azure Run Command for init
  - pyssh for update and isolated exec flows

### End-To-End Create And Update Flow
1. Resolve platform, config, and command intent.
2. Validate naming, region, image, and SKU inputs.
3. Resolve or select the active managed resource group.
4. Create or reconcile network resources.
5. Create or update the VM.
6. Run init tasks.
7. Run update tasks.
8. Print a final VM/resource summary.

The same mental model applies to `update`, except that existing managed resources are reconciled instead of always starting from empty state.

### Safety Model And Failure Handling
- Validation happens before destructive Azure work.
- Friendly failures include a short reason and a corrective hint.
- Retry behavior is bounded and explicit.
- Isolated reruns are preferred over destructive rebuild loops unless a rebuild is clearly what the operator requested.

### Documentation, History, And Release Discipline
- `AGENTS.md` defines the engineering contract.
- `README.md` is the operator and contributor manual.
- `CHANGELOG.md` records full project history.
- `release-notes.md` summarizes the current documented release.
- `roadmap.md` captures forward work by value and priority.
- `docs/prompt-history.md` records completed prompt/summary pairs in English-normalized form.

## Configuration Guide

### Runtime Precedence
- CLI override wins over everything else.
- `.env` is the main local working configuration file.
- Hard-coded defaults are the last fallback and should not be treated as the main operator contract.

### High-Value `.env` Keys
- `VM_OS_TYPE`: default platform for auto flows.
- `VM_NAME`: actual Azure VM name and the naming seed for derived resources.
- `company_name`: default Chrome `--profile-directory` for repo-managed Windows web shortcuts.
- `AZ_LOCATION`: default Azure region.
- `RESOURCE_GROUP`, `VNET_NAME`, `SUBNET_NAME`, `NSG_NAME`, `PUBLIC_IP_NAME`, `NIC_NAME`, `VM_DISK_NAME`: optional explicit resource-name overrides.

### Platform-Specific Settings
- Windows:
  - `WIN_VM_IMAGE`
  - `WIN_VM_SIZE`
  - `WIN_VM_DISK_SIZE_GB`
  - `WIN_VM_INIT_TASK_DIR`
  - `WIN_VM_UPDATE_TASK_DIR`
- Linux:
  - `LIN_VM_IMAGE`
  - `LIN_VM_SIZE`
  - `LIN_VM_DISK_SIZE_GB`
  - `LIN_VM_INIT_TASK_DIR`
  - `LIN_VM_UPDATE_TASK_DIR`

### Connection And Task Settings
- `VM_ADMIN_USER`, `VM_ADMIN_PASS`
- `VM_ASSISTANT_USER`, `VM_ASSISTANT_PASS`
- `VM_SSH_PORT`, `VM_RDP_PORT`
- `AZ_COMMAND_TIMEOUT_SECONDS`
- `SSH_CONNECT_TIMEOUT_SECONDS`
- `SSH_TASK_TIMEOUT_SECONDS`
- `VM_TASK_OUTCOME_MODE`
- `SSH_MAX_RETRIES`
- `PYSSH_CLIENT_PATH`
- `TCP_PORTS`

## Command Guide

### Global Options
- `--auto[=true|false]`: unattended create/update/delete.
- `--perf[=true|false]`: timing output.
- `--windows`, `--linux`: force platform for supported commands.
- `--help`: show overview or command-specific help.

### `configure`
Purpose: preview and validate the target configuration before Azure mutation.

Typical usage:
```powershell
.\az-vm.cmd configure
.\az-vm.cmd configure --windows
```

What to expect:
- interactive selection or confirmation when needed
- validation-focused output
- no destructive Azure mutation

### `create`
Purpose: build a managed VM flow from the selected step range.

Usage patterns:
```powershell
.\az-vm.cmd create --auto --windows
.\az-vm.cmd create --single-step=network --linux
.\az-vm.cmd create --from-step=vm-deploy --to-step=vm-summary --perf
```

Operator expectations:
- validates config before mutation
- creates missing resources
- runs init and update task windows unless the step range slices them out
- success ends with a summary of the managed VM state

Failure patterns:
- invalid region/image/SKU
- resource naming conflicts
- guest task failures depending on `VM_TASK_OUTCOME_MODE`

### `update`
Purpose: rerun create-or-update logic against existing managed resources.

Usage patterns:
```powershell
.\az-vm.cmd update --auto
.\az-vm.cmd update --to-step=vm-init --auto
.\az-vm.cmd update --single-step=vm-update --windows
```

Operator expectations:
- keeps the same orchestration model as `create`
- targets already-managed resources
- useful for post-fix reruns and guest task refreshes

### `group`
Purpose: list or select managed resource groups.

Usage patterns:
```powershell
.\az-vm.cmd group --list=examplevm
.\az-vm.cmd group --select=rg-examplevm-sec1-g1
```

What users see:
- a human-readable group selection or inventory path
- direct control over the active managed context

### `show`
Purpose: print a readable system/configuration inventory for managed resources and VMs.

Usage patterns:
```powershell
.\az-vm.cmd show
.\az-vm.cmd show --group=rg-examplevm-sec1-g1
```

Good for:
- pre-mutation inspections
- post-create or post-move confirmation
- support and diagnostics snapshots

### `do`
Purpose: inspect or change one VM lifecycle state.

Supported actions:
- `status`
- `start`
- `restart`
- `stop`
- `deallocate`
- `hibernate`

Usage patterns:
```powershell
.\az-vm.cmd do --vm-action=status --vm-name=examplevm
.\az-vm.cmd do --vm-action=start --group=rg-examplevm-sec1-g1 --vm-name=examplevm
.\az-vm.cmd do --vm-action=deallocate --group=rg-examplevm-sec1-g1 --vm-name=examplevm
.\az-vm.cmd do --vm-action=hibernate --group=rg-examplevm-sec1-g1 --vm-name=examplevm
```

Behavior notes:
- if parameters are omitted, the command falls back to interactive group/VM/action selection
- mutating actions validate the current power/provisioning state before calling Azure
- `hibernate` follows Azure hibernation semantics and deallocates the VM

Friendly refusal examples:
- trying `restart` on a stopped VM
- trying `hibernate` when the VM is not running
- trying a mutating action while the VM is in a transitional Azure state

### `exec`
Purpose: run one init task, one update task, or open an interactive remote shell path.

Usage patterns:
```powershell
.\az-vm.cmd exec --init-task=01 --group=rg-examplevm-sec1-g1 --vm-name=examplevm
.\az-vm.cmd exec --update-task=27 --group=rg-examplevm-sec1-g1 --vm-name=examplevm --windows
.\az-vm.cmd exec --linux
```

Behavior notes:
- direct task runs resolve only the selected VM plus task context
- no broad resource-inventory traversal is needed for direct one-task execution
- interactive shell mode is used when no task selector is provided

Failure patterns:
- unknown task number
- task timeout
- guest transport failure
- strict task outcome mode halting a stage on first failure

### `ssh`
Purpose: launch the local Windows OpenSSH client for a managed VM.

Usage patterns:
```powershell
.\az-vm.cmd ssh --vm-name=examplevm
.\az-vm.cmd ssh --group=rg-examplevm-sec1-g1 --vm-name=examplevm --user=assistant
```

Behavior notes:
- only runs when the target VM is already running
- uses current managed VM state and connection settings from config/runtime
- politely refuses and suggests `az-vm do --vm-action=start` when the VM is not running

### `rdp`
Purpose: launch the local Remote Desktop client for a managed Windows VM.

Usage patterns:
```powershell
.\az-vm.cmd rdp --vm-name=examplevm
.\az-vm.cmd rdp --group=rg-examplevm-sec1-g1 --vm-name=examplevm --user=assistant
```

Behavior notes:
- only runs when the target VM is already running
- stages credentials via `cmdkey` and launches `mstsc.exe`
- politely refuses and suggests `az-vm do --vm-action=start` when the VM is not running

### `move`
Purpose: move a managed VM to another Azure region with a health-gated cutover.

Usage pattern:
```powershell
.\az-vm.cmd move --group=rg-examplevm-ate1-g1 --vm-name=examplevm --vm-region=swedencentral
```

Observed reference timing:
- live reference for `austriaeast -> swedencentral`, `Standard_D4as_v5`, `127 GB` OS disk: about `25-30 minutes`
- the longest phase was cross-region snapshot copy at about `17-19 minutes`

Move flow:
1. Validate source group, target region, SKU availability, and cutover safety rules.
2. Deallocate the source VM.
3. Create the source snapshot and the target-region copy.
4. Wait for target snapshot copy completion.
5. Rebuild target-side network, disk, and VM.
6. Re-apply hibernation state where needed and start the target VM.
7. Run target health checks.
8. Delete the old source group only after the target is confirmed healthy.

What can fail:
- invalid target region or unavailable SKU
- Azure snapshot-copy delays
- target health gate failure
- old source cleanup failure after successful cutover

### `resize`
Purpose: change the VM size in-place within the current region.

Usage patterns:
```powershell
.\az-vm.cmd resize --group=rg-examplevm-sec1-g1 --vm-name=examplevm --vm-size=Standard_D4as_v5
.\az-vm.cmd resize --group=rg-examplevm-sec1-g1 --vm-name=examplevm --vm-size=Standard_D2as_v5 --windows
.\az-vm.cmd resize
```

Behavior notes:
- same-region only
- fully specified calls run directly
- parameterless use falls back to interactive target and size selection
- `--windows` and `--linux` act as expected-platform assertions

### `set`
Purpose: apply VM feature flags.

Supported flags:
- `--hibernation=on|off`
- `--nested-virtualization=on|off`

Usage patterns:
```powershell
.\az-vm.cmd set --group=rg-examplevm-sec1-g1 --vm-name=examplevm --hibernation=off
.\az-vm.cmd set --group=rg-examplevm-sec1-g1 --vm-name=examplevm --nested-virtualization=off
.\az-vm.cmd set --group=rg-examplevm-sec1-g1 --vm-name=examplevm --hibernation=on --nested-virtualization=off
```

### `delete`
Purpose: delete a selected scope from a managed resource group.

Supported targets:
- `group`
- `network`
- `vm`
- `disk`

Usage patterns:
```powershell
.\az-vm.cmd delete --target=group --group=rg-examplevm-sec1-g1 --yes
.\az-vm.cmd delete --target=vm --group=rg-examplevm-sec1-g1 --yes
```

Behavior notes:
- destructive by design
- requires clear target selection
- `--yes` is for non-interactive confirmation bypass

### `help`
Purpose: print the quick overview or one-command help.

Usage patterns:
```powershell
.\az-vm.cmd --help
.\az-vm.cmd help
.\az-vm.cmd help move
```

## Task Authoring And Execution

### Catalog Ownership
Catalog JSON files are the source of truth for task ordering, enable state, and timeouts. Runtime code must not rewrite them automatically.

### Task Naming Rules
- `NN-verb-topic.ext`
- `NN` is two digits
- 2-5 English words in kebab-case
- `.ps1` for Windows
- `.sh` for Linux

### Timeouts, Priority, And Enable Flags
- catalog entry present: use catalog values
- missing `priority`: default to `1000`
- missing `timeout`: default to `180`
- missing entry entirely: `priority=1000`, `enabled=true`, `timeout=180`

### Direct Task Execution With `exec`
Direct `exec --init-task` and `exec --update-task` are the main diagnosis path when one task needs to be rerun without replaying the entire orchestration chain.

## Practical Operating Scenarios

### Provision A New Windows VM
```powershell
.\az-vm.cmd create --auto --windows
.\az-vm.cmd do --vm-action=status --vm-name=examplevm
.\az-vm.cmd rdp --vm-name=examplevm
```

### Rerun Update Tasks On An Existing VM
```powershell
.\az-vm.cmd update --single-step=vm-update --auto --windows
.\az-vm.cmd exec --update-task=20 --group=rg-examplevm-sec1-g1 --vm-name=examplevm --windows
```

### Resize In Place
```powershell
.\az-vm.cmd resize --group=rg-examplevm-sec1-g1 --vm-name=examplevm --vm-size=Standard_D4as_v5 --windows
.\az-vm.cmd resize --group=rg-examplevm-sec1-g1 --vm-name=examplevm --vm-size=Standard_D2as_v5 --windows
```

### Move To Another Region
```powershell
.\az-vm.cmd move --group=rg-examplevm-ate1-g1 --vm-name=examplevm --vm-region=swedencentral
```

### Inspect And Control Power State
```powershell
.\az-vm.cmd do --vm-action=status --vm-name=examplevm
.\az-vm.cmd do --vm-action=start --group=rg-examplevm-sec1-g1 --vm-name=examplevm
.\az-vm.cmd do --vm-action=stop --group=rg-examplevm-sec1-g1 --vm-name=examplevm
```

### Connect With SSH Or RDP
```powershell
.\az-vm.cmd do --vm-action=start --group=rg-examplevm-sec1-g1 --vm-name=examplevm
.\az-vm.cmd ssh --group=rg-examplevm-sec1-g1 --vm-name=examplevm
.\az-vm.cmd rdp --group=rg-examplevm-sec1-g1 --vm-name=examplevm --user=assistant
```

## Troubleshooting Guide

### Validation Failures
- Check region, image, and SKU first.
- Confirm the naming seed and resource templates.
- Prefer fixing config and rerunning the isolated failing command instead of restarting from zero immediately.

### Task Failures
- Rerun the failing task with `exec`.
- Check task catalog timeout and enabled state.
- Use `VM_TASK_OUTCOME_MODE=strict` when you want the stage to stop at the first failure.

### Connection Failures
- Check `do --vm-action=status`.
- Confirm the VM is running before `ssh` or `rdp`.
- Verify guest firewall, NSG exposure, and configured ports together.

### Move And Resize Expectations
- `move` is a deliberate cutover operation with downtime and cross-region copy time.
- `resize` is same-region only and is much smaller in scope than `move`.
- Both commands validate before mutation and return friendly hints on invalid state or configuration.

## Developer Workflow

### Branching And Local Hooks
- Use a working branch for changes.
- Enable local hooks with:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\enable-git-hooks.ps1
```
- Disable them with:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\disable-git-hooks.ps1
```

### Quality Gates
Run these locally:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\code-quality-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\documentation-contract-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\powershell-compatibility-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\az-vm-smoke-tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bash-syntax-check.ps1
```

### Documentation Contract
When a prompt changes repo files:
- update `README.md`, `AGENTS.md`, `.env.example`, tests, or help text when the contract changes
- update `CHANGELOG.md` and `release-notes.md` in the same final change set before commit
- update `docs/prompt-history.md` with the English-normalized prompt and final summary

### Prompt History Rule
- Repo-changing prompts must be recorded.
- Non-mutating prompts are recorded only after explicit user confirmation.
- Recorded entries are stored in English. If the original dialog was not English, it is translated before recording.

## Documentation Set
- `AGENTS.md`: engineering contract and collaboration rules.
- `README.md`: operator and contributor manual.
- `CHANGELOG.md`: complete project history.
- `release-notes.md`: current documented release summary.
- `roadmap.md`: forward plan organized by business value.
- `docs/prompt-history.md`: English-normalized prompt ledger.

## License And Sponsorship
This repository is distributed under the custom non-commercial license in [LICENSE](LICENSE).

High-level intent:
- learning, teaching, evaluation, and private non-commercial modification are allowed
- public redistribution and commercial use require developer permission
- commercial licensing and sponsorship discussions should be directed to the developer

If this project saves time, reduces operational risk, or is useful in your environment, sponsorship helps keep the documentation, testing, and VM automation work moving forward.
