# az-vm

`az-vm` is a unified Azure VM provisioning and lifecycle toolkit for Windows and Linux. It creates or updates Azure infrastructure, prepares guest connectivity, executes init tasks, executes update tasks, and exposes operator-facing commands for inspection, maintenance, and connection.

## What This Project Is For
- Building reproducible Azure VM environments from one orchestrator.
- Keeping Linux and Windows deployment flow as close as possible.
- Providing a pragmatic operator UX for create, update, inspect, connect, and repair workflows.
- Maintaining explicit task catalogs instead of hidden guest-side logic.

## Repository Layout
- `az-vm.cmd`: elevated Windows launcher.
- `az-vm.ps1`: unified orchestrator entrypoint.
- `modules/`: runtime modules grouped by domain.
- `windows/init/`, `windows/update/`: Windows guest task catalogs.
- `linux/init/`, `linux/update/`: Linux guest task catalogs.
- `tools/`: helper tooling including pyssh bootstrap, git-hook toggles, and manual support scripts.
- `tests/`: static and compatibility checks.
- `docs/`: prompt history and supporting operational documentation.

## Command Surface
- `configure`: interactive configuration and preview without Azure mutation.
- `create`: create missing resources and continue through the configured step window.
- `update`: rerun create-or-update logic on existing managed resources.
- `group`: list or select managed resource groups.
- `show`: print a human-readable resource and VM inventory.
- `do`: inspect or change the power/lifecycle state of one managed VM.
- `exec`: run one init task, one update task, or open an interactive remote shell path; direct task runs can target one VM with `--group` plus `--vm-name`.
- `ssh`: launch the local Windows OpenSSH client for a managed VM.
- `rdp`: launch the local Remote Desktop client for a managed Windows VM.
- `move`: migrate a managed VM to another Azure region.
- `resize`: change the VM size in-place within the current region.
- `set`: toggle supported VM feature flags such as hibernation and nested virtualization.
- `delete`: purge a selected scope such as group, network, VM, or disk.
- `help`: show quick or detailed command help.

## Orchestration Model
Top-level steps are:
1. `configure`
2. `group`
3. `network`
4. `vm-deploy`
5. `vm-init`
6. `vm-update`
7. `vm-summary`

Execution semantics:
- `vm-init` runs through Azure Run Command in task-batch mode.
- `vm-update` runs task-by-task through persistent pyssh.
- isolated `exec --init-task` / `exec --update-task` runs resolve only the selected VM plus task context instead of traversing the broader create/update resource inventory path.
- Full `create` and `update` flows execute the whole step chain unless explicitly sliced.

## Runtime Modes
- Default mode is `interactive`.
- `--auto` / `-a` applies to `create`, `update`, and `delete`.
- `show`, `do`, `ssh`, and `rdp` are operator-style commands and do not need `--auto`.
- `exec` is interactive when no task selector is provided, otherwise direct.

## Platform Selection
Platform selection precedence is:
1. `--windows` or `--linux`
2. `VM_OS_TYPE` from `.env`
3. interactive prompt

In `--auto` mode, unresolved platform state must terminate gracefully with an actionable message.

## Configuration Model
Runtime precedence is:
1. CLI override
2. `.env`
3. hard-coded default

Key principles:
- `.env` is local and untracked.
- `.env.example` is the committed contract.
- Generic keys are preferred.
- `WIN_` / `LIN_` keys exist only for true platform-specific settings.
- `VM_NAME` is the single naming seed.

Important current keys include:
- `VM_OS_TYPE`
- `VM_NAME`
- `company_name` for the default Google Chrome `--profile-directory` used by repo-managed Windows public desktop web shortcuts such as internet, account-setup, and banking links
- `AZ_LOCATION`
- `VM_ADMIN_USER`, `VM_ADMIN_PASS`
- `VM_ASSISTANT_USER`, `VM_ASSISTANT_PASS`
- `VM_SSH_PORT`, `VM_RDP_PORT`
- `VM_TASK_OUTCOME_MODE`
- platform-specific image, size, disk, and task-directory keys

## Naming Strategy
Managed resource names are template-driven.

Core principles:
- `VM_NAME` is both the real Azure VM name and the naming seed.
- resource group and managed resource names derive from `VM_NAME`, region code, and the committed templates.
- uniqueness is suffix-based and deterministic.
- explicit overrides are allowed, but they are validated before mutation.

## Task Catalog Model
Task catalogs live beside the task files and drive:
- execution order
- priority
- timeout per task
- manual task enable/disable control

Catalog behavior:
- Catalog JSON files are never auto-written or auto-synchronized by runtime code.
- Missing catalog entry for a discovered task falls back to `priority=1000`, `enabled=true`, `timeout=180`.
- Missing `priority` in a catalog entry falls back to `1000`.
- Missing `timeout` in a catalog entry falls back to `180`.

Task naming rules:
- `NN-verb-topic.ext`
- two-digit task number
- 2-5 English words in kebab-case
- `.ps1` for Windows, `.sh` for Linux

## Connections
Connection helpers use the current managed VM state plus `.env` credentials.

- `ssh` launches local `ssh.exe`.
- `rdp` stages credentials with `cmdkey` and launches `mstsc.exe`.
- `ssh` and `rdp` only launch when the target VM is already running.
- `VM_SSH_PORT` and `VM_RDP_PORT` are the canonical connection-port keys.
- guest firewall and NSG port exposure must remain synchronized end-to-end.

## Quality and Testing
Current repo-level quality gates include:
- PowerShell parse validation
- PowerShell 5.1 and 7 compatibility checks
- Python syntax/cache hygiene for pyssh tooling
- CLI help smoke checks
- documentation contract checks
- Linux shell syntax checks in CI

Local quality entry points:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\code-quality-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\bash-syntax-check.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\powershell-compatibility-check.ps1
```

Manual git-history regression replay:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\scripts\git-history-replay.ps1 -Days 2
```
Use this only when you need to replay recent commits in detached worktrees to see where a quality regression entered history.

## Native Git Hooks
Enable the committed local hooks with:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\enable-git-hooks.ps1
```

Disable them again with:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\disable-git-hooks.ps1
```

Hook behavior:
- `pre-commit`: fast static and contract checks
- `pre-push`: fuller local audit path

## Release Versioning
- `CHANGELOG.md` and `release-notes.md` use `YYYY.M.D.N`.
- `N` is the cumulative repository commit count at the documented release point.
- The current documented release is `2026.3.10.258`.

## Documentation Set
- `AGENTS.md`: engineering contract.
- `README.md`: operator and contributor guide.
- `CHANGELOG.md`: detailed project history.
- `release-notes.md`: current release-oriented summary.
- `roadmap.md`: future work.
- `docs/prompt-history.md`: raw prompt plus assistant-summary ledger.

## Practical Operator Flows
Typical workflows:
```powershell
# configure only
.\az-vm.cmd configure

# create Windows VM end-to-end
.\az-vm.cmd create --auto --windows

# rerun update tasks on the active managed group
.\az-vm.cmd update --auto

# inspect the selected group
.\az-vm.cmd show --group=rg-examplevm-ate1-g1

# inspect or change one VM lifecycle state
.\az-vm.cmd do --vm-action=status --vm-name=examplevm
.\az-vm.cmd do --vm-action=deallocate --group=rg-examplevm-ate1-g1 --vm-name=examplevm
.\az-vm.cmd do --vm-action=hibernate --group=rg-examplevm-ate1-g1 --vm-name=examplevm
.\az-vm.cmd do --vm-action=stop --group=rg-examplevm-ate1-g1 --vm-name=examplevm    # keep provisioned; Azure hibernation deallocates

# resize the active VM in-place
.\az-vm.cmd resize --vm-name=examplevm --vm-size=Standard_D4as_v5 --group=rg-examplevm-ate1-g1
.\az-vm.cmd resize --vm-name=examplevm --vm-size=Standard_D2as_v5 --group=rg-examplevm-ate1-g1 --windows

# move the active VM to another Azure region with health-gated cutover
.\az-vm.cmd move --group=rg-examplevm-ate1-g1 --vm-name=examplevm --vm-region=swedencentral

# change one VM capability on the selected VM
.\az-vm.cmd set --group=rg-examplevm-ate1-g1 --vm-name=examplevm --hibernation=off

# run one guest update task
.\az-vm.cmd exec --update-task=27 --group=rg-examplevm-ate1-g1 --vm-name=examplevm --windows

# connect
.\az-vm.cmd do --vm-action=start --group=rg-examplevm-ate1-g1 --vm-name=examplevm
.\az-vm.cmd ssh --vm-name=examplevm
.\az-vm.cmd rdp --vm-name=examplevm --user=assistant
```

Move timing reference:
- Observed live reference for `austriaeast -> swedencentral`, `Standard_D4as_v5`, and a `127 GB` OS disk was roughly `25-30 minutes`.
- The longest phase was cross-region snapshot copy at about `17-19 minutes`; the rest was mostly source deallocate, target network/disk/VM rebuild, first target start, health checks, and old-group cleanup.
- Treat this as an operator expectation, not a guarantee. Region pair, disk size, Azure background load, and target start time can shift the total noticeably.

Move flow:
1. Validate the source group, target region/SKU, and auto-delete safety rules.
2. Deallocate the source VM so the snapshot-based cutover starts from a safe stopped state.
3. Create the source snapshot and start the target-region snapshot copy.
4. Wait until the target snapshot reports `Available` and `100%` copy completion.
5. Create the target resource group, network, NIC, disk, and VM in the new region.
6. Re-apply hibernation-related flags when required, then start the target VM.
7. Run the target health gate, including `29-health-snapshot` and port reachability checks.
8. Update the active target context, then delete the old source group only after the new VM is confirmed healthy.

## Troubleshooting Themes
Recurring patterns captured in this repo's history:
- region, image, and SKU validation must happen before mutation.
- Windows package tasks may require explicit PATH refresh or deferred first sign-in handling.
- long-running Azure operations should report timing without flooding logs.
- command-surface migrations should remove legacy forms instead of preserving compatibility shims.
- Linux and Windows flows should remain conceptually parallel even when guest tasks differ.

## Development Guidance
When changing this repo:
- update docs, tests, and config contracts together.
- keep current command names and env keys consistent across help, README, and runtime messages.
- prefer isolated diagnosis over destructive full rebuilds unless the user explicitly asks for a rebuild.
- for prompts that change repo files, update `docs/prompt-history.md` and create the contextual git commit before presenting the final summary.
- for prompts that do not change repo files, answer directly and ask whether the user wants that turn recorded; only append to `docs/prompt-history.md` and create a git commit after an explicit positive confirmation.
