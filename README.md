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
  - [Quick Accelerator](#quick-accelerator)
- [Customer Business Value](#customer-business-value)
  - [Executive Summary](#executive-summary)
  - [Delivered VM Outcome Matrix](#delivered-vm-outcome-matrix)
- [Developer Benefits](#developer-benefits)
  - [Why Developers Move Faster](#why-developers-move-faster)
  - [Daily Maintainer Flow](#daily-maintainer-flow)
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
  - [`list`](#list)
  - [`show`](#show)
  - [`do`](#do)
  - [`task`](#task)
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
- [Practical And Extensive Usage Scenarios](#practical-and-extensive-usage-scenarios)
  - [Create A Fresh Managed VM](#create-a-fresh-managed-vm)
  - [Update An Existing Managed VM](#update-an-existing-managed-vm)
  - [Inspect Managed Resource Groups And VM State](#inspect-managed-resource-groups-and-vm-state)
  - [Run One Task Or Open A Remote Shell](#run-one-task-or-open-a-remote-shell)
  - [Resize Compute Or OS Disk In Place](#resize-compute-or-os-disk-in-place)
  - [Move Regions And Clean Up Safely](#move-regions-and-clean-up-safely)
  - [Delete Only The Scope You Intend](#delete-only-the-scope-you-intend)
- [Troubleshooting Guide](#troubleshooting-guide)
  - [Validation Failures](#validation-failures)
  - [Task Failures](#task-failures)
  - [Connection Failures](#connection-failures)
  - [Move And Resize Expectations](#move-and-resize-expectations)
- [Developer Workflow](#developer-workflow)
  - [Branching And Local Hooks](#branching-and-local-hooks)
  - [Quality Gates](#quality-gates)
  - [Support And Contribution Paths](#support-and-contribution-paths)
  - [Documentation Contract](#documentation-contract)
  - [Prompt History Rule](#prompt-history-rule)
- [Documentation Set](#documentation-set)
- [License And Sponsorship](#license-and-sponsorship)

## Why az-vm Exists

### What It Does
- Provisions Azure infrastructure for one managed Windows or Linux VM from one orchestrator.
- Applies deterministic guest initialization and guest update task catalogs.
- Gives operators lifecycle commands for status, start, restart, reapply, stop, deallocate, hibernate-stop, hibernate-deallocate, move, resize, connect, inspect, and delete flows.
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
- `modules/azvm-runtime-manifest.ps1`: deterministic ordered manifest of the runtime leaf files loaded by `az-vm.ps1`.
- `modules/core/`: shared runtime foundations, CLI/system helpers, task discovery, and host/runtime utilities.
- `modules/config/`: dotenv parsing, naming templates, region-code helpers, and config-resolution primitives.
- `modules/commands/`: command-owned implementations split by command, plus shared pipeline/context/step/feature helpers.
- `modules/ui/`: prompts, interactive selection, show/report rendering, and connection presentation helpers.
- `modules/tasks/`: Azure Run Command and persistent SSH transport/runtime helpers.
- `windows/init/`, `windows/update/`: Windows stage roots with tracked catalog-driven tasks at the root, tracked disabled tasks under `disabled/`, and local-only metadata-driven tasks under `local/` and `local/disabled/`.
- `linux/init/`, `linux/update/`: Linux stage roots with tracked catalog-driven tasks at the root, tracked disabled tasks under `disabled/`, and local-only metadata-driven tasks under `local/` and `local/disabled/`.
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
   - `VM_ASSISTANT_USER`, `VM_ASSISTANT_PASS`
   - platform-specific image and size keys as needed
3. Set `company_name`, `employee_email_address`, and `employee_full_name` for Windows flows. Repo-managed public desktop web shortcuts require all three; business shortcuts use `company_name` and personal shortcuts use the email local-part from `employee_email_address` as the Chrome `--profile-directory`. The task normalizes both sources to lowercase before writing the Chrome profile name.
4. Treat `.env` as the home for app-wide identity, secrets, and reusable overrides. Task-only constants should stay in the owning task script's top config block.

### First End-To-End Run
```powershell
.\az-vm.cmd configure
.\az-vm.cmd create --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku>
.\az-vm.cmd do --vm-action=status --vm-name=<vm-name>
.\az-vm.cmd rdp --vm-name=<vm-name>
```

### Daily Operator Shortcuts
```powershell
.\az-vm.cmd -h
.\az-vm.cmd show --group=<resource-group>
.\az-vm.cmd do --vm-action=start --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd task --list --vm-update --windows
.\az-vm.cmd resize --group=<resource-group> --vm-name=<vm-name> --vm-size=Standard_D4as_v5 --windows
```

### Quick Accelerator
If you want the fastest safe path to value, use this order:
1. Run `.\az-vm.cmd configure` and confirm the generated `.env` values.
2. Run `.\az-vm.cmd create --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku>` or `.\az-vm.cmd create --auto --linux --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku>`.
3. Run `.\az-vm.cmd show --group=<resource-group>` to verify the managed inventory while password-bearing `.env` values are redacted.
4. Run `.\az-vm.cmd do --vm-action=status --vm-name=<vm-name>` to confirm the VM is started.
5. Run `.\az-vm.cmd ssh --vm-name=<vm-name> --user=manager --test`; for Windows also run `.\az-vm.cmd rdp --vm-name=<vm-name> --user=manager --test`.

## Customer Business Value

### Executive Summary
`az-vm` compresses the time from "we need a working Azure VM" to "we have a repeatable, supportable, documented VM" into one repo-owned workflow. Instead of a portal-heavy build with hidden post-install steps, the operator gets one command surface for provisioning, guest bootstrap, guest software rollout, health capture, follow-up updates, repair actions, resizing, move operations, and eventual deletion.

For executive and customer-facing teams, the practical value is speed with lower variance:
- faster time to a usable VM
- less manual setup drift between environments
- repeatable update and repair flows after the first deployment
- clearer support handoff because runtime behavior, docs, release notes, and prompt history live together

### Delivered VM Outcome Matrix
| Outcome Area | Windows managed VM outcome | Linux managed VM outcome | Business value |
| --- | --- | --- | --- |
| Base access | Local users, OpenSSH, RDP, firewall ports, repo-managed connection flow | Local users, SSHD port config, firewall ports, repo-managed connection flow | Teams can connect and hand over access quickly without rediscovering the host setup. |
| Core tooling | PowerShell 7, Git, Python, Node.js, Azure CLI, GitHub CLI, azd, VS Code, 7-Zip, Sysinternals, FFmpeg | System package upgrade, Node capability tuning, SSHD tuning | A new VM becomes productive for cloud, scripting, and developer workflows in minutes instead of after many manual installs. |
| Developer runtime | Docker Desktop, WSL2, npm global package set, Ollama, Codex app, VS 2022 Community | Node-ready SSH environment and updated base packages | Engineering teams get a ready-to-use workstation or automation host with less first-day setup work. |
| Collaboration and daily apps | Edge, Chrome validation, Teams, WhatsApp, OneDrive, Google Drive, VLC, iTunes, iCloud | Minimal by design | Customer-facing and operator-facing daily-use software is staged consistently instead of being installed ad hoc. |
| Accessibility and remote support | AnyDesk, Windscribe, NVDA, Be My Eyes, startup flows, autologon manager, advanced Windows settings, public desktop shortcuts | Minimal by design | Support, accessibility, and assisted-operation scenarios are easier to reproduce and maintain. |
| Health and observability | Snapshot-health capture, show/report output, direct task reruns, redeploy-ready update flow | Snapshot-health capture, show/report output, direct task reruns | Troubleshooting time falls because the repo already knows how to inspect, rerun, and summarize the environment. |
| Lifecycle changes | Create fresh, destructive rebuild, update, reapply, hibernation, move, VM-size resize, managed OS disk expand, explicit shrink guidance | Create fresh, destructive rebuild, update, move, VM-size resize, managed OS disk expand, explicit shrink guidance | The same toolkit keeps working after day one, so operations do not regress to manual portal work. |

## Developer Benefits

### Why Developers Move Faster
- One orchestrator means less context switching between separate scripts for provisioning, update, connection, and repair.
- The same command surface covers Windows and Linux, so platform differences stay narrow and explicit.
- `create` now stays dedicated to one fresh managed resource group plus one fresh managed VM; `create explicit destructive rebuild flow` remains the explicit destructive rebuild path for that fresh target.
- `update` now requires an existing managed resource group and VM, then applies create-or-update operations plus `az vm redeploy` in one guided maintenance flow.
- `resize --disk-size=... --expand` gives a safe in-place managed OS disk growth path, while `resize --disk-size=... --shrink` stops early and explains the supported alternatives instead of risking data loss.
- Direct `task` and `exec` flows let maintainers inspect and rerun exactly the step or task that matters.

### Daily Maintainer Flow
1. Confirm the target with `list`, `show`, `configure`, and `do --vm-action=status`.
2. Use `create` for first deploys and fresh environments; use `create explicit destructive rebuild flow` only when a full destructive rebuild is intentional.
3. Use `update` for ongoing maintenance, guest-task refresh, and Azure redeploy-backed repair on an existing VM.
4. Use `task` and `exec` to isolate one failing init or update task instead of replaying the whole chain.
5. Use `move`, `resize`, `set`, and `delete` only after the inventory and current state are explicit.

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

`create` and `update` can run the full chain or a selected window of steps by using `--step-from`, `--step-to`, or `--step`.

### Init Tasks Versus Update Tasks
- `vm-init` is Azure Run Command driven and is used for early guest bootstrap.
- `vm-update` is pyssh driven and is used for richer task-by-task update flows after the VM is reachable.
- Both stages use catalog JSON files as the source of truth for ordering, timeout, and enable/disable state.
- The natural execution order for both stages is: builtin catalog `initial` tasks, builtin catalog `normal` tasks, local git-untracked tasks from `local/`, then builtin catalog `final` tasks.

### Interactive Versus Auto Mode
- Interactive mode is the default and prompts when required values are missing.
- Interactive `create` and `update` always show the configuration screen first and the VM summary screen last.
- Interactive `create` and `update` use `yes/no/cancel` review checkpoints only for `group`, `vm-deploy`, `vm-init`, and `vm-update`.
- `--auto` is for unattended `create`, `update`, and `delete` flows.
- Auto `create` requires an explicit platform plus `--vm-name`, `--vm-region`, and `--vm-size`.
- Auto `update` requires an explicit platform plus `--group` and `--vm-name`.
- Auto mode prints the same review context, but it continues without waiting for checkpoint confirmation.
- `configure` and `vm-summary` stay visible in both interactive and auto mode, even when partial step selection skips interior stages.
- Operator commands such as `show`, `do`, `ssh`, and `rdp` stay direct and do not require `--auto`.

### Naming And Managed Resource Rules
- `VM_NAME` is the single naming seed.
- Managed names are template-driven and deterministic.
- Managed resource group ids use a global `gX` suffix that increments across all managed groups, regardless of region.
- Managed resource ids use a global `nX` suffix that increments across all generated managed resources and is never reused by another managed resource of any type.
- Runtime code validates names before Azure mutation.

## Architecture From Zero To Hero

### Entrypoints And Runtime Modules
- `az-vm.cmd` exists to give Windows operators a simple launcher path.
- `az-vm.ps1` loads `modules/azvm-runtime-manifest.ps1`, then dot-sources the ordered runtime leaf files directly before dispatching the command surface.
- There is no transitional root-loader layer for `core`, `config`, `commands`, `ui`, or `tasks`; the launcher now resolves the refactored module tree directly.
- `modules/core/` now holds smaller domain files for shared contracts, CLI helpers, system/runtime utilities, task discovery, and host mirroring logic.
- `modules/config/` isolates dotenv, naming-template, region-code, and related config helpers from command/UI code.
- `modules/commands/` now owns the public command surface: each supported command lives under its own subtree with `entry.ps1`, `contract.ps1`, `runtime.ps1`, and `parameters/`, while shared create/update orchestration lives under `context/`, `steps/`, `features/`, `pipeline/`, and `shared/`.
- `modules/ui/` is now restricted to operator interaction concerns such as prompts, selection flows, show rendering, and connection-facing helpers.
- `modules/tasks/` is split into `run-command/` and `ssh/` internals so Azure Run Command and persistent SSH execution remain reusable without leaving task transport logic in command or UI files.

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
- `priority=1000` for tracked tasks
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
3. For `create`, synthesize the next fresh managed resource group name plus fresh globally unique managed resource names; for `update`, resolve one existing managed resource group plus one existing VM only.
4. Create or reconcile network resources for the current mode.
5. Create or update the VM, then redeploy when `update` targets an existing VM.
6. Run init tasks.
7. Run update tasks.
8. Print a final VM/resource summary.

`create` never reuses an existing managed resource group or existing managed resource names, and `update` never falls through to an implicit fresh-create path. `configure` and `vm-summary` still render even when a partial step selection slices out interior stages.
Shared post-deploy feature intent comes from `.env` keys `VM_ENABLE_HIBERNATION` and `VM_ENABLE_NESTED_VIRTUALIZATION`; set them to `false` when you want create/update to skip those feature paths even if the SKU supports them. When either key is `true`, create/update now treats that capability as a required verified outcome, not a best-effort warning.

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
- Sensitive values such as VM passwords must be set explicitly. Placeholder values are treated as invalid configuration.

### High-Value `.env` Keys
- `VM_OS_TYPE`: default platform for auto flows.
- `VM_NAME`: actual Azure VM name and the naming seed for derived resources.
- `company_name`: required for the Windows business public desktop shortcut flow and used as the lowercase Chrome `--profile-directory` for repo-managed Windows business web shortcuts.
- `employee_email_address`: required for the Windows public desktop shortcut flow and used to derive the lowercase Chrome `--profile-directory` for repo-managed Windows personal web shortcuts by taking the email local-part before `@`.
- `employee_full_name`: required Windows operator identity metadata for the public desktop shortcut contract.
- `AZ_LOCATION`: default Azure region.
- `RESOURCE_GROUP`, `VNET_NAME`, `SUBNET_NAME`, `NSG_NAME`, `PUBLIC_IP_NAME`, `NIC_NAME`, `VM_DISK_NAME`: optional explicit resource-name overrides.
- `NSG_RULE_NAME`, `NSG_RULE_NAME_TEMPLATE`: explicit override or template for inbound-rule naming. The default template prefix is `nsg-rule-`.

### Shared VM Feature Toggles
- `VM_ENABLE_HIBERNATION`: `true` or `false`. Controls whether create/update flows should attempt post-deploy Azure hibernation enablement when the target SKU supports it.
- `VM_ENABLE_NESTED_VIRTUALIZATION`: `true` or `false`. Controls whether create/update flows should require nested virtualization guest readiness. Azure single-VM APIs do not expose a separate nested-virtualization toggle here; the repo validates the capability from inside the guest on running VMs.
- These are common keys, not platform-specific keys. Keep them in `.env` unless you are deliberately overriding them on the CLI/runtime side.

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
- `PYSSH_CLIENT_PATH`: defaults to the repo-relative client path `tools/pyssh/ssh_client.py`
- `TCP_PORTS`

### Global Versus Task-Local Configuration
- Put app-wide identity, secrets, reusable ports, and cross-command overrides in `.env`.
- Put task-only constants such as package IDs, product-specific fallback paths, shortcut bundles, and task-local URLs in the owning `vm-init` or `vm-update` script's top config block.
- Keep the committed repo portable and brand-neutral. Avoid embedding personal, company-specific, or secret fallback values in shared runtime code.

## Command Guide

### Global Options
- `--auto[=true|false]`: unattended create/update/delete.
- `--perf[=true|false]`: timing output.
- `--windows`, `--linux`: force platform for supported commands.
- `-h`, `--help`: show overview or command-specific help.

### `configure`
Purpose: select one existing managed VM target, read actual Azure state, and sync target-derived values into `.env`.

Typical usage:
```powershell
.\az-vm.cmd configure -h
.\az-vm.cmd configure
.\az-vm.cmd configure --vm-name=<vm-name>
.\az-vm.cmd configure --group=<resource-group> --vm-name=<vm-name>
```

What to expect:
- interactive managed RG and VM selection when parameters are omitted
- actual Azure state drives the persisted `.env` values
- `--windows` and `--linux` act as validation-only platform checks against the real VM
- stale opposite-platform keys are cleared
- no create, update, or delete Azure mutation

### `create`
Purpose: build one fresh managed VM flow from the selected step range.

Usage patterns:
```powershell
.\az-vm.cmd create -h
.\az-vm.cmd create --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku>
.\az-vm.cmd create --step=network --linux
.\az-vm.cmd create --step-from=vm-deploy --step-to=vm-summary --perf
.\az-vm.cmd create explicit destructive rebuild flow --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku>
```

Operator expectations:
- validates config before mutation
- creates one fresh managed resource group and one fresh VM target
- if `--windows` or `--linux` is omitted, interactive mode asks for the VM OS type first and then scopes size, disk, and image defaults to that selection
- interactive mode proposes the next globally unique managed `gX` resource group and globally unique managed `nX` resource ids
- any interactive override for the generated managed resource group still has to be unused and template-compliant
- interactive mode shows configuration first, always shows `vm-summary` last, and uses review checkpoints only for `group`, `vm-deploy`, `vm-init`, and `vm-update`
- auto mode requires an explicit platform plus `--vm-name`, `--vm-region`, and `--vm-size`
- uses `explicit destructive rebuild flow` as the explicit destructive recreate path
- runs init and update task windows unless the step range slices them out
- success ends with a summary of the managed VM state

Failure patterns:
- invalid region/image/SKU
- resource naming conflicts
- guest task failures depending on `VM_TASK_OUTCOME_MODE`

### `update`
Purpose: rerun create-or-update logic against one existing managed VM.

Usage patterns:
```powershell
.\az-vm.cmd update -h
.\az-vm.cmd update --auto --windows --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd update --step-to=vm-init --auto --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd update --step=vm-update --windows
```

Operator expectations:
- keeps the same orchestration model as `create`
- requires an existing managed resource group and existing VM before it starts
- interactive mode only selects from existing managed resource groups and existing VM names
- invalid free-form resource-group or VM-name input is rejected with a corrective hint
- interactive mode shows configuration first, always shows `vm-summary` last, and uses review checkpoints only for `group`, `vm-deploy`, `vm-init`, and `vm-update`
- auto mode requires an explicit platform plus `--group` and `--vm-name`
- targets already-managed resources without destructive delete behavior
- runs `az vm redeploy` for an existing VM during the VM deploy stage
- useful for post-fix reruns and guest task refreshes

### `list`
Purpose: print read-only managed inventory sections for az-vm-tagged resource groups and resources.

Usage patterns:
```powershell
.\az-vm.cmd list -h
.\az-vm.cmd list
.\az-vm.cmd list --type=group,vm
.\az-vm.cmd list --type=nsg,nsg-rule --group=<resource-group>
```

What users see:
- deterministic managed inventory sections
- exact managed resource-group filtering with `--group`
- read-only output; `.env` selection and synchronization stay in `configure`

### `show`
Purpose: print a readable system/configuration inventory for managed resources and VMs.

Usage patterns:
```powershell
.\az-vm.cmd show -h
.\az-vm.cmd show
.\az-vm.cmd show --group=<resource-group>
```

Good for:
- pre-mutation inspections
- post-create or post-move confirmation
- support and diagnostics snapshots

Behavior notes:
- password-bearing `.env` values are redacted in the rendered report
- the VM detail section includes the effective hibernation state and, when the VM is running, guest-validated nested-virtualization state plus validation evidence

### `do`
Purpose: inspect or change one VM lifecycle state.

Supported actions:
- `status`
- `start`
- `restart`
- `reapply`
- `stop`
- `deallocate`
- `hibernate-stop`
- `hibernate-deallocate`

Usage patterns:
```powershell
.\az-vm.cmd do -h
.\az-vm.cmd do --vm-action=status --vm-name=<vm-name>
.\az-vm.cmd do --vm-action=start --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd do --vm-action=reapply --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd do --vm-action=deallocate --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd do --vm-action=hibernate-stop --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd do --vm-action=hibernate-deallocate --group=<resource-group> --vm-name=<vm-name>
```

Behavior notes:
- if parameters are omitted, the command falls back to interactive group/VM/action selection
- mutating actions validate the current power/provisioning state before calling Azure
- `reapply` calls `az vm reapply` and then prints a refreshed lifecycle snapshot; it stays available even when provisioning is not currently in the succeeded state
- `hibernate-stop` requires a running VM plus working SSH access, runs `shutdown /h /f` through the repo-managed pyssh path, and waits until the guest is no longer running without Azure deallocation
- `hibernate-deallocate` follows Azure hibernation semantics and deallocates the VM

Friendly refusal examples:
- trying `restart` on a stopped VM
- trying `hibernate-stop` or `hibernate-deallocate` when the VM is not running
- trying a mutating action while the VM is in a transitional Azure state

### `task`
Purpose: list the real discovered task inventory and execution order without mutating Azure or the guest VM.

Usage patterns:
```powershell
.\az-vm.cmd task -h
.\az-vm.cmd task --list
.\az-vm.cmd task --list --vm-init
.\az-vm.cmd task --list --vm-update --disabled --windows
```

Behavior notes:
- uses the same discovery pipeline as real init/update execution
- lists tracked catalog-driven tasks and local metadata-driven tasks together
- shows stage, source, task type, priority, timeout, enabled state, disabled reason, task name, and relative path
- `--disabled` filters the output to disabled tasks only

### `exec`
Purpose: run one init task, one update task, or open an interactive remote shell path.

Usage patterns:
```powershell
.\az-vm.cmd exec -h
.\az-vm.cmd exec --init-task=01 --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd exec --update-task=10002 --group=<resource-group> --vm-name=<vm-name> --windows
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
.\az-vm.cmd ssh -h
.\az-vm.cmd ssh --vm-name=<vm-name>
.\az-vm.cmd ssh --group=<resource-group> --vm-name=<vm-name> --user=assistant
.\az-vm.cmd ssh --group=<resource-group> --vm-name=<vm-name> --user=manager --test
```

Behavior notes:
- only runs when the target VM is already running
- uses current managed VM state and connection settings from config/runtime
- politely refuses and suggests `az-vm do --vm-action=start` when the VM is not running
- `--test` performs a non-interactive SSH authentication and `whoami` handshake by using the repo-managed pyssh client instead of opening `ssh.exe`

### `rdp`
Purpose: launch the local Remote Desktop client for a managed Windows VM.

Usage patterns:
```powershell
.\az-vm.cmd rdp -h
.\az-vm.cmd rdp --vm-name=<vm-name>
.\az-vm.cmd rdp --group=<resource-group> --vm-name=<vm-name> --user=assistant
.\az-vm.cmd rdp --group=<resource-group> --vm-name=<vm-name> --user=manager --test
```

Behavior notes:
- only runs when the target VM is already running
- stages credentials via `cmdkey` and launches `mstsc.exe`
- politely refuses and suggests `az-vm do --vm-action=start` when the VM is not running
- `--test` performs a non-interactive TCP reachability check against the resolved RDP endpoint instead of launching `mstsc.exe`

### `move`
Purpose: move a managed VM to another Azure region with a health-gated cutover.

Usage pattern:
```powershell
.\az-vm.cmd move -h
.\az-vm.cmd move --group=<resource-group> --vm-name=<vm-name> --vm-region=swedencentral
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
Purpose: change the VM size or expand the managed OS disk in-place within the current region.

Usage patterns:
```powershell
.\az-vm.cmd resize -h
.\az-vm.cmd resize --group=<resource-group> --vm-name=<vm-name> --vm-size=Standard_D4as_v5
.\az-vm.cmd resize --group=<resource-group> --vm-name=<vm-name> --disk-size=196gb --expand --windows
.\az-vm.cmd resize --group=<resource-group> --vm-name=<vm-name> --disk-size=98304mb --expand
.\az-vm.cmd resize --group=<resource-group> --vm-name=<vm-name> --disk-size=64gb --shrink
.\az-vm.cmd resize --group=<resource-group> --vm-name=<vm-name> --vm-size=Standard_D2as_v5 --windows
.\az-vm.cmd resize
```

Behavior notes:
- same-region only
- fully specified calls run directly
- parameterless use falls back to interactive target and size selection
- `--windows` and `--linux` act as expected-platform assertions
- `--disk-size=... --expand` deallocates the VM, grows the managed OS disk, starts the VM again, and persists the new platform disk-size key in `.env`
- `--disk-size=... --shrink` is a non-mutating guidance path because Azure does not support shrinking an existing managed OS disk in place; the command prints supported rebuild and migration alternatives instead of risking disk integrity

### `set`
Purpose: apply hibernation and sync nested-virtualization desired state.

Supported flags:
- `--hibernation=on|off`
- `--nested-virtualization=on|off`

Usage patterns:
```powershell
.\az-vm.cmd set -h
.\az-vm.cmd set --group=<resource-group> --vm-name=<vm-name> --hibernation=off
.\az-vm.cmd set --group=<resource-group> --vm-name=<vm-name> --nested-virtualization=off
.\az-vm.cmd set --group=<resource-group> --vm-name=<vm-name> --hibernation=on --nested-virtualization=off
```

Behavior notes:
- `set` resolves the target VM directly and does not depend on the heavier Step-1 create/update runtime path.
- Hibernation is changed through Azure.
- Nested virtualization is governed by VM size, security type, and guest readiness; `--nested-virtualization=on` validates the capability from inside a running VM, while `--nested-virtualization=off` only updates repo desired state.
- After each successful change, the command syncs the resolved `RESOURCE_GROUP`, `VM_NAME`, and the changed `VM_ENABLE_HIBERNATION` / `VM_ENABLE_NESTED_VIRTUALIZATION` values back into the local `.env` file.
- If one toggle succeeds and a later toggle fails, `.env` is still updated to match the successful change so local intent does not drift away from the actual VM state.

### `delete`
Purpose: delete a selected scope from a managed resource group.

Supported targets:
- `group`
- `network`
- `vm`
- `disk`

Usage patterns:
```powershell
.\az-vm.cmd delete -h
.\az-vm.cmd delete --target=group --group=<resource-group> --yes
.\az-vm.cmd delete --target=vm --group=<resource-group> --yes
```

Behavior notes:
- destructive by design
- requires clear target selection
- `--yes` is for non-interactive confirmation bypass

### `help`
Purpose: print the quick overview or one-command help.

Usage patterns:
```powershell
.\az-vm.cmd -h
.\az-vm.cmd --help
.\az-vm.cmd do -h
.\az-vm.cmd help
.\az-vm.cmd help move
```

## Task Authoring And Execution

### Catalog Ownership
Catalog JSON files are the source of truth for task ordering, enable state, and timeouts. Runtime code must not rewrite them automatically.

### Task Naming Rules
- `<task-number>-verb-noun-target.ext`
- task-number bands:
  - `01-99` = `initial`
  - `101-999` = `normal`
  - `1001-9999` = local-only
  - `10001-10099` = `final`
- 2-5 English words in kebab-case
- `.ps1` for Windows
- `.sh` for Linux

### Timeouts, Priority, And Enable Flags
- tracked task at the stage root: use catalog values
- local-only task under `local/` may declare `# az-vm-task-meta: {...}` on the first non-empty comment line for `priority`, `enabled`, `timeout`, and `assets`
- local-only tasks under `local/` are discovered from disk dynamically and do not consume catalog entries
- local-only tasks under `local/disabled/` remain disabled by location even if their metadata says `enabled=true`
- local-only asset paths are resolved relative to the local task file directory
- if both catalog state and script metadata exist, the catalog wins for `priority`, `enabled`, and `timeout`
- tracked missing `priority`: default to `1000`
- local missing `priority`: script metadata first, then filename task number, then deterministic auto-detect from the `1001+` band
- missing `timeout`: default to `180`
- missing tracked entry entirely: `priority=1000`, `enabled=true`, `timeout=180`

### Direct Task Execution With `exec`
Direct `exec --init-task` and `exec --update-task` are the main diagnosis path when one task needs to be rerun without replaying the entire orchestration chain.

## Practical And Extensive Usage Scenarios

### Create A Fresh Managed VM
```powershell
.\az-vm.cmd create --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku>
.\az-vm.cmd create --step=network --linux
.\az-vm.cmd create --step-from=vm-deploy --step-to=vm-summary --perf
.\az-vm.cmd create explicit destructive rebuild flow --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku>
```

Practical outcomes:
- the default path creates one fresh managed resource group and one fresh VM target
- interactive mode proposes the next globally unique managed `gX` group id and globally unique managed `nX` resource ids
- auto mode requires an explicit platform plus `--vm-name`, `--vm-region`, and `--vm-size`
- `explicit destructive rebuild flow` is the explicit rebuild path when the operator wants a destructive recreate
- the same step model works in interactive and auto mode

### Update An Existing Managed VM
```powershell
.\az-vm.cmd update --auto --windows --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd update --step=vm-update --auto --windows --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd update --step-to=vm-init --auto --group=<resource-group> --vm-name=<vm-name>
```

Practical outcomes:
- the command fails fast if the managed resource group or VM does not exist, and it points the operator to `create`
- auto mode requires an explicit platform plus `--group` and `--vm-name`
- the VM deploy step uses Azure create-or-update plus `az vm redeploy` when the target VM already exists
- update is the main maintenance path after the first deployment

### Inspect Managed Resource Groups And VM State
```powershell
.\az-vm.cmd list --type=group,vm
.\az-vm.cmd configure --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd show --group=<resource-group>
.\az-vm.cmd do --vm-action=status --vm-name=<vm-name>
```

Practical outcomes:
- `list` gives a read-only managed inventory view across groups and resource types
- `configure` selects one managed VM target and synchronizes actual Azure state into `.env`
- `show` gives an inventory snapshot while password-bearing `.env` values are redacted
- `do --vm-action=status` is the quickest preflight check before a mutating change

### Run One Task Or Open A Remote Shell
```powershell
.\az-vm.cmd task --list --vm-update --windows
.\az-vm.cmd exec --update-task=10099 --group=<resource-group> --vm-name=<vm-name> --windows
.\az-vm.cmd exec --init-task=01 --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd ssh --group=<resource-group> --vm-name=<vm-name> --user=manager
.\az-vm.cmd rdp --group=<resource-group> --vm-name=<vm-name> --user=assistant
```

Practical outcomes:
- support and development teams can rerun only the failing task instead of replaying the whole deployment
- `task` exposes the real discovered inventory, including tracked and local-only tasks
- `ssh` and `rdp` remain direct operator commands, with `--user=manager --test` available for non-interactive validation

### Resize Compute Or OS Disk In Place
```powershell
.\az-vm.cmd resize --group=<resource-group> --vm-name=<vm-name> --vm-size=Standard_D4as_v5 --windows
.\az-vm.cmd resize --group=<resource-group> --vm-name=<vm-name> --disk-size=196gb --expand --windows
.\az-vm.cmd resize --group=<resource-group> --vm-name=<vm-name> --disk-size=98304mb --expand
.\az-vm.cmd resize --group=<resource-group> --vm-name=<vm-name> --disk-size=64gb --shrink
```

Practical outcomes:
- `--vm-size` changes compute SKU in the same region
- `--expand` performs the supported managed OS disk growth path with explicit before/after logging
- `--shrink` explains why Azure OS disk shrink is unsupported and lists safer rebuild alternatives

### Move Regions And Clean Up Safely
```powershell
.\az-vm.cmd move --group=<resource-group> --vm-name=<vm-name> --vm-region=swedencentral
```

### Delete Only The Scope You Intend
```powershell
.\az-vm.cmd delete --target=vm --group=<resource-group> --yes
.\az-vm.cmd delete --target=group --group=<resource-group> --yes
```

### Inspect And Control Power State
```powershell
.\az-vm.cmd do --vm-action=status --vm-name=<vm-name>
.\az-vm.cmd do --vm-action=start --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd do --vm-action=reapply --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd do --vm-action=stop --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd do --vm-action=hibernate-stop --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd do --vm-action=hibernate-deallocate --group=<resource-group> --vm-name=<vm-name>
```

### Connect With SSH Or RDP
```powershell
.\az-vm.cmd do --vm-action=start --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd ssh --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd rdp --group=<resource-group> --vm-name=<vm-name> --user=assistant
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
- managed OS disk shrink is intentionally blocked as an unsupported Azure scenario; use the printed rebuild or migration alternatives instead.
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

GitHub Actions runs the non-destructive `.github/workflows/quality-gate.yml` workflow on pull requests, pushes to `main`, and manual dispatch. It covers static audit, an explicit documentation-contract check, PowerShell compatibility, Linux shell syntax, workflow linting, and the non-live smoke-contract suite.

### Live Release Acceptance
Before calling the repo or the active profile release-ready for a live publish, run one end-to-end live acceptance cycle against the current `.env` target:
- if the target group is safe to purge, prefer a full recreate by running `az-vm delete --target=group --group=<resource-group> --yes` before the live create
- run a clean `az-vm create --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku> --perf` or `az-vm create --auto --linux --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku> --perf`
- rerun `az-vm update --auto --windows --group=<resource-group> --vm-name=<vm-name> --perf` or `az-vm update --auto --linux --group=<resource-group> --vm-name=<vm-name> --perf` without changing the natural task order
- confirm `az-vm show` prints the expected inventory while password-bearing `.env` values stay redacted
- confirm `az-vm do --vm-action=status --vm-name=<vm-name>` reports the VM as started
- confirm `az-vm ssh --vm-name=<vm-name> --user=manager --test`; for Windows also confirm `az-vm rdp --vm-name=<vm-name> --user=manager --test`
- when `VM_ENABLE_HIBERNATION=true`, validate the intended hibernation path explicitly and restore the VM to `started` before finishing the release gate
- when `VM_ENABLE_NESTED_VIRTUALIZATION=true`, verify that outcome after the live run before declaring release readiness

### Support And Contribution Paths
- Read [SUPPORT.md](SUPPORT.md) before opening a public issue.
- Read [SECURITY.md](SECURITY.md) for vulnerability reporting; do not post sensitive reports publicly.
- Read [CONTRIBUTING.md](CONTRIBUTING.md) before sending a pull request, especially for command-surface or workflow changes.
- Read [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) before participating in repo discussions or reviews.
- This repo uses a contact-first contribution model for large changes and a maintainer-curated review path.

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
- `LICENSE`: custom non-commercial repository license.
- `CONTRIBUTING.md`: contributor workflow and review expectations.
- `SUPPORT.md`: support and escalation guidance.
- `SECURITY.md`: private vulnerability-reporting path.
- `CODE_OF_CONDUCT.md`: participation expectations for repo spaces.
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
