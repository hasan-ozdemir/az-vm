# AGENTS.md - az-vm Development Conventions

## Purpose
This repository manages Linux and Windows Azure VM provisioning scripts with high parity, predictable run modes, and strong operator feedback.

## Repository Layout
- `az-vm-lin.cmd`: Elevated launcher for Linux VM flow.
- `az-vm-win.cmd`: Elevated launcher for Windows VM flow.
- `lin-vm/`: Linux-specific orchestration and guest update artifacts.
- `win-vm/`: Windows-specific orchestration and guest update artifacts.
- `co-vm/`: Shared cross-platform PowerShell helpers (config, Azure calls, run-command helpers, core utilities).

## Core Design Rules
- Keep `lin-vm` and `win-vm` scripts as identical as possible.
- Allow differences only for platform-specific requirements:
  - VM image/OS provisioning model
  - Guest-side update scripts (`bash` vs `powershell`)
  - Windows-only RDP and Windows firewall/service specifics
- Shared logic must be moved to `co-vm/az-vm-co-*.ps1` whenever feasible.

## Runtime Modes
- Default mode is `interactive`.
- Auto mode is `--auto` or `-a`.
- Task diagnostic mode is `--step` or `-s`.

### Mode Semantics
- Main flow uses `Step 1..9` for top-level orchestration.
- `Step 8` contains guest-side `Task` executions.
- If `--step` is provided:
  - Step 8 guest tasks run task-by-task via run-command.
- If `--step` is not provided:
  - Step 8 executes the full guest update script in a single run-command call.

## Configuration Strategy
- Runtime precedence: CLI override > `.env` value > script hard-coded default.
- `.env` files are local-only and not tracked.
- `.env.example` files are the source-of-truth templates and must be kept current.

## Networking and Security Rules
- Ports defined by `TCP_PORTS` must be consistently applied to:
  - NSG inbound rules (Azure side)
  - Guest OS firewall rules (Linux UFW / Windows Defender Firewall)
- SSH port value must remain synced end-to-end (NSG, guest firewall, sshd config, connection output).
- Current canonical SSH port is expected to be configurable, currently used as `444` in templates.

## Reliability and Error Handling
- Pre-check region/image/VM-size availability before provisioning/destructive operations.
- Prefer fast server-side filtered checks (`az rest` / filtered availability paths) over broad expensive SKU scans.
- All exceptional paths should fail with user-friendly summary + actionable hint + graceful exit.

## Package/Path Setup Convention (Windows)
- Chocolatey is installed unattended when missing.
- `allowGlobalConfirmation` is enabled once immediately after Chocolatey bootstrap.
- Required packages are installed through Chocolatey.
- `refreshenv.cmd` is called:
  - immediately after Chocolatey setup,
  - after each package installation check/install step.
- If executable resolution fails, append installation path to machine PATH without duplicate entries, refresh environment, and retest.

## Language and UX Consistency
- Keep UI messages, comments, and user-facing strings in English.
- Keep wording aligned between Linux and Windows scripts for equivalent steps.

## Logging and Traceability
- Scripts should transcript and mirror output to dedicated log files.
- Step/task output should be explicit and easy to correlate with failures.

## Commit Discipline
- Commit in small, contextual, developer-friendly English messages.
- Use prefixes such as `feat:`, `fix:`, `refactor:`, `docs:`, `chore:`, `test:`.
- Reflect real intent and scope in each commit.

## Required Assistant Workflow Rule
After each user prompt is implemented, the assistant must create a meaningful, contextual, developer-friendly English git commit immediately before presenting the final summary.
