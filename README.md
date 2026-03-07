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
- `tools/`: helper tooling including pyssh bootstrap and git-hook installer.
- `tests/`: static and compatibility checks.
- `docs/`: historical reconstruction and prompt history.

## Command Surface
- `configure`: interactive configuration and preview without Azure mutation.
- `create`: create missing resources and continue through the configured step window.
- `update`: rerun create-or-update logic on existing managed resources.
- `group`: list or select managed resource groups.
- `show`: print a human-readable resource and VM inventory.
- `exec`: run one init task, one update task, or open an interactive remote shell path.
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
- Full `create` and `update` flows execute the whole step chain unless explicitly sliced.

## Runtime Modes
- Default mode is `interactive`.
- `--auto` / `-a` applies to `create`, `update`, and `delete`.
- `show`, `ssh`, and `rdp` are operator-style commands and do not need `--auto`.
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

Task naming rules:
- `NN-verb-topic.ext`
- two-digit task number
- 2-5 English words in kebab-case
- `.ps1` for Windows, `.sh` for Linux

## Connections
Connection helpers use the current managed VM state plus `.env` credentials.

- `ssh` launches local `ssh.exe`.
- `rdp` stages credentials with `cmdkey` and launches `mstsc.exe`.
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
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\git-history-replay.ps1 -Days 2
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
- The current documented release is `2026.3.8.231`.

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

# run one guest update task
.\az-vm.cmd exec --update-task=27 --group=rg-examplevm-ate1-g1 --windows

# connect
.\az-vm.cmd ssh --vm-name=examplevm
.\az-vm.cmd rdp --vm-name=examplevm --user=assistant
```

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
- update `docs/prompt-history.md` and create the contextual git commit before presenting the final summary.
