# az-vm

`az-vm` is a unified Azure VM provisioning and lifecycle toolkit for Windows and Linux. It gives one operator-facing entrypoint for provisioning, updating, inspecting, connecting to, repairing, resizing, moving, and deleting managed Azure VMs with deterministic task execution and explicit validation before mutation. In its current Windows flagship path, the repo goes beyond raw infrastructure creation and drives the machine toward a ready-to-use remote workstation experience: core apps installed, startup behavior configured, public desktop shortcuts prepared, advanced settings applied, and day-one user experience shaped before the first serious session begins.

At a glance:
- Customer teams get a repeatable Azure VM outcome that can feel closer to an all-in-one prepared remote computer than a portal-built raw VM.
- Executive teams get lower drift, faster support handoff, and one repo that captures runtime behavior, guest-configuration intent, release notes, and operating guidance together.
- Developers and DevOps maintainers get one command surface plus portable task folders that can preload apps, services, settings, desktop behavior, and UX details on both Windows and Linux.
- Employees, administrative teams, workers, and regular operators get a near-zero-touch first session: connect remotely and find the machine already prepared for common daily work.
- Visitors and sponsors can evaluate a mature operational toolkit with visible docs, quality gates, release discipline, and proof-of-outcome scenarios instead of vague promises.

## Table Of Contents
- [Quick Start Guide](#quick-start-guide)
  - [Why Start Here](#why-start-here)
  - [Prerequisites](#prerequisites)
  - [Repository Layout](#repository-layout)
  - [First Configuration Pass](#first-configuration-pass)
  - [Fastest Safe Path To Value](#fastest-safe-path-to-value)
  - [First End-To-End Run](#first-end-to-end-run)
  - [Daily Operator Shortcuts](#daily-operator-shortcuts)
- [Customer Business Value](#customer-business-value)
- [Executive Summary](#executive-summary)
- [Value By Audience](#value-by-audience)
- [Delivered VM Outcome Matrix](#delivered-vm-outcome-matrix)
- [Who az-vm Is For](#who-az-vm-is-for)
- [Why az-vm Exists](#why-az-vm-exists)
  - [What It Does](#what-it-does)
  - [Problems It Solves](#problems-it-solves)
  - [When To Use It](#when-to-use-it)
  - [When Not To Use It](#when-not-to-use-it)
- [Operational Command Matrix](#operational-command-matrix)
  - [Global Options Matrix](#global-options-matrix)
  - [Command Matrix](#command-matrix)
  - [Command Variations By Command](#command-variations-by-command)
- [Practical And Extensive Usage Scenarios](#practical-and-extensive-usage-scenarios)
  - [Create A Fresh Managed VM](#create-a-fresh-managed-vm)
  - [Update An Existing Managed VM](#update-an-existing-managed-vm)
  - [Inspect Managed Resource Groups And VM State](#inspect-managed-resource-groups-and-vm-state)
  - [Run One Task Or Open A Remote Shell](#run-one-task-or-open-a-remote-shell)
  - [Resize Compute Or OS Disk In Place](#resize-compute-or-os-disk-in-place)
  - [Move Regions And Clean Up Safely](#move-regions-and-clean-up-safely)
  - [Delete Only The Scope You Intend](#delete-only-the-scope-you-intend)
  - [Inspect And Control Power State](#inspect-and-control-power-state)
  - [Connect To The VM](#connect-to-the-vm)
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
  - [`connect`](#connect)
  - [`move`](#move)
  - [`resize`](#resize)
  - [`set`](#set)
  - [`delete`](#delete)
  - [`help`](#help)
- [Task Authoring And Execution](#task-authoring-and-execution)
  - [Task Folder Ownership](#task-folder-ownership)
  - [Task Naming Rules](#task-naming-rules)
  - [Timeouts, Priority, And Enable Flags](#timeouts-priority-and-enable-flags)
  - [Direct Task Execution With `task`](#direct-task-execution-with-task)
- [Configuration Guide](#configuration-guide)
  - [Runtime Precedence](#runtime-precedence)
  - [High-Value `.env` Keys](#high-value-env-keys)
  - [Shared VM Feature Toggles](#shared-vm-feature-toggles)
  - [Platform-Specific Settings](#platform-specific-settings)
  - [Connection And Task Settings](#connection-and-task-settings)
  - [Global Versus Task-Local Configuration](#global-versus-task-local-configuration)
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
  - [Task Folder Model](#task-folder-model)
  - [Windows And Linux Execution Model](#windows-and-linux-execution-model)
  - [End-To-End Create And Update Flow](#end-to-end-create-and-update-flow)
  - [Safety Model And Failure Handling](#safety-model-and-failure-handling)
  - [Documentation, History, And Release Discipline](#documentation-history-and-release-discipline)
- [Troubleshooting Guide](#troubleshooting-guide)
  - [Validation Failures](#validation-failures)
  - [Task Failures](#task-failures)
  - [Connection Failures](#connection-failures)
  - [Move And Resize Expectations](#move-and-resize-expectations)
- [Developer Workflow](#developer-workflow)
  - [Branching And Local Hooks](#branching-and-local-hooks)
  - [Quality Gates](#quality-gates)
  - [Live Release Acceptance](#live-release-acceptance)
  - [Support And Contribution Paths](#support-and-contribution-paths)
  - [Documentation Contract](#documentation-contract)
  - [Prompt History Rule](#prompt-history-rule)
- [Documentation Set](#documentation-set)
- [License And Sponsorship](#license-and-sponsorship)

## Quick Start Guide

### Why Start Here
This section is optimized for the reader who wants usable value quickly without skipping the repo's safety model. The goal is simple: get from clone to one visible Azure VM outcome fast, while still understanding what the command surface is doing, which config matters first, and how to verify that the result is healthy.

On the current Windows hero path, one successful `create` is designed to leave behind much more than infrastructure. The machine can arrive with cloud and developer tooling, collaboration and storage apps, accessibility and support tools, startup flows, public desktop shortcuts, advanced Windows tuning, and copied user preferences where the repo already has tasks for them. Linux is intentionally lighter today, but it is already stable and uses the same task model, so teams can extend it with their own apps, services, settings, and UX decisions without changing the operator surface.

### Prerequisites
- Windows host with PowerShell and the Azure CLI available.
- Azure subscription access with permission to create, update, and delete compute and networking resources.
- Azure CLI sign-in is strictly required for Azure-touching commands. Run `az login` before using `create`, `update`, `list`, `show`, `do`, `task --run-*`, `task --save-app-state`, `task --restore-app-state`, `connect`, `move`, `resize`, `set`, `exec`, or `delete`. `configure` can open without Azure sign-in, but its Azure-backed pickers stay read-only until `az login` is available.
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
- `windows/init/`, `windows/update/`: Windows stage roots with portable task folders at the root, portable disabled task folders under `disabled/`, and portable local-only task folders under `local/` and `local/disabled/`.
- `linux/init/`, `linux/update/`: Linux stage roots with portable task folders at the root, portable disabled task folders under `disabled/`, and portable local-only task folders under `local/` and `local/disabled/`.
- `tools/`: pyssh helper, scripts, Windows helper assets, and git-hook toggles.
- `tests/`: local quality and contract checks.
- `docs/prompt-history.md`: English-normalized historical ledger of completed prompt/summary pairs.

### First Configuration Pass
1. Copy `.env.example` to `.env`.
2. Set the minimum values:
   - `SELECTED_VM_OS`
   - `SELECTED_VM_NAME`
   - `SELECTED_AZURE_REGION`
   - `SELECTED_AZURE_SUBSCRIPTION_ID` when you want a repo-local default Azure subscription id for Azure-touching commands
   - `VM_ADMIN_USER`, `VM_ADMIN_PASS`
   - `VM_ASSISTANT_USER`, `VM_ASSISTANT_PASS`
   - platform-specific image and size keys as needed
3. Set `SELECTED_COMPANY_NAME`, `SELECTED_COMPANY_WEB_ADDRESS`, `SELECTED_COMPANY_EMAIL_ADDRESS`, `SELECTED_EMPLOYEE_EMAIL_ADDRESS`, and `SELECTED_EMPLOYEE_FULL_NAME` for Windows flows. Repo-managed public desktop web shortcuts require the company and employee identity inputs; business shortcuts use `SELECTED_COMPANY_NAME` plus `SELECTED_COMPANY_WEB_ADDRESS`, personal shortcuts use the email local-part from `SELECTED_EMPLOYEE_EMAIL_ADDRESS` as the Chrome `--profile-directory`, and future mail-facing shortcuts can reuse `SELECTED_COMPANY_EMAIL_ADDRESS`. The task normalizes profile-directory sources to lowercase before writing the Chrome profile name.
4. Treat `.env` as the home for app-wide identity, secrets, and reusable overrides. Task-only constants should stay in the owning task script's top config block.

### Fastest Safe Path To Value
If you want the fastest safe path to value, use this order. The target outcome is not only "the VM exists"; it is "someone can connect and start real work quickly" with a machine that already looks curated. On the current Windows path that includes Store-aware public desktop shortcuts, managed short-launcher wrapping for overlong Chrome/Edge-style shortcut invocations, per-task git-ignored app-state zip plugins resolved from `<task-folder>/app-state/app-state.zip`, and WSL2 plus Docker Desktop prerequisite hardening before developer-runtime health is considered ready:
1. Run `.\az-vm.cmd configure` and review the interactive `.env` sections, picker-backed fields, and next-create preview before saving.
2. Run `.\az-vm.cmd create --auto -s <subscription-guid>`. When `.env` already contains a complete `SELECTED_*` target plus the matching platform image and size defaults, the command can provision end-to-end without repeating platform, VM name, region, or size on the CLI.
3. Run `.\az-vm.cmd show --group=<resource-group>` to verify the managed inventory while password-bearing `.env` values are redacted.
4. Run `.\az-vm.cmd do --vm-action=status --vm-name=<vm-name>` to confirm the VM is started.
5. Run `.\az-vm.cmd connect --ssh --vm-name=<vm-name> --user=manager --test`; for Windows also run `.\az-vm.cmd connect --rdp --vm-name=<vm-name> --user=manager --test`.

Representative PoC / PoE outcomes from the current repo shape:
- Employee or knowledge-worker desktop: connect over RDP and land on a machine with browser, collaboration, storage, media, support, and accessibility tooling already staged, with desktop shortcuts and startup behavior already prepared.
- Developer or DevOps workstation: connect and find PowerShell, Git, Python, Node.js, Azure CLI, GitHub CLI, azd, VS Code, WSL2, Docker Desktop, Ollama, Codex app, and other repo-managed tooling prepared by the current portable task inventory.
- Administrative or support machine: connect and find remote-support, startup, health-capture, user-copy, and advanced settings tasks already applied so day-two assistance is easier.
- Linux proof path: use the same orchestrator, connection flow, and portable task-folder model today, then extend the lighter default guest with your own task-authored apps, services, and settings as needed.

### First End-To-End Run
```powershell
az login
.\az-vm.cmd configure
.\az-vm.cmd create --auto -s <subscription-guid>
.\az-vm.cmd do --vm-action=status --vm-name=<vm-name>
.\az-vm.cmd connect --rdp --vm-name=<vm-name>
```

### Daily Operator Shortcuts
```powershell
.\az-vm.cmd --version
.\az-vm.cmd -h
.\az-vm.cmd show --group=<resource-group>
.\az-vm.cmd do --vm-action=start --group=<resource-group> --vm-name=<vm-name> -s <subscription-guid>
.\az-vm.cmd task --list --vm-update --windows
.\az-vm.cmd task --save-app-state --vm-update-task=115 --group=<resource-group> --vm-name=<vm-name> -s <subscription-guid>
.\az-vm.cmd task --restore-app-state --vm-update-task=115 --group=<resource-group> --vm-name=<vm-name> -s <subscription-guid>
.\az-vm.cmd task --save-app-state --source=lm --user=.current. --vm-update-task=115 --windows
.\az-vm.cmd task --restore-app-state --target=lm --user=.current. --vm-update-task=115 --windows
.\az-vm.cmd resize --group=<resource-group> --vm-name=<vm-name> --vm-size=Standard_D4as_v5 --windows
```

## Customer Business Value

`az-vm` compresses the time between "we need a working Azure VM" and "someone can remotely connect and start real work" into one operator workflow. The practical benefit is not just faster provisioning; it is lower variance after provisioning. The repo keeps infrastructure intent, guest configuration, direct task reruns, diagnostics, release notes, and support-facing guidance together, so a team does not have to rediscover the same setup logic every time a VM must be rebuilt, updated, resized, repaired, or handed to another person.

The strongest current story is the Windows workstation path. With one command, the repo can provision Azure resources and continue until the guest looks and behaves much closer to a prepared remote computer than to an empty VM: core tooling is installed, common collaboration and storage apps are staged, startup behavior is configured, public desktop shortcuts are created and refreshed, Store-backed desktop apps can launch through `shell:AppsFolder\<AUMID>` instead of brittle version-pinned paths, overlong browser-style shortcut commands are rewritten through managed short launchers so the desktop contract stays healthy, advanced OS settings are applied, per-task app-state plugins can replay durable settings when a matching `app-state.zip` exists, and safe user-level preferences are copied where the repo already has task coverage. The result is a near-zero-touch first session for the people who actually need to use the machine.

From a customer-facing perspective, the value proposition is concrete:
- one-command path to a near-zero-touch remote Windows workstation in Azure, backed by the current portable task inventory
- faster time to a usable VM with known software, known guest-side configuration, and a prepared desktop experience
- safer day-two operations because the same toolkit handles update, inspect, resize, move, repair, and delete flows
- more predictable support handoff because runtime behavior, docs, release notes, and prompt history live in the same repository

Representative PoC / PoE stories the current repo can already support:
- A customer demo or pilot machine that already contains the common tooling, shortcuts, and tuned settings needed to make the environment feel complete on first login.
- A cloud-hosted employee workstation where the user connects remotely and finds mainstream daily apps, developer tools, service tooling, startup entries, and desktop organization already staged.
- A support or accessibility-focused machine where remote-support tools, accessibility apps, and curated desktop/startup behavior reduce the amount of manual aftercare needed after provisioning.

## Executive Summary

For decision-makers, `az-vm` is an operational standardization asset. It turns a previously manual, portal-heavy, and person-dependent VM build into a repo-governed process with validation before mutation, visible orchestration steps, repeatable guest task folders, and non-live quality gates. That matters because environment drift, undocumented post-install tweaks, and ad hoc support work are expensive even when the VM count is small.

Viewed as a service outcome rather than a scripting repo, `az-vm` helps teams deliver an Azure-hosted computer experience, not just an Azure-hosted VM. The flagship Windows path is intentionally positioned to produce an all-in-one remote workstation feel: applications installed, desktop experience shaped, startup behavior prepared, advanced settings applied, and supportability built in. That shortens the path from "budget approved" to "someone is productively connected and working."

The executive-level outcomes are straightforward:
- lower operational variance across fresh builds and maintenance windows
- faster onboarding for internal operators, downstream support teams, and end users who simply need a prepared machine
- clearer release readiness because the repo already enforces docs, quality, and live acceptance discipline
- stronger sponsor and stakeholder confidence because the value is visible in the repo structure, not only in verbal explanation

Windows is the richest end-user path today. Linux is already reliable, intentionally lighter by default, and fully extensible through the same task model, so the platform story can keep expanding without replacing the operator contract.

## Value By Audience

| Audience | What they care about | What `az-vm` delivers | Why it matters |
| --- | --- | --- | --- |
| Customer | A usable VM quickly, with fewer surprises | One command surface for create, update, inspect, connect, resize, move, and delete flows, plus a prepared guest experience on the Windows hero path | The delivered environment is easier to understand, verify, and support. |
| Executive / decision maker | Risk reduction, repeatability, supportability | Validation before mutation, explicit orchestration, repo-owned release and docs discipline, and a service-like remote workstation outcome | Operational work becomes more predictable and less person-dependent. |
| Employee / knowledge worker | A machine that feels ready on first login | Browsers, collaboration apps, storage tools, desktop shortcuts, startup entries, and tuned settings from current Windows task coverage | The first remote session can feel closer to "sit down and work" than "finish setting up the machine." |
| Administrative / support team | Easier handoff, assistance, and guided maintenance | Remote-support tooling, health capture, curated desktop/startup behavior, and readable lifecycle commands | Supporting the machine takes less rediscovery and less ad hoc recovery work. |
| Developer / DevOps / maintainer | Faster iteration, fewer hidden scripts, isolated reruns | Catalog-driven init/update tasks, direct `task` and `exec` paths, one Windows/Linux mental model, and easy task-based extensibility | Maintenance and debugging become narrower, faster, and more deterministic. |
| Worker / field operator | Reliable access to the same prepared toolset from anywhere | Remote connection flow, curated shortcuts, common apps, and a repeatable rebuild/update path | The cloud machine behaves more like a stable working environment than a one-off build. |
| Operator / regular user | Practical daily commands that do what they say | Clear lifecycle, connection, inventory, and repair commands with readable output | Day-to-day work is easier without learning a sprawling platform surface first. |
| Visitor / evaluator | Evidence that the repo is real and usable | Readable README, release notes, prompt history, tests, workflow gates, and proof-of-outcome scenarios | Evaluation is based on visible substance rather than vague promises. |
| Sponsor / backer | A credible project with continuing value | Strong operator documentation, explicit contracts, repeatable acceptance, and clear business framing | Sponsorship has a concrete quality and maintainability story behind it. |

## Delivered VM Outcome Matrix

| Outcome area | Windows managed VM outcome | Linux managed VM outcome | Operator impact | Business value |
| --- | --- | --- | --- | --- |
| Base access | Local users, OpenSSH, RDP, firewall ports, repo-managed connection flow | Local users, SSHD port config, firewall ports, repo-managed connection flow | Teams can connect immediately with less setup drift. | Handoffs happen faster and with less rediscovery. |
| Core tooling | PowerShell 7, Git, Python, Node.js, Azure CLI, GitHub CLI, azd, VS Code, 7-Zip, Sysinternals, FFmpeg | System package upgrade, Node capability tuning, SSHD tuning | A new VM becomes useful for cloud, scripting, and diagnostics fast. | Less first-day setup work and less tool inconsistency. |
| Developer runtime | Docker Desktop, WSL2, npm global package set, Ollama, Codex app, VS 2022 Community, WSL prerequisite hardening, Docker health probes, and docker-desktop-focused WSL state replay | Node-ready SSH environment and updated base packages | Engineering workflows can start earlier and recover with fewer hidden prerequisites. | Faster onboarding and less rebuild waste. |
| Collaboration and daily apps | Edge, Chrome validation, Teams, WhatsApp, OneDrive, Google Drive, VLC, iTunes, iCloud | Minimal by design | The machine feels operational, not half-finished. | Customer-facing and operator-facing use is easier to stage. |
| Accessibility and remote support | AnyDesk, Windscribe, NVDA, JAWS, Be My Eyes, startup flows, autologon manager, advanced Windows settings, public desktop shortcuts | Minimal by design | Assisted-operation scenarios are easier to reproduce and support. | Broader usability and faster support response. |
| Desktop and personalization | Startup configuration, grouped public desktop shortcuts, Store-backed `AppsFolder` launches where supported, Windows UX tuning, advanced settings, per-task git-ignored app-state zip replay, and safe user preference copy | Extensible through the same task model rather than a rich built-in desktop catalog | People connect to a machine that already feels curated and less drift-prone. | Less post-build manual cleanup and faster user adoption. |
| Health and observability | Snapshot-health capture, show/report output, direct task reruns, redeploy-ready update flow | Snapshot-health capture, show/report output, direct task reruns | Troubleshooting narrows quickly to the failing area. | Less wasted time during support and maintenance. |
| Lifecycle changes | Create fresh, explicit rebuild by `delete` plus `create`, update, reapply, redeploy, hibernation, move, VM-size resize, managed OS disk expand, explicit shrink guidance | Create fresh, explicit rebuild by `delete` plus `create`, update, move, VM-size resize, managed OS disk expand, explicit shrink guidance | The same toolkit still works after day one. | Operations do not regress to ad hoc portal work. |

## Who az-vm Is For

- Operators who want reproducible Azure VM environments without rebuilding the full stack by hand every time.
- Maintainers who need Windows and Linux parity under one command surface.
- Developers who want infrastructure, guest tasks, and operator workflows documented together.
- Small teams that value pragmatic automation, explicit state, and readable PowerShell over opaque orchestration layers.
- Stakeholders and sponsors who want visible evidence of operational maturity, not just a thin wrapper around Azure CLI calls.

## Why az-vm Exists

### What It Does
- Provisions Azure infrastructure for one managed Windows or Linux VM from one orchestrator.
- Applies deterministic guest initialization and guest update task inventories.
- Gives operators lifecycle commands for status, start, restart, reapply, redeploy, stop, deallocate, hibernate-stop, hibernate-deallocate, move, resize, connect, inspect, and delete flows.
- Keeps command wording, configuration behavior, and execution semantics as parallel as possible across Windows and Linux.

### Problems It Solves
- Eliminates ad hoc VM setup drift caused by one-off portal changes and manual guest tweaking.
- Replaces hidden or implicit guest scripts with explicit, portable task-folder ordering and timeouts.
- Reduces unsafe Azure mutations by validating names, regions, SKUs, image values, and state before mutating resources.
- Gives one repeatable operator workflow for create, update, repair, inspect, connect, and cutover work.
- Captures repo behavior, release notes, and development decisions in the same repository instead of splitting them across chat history and tribal knowledge.

### When To Use It
- When one managed VM per flow is the main unit of operation.
- When you need repeatable Windows or Linux workstation/server-like environments in Azure.
- When you need deterministic reruns of guest-side tasks after provisioning.
- When move, resize, hibernation, and isolated task reruns need to stay operator-friendly.

### When Not To Use It
- When you need large-scale fleet orchestration across many VMs at once.
- When you want a generic IaC module library rather than one opinionated operator toolkit.
- When you want a broad public open-source license with unrestricted commercial use.

## Operational Command Matrix

### Global Options Matrix

| Option | Applies to | Operational effect | Common usage note |
| --- | --- | --- | --- |
| `--auto` | `create`, `update`, `delete` | Runs the command without waiting for interactive confirmation | Use it only when the target and intent are already explicit. |
| `--perf` | Most public commands | Prints timing metrics for the current command | Useful during profiling, acceptance, and long-running change windows. |
| `--windows` | `create`, `update`, `exec`, `resize` | Forces the Windows platform path or validates Windows expectation | Use this when the target platform must be explicit. |
| `--linux` | `create`, `update`, `exec`, `resize` | Forces the Linux platform path or validates Linux expectation | Use this when the target platform must be explicit. |
| `-s`, `--subscription-id=<subscription-guid>` | All Azure-touching commands plus `task --run-*` and `task --save/restore-app-state` | Targets Azure operations to one subscription and persists CLI-provided subscription intent locally | `-s`, `--subscription-id=<subscription-guid>`: target Azure subscription for every Azure-touching command; successful CLI usage also writes `SELECTED_AZURE_SUBSCRIPTION_ID` into `.env`. |
| `-h`, `--help` | All public commands | Prints quick help or command-specific help | `-h`, `--help` are equivalent operator aliases. |

### Command Matrix

| Command | Purpose | Mutation level | When to use it | Primary outcome |
| --- | --- | --- | --- | --- |
| `configure` | Review, edit, validate, preview, and save the supported `.env` contract | Local `.env` only | Before create/update work, or whenever the next VM configuration needs a safe frontend | Validated `.env` values with a next-create preview |
| `create` | Build one fresh managed resource group and one fresh VM | Azure-mutating | First deployment or explicit rebuild flow | New managed VM environment |
| `update` | Maintain one existing managed resource group and VM | Azure-mutating | Ongoing maintenance, guest-task refresh, redeploy-backed repair | Updated existing VM |
| `list` | Print managed inventory by type | Azure-read-only | Inventory, targeting, quick visibility | Managed group/resource listings |
| `show` | Print a full managed report plus focused target-derived config when one VM is in scope | Azure-read-only | Health review, support handoff, release verification | Inventory and read-only target-derived configuration |
| `do` | Apply lifecycle or repair actions | Azure-mutating or read-only for `status` | Power-state control, reapply, redeploy, hibernation flow | Target VM lifecycle action |
| `task` | List discovered task inventory, run one task, or save/restore task app-state | Local/read-only for `--list`; Azure-touching for `--run-*` and VM app-state maintenance; local-machine for `--source=lm` / `--target=lm` | Understand task order, rerun one task, or refresh one task payload | Visible task inventory or one isolated task/app-state action |
| `connect` | Launch or test SSH/RDP access | Azure-touching, local-client action | Linux or Windows SSH access, or Windows desktop access | Direct client launch or connection test |
| `exec` | Open direct remote shell path or run one remote command | Azure-touching and guest-touching | Interactive shell work or one-shot remote command execution | One direct shell or command result |
| `move` | Move a managed VM to another region | Azure-mutating | Planned cutover or regional relocation | Health-gated regional move |
| `resize` | Change VM SKU or expand OS disk | Azure-mutating | Compute sizing change or safe disk growth | Resized VM or grown OS disk |
| `set` | Apply hibernation and validate or store nested virtualization settings | Azure-mutating plus guest validation | Feature-state management | Updated feature settings and VM state |
| `delete` | Purge a selected managed scope | Azure-mutating | Controlled cleanup | Deleted selected target scope |
| `help` | Print the command catalog or one command's details | Local/read-only | Operator discovery and reference | Command documentation |

### Command Variations By Command

#### `configure`

| Usage pattern | Key parameters | What it does | When to use it | Important notes |
| --- | --- | --- | --- | --- |
| `.\az-vm.cmd configure` | none | Opens the interactive `.env` editor | First configuration pass or safe local config maintenance | Purpose: review, edit, validate, preview, and save the supported `.env` contract through sections and pickers. |
| `.\az-vm.cmd configure --help` | `--help` | Prints the configure editor contract | Operator discovery | `configure` is interactive-only and rejects target-selection flags such as `--group`, `--vm-name`, and `--subscription-id`. |

#### `create`

| Usage pattern | Key parameters | What it does | When to use it | Important notes |
| --- | --- | --- | --- | --- |
| `.\az-vm.cmd create` | interactive | Review-first fresh create flow | Manual first build | Interactive `create` and `update` use `yes/no/cancel` review checkpoints only for `group`, `vm-deploy`, `vm-init`, and `vm-update`. |
| `.\az-vm.cmd create --auto` | `--auto` | Fresh unattended build from `.env` selections | Repeatable release or scripted setup | Auto `create` succeeds when CLI overrides or `.env` `SELECTED_*` values plus platform VM defaults resolve platform, VM name, region, and size. |
| `.\az-vm.cmd create --auto --windows --vm-name=<vm-name> --vm-region=<azure-region> --vm-size=<vm-sku>` | `--auto`, platform, name, region, size | Fresh unattended Windows build with explicit CLI overrides | Override-driven release or scripted setup | CLI overrides still win over `.env` selections. |
| `.\az-vm.cmd delete --target=group --group=<resource-group> --yes` then `.\az-vm.cmd create --auto` | `delete`, `create` | Destructive rebuild of a managed target | Clean rebuild when intended | `create` now stays dedicated to one fresh managed resource group plus one fresh managed VM; use `delete` and then `create` when a destructive rebuild is intentional. |
| `.\az-vm.cmd create --step=network --linux` | `--step` | Runs one top-level create step | Targeted orchestration testing | `create` never reuses an existing managed resource group or existing managed resource names, and `update` never falls through to an implicit fresh-create path. |
| `.\az-vm.cmd create --step-from=vm-deploy --step-to=vm-summary --perf` | `--step-from`, `--step-to`, `--perf` | Runs a partial create window | Controlled reruns | `configure` and `vm-summary` stay visible in both interactive and auto mode, even when partial step selection skips interior stages. |

#### `update`

| Usage pattern | Key parameters | What it does | When to use it | Important notes |
| --- | --- | --- | --- | --- |
| `.\az-vm.cmd update` | interactive | Review-first maintenance flow on an existing target | Manual upkeep | interactive mode prompts for Azure subscription first when `--subscription-id` is omitted |
| `.\az-vm.cmd update --auto` | `--auto` | Unattended update from the selected managed target | Scheduled or controlled maintenance | Auto `update` uses CLI overrides first, then `.env` `SELECTED_RESOURCE_GROUP` and `SELECTED_VM_NAME`, with single-VM auto-resolution allowed inside the selected group. |
| `.\az-vm.cmd update --auto --group=<resource-group> --vm-name=<vm-name>` | `--auto`, `--group`, `--vm-name` | Unattended update with explicit target override | Controlled maintenance | `update` now requires an existing managed resource group and VM, then applies create-or-update operations plus `az vm redeploy` in one guided maintenance flow. |
| `.\az-vm.cmd update --step=vm-update --auto --group=<resource-group> --vm-name=<vm-name>` | `--step` | Runs one update step | Isolated maintenance work | Useful for direct task-phase targeting. |
| `.\az-vm.cmd update --step-to=vm-init --auto --group=<resource-group> --vm-name=<vm-name>` | `--step-to` | Runs an early partial update window | Controlled reruns | Same review-first step model as create. |

#### `list`

| Usage pattern | Key parameters | What it does | When to use it | Important notes |
| --- | --- | --- | --- | --- |
| `.\az-vm.cmd list` | none | Prints all managed inventory sections | Quick managed visibility | Purpose: print read-only managed inventory sections for az-vm-tagged resource groups and resources. |
| `.\az-vm.cmd list --type=group,vm` | `--type` | Narrows output to selected inventory types | Daily operator targeting | `list` gives a read-only managed inventory view across groups and resource types |
| `.\az-vm.cmd list --type=nsg,nsg-rule --group=<resource-group>` | `--type`, `--group` | Group-filtered managed inventory | Resource-specific inspection | Azure-read-only output; `--subscription-id` / `-s` only changes the subscription context and persists `SELECTED_AZURE_SUBSCRIPTION_ID` when it comes from the CLI |

#### `show`

| Usage pattern | Key parameters | What it does | When to use it | Important notes |
| --- | --- | --- | --- | --- |
| `.\az-vm.cmd show` | none | Prints the broader managed report | Environment audit | Good for multi-group review. |
| `.\az-vm.cmd show --group=<resource-group>` | `--group` | Prints one managed group report | Support handoff and verification | `show` prints the expected inventory while password-bearing `.env` values are redacted. |
| `.\az-vm.cmd show --group=<resource-group> --vm-name=<vm-name>` | `--group`, `--vm-name` | Prints the managed report and one VM's target-derived configuration | Focused inspection of a single managed target | `show` stays read-only and uses actual Azure state without writing `.env`. |

#### `do`

| Usage pattern | Key parameters | What it does | When to use it | Important notes |
| --- | --- | --- | --- | --- |
| `.\az-vm.cmd do --vm-action=status --vm-name=<vm-name>` | `--vm-action=status` | Reads lifecycle state | Preflight and release checks | Fastest safety check before mutation. |
| `.\az-vm.cmd do --vm-action=start --group=<resource-group> --vm-name=<vm-name>` | lifecycle action | Starts the VM | Connection prep | Use before `connect --ssh` or `connect --rdp`. |
| `.\az-vm.cmd do --vm-action=reapply --group=<resource-group> --vm-name=<vm-name>` | `reapply` | Calls Azure reapply | Repair path | Good when provisioning succeeded but the instance needs Azure-side repair. |
| `.\az-vm.cmd do --vm-action=redeploy --group=<resource-group> --vm-name=<vm-name>` | `redeploy` | Calls Azure redeploy and waits for recovery | Host-level repair path | Good when the VM needs Azure-side host repair or provisioning recovery. |
| `.\az-vm.cmd do --vm-action=hibernate-stop --group=<resource-group> --vm-name=<vm-name>` | `hibernate-stop` | Guest-triggered hibernation through SSH | Preserve guest state without Azure deallocation path | Requires the VM to be running first. |
| `.\az-vm.cmd do --vm-action=hibernate-deallocate --group=<resource-group> --vm-name=<vm-name>` | `hibernate-deallocate` | Azure hibernation-through-deallocation path | Platform-backed hibernation path | Use when the VM is configured for hibernation. |

#### `task`

| Usage pattern | Key parameters | What it does | When to use it | Important notes |
| --- | --- | --- | --- | --- |
| `.\az-vm.cmd task --list --vm-init` | `--list`, `--vm-init` | Lists init tasks | Init audit | Shows real execution order. |
| `.\az-vm.cmd task --list --vm-update --windows` | `--list`, `--vm-update`, `--windows` | Lists Windows update tasks | Update inspection | Good before isolated reruns. |
| `.\az-vm.cmd task --list --disabled --vm-update --windows` | `--disabled` | Lists disabled tasks | Cleanup or contract review | Surfaces disabled reason and source. |
| `.\az-vm.cmd task --run-vm-init 01 --group <resource-group> --vm-name <vm-name>` | `--run-vm-init`, target selectors | Runs one init task directly | Isolated bootstrap rerun | Uses Azure run-command against one managed VM. |
| `.\az-vm.cmd task --run-vm-update 10002 --group <resource-group> --vm-name <vm-name> --windows` | `--run-vm-update`, platform | Runs one update task directly | Isolated guest fix | Uses the SSH task runner against one managed VM; task-signaled immediate restarts still run, but the workflow-only final vm-update restart does not. |
| `.\az-vm.cmd task --save-app-state --vm-update-task=115 --group=<resource-group> --vm-name=<vm-name> -s <subscription-guid>` | `--save-app-state`, `--vm-update-task`, target selectors | Captures one live task-owned app-state payload into the task-local `<task-folder>/app-state/app-state.zip` | Refreshing an operator-owned payload from the active VM | Cleanly skips when no capture coverage exists. |
| `.\az-vm.cmd task --restore-app-state --vm-update-task=115 --group=<resource-group> --vm-name=<vm-name> -s <subscription-guid>` | `--restore-app-state`, `--vm-update-task`, target selectors | Replays one saved task-owned app-state payload to the active VM | Targeted state restore after reinstall or cleanup | Fails cleanly when the requested zip is missing or invalid, and otherwise verifies the guest replayed content and rolls back from guest-side backup staging on mismatch. |
| `.\az-vm.cmd task --save-app-state --source=lm --user=.current. --vm-update-task=115 --windows` | `--save-app-state`, `--source=lm`, `--user=.current.` | Captures one local-machine task payload into the same task-local zip path | Refreshing a portable app-state payload from the operator machine | Windows-host-only. |
| `.\az-vm.cmd task --restore-app-state --target=lm --user=.current. --vm-update-task=115 --windows` | `--restore-app-state`, `--target=lm`, `--user=.current.` | Restores one task-local payload back onto the operator machine | Safe local replay and troubleshooting | Validates `task.json`, writes task-adjacent `backup-app-states/<task-name>/` snapshots plus `restore-journal.json` and `verify-report.json`, and rolls back on verification failure. |

#### `exec`

| Usage pattern | Key parameters | What it does | When to use it | Important notes |
| --- | --- | --- | --- | --- |
| `.\az-vm.cmd exec --group <resource-group> --vm-name <vm-name>` | target selectors | Opens the interactive remote-shell path | Manual guest work | Interactive shell mode is used when no `--command` is provided. |
| `.\az-vm.cmd exec --command "Get-Date" --group <resource-group> --vm-name <vm-name>` | `--command`, target selectors | Runs one remote command over SSH | One-shot diagnosis or manual admin action | Uses PowerShell on Windows and bash on Linux. |
| `.\az-vm.cmd exec --quiet --command "Get-Date" --group <resource-group> --vm-name <vm-name>` | `--quiet`, `--command`, target selectors | Runs one remote command and prints only its result | Script-friendly automation | Suppresses banner, progress, and completion chatter. |
| `.\az-vm.cmd exec -c "uname -a" --group <resource-group> --vm-name <vm-name>` | `-c`, target selectors | Same one-shot remote command path with short syntax | Operator convenience | `-c` and `--command` are equivalent. |

#### `connect`

| Usage pattern | Key parameters | What it does | When to use it | Important notes |
| --- | --- | --- | --- | --- |
| `.\az-vm.cmd connect --ssh --vm-name <vm-name>` | `--ssh`, `--vm-name` | Opens SSH with default targeting | Direct shell access | Only works when the VM is already running. |
| `.\az-vm.cmd connect --ssh --group <resource-group> --vm-name <vm-name> --user assistant` | `--ssh`, `--group`, `--vm-name`, `--user` | Opens SSH as a selected user | Role-specific shell access | Password entry remains local. |
| `.\az-vm.cmd connect --ssh --group <resource-group> --vm-name <vm-name> --user manager --test` | `--ssh`, `--test` | Runs a non-interactive SSH handshake check | Release and connection verification | Helpful before opening a real session. |
| `.\az-vm.cmd connect --rdp --vm-name <vm-name>` | `--rdp`, `--vm-name` | Opens RDP with default targeting | Windows desktop access | Only works when the VM is already running. |
| `.\az-vm.cmd connect --rdp --group <resource-group> --vm-name <vm-name> --user assistant` | `--rdp`, `--group`, `--vm-name`, `--user` | Opens RDP as a selected user | Assistant desktop access | Uses `cmdkey` before `mstsc.exe`. |
| `.\az-vm.cmd connect --rdp --group <resource-group> --vm-name <vm-name> --user manager --test` | `--rdp`, `--test` | Runs a non-interactive TCP reachability check | Release and connection verification | Useful before a full interactive desktop session. |

#### `move`

| Usage pattern | Key parameters | What it does | When to use it | Important notes |
| --- | --- | --- | --- | --- |
| `.\az-vm.cmd move --group=<resource-group> --vm-name=<vm-name> --vm-region=swedencentral -s <subscription-guid>` | `--group`, `--vm-name`, `--vm-region`, `-s` | Performs a health-gated regional move | Planned cutover | Expect a longer-running operation with snapshot copy time. |

#### `resize`

| Usage pattern | Key parameters | What it does | When to use it | Important notes |
| --- | --- | --- | --- | --- |
| `.\az-vm.cmd resize --group=<resource-group> --vm-name=<vm-name> --vm-size=Standard_D4as_v5 --windows` | `--vm-size` | Changes the VM SKU in the same region | Compute sizing changes | Same-region only. |
| `.\az-vm.cmd resize --group=<resource-group> --vm-name=<vm-name> --disk-size=196gb --expand --windows` | `--disk-size`, `--expand` | Performs supported managed OS disk growth | Safe in-place disk growth | Deallocates the VM, updates disk size, and starts it again. |
| `.\az-vm.cmd resize --group=<resource-group> --vm-name=<vm-name> --disk-size=98304mb --expand` | `mb` units | Performs the same expand path with MB input | Operator convenience | The runtime normalizes to Azure-safe GB values. |
| `.\az-vm.cmd resize --group=<resource-group> --vm-name=<vm-name> --disk-size=64gb --shrink` | `--shrink` | Stops before mutation and explains supported alternatives | Operator guidance only | `--disk-size=... --shrink` is a non-mutating guidance path because Azure does not support shrinking an existing managed OS disk in place; the command prints supported rebuild and migration alternatives instead of risking disk integrity |

#### `set`

| Usage pattern | Key parameters | What it does | When to use it | Important notes |
| --- | --- | --- | --- | --- |
| `.\az-vm.cmd set --group=<resource-group> --vm-name=<vm-name> --hibernation=off -s <subscription-guid>` | `--hibernation` | Changes hibernation state | Feature-state management | Syncs the successful change into `.env`. |
| `.\az-vm.cmd set --group=<resource-group> --vm-name=<vm-name> --nested-virtualization=off` | `--nested-virtualization` | Saves the requested nested virtualization setting | Repo setting sync | Azure single-VM APIs do not expose a separate nested-virtualization toggle |
| `.\az-vm.cmd set --group=<resource-group> --vm-name=<vm-name> --hibernation=on --nested-virtualization=off` | both flags | Applies both feature controls | Coordinated feature changes | Partial success still updates local state for the successful part. |

#### `delete`

| Usage pattern | Key parameters | What it does | When to use it | Important notes |
| --- | --- | --- | --- | --- |
| `.\az-vm.cmd delete --target=vm --group=<resource-group> --yes` | `--target=vm`, `--yes` | Deletes only the VM scope | Controlled cleanup | Destructive by design. |
| `.\az-vm.cmd delete --target=group --group=<resource-group> --yes -s <subscription-guid>` | `--target=group`, `--yes`, `-s` | Deletes the full managed group | Full teardown | Best used when the target is explicitly safe to purge. |

#### `help`

| Usage pattern | Key parameters | What it does | When to use it | Important notes |
| --- | --- | --- | --- | --- |
| `.\az-vm.cmd -h` | `-h` | Prints the quick overview | Fast discovery | Same as `--help`. |
| `.\az-vm.cmd help` | `help` | Prints the detailed command catalog | Full command reference | Good onboarding path for new operators. |
| `.\az-vm.cmd help move` | one command topic | Prints one command's details | Deep dive into one operation | Best companion to the command matrix. |

## Practical And Extensive Usage Scenarios

### Create A Fresh Managed VM
```powershell
.\az-vm.cmd create --auto
.\az-vm.cmd create --step=network --linux
.\az-vm.cmd create --step-from=vm-deploy --step-to=vm-summary --perf
.\az-vm.cmd delete --target=group --group=<resource-group> --yes
.\az-vm.cmd create --auto
```

Practical outcomes:
- the default path creates one fresh managed resource group and one fresh VM target
- interactive mode proposes the next globally unique managed `gX` group id and globally unique managed `nX` resource ids
- auto mode succeeds when CLI overrides or `.env` `SELECTED_*` values plus the platform VM defaults resolve platform, VM name, Azure region, and VM size
- when a destructive rebuild is intentional, run `delete` first and then run `create`
- the same step model works in interactive and auto mode

### Update An Existing Managed VM
```powershell
.\az-vm.cmd update --auto
.\az-vm.cmd update --step=vm-update --auto --group=<resource-group> --vm-name=<vm-name>
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
.\az-vm.cmd configure
.\az-vm.cmd show --group=<resource-group>
.\az-vm.cmd do --vm-action=status --vm-name=<vm-name>
```

Practical outcomes:
- `list` gives a read-only managed inventory view across groups and resource types
- `configure` gives a safe interactive frontend for every supported `.env` key, with picker-backed multi-option fields and a next-create preview before save
- `show` gives an inventory snapshot while password-bearing `.env` values are redacted, and adds target-derived configuration when one managed VM is in scope
- `do --vm-action=status` is the quickest preflight check before a mutating change

### Run One Task Or Open A Remote Shell
```powershell
.\az-vm.cmd task --list --vm-update --windows
.\az-vm.cmd task --run-vm-update 10099 --group <resource-group> --vm-name <vm-name> --windows
.\az-vm.cmd task --run-vm-init 01 --group <resource-group> --vm-name <vm-name>
.\az-vm.cmd exec --group <resource-group> --vm-name <vm-name>
.\az-vm.cmd connect --ssh --group <resource-group> --vm-name <vm-name> --user manager
.\az-vm.cmd connect --rdp --group <resource-group> --vm-name <vm-name> --user assistant
```

Practical outcomes:
- support and development teams can rerun only the failing task instead of replaying the whole deployment
- `task` exposes the real discovered inventory, including tracked and local-only tasks
- `connect --ssh` and `connect --rdp` remain direct operator commands, with `--user=manager --test` available for non-interactive validation

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
.\az-vm.cmd do --vm-action=redeploy --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd do --vm-action=stop --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd do --vm-action=hibernate-stop --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd do --vm-action=hibernate-deallocate --group=<resource-group> --vm-name=<vm-name>
```

### Connect To The VM
```powershell
.\az-vm.cmd do --vm-action=start --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd connect --ssh --group=<resource-group> --vm-name=<vm-name>
.\az-vm.cmd connect --rdp --group=<resource-group> --vm-name=<vm-name> --user=assistant
```

## Command Guide

### Global Options
- `--version`: print the current documented az-vm release and exit without loading the normal command workflow
- `--auto`: unattended mode for `create`, `update`, and `delete`
- `--perf`: print timing metrics
- `--windows`, `--linux`: explicit platform selection or platform expectation
- `-s`, `--subscription-id=<subscription-guid>`: target Azure subscription for every Azure-touching command; successful CLI usage also writes `SELECTED_AZURE_SUBSCRIPTION_ID` into `.env`.
- `-h`, `--help`: print quick or command-specific help
- Canonical target selectors are `--group` / `-g`, `--vm-name` / `-v`, and `--subscription-id` / `-s`; value-taking options accept both `--option=value` and `--option value`, plus short-form `-x=value` and `-x value` when a short alias exists.

Azure subscription selection precedence is: CLI `--subscription-id` / `-s` -> `.env` `SELECTED_AZURE_SUBSCRIPTION_ID` -> active Azure CLI subscription.

### `configure`
Purpose: review, edit, validate, preview, and save the supported `.env` contract through one interactive frontend.

Behavior notes:
- interactive-only `.env` editor
- shows every supported `.env` key in section order derived from `.env.example`
- uses a picker for every finite or discoverable multi-option field
- stages edits in memory until final confirmation, then writes only supported `.env` keys once
- renders a next-create preview with effective platform inputs plus next managed resource names when Azure validation is available
- can open without `az login`, but Azure-backed fields stay read-only until Azure validation is available
- recovers softly for blank-permitted fields, including clearing `SELECTED_RESOURCE_GROUP` when no managed resource groups exist, and blocks save only when create-critical values remain unresolved

### `create`
Purpose: build one fresh managed resource group, one fresh managed VM, and then continue with the init/update workflow when selected.

Behavior notes:
- `create` now stays dedicated to one fresh managed resource group plus one fresh managed VM; use `delete` and then `create` when a destructive rebuild is intentional.
- `create` never reuses an existing managed resource group or existing managed resource names, and `update` never falls through to an implicit fresh-create path.
- Auto `create` succeeds when CLI overrides or `.env` `SELECTED_*` values plus the platform defaults resolve platform, VM name, Azure region, and VM size.
- Reboot-signaling `vm-init` and `vm-update` tasks restart the VM immediately, wait for recovery, and then continue with the next task. During end-to-end `create` and `update`, Windows `vm-update` also performs one additional final restart before `vm-summary`.
- if `--windows` or `--linux` is omitted, interactive mode asks for the VM OS type first and then scopes size, disk, and image defaults to that selection
- Interactive `create` and `update` use `yes/no/cancel` review checkpoints only for `group`, `vm-deploy`, `vm-init`, and `vm-update`.
- `configure` and `vm-summary` stay visible in both interactive and auto mode, even when partial step selection skips interior stages.

### `update`
Purpose: maintain one existing managed resource group and one existing VM target.

Behavior notes:
- `update` now requires an existing managed resource group and VM, then applies create-or-update operations plus `az vm redeploy` in one guided maintenance flow.
- Auto `update` resolves its target from CLI overrides first, then `.env` `SELECTED_RESOURCE_GROUP` and `SELECTED_VM_NAME`, with single-VM auto-resolution allowed when the selected group contains exactly one VM.
- Reboot-signaling `vm-init` and `vm-update` tasks restart the VM immediately, wait for recovery, and then continue with the next task. During end-to-end `create` and `update`, Windows `vm-update` also performs one additional final restart before `vm-summary`.
- best fit for day-two maintenance, guest-task refresh, and Azure redeploy-backed repair

### `list`
Purpose: print read-only managed inventory sections for az-vm-tagged resource groups and resources.

Behavior notes:
- supports `--type` and `--group` for managed inventory output
- `list` gives a read-only managed inventory view across groups and resource types
- Azure-read-only output; `--subscription-id` / `-s` only changes the subscription context and persists `SELECTED_AZURE_SUBSCRIPTION_ID` when it comes from the CLI

### `show`
Purpose: print a full system and configuration dump for app resource groups and VMs.

Behavior notes:
- good for support handoff, release verification, and environment auditing
- password-bearing `.env` values are redacted
- when the VM is running, nested virtualization is shown from guest validation evidence

### `do`
Purpose: apply one VM lifecycle action or print the current VM lifecycle state.

Behavior notes:
- use `status` before mutating changes
- `reapply` and `redeploy` are available for Azure-side repair on an existing VM
- `hibernate-stop` and `hibernate-deallocate` remain explicit, separate operator paths

### `task`
Purpose: list discovered init/update tasks in runtime order, run one task in isolation, or save/restore one task-owned app-state payload.

Behavior notes:
- shows tracked and local-only task folders together
- `--run-vm-init` routes one init task through Azure run-command and relays the full guest transcript immediately after that task finishes
- `--run-vm-update` routes one update task through the SSH task runner and streams guest stdout/stderr live over SSH
- `--save-app-state` defaults to `--source=vm`; `--restore-app-state` defaults to `--target=vm`; both default to `--user=.all.`
- `--user` accepts `.all.`, `.current.`, one explicit user, or a comma-separated user list such as `--user=operator,assistant`
- managed VM app-state reads or writes the task-local payload at `<task-folder>/app-state/app-state.zip`
- VM restore uses guest-side temporary backup staging, verifies restored files and registry after replay, and rolls back automatically if verification fails
- local-machine save/restore is Windows-host-only and reuses the same task-local payload path
- init and update restore flows both reuse the same shared per-task app-state post-process over SSH; init defers replay until SSH is reachable and update replays immediately over SSH
- task-owned app-state payloads target only the managed `manager` and `assistant` OS profiles on VM paths; missing zips skip cleanly, and broad generated caches, installers, models, and telemetry payloads are pruned from the managed capture contract
- local restore validates the current `task.json` allow-list, writes task-adjacent `backup-app-states/<task-name>/` snapshots plus `restore-journal.json` and `verify-report.json` first, verifies the replayed content, and rolls back the current target user if replay or verification fails
- useful before isolated reruns or when checking timeout and enable-state behavior

### `exec`
Purpose: open the direct remote shell path or run one one-shot remote command.

Behavior notes:
- ideal for isolated diagnosis or manual guest work
- resolves only the selected VM plus SSH context
- `--command` / `-c` runs one remote PowerShell or bash snippet without opening the interactive shell
- `--quiet` / `-q` is valid only with `--command` / `-c` and prints only the remote command result

### `connect`
Purpose: launch the local Windows OpenSSH client or Remote Desktop client for a managed VM, or run connection tests without opening the client.

Behavior notes:
- only works when the VM is already running
- requires exactly one transport flag: `--ssh` or `--rdp`
- `--test` performs a non-interactive handshake or reachability check instead of opening the external client
- `connect --rdp` is only valid for Windows VMs

### `move`
Purpose: move a managed VM to another Azure region with a health-gated cutover.

Observed reference timing:
- live reference for `austriaeast -> swedencentral`, `Standard_D4as_v5`, `127 GB` OS disk: about `25-30 minutes`
- the longest phase was cross-region snapshot copy at about `17-19 minutes`

### `resize`
Purpose: change the VM size or expand the managed OS disk in-place within the current region.

Behavior notes:
- same-region only
- `--vm-size` changes compute SKU
- `--disk-size=... --expand` performs the supported managed OS disk growth path
- `--disk-size=... --shrink` is a non-mutating guidance path because Azure does not support shrinking an existing managed OS disk in place; the command prints supported rebuild and migration alternatives instead of risking disk integrity

### `set`
Purpose: apply hibernation and validate or store nested-virtualization settings.

Behavior notes:
- Hibernation is changed through Azure.
- Azure single-VM APIs do not expose a separate nested-virtualization toggle
- successful changes are synchronized back into local `.env`

### `delete`
Purpose: delete a selected scope from a managed resource group.

Behavior notes:
- destructive by design
- requires explicit target selection
- `--yes` is the non-interactive confirmation bypass

### `help`
Purpose: print the quick overview or one-command help.

Behavior notes:
- use `.\az-vm.cmd -h` or `.\az-vm.cmd --help` for the overview
- use `.\az-vm.cmd help <command>` for one command topic

## Task Authoring And Execution

### Task Folder Ownership
Every task is a portable folder. The folder name defines the task identity, the same-named script defines the executable body, and `task.json` defines ordering, enable state, timeout, assets, and app-state capture coverage. Runtime code must not rewrite `task.json` automatically.

### Task Naming Rules
- `<task-number>-verb-noun-target/`
- task-number bands:
  - `01-99` = `initial`
  - `101-999` = `normal`
  - `1001-9999` = local-only
  - `10001-10099` = `final`
- 2-5 English words in kebab-case
- each task folder contains one same-named `.ps1` or `.sh` script plus `task.json`

### Timeouts, Priority, And Enable Flags
- every task folder uses `task.json` for `priority`, `enabled`, `timeout`, optional `assets`, and optional `appState`
- local-only tasks under `local/` are discovered from disk dynamically
- local-only tasks under `local/disabled/` remain disabled by location
- task asset paths are resolved relative to the owning task folder
- task-folder discovery scans the stage root, `disabled/`, `local/`, and `local/disabled/`
- missing task folders behave as if the task never existed; malformed task folders warn and skip; duplicate task names or duplicate effective priorities still fail fast
- missing `priority`: default to the filename task number when available, otherwise `1000`
- missing `timeout`: default to `180`
- builtin `initial` task folders, builtin `normal` task folders, local task folders from `local/`, then builtin `final` task folders

### Direct Task Execution With `task`
Direct `task --run-vm-init` and `task --run-vm-update` are the main diagnosis path when one task needs to be rerun without replaying the entire orchestration chain.

Current task template replacement uses the public selected-value placeholders: `__SELECTED_VM_NAME__`, `__SELECTED_AZURE_REGION__`, `__SELECTED_RESOURCE_GROUP__`, `__SELECTED_COMPANY_NAME__`, `__SELECTED_COMPANY_WEB_ADDRESS__`, `__SELECTED_COMPANY_EMAIL_ADDRESS__`, `__SELECTED_EMPLOYEE_EMAIL_ADDRESS__`, and `__SELECTED_EMPLOYEE_FULL_NAME__`.

Task-scoped app-state capture and replay use the same portable task folder contract. The current task-local zip path is always `<task-folder>/app-state/app-state.zip`, and the current app-state allow-list lives beside it in the same folder's `task.json`. Local-machine restore snapshots live beside the stage as `backup-app-states/<task-name>/`, or `local/backup-app-states/<task-name>/` for local-only tasks, and those roots carry both `restore-journal.json` and `verify-report.json`.

## Configuration Guide

### Runtime Precedence
Runtime precedence is:
1. CLI override
2. `.env`
3. hard-coded default

This matters because:
- command-line overrides are the safest way to test one change without rewriting local defaults
- `.env.example` is the committed configuration contract
- `.env` remains local and untracked

### High-Value `.env` Keys
- `SELECTED_VM_OS`: persisted active platform selection
- `SELECTED_VM_NAME`: persisted active VM naming seed for unattended and existing-target flows
- `SELECTED_AZURE_REGION`: persisted active region selection
- `SELECTED_RESOURCE_GROUP`: persisted active existing-target group selection
- `SELECTED_AZURE_SUBSCRIPTION_ID`: optional repo-local default Azure subscription id for Azure-touching commands
- `VM_ADMIN_USER`, `VM_ADMIN_PASS`: manager/admin identity
- `VM_ASSISTANT_USER`, `VM_ASSISTANT_PASS`: assistant identity
- `SELECTED_COMPANY_NAME`, `SELECTED_COMPANY_WEB_ADDRESS`, `SELECTED_COMPANY_EMAIL_ADDRESS`, `SELECTED_EMPLOYEE_EMAIL_ADDRESS`, `SELECTED_EMPLOYEE_FULL_NAME`: Windows shortcut and UX identity inputs
- `VM_PRICE_COUNT_HOURS`: pricing window used by SKU-selection helpers
- `AZURE_COMMAND_TIMEOUT_SECONDS`: shared Azure command timeout
- `PYSSH_CLIENT_PATH`: default path should remain `tools/pyssh/ssh_client.py`

### Shared VM Feature Toggles
- `VM_ENABLE_HIBERNATION`
- `VM_ENABLE_NESTED_VIRTUALIZATION`

Use these as shared cross-platform intent flags instead of creating platform-specific duplicates.

### Platform-Specific Settings
- `WIN_` keys are for Windows-only settings such as Windows image and disk-size defaults.
- `LIN_` keys are for Linux-only settings such as Linux image and disk-size defaults.
- The committed managed-resource templates in `.env.example` use `{SELECTED_VM_NAME}` as the naming placeholder, for example `rg-{SELECTED_VM_NAME}-{REGION_CODE}-g{N}`.
- Managed resource group ids use a global `gX` suffix that increments across all managed groups, regardless of region.
- Managed resource ids use a global `nX` suffix that increments across all generated managed resources and is never reused by another managed resource of any type.

### Connection And Task Settings
- Configure SSH and RDP ports through the committed runtime contract instead of editing tasks blindly.
- Keep long-running task timeouts in `task.json`, not hidden in repo-wide runtime logic.
- Use `--perf` when you want timing evidence for long-running flows.

### Global Versus Task-Local Configuration
- Keep app-wide customization, secrets, operator identity, and reusable overrides in `.env`.
- Task-only constants should stay in the owning task script, in a clearly labeled config block at the top of the owning `vm-init` or `vm-update` script.

## Developer Benefits

### Why Developers Move Faster
- One orchestrator means less context switching between separate scripts for provisioning, update, connection, and repair.
- The same command surface covers Windows and Linux, so platform differences stay narrow and explicit.
- `create` now stays dedicated to one fresh managed resource group plus one fresh managed VM; use `delete` and then `create` when a destructive rebuild is intentional.
- `update` now requires an existing managed resource group and VM, then applies create-or-update operations plus `az vm redeploy` in one guided maintenance flow.
- `resize --disk-size=... --expand` gives a safe in-place managed OS disk growth path, while `resize --disk-size=... --shrink` stops early and explains the supported alternatives instead of risking data loss.
- Direct `task` and `exec` flows let maintainers inspect and rerun exactly the step or task that matters.

### Daily Maintainer Flow
1. Confirm the target with `list`, `show`, `configure`, and `do --vm-action=status`.
2. Use `create` for first deploys and fresh environments; when a full destructive rebuild is intentional, run `delete` first and then run `create`.
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
- `vm-init` is Azure Run Command driven and is used for early guest bootstrap, one task at a time.
- `vm-update` is pyssh driven and is used for richer task-by-task update flows after the VM is reachable.
- `vm-init` relays the full guest transcript back to the local az-vm console as soon as each task completes, while `vm-update` streams guest stdout/stderr live over SSH while the task is still running.
- Both stages use portable task folders plus `task.json` as the source of truth for ordering, timeout, and enable/disable state, and both now invoke the same per-task app-state restore helper as a post-task step when a matching task-local plugin zip exists.
- The natural execution order for both stages is: builtin `initial` task folders, builtin `normal` task folders, local task folders from `local/`, then builtin `final` task folders.
- Every task timeout is normalized to a minimum of `30` seconds and then rounded up in `15`-second slots.
- Reboot-signaling tasks restart the VM immediately, wait for the required transport recovery, and then resume from the next task. During end-to-end `create` and `update`, Windows `vm-update` also performs one unconditional final restart before `vm-summary`; isolated `task --run-vm-update` reruns skip that workflow-only final restart.
- `vm-summary` begins with a read-only guest readback block and then continues with the normal summary and connection details.

### Interactive Versus Auto Mode
- Interactive mode is the default and prompts when required values are missing.
- Interactive `create` and `update` always show the configuration screen first and the VM summary screen last.
- Interactive `create` and `update` use `yes/no/cancel` review checkpoints only for `group`, `vm-deploy`, `vm-init`, and `vm-update`.
- `--auto` is for unattended `create`, `update`, and `delete` flows.
- Auto `create` runs from the resolved CLI-or-`.env` selection set; when `.env` is complete, `create --auto` does not need repeated platform, VM name, region, or size flags.
- Auto `update` resolves its managed target from CLI overrides first, then `.env` `SELECTED_RESOURCE_GROUP` and `SELECTED_VM_NAME`.
- Auto mode prints the same review context, but it continues without waiting for checkpoint confirmation.
- `configure` and `vm-summary` stay visible in both interactive and auto mode, even when partial step selection skips interior stages.
- Operator commands such as `show`, `do`, `connect`, and `exec` stay direct and do not require `--auto`.

### Naming And Managed Resource Rules
- `SELECTED_VM_NAME` is the persisted naming seed.
- Managed names are template-driven and deterministic.
- Managed resource group ids use a global `gX` suffix that increments across all managed groups, regardless of region.
- Managed resource ids use a global `nX` suffix that increments across all generated managed resources and is never reused by another managed resource of any type.
- Runtime code validates names before Azure mutation.

## Architecture From Zero To Hero

### Entrypoints And Runtime Modules
- `az-vm.cmd` exists to give Windows operators a simple launcher path.
- `az-vm.ps1` loads `modules/azvm-runtime-manifest.ps1`, then dot-sources the ordered runtime leaf files directly before dispatching the command surface.
- There is no transitional root-loader layer for `core`, `config`, `commands`, `ui`, or `tasks`; the launcher resolves the refactored module tree directly.
- `modules/core/` holds shared contracts, CLI helpers, system/runtime utilities, task discovery, and host mirroring logic.
- `modules/config/` isolates dotenv, naming-template, region-code, and related config helpers from command and UI code.
- `modules/commands/` owns the public command surface plus shared create/update pipeline helpers.
- `modules/ui/` is restricted to operator interaction concerns such as prompts, selection flows, report rendering, and connection-facing helpers.
- `modules/tasks/` is split into Azure Run Command and persistent SSH internals so guest transport logic stays reusable and explicit.

### Configuration Resolution
Runtime precedence is:
1. CLI override
2. `.env`
3. hard-coded default

This matters because:
- command-line overrides are the safest way to test one change without rewriting local defaults
- `.env.example` is the committed contract
- `.env` remains local and untracked

### Task Folder Model
Each task directory is self-contained. The folder holds one same-named script, one `task.json`, optional helper assets, and an optional git-ignored `app-state/` directory. The runtime never auto-writes `task.json`, and a missing portable task folder is treated as absent rather than as a failure.

### Windows And Linux Execution Model
- Windows and Linux share the same top-level orchestration model.
- Guest task language, package model, access model, and platform-specific tooling differ only where they must.
- Help output, docs, and runtime wording try to stay parallel across both platforms.

### End-To-End Create And Update Flow
- `create` is fresh-only: it creates one new managed resource group plus one new managed VM target and must not be documented or wired as an existing-resource reuse path.
- `update` is existing-managed-target only: it requires one existing managed resource group plus one existing VM and must not fall through to implicit fresh-create behavior.
- `configure` is the interactive `.env` frontend: it must stay focused on reviewing, editing, validating, previewing, and saving supported `.env` values, and it must not sync `.env` from a live Azure target.
- `list` is the managed inventory command: it must stay Azure-read-only, must not mutate Azure resources, and must expose managed resource listings through `--type` plus optional exact `--group` filtering.

### Safety Model And Failure Handling
- Validate before mutating Azure resources.
- Prefer fast, filtered Azure checks over broad slow listings.
- If Azure does not support a requested operation safely, fail before mutation with the explicit platform reason and list the supported alternatives.
- Avoid retry storms; retry behavior should stay explicit and intentionally bounded.

### Documentation, History, And Release Discipline
- `README.md` is the operator and contributor guide.
- `CHANGELOG.md` and `release-notes.md` are updated in the same final change set as shipped behavior or contract changes.
- `docs/prompt-history.md` keeps the English-normalized prompt ledger.
- `.github/workflows/quality-gate.yml` is the non-live GitHub Actions quality gate workflow.

## Troubleshooting Guide

### Validation Failures
- Check region, image, and SKU first.
- Confirm the naming seed and resource templates.
- Prefer fixing config and rerunning the isolated failing command instead of restarting from zero immediately.

### Task Failures
- Rerun the failing task with `task --run-vm-init` or `task --run-vm-update`.
- Check `task.json` timeout and enabled state.
- Vm-init and vm-update app-state replay are post-task and plug-in based. If `<task-folder>/app-state/app-state.zip` is absent, the task logs a skip and continues; if it exists, the shared SSH post-process deploys it without requiring a dedicated restore task, and vm-init defers replay until SSH is ready.
- Managed app-state save and restore target only the `manager` and `assistant` OS profiles. Large generated payloads such as installers, models, telemetry trees, and low-value caches are intentionally pruned so the zips stay operator-owned and reusable instead of drifting into machine-image snapshots.
- Local-machine app-state restore validates the current `task.json` allow-list and writes task-adjacent `backup-app-states/<task-name>/` snapshots plus `restore-journal.json` and `verify-report.json` before replaying onto the operator machine.
- Windows public desktop shortcut validation names the exact missing `.env` keys, for example `SELECTED_COMPANY_NAME is required for the Windows business public desktop shortcut flow.` and `SELECTED_EMPLOYEE_EMAIL_ADDRESS is required for the Windows public desktop shortcut flow.`
- Use `VM_TASK_OUTCOME_MODE=strict` when you want the stage to stop at the first failure.

### Connection Failures
- Check `do --vm-action=status`.
- Confirm the VM is running before `connect --ssh` or `connect --rdp`.
- Verify guest firewall, NSG exposure, and configured ports together.
- If Azure keeps the VM in provisioning state `Updating`, the connection and direct-task runtime now performs one bounded `az vm redeploy` repair attempt before it gives up.

### Move And Resize Expectations
- `move` is a deliberate cutover operation with downtime and cross-region copy time.
- `resize` is same-region only and is much smaller in scope than `move`.
- managed OS disk shrink is intentionally blocked as an unsupported Azure scenario; use the printed rebuild or migration alternatives instead.
- both commands validate before mutation and return friendly hints on invalid state or configuration.

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
- The local hook path blocks obvious contact-style values, concrete identity leaks, and non-placeholder sensitive config drift before commits and pushes are shared.

### Quality Gates
Run these locally:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\code-quality-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\sensitive-content-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\documentation-contract-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\powershell-compatibility-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\az-vm-smoke-tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bash-syntax-check.ps1
```

`code-quality-check.ps1` and the local commit hook keep the current tree and the current commit message clean. Run `.\tests\sensitive-content-check.ps1` directly when you also want the full reachable-history commit-message audit.

GitHub Actions runs the non-destructive `.github/workflows/quality-gate.yml` workflow on pull requests, pushes to `main`, and manual dispatch. It covers static audit, an explicit documentation-contract check, PowerShell compatibility, Linux shell syntax, workflow linting, and the non-live smoke-contract suite.
For a release push, the job is not finished until the pushed `main` SHA completes this workflow green.

### Live Release Acceptance
Before calling the repo or the active profile release-ready for a live publish, run one end-to-end live acceptance cycle against the current `.env` target:
- if the target group is safe to purge, prefer a full recreate by running `az-vm delete --target=group --group=<resource-group> --yes` before the live create
- run a clean `az-vm create --auto --perf` once the target `.env` `SELECTED_*` values and platform defaults are complete
- rerun `az-vm update --auto --perf` without changing the natural task order
- confirm `az-vm show` prints the expected inventory while password-bearing `.env` values stay redacted
- confirm `az-vm do --vm-action=status --vm-name=<vm-name>` reports the VM as started
- confirm `az-vm connect --ssh --vm-name=<vm-name> --user=manager --test`; for Windows also confirm `az-vm connect --rdp --vm-name=<vm-name> --user=manager --test`
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
- when a maintained document records a time-of-day, record it in UTC

### Prompt History Rule
- Very short approval/confirmation/follow-up prompts are not auto-recorded.
- Non-mutating questions, analysis requests, and investigation-only prompts are not auto-recorded.
- All other substantive prompts are recorded.
- Excluded prompt types are recorded only after explicit user confirmation.
- Recorded entries are stored in English. If the original dialog was not English, it is translated before recording.
- Prompt-history headings use `### YYYY-MM-DD HH:MM UTC`.

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
- `docs/windows-store-migration-audit.md`: current Windows installer-source audit, including which Store migrations are already active and which candidates still wait for explicit approval.

## License And Sponsorship
This repository is distributed under the custom non-commercial license in [LICENSE](LICENSE).

High-level intent:
- learning, teaching, evaluation, and private non-commercial modification are allowed
- public redistribution and commercial use require developer permission
- commercial licensing and sponsorship discussions should be directed to the developer

If this project saves time, reduces operational risk, or is useful in your environment, sponsorship helps keep the documentation, testing, and VM automation work moving forward.
