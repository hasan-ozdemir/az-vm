# Release Notes

This document uses `YYYY.M.D.N`, where `N` is the cumulative repository commit count at the documented release point.

## Release 2026.3.9.246 - 2026-03-09

### Summary
This release turns `az-vm` into a documented, process-hardened, operator-facing Azure VM toolkit with one orchestrator, explicit task catalogs, stronger documentation boundaries, formal local/CI quality gates, explicit hook enable/disable controls, a new state-aware VM power-action command, a corrected direct resize contract, faster isolated `exec` task runs, connection commands that now require a running VM, a hardened Ollama installer check, and a far more reliable Windows interactive UX task path.

### Highlights
- Unified command surface for configure, create, update, inspect, connect, power-action, move, resize, set, and delete workflows.
- One orchestrator for Windows and Linux with parity-first step semantics.
- Catalog-driven guest task execution with explicit priority and timeout metadata.
- New `do` command for `status`, `start`, `restart`, `stop`, `deallocate`, and `hibernate` actions against managed VMs.
- `do --vm-action=hibernate` remains the public hibernation action; Azure still executes it through the deallocation-based hibernate path, so `stop` remains the non-deallocated power-off path.
- Corrected `resize` command syntax to use `--vm-name`, added `--windows`/`--linux` support, and kept resize interactive when parameters are omitted.
- Direct `exec` task runs now accept `--vm-name` and skip the broader Step-1 resource inventory path so isolated task execution reaches pyssh more quickly.
- `ssh` and `rdp` now refuse politely unless the target VM is already running, with a direct hint to start it through `do`.
- External `ssh` and `rdp` connection commands for managed VMs.
- Windows update task `09-install-ollama` now installs `Ollama.Ollama` through `winget`, verifies the CLI, and requires a healthy `127.0.0.1:11434/api/version` response, starting `ollama serve` when needed.
- Windows update task `04` now applies and validates `manager` UX settings through a bounded password-logon scheduled task instead of a reboot/autologon loop.
- Windows update task `04` now enforces hibernate-menu visibility, Explorer details/no-group defaults, desktop name-sort plus auto-arrange/grid alignment, Control Panel small icons, file-copy details, keyboard repeat delay, and Task Manager full view via `TaskManager\settings.json`.
- Windows update task `05` now keeps only deterministic machine-level advanced settings and no longer carries unsupported audio/max-volume automation.
- Hardened naming, env-key, and validation contracts across provisioning flows.
- Post-deploy feature enablement for hibernation and nested-virtualization support checks.
- Broader Windows guest update coverage, including UX tuning and public desktop shortcut generation.
- Windows private local-only accessibility update assets now deploy from repo-managed zip packages, including staged version replacement, roaming settings restore, and stricter post-copy verification.

### Breaking and Contract-Significant Changes
- Legacy command names and aliases have been removed rather than preserved.
- `configure` is the current configuration-preview command; `config` is no longer part of the public surface.
- `do` is the current VM power-action command; `release` is no longer a valid VM action token.
- `resize` now uses `--vm-name`; the legacy `--vm` form is no longer part of the public resize contract.
- `VM_NAME` is the single naming seed for managed resources.
- `VM_SSH_PORT` and `VM_RDP_PORT` are the canonical connection-port keys.
- `VM_TASK_OUTCOME_MODE` is the canonical task outcome policy key.
- Generic task-directory config keys and other historical fallbacks are no longer part of the runtime contract.

### Reliability and UX Improvements
- Earlier validation for region, VM name, naming templates, and mutation-critical config.
- Cleaner operator logging with explicit stage summaries and failure/reboot reporting.
- Catalog-driven timeout handling for guest tasks.
- Repo-managed Python tooling configured to avoid bytecode cache artifacts.
- More consistent Linux/Windows terminology and step/task wording.
- Renamed Windows vm-update task entries are now aligned with the task catalog so the intended `19/20/28` ordering and timeout policy apply again.
- The merged Windows update catalog now preserves the late-stage ordering intent by keeping public desktop shortcuts at priority `98` and health snapshot at priority `99`.
- Windows interactive UX tasks no longer depend on reboot-resume metadata or autologon cleanup; isolated `exec` runs stay on the normal bounded SSH flow.
- Isolated live validation now covers tasks `04`, `05`, and `20` on `rg-examplevm-ate1-g1/examplevm`, including idempotent rerun of `04` and private local-only accessibility hash/manifest readbacks.
- Isolated live validation now also covers full Windows `vm-init` and `vm-update` sweeps plus a focused Ollama rerun that confirms HTTP readiness on port `11434`.

### Documentation and Process Improvements
- Expanded `AGENTS.md` into a repository engineering contract.
- Upgraded `README.md` into a fuller operator and contributor guide.
- Added full-project `CHANGELOG.md`.
- Added `docs/prompt-history.md` as a human-readable dialog ledger.
- Added `roadmap.md` to track future work.
- Added a GitHub Actions `quality-gate.yml` workflow and native local git hooks.
- Replaced the one-way hook installer with explicit enable/disable scripts for local git-hook control.
- Adopted commit-count version labels for `CHANGELOG.md` and `release-notes.md`.
- Normalized `CHANGELOG.md` and `release-notes.md` to LF line endings and pinned that expectation in `.gitattributes` so documentation-contract checks behave consistently.
- Removed the retired `docs/reconstruction/` folder after folding its remaining value into the maintained documentation set.
- Renamed the `tests/` scripts to clearer, self-explanatory dash-separated file names.
- Renamed the documentation contract gate to `documentation-contract-check` for clearer test intent.
- Renamed the `az-vm` smoke suite to `az-vm-smoke-tests` so the file name reflects its actual repo-specific purpose.
- Split code-quality, bash-syntax, and PowerShell-compatibility checks into separate scripts instead of using skip-style audit switches.
- Moved the manual history replay utility to `tools/scripts/git-history-replay.ps1` and corrected it so it resolves the quality script that actually exists in each historical worktree.
- Removed runtime auto-sync writes for task catalogs and moved catalog handling to manual-only editing.
- Standardized catalog fallback defaults to `priority=1000` and `timeout=180` when entries or timeout values are missing.
- Added a strict `AGENTS.md` rule requiring repository-wide context assimilation before implementing each prompt.
- Relaxed the prompt-history policy so non-mutating prompts are only recorded on explicit user confirmation, while repo-changing prompts still require prompt-history capture plus a commit.

### Operator Notes
- CI remains static and non-live. Azure provisioning is intentionally excluded from automated workflows.
- Some Windows application installs may still require first interactive sign-in for full activation even after unattended installation succeeds.
- `docs/prompt-history.md` is append-only for recorded turns; repo-changing prompts are mandatory entries, while non-mutating prompts are recorded only after explicit user confirmation.

### Known Limitations
- No live Azure end-to-end validation runs in CI.
- Some Store-backed Windows applications may need deferred first-sign-in finalization.
- Release notes are commit-count-versioned; the repo still does not use a tag-driven release workflow.
