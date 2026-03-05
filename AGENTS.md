# AGENTS.md - az-vm Development Conventions

## Purpose
This repository manages unified Azure VM provisioning for Linux and Windows from a single entrypoint with high parity, predictable run modes, and explicit operator feedback.

## Repository Layout
- `az-vm.cmd`: Elevated launcher.
- `az-vm.ps1`: Single orchestrator for both platforms.
- `linux/init/*.sh`: Linux VM init task catalog.
- `linux/update/*.sh`: Linux VM update task catalog.
- `windows/init/*.ps1`: Windows VM init task catalog.
- `windows/init/disabled/*.ps1`: Windows init tasks intentionally disabled.
- `windows/update/*.ps1`: Windows VM update task catalog.
- `windows/update/disabled/*.ps1`: Windows update tasks intentionally disabled.
- `tools/`: pyssh/utility scripts.
- `tests/`: PowerShell compatibility smoke tests.

## Core Design Rules
- One orchestration script (`az-vm.ps1`) for both platforms.
- Keep Linux/Windows flow and wording as identical as possible.
- Allow differences only for true platform-specific requirements:
  - VM image and OS behavior
  - guest task language (`.sh` vs `.ps1`)
  - Windows-only RDP/Windows-service configuration

## Runtime Modes
- Default mode is `interactive`.
- Auto mode is `--auto` or `-a`.
- Update mode is `--update` or `-u`.
- destructive rebuild mode is `explicit destructive rebuild flow` or `-r`.

### Mode Semantics
- `Step 1..9` are top-level orchestration steps.
- `Step 8` executes guest-side tasks.
- Init tasks (Windows + Linux) run once via Azure Run Command in task-batch mode when VM is newly created.
- Update tasks run via persistent pyssh task-by-task.

## OS Selection
- CLI flags: `--windows` or `--linux`.
- Config: `VM_OS_TYPE=windows|linux`.
- Precedence: CLI > `.env` > interactive prompt.
- In auto mode, unresolved OS type must gracefully exit with actionable guidance.

## Configuration Strategy
- Runtime precedence: CLI override > `.env` value > hard-coded default.
- Root `.env` is local-only and not tracked.
- Root `.env.example` is source-of-truth and must be kept current.
- Prefer generic keys; use `WIN_`/`LIN_` fallback keys only when truly platform-specific.

## Task Catalog Rules
- Task files must use: `NN-verb-topic.ext`.
- `NN` is two-digit execution order.
- `verb-topic` must contain 2-5 English words in kebab-case.
- Linux extensions: `.sh`; Windows extensions: `.ps1`.
- `disabled/` subfolders are reserved for intentionally skipped tasks.

## Networking and Security Rules
- Ports defined by `TCP_PORTS` must be consistently applied to:
  - NSG inbound rules (Azure)
  - Guest OS firewall rules
- SSH port must remain synchronized end-to-end (NSG, guest firewall/config, printed connection command).
- Canonical SSH port remains configurable (currently expected as `444` in templates).

## Reliability and Error Handling
- Pre-check region/image/VM-size availability before provisioning/destructive operations.
- Prefer server-side filtered checks (`az rest`) over broad slow listings.
- Exceptional paths must fail gracefully with:
  - short summary
  - actionable hint
  - non-ambiguous exit

## Package/Path Setup Convention (Windows)
- Chocolatey is installed unattended when missing.
- `allowGlobalConfirmation` is enabled once immediately after Chocolatey bootstrap.
- Required packages are installed via Chocolatey.
- `refreshenv.cmd` is called after choco bootstrap and after each package installation check/install step.

## Language and UX Consistency
- Keep UI messages, comments, and user-facing strings in English.
- Keep Linux/Windows wording aligned for equivalent steps.

## Logging and Traceability
- Scripts should transcript output to timestamped run logs.
- Step/task output should be explicit and easy to correlate with failures.

## Commit Discipline
- Commit in small, contextual, developer-friendly English messages.
- Use prefixes such as `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, `test:`.
- Reflect real intent and scope in each commit.

## Required Assistant Workflow Rule
After each user prompt is implemented, the assistant must create a meaningful, contextual, developer-friendly English git commit immediately before presenting the final summary.
