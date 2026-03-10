# Release Notes

This document uses `YYYY.M.D.N`, where `N` is the cumulative repository commit count at the documented release point.

## Release 2026.3.10.260 - 2026-03-10

### Summary
This release focuses on the developer-facing contract and documentation set. It adds a custom non-commercial `LICENSE`, rewrites the README into a much broader operator/developer manual, rewrites the roadmap around business value and a more sustainable delivery rhythm, converts prompt-history recording to an English-normalized model, tightens the engineering contract in `AGENTS.md`, and adds a pre-commit release-document gate so repo-changing prompts cannot be committed without aligned changelog and release-notes updates.

### Highlights
- Added a root `LICENSE` file with the repository's custom non-commercial terms, including learning/teaching/evaluation allowances, private non-commercial modification allowance, and a clear commercial licensing and sponsorship contact path.
- Expanded `README.md` into a much more detailed guide covering purpose, target audience, quick start, architecture, configuration, full command guide, task model, troubleshooting, developer workflow, and licensing.
- Reworked `roadmap.md` around business value, relaxed planning horizons, promotion rules, and concrete done criteria.
- Updated `AGENTS.md` so maintained docs, help text, comments, and operator-facing runtime wording must stay in English.
- Changed `docs/prompt-history.md` to an English-normalized contract and translated the existing historical entries into English while preserving structure and chronology.
- Added `tests/pre-commit-release-doc-check.ps1` and wired it into `.githooks/pre-commit`, so repo-changing staged work must include `CHANGELOG.md` and `release-notes.md` in the same final change set.
- Fixed `.github/workflows/quality-gate.yml` so the PowerShell compatibility job now calls the current `tests/powershell-compatibility-check.ps1` entrypoint.

### Reliability And Process Notes
- The stronger release-doc gate is intentionally non-recursive: release-history-only staged changes are exempt, but any other staged repo change must include both `CHANGELOG.md` and `release-notes.md`.
- The English-only documentation rule still allows explicit literal display-label exceptions where the repository intentionally preserves a user-defined non-English shortcut or product/site name.
- No Azure runtime behavior changed in this release; the work is contract, documentation, and developer-workflow hardening.

## Release 2026.3.10.259 - 2026-03-10

### Summary
This release turns `az-vm` into a documented, process-hardened, operator-facing Azure VM toolkit with one orchestrator, explicit task catalogs, stronger documentation boundaries, formal local/CI quality gates, explicit hook enable/disable controls, a new state-aware VM power-action command, a corrected direct resize contract, a fully `--vm-name`-based move/set surface, faster isolated `exec` task runs, connection commands that now require a running VM, hardened Ollama and Docker Desktop installer recovery, a far more reliable Windows interactive UX and user-settings propagation path, an expanded public desktop/app-install contract that now includes the Store-backed Codex desktop app plus a statically curated and live-validated guest auto-start set, and a hardened snapshot-based regional move path validated live from `austriaeast` to `swedencentral`.

### Highlights
- Unified command surface for configure, create, update, inspect, connect, power-action, move, resize, set, and delete workflows.
- `move` and `set` now consistently use `--vm-name`; the legacy `--vm` form is no longer part of their public contract.
- One orchestrator for Windows and Linux with parity-first step semantics.
- Catalog-driven guest task execution with explicit priority and timeout metadata.
- New `do` command for `status`, `start`, `restart`, `stop`, `deallocate`, and `hibernate` actions against managed VMs.
- `do --vm-action=hibernate` remains the public hibernation action; Azure still executes it through the deallocation-based hibernate path, so `stop` remains the non-deallocated power-off path.
- Corrected `resize` command syntax to use `--vm-name`, added `--windows`/`--linux` support, and kept resize interactive when parameters are omitted.
- Direct `exec` task runs now accept `--vm-name` and skip the broader Step-1 resource inventory path so isolated task execution reaches pyssh more quickly.
- Windows Chrome-based public desktop shortcuts now take their default `--profile-directory` from `.env` `company_name`, so shared web shortcuts can target a stable company profile such as `exampleorg` instead of deriving the profile name from `VM_NAME`.
- Snapshot-based regional move now deallocates the source VM before snapshotting, validates that the source group is safe for automatic purge, creates target public IPs with explicit zonal intent to avoid Azure CLI warning noise, attaches copied OS disks without invalid admin-credential flags, and keeps post-cutover task validation strict before old-source cleanup.
- `README.md` and `az-vm help move` now document the move cutover sequence and include an observed live timing reference: the `austriaeast -> swedencentral` move of a `Standard_D4as_v5` VM with a `127 GB` OS disk took about `25-30 minutes`, with cross-region snapshot copy as the dominant phase.
- `ssh` and `rdp` now refuse politely unless the target VM is already running, with a direct hint to start it through `do`.
- External `ssh` and `rdp` connection commands for managed VMs.
- Windows update task `09-install-ollama` now short-circuits healthy existing installs, detaches `ollama serve` from the SSH transcript, clears stale installer locks before `winget`, and bounds installer wait time with explicit timeout diagnostics.
- Windows update task `18-docker-desktop-install-and-configure` now clears stale installer locks before `winget install Docker.DockerDesktop` and reports timed-out installer waits without hanging indefinitely.
- Windows update task `25-install-microsoft-vscode` now short-circuits healthy existing installs instead of re-entering `winget` during resumed e2e runs.
- Windows update task `04` now applies and validates `manager` UX settings through a bounded password-logon scheduled task instead of a reboot/autologon loop.
- Windows update task `04` now enforces hibernate-menu visibility, Explorer details/no-group defaults, desktop name-sort plus auto-arrange/grid alignment, Control Panel small icons, file-copy details, keyboard repeat delay, Task Manager full view via `TaskManager\settings.json`, and hidden Search/Widgets/Task View taskbar controls.
- Windows update task `04` now also uses writable .NET registry handles for user-hive writes, avoids generating a synthetic minimal Task Manager store, and hides Widgets through the supported `AllowNewsAndInterests` machine policy after live `TaskbarDa` failures showed that the prior path was not reliable.
- Windows update task `05` now keeps only deterministic machine-level advanced settings and no longer carries unsupported audio/max-volume automation.
- Windows update task `28-copy-user-settings` now propagates the repo-owned manager user settings into `assistant`, the default profile, and the logon-screen hive with explicit exclusions for volatile and identity-bound stores.
- Windows update task `28-copy-user-settings` was further hardened so `assistant` receives its HKCU/user-class seed through a dedicated password-logon worker while default-profile seeding skips heavyweight non-settings branches such as `AppData\\Local\\Programs`, `Microsoft\\WindowsApps`, and default-profile `LocalLow`, removing the live robocopy stalls seen during repeated isolated `exec` validation.
- Windows update task `27-windows-ux-public-desktop-shortcuts` now creates the refreshed public shortcut set for ChatGPT, internet, WhatsApp desktop/web, Google and Office account setup, banking links, and command-style tool launchers with canonical `a1/i0/i1/i2/z1/z2/t*` names, dynamic WhatsApp desktop resolution, and `cmd.exe` wrappers for `.cmd` launchers.
- Windows update tasks `30` through `37` now install and verify iTunes, Be My Eyes, NVDA, Microsoft Edge, VLC, rclone, OneDrive, and Google Drive through the same bounded install-and-readback pattern used elsewhere in the repo.
- Windows update task `38-install-codex-app` now installs the Store-backed Codex desktop app through `winget install codex -s msstore`, verifies it through AppX/StartApps/winget readback, and registers a deferred RunOnce retry when a noninteractive Store session cannot finish immediately.
- Windows update task `39-auto-start-apps` now applies a static startup snapshot for Docker Desktop, Ollama, OneDrive, Teams, private local-only accessibility, and iTunesHelper onto the guest VM and writes the resulting launchers into the machine Startup folder.
- Windows update task `39-auto-start-apps` now also creates missing `StartupApproved` registry keys before it marks existing startup shortcuts enabled, after isolated live `exec` validation exposed that reruns on an already-provisioned VM could otherwise fail on Docker Desktop approval.
- Windows update task `27-windows-ux-public-desktop-shortcuts` now also normalizes the broader Public Desktop set with social-media links, app launchers, dynamic app-path fallbacks, a `Ctrl+Shift+J` hotkey on `local-only-shortcut`, and Unicode-safe `q1Eksisozluk` handling.
- Windows update task `27-windows-ux-public-desktop-shortcuts` now also adds `a3CodexApp` and keeps the requested `OpenAI.Codex_26.306.996.0_x64__2p2nqsd0c76g0\app\Codex.exe` fallback target in the public shortcut contract, while `29-health-snapshot` inventories that shortcut during late-stage validation.
- Windows update task `29-health-snapshot` now also reads back the static machine-startup shortcut set so late-stage validation can show exactly which auto-start launchers were expected and present.
- Windows update task `29-health-snapshot` now inventories the expanded public desktop shortcut set and reads back the exact target-path, argument, hotkey, and Unicode shortcut contracts during late-stage validation.
- Windows update task `29-health-snapshot` now uses a `30s` catalog timeout so live move cutover validation does not produce false timeout warnings on a healthy target VM.
- Windows `vm-update` task catalog timeouts are now derived from observed successful live durations with a 30% buffer, including isolated rerun calibration for tasks `27` and `29`.
- Windows `vm-update` task catalog timeouts are now also calibrated for tasks `30` through `37` from successful isolated live durations, with rerun-confirmed bounded values applied back into the catalog.
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
- The merged Windows update catalog now preserves the late-stage ordering intent by keeping public desktop shortcuts at priority `98`, running `copy-user-settings` at priority `99`, and moving health snapshot to priority `100`.
- Windows interactive UX tasks no longer depend on reboot-resume metadata or autologon cleanup; isolated `exec` runs stay on the normal bounded SSH flow.
- Isolated live validation now covers tasks `04`, `05`, and `20` on `rg-examplevm-ate1-g1/examplevm`, including idempotent rerun of `04` and private local-only accessibility hash/manifest readbacks.
- Isolated live validation now also covers the repaired Windows UX/user-settings late-stage chain: task `04` succeeds after the registry-write fix, task `28` completes without hive-unload or default-profile copy hangs, and task `29` confirms the post-copy machine state on `rg-examplevm-ate1-g1/examplevm`.
- Isolated live validation now also covers full Windows `vm-init` and `vm-update` sweeps plus a focused Ollama rerun that confirms HTTP readiness on port `11434`.
- Isolated live validation now also covers tasks `30` through `37` plus rerun-confirmed `27` and `29`, proving the new package installs, app-backed Public Desktop shortcuts, `local-only-shortcut` hotkey assignment, and Unicode-safe `q1Eksisozluk` readback on `rg-examplevm-ate1-g1/examplevm`.
- Persistent SSH task parsing now strips spinner prefixes from `AZ_VM_*` protocol markers so long-running Windows installers cannot hide task-completion signals.
- A fresh `create --auto --windows --perf --from-step=vm-update` rerun now completes successfully on `rg-examplevm-ate1-g1/examplevm` with `Standard_D4as_v5`, and the rebuilt VM answers on RDP port `3389`.

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
