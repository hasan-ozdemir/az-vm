# Changelog

All notable changes to `az-vm` are documented here. The structure follows a Keep a Changelog style, while the content is curated from the repository commit history and the reconstructed Codex development record.
Documented versions use `YYYY.M.D.N`, where `N` is the cumulative repository commit count at the documented release point.

## [2026.3.9.250] - 2026-03-09

### Features
- Added a new `do` operator command for `status`, `start`, `restart`, `stop`, `deallocate`, and `hibernate` actions against one managed VM.
- Made the new `do` command state-aware so it inspects Azure power/provisioning/hibernation state before mutating and exits politely with a non-zero code when the requested action is not valid for the current VM state.

### Fixes
- Restored `do --vm-action=hibernate` as the single public hibernation action while keeping the underlying Azure behavior unchanged: hibernation still runs through Azure's deallocation-based hibernate path.
- Made `ssh` and `rdp` state-aware so they now refuse politely when the target VM is not running and point operators to `az-vm do --vm-action=start`.
- Updated `resize` to use `--vm-name` instead of legacy `--vm`, added `--windows`/`--linux` support, and kept no-parameter invocation interactive.
- Split `resize` away from the generic move/resize prompt flow so interactive resize stays in the current region and direct fully specified resize runs without an extra confirmation prompt.
- Streamlined isolated `exec` task runs so they now accept `--vm-name`, resolve only the selected VM/task context, and skip the broader Step-1 managed-resource inventory path before pyssh execution.
- Refreshed `27-windows-ux-public-desktop-shortcuts` so the public desktop set now uses the new canonical `a1/i0/i1/i2/z1/z2/t*` naming, removes legacy `i7whatsapp`, adds shared Chrome-profile launchers for ChatGPT, internet, WhatsApp Web, and account setup, dynamically resolves the WhatsApp desktop executable with a fixed fallback path, and wraps command-style launchers through `cmd.exe` so `.cmd`-backed tools do not open in Notepad.
- Expanded `29-health-snapshot` to inventory the refreshed public desktop shortcut set and read back the updated target-path and argument contracts during late Windows validation.
- Recalibrated all Windows `vm-update` task catalog timeouts from live transcript data and successful isolated reruns using a `max_success_seconds * 1.3` buffer rule, including new bounded values for tasks `27` and `29` after live `exec` confirmation at `7.2s` and `6.7s`.
- Replaced the fragile reboot/autologon path for Windows `vm-update` tasks `04` and `05` with a bounded `manager` password-logon scheduled-task helper so isolated `exec` runs no longer stall in interactive-session retry loops.
- Reworked `04-windows-ux-performance-tuning` so it now enforces and readback-validates hibernate-menu visibility, Explorer details/no-group defaults, desktop name sort plus auto-arrange/grid alignment, Control Panel small icons, file-copy details, keyboard repeat delay, and Task Manager full view through `TaskManager\settings.json`.
- Repaired `04-windows-ux-performance-tuning` so it now verifies Task Manager can really launch before and after patching `TaskManager\settings.json`, restores the prior store on failure, and also hides the taskbar Search, Widgets, and Task View controls.
- Reworked `04-windows-ux-performance-tuning` again after live `exec` failures so user-hive writes now run through the bounded password-logon helper, registry writes use writable .NET registry handles instead of `New-ItemProperty`/`reg add`, Task Manager no longer synthesizes a minimal `settings.json`, and Widgets hiding now uses the supported `HKLM\SOFTWARE\Policies\Microsoft\Dsh\AllowNewsAndInterests=0` policy path instead of the failing `TaskbarDa` value.
- Simplified `05-windows-advanced-system-settings` down to deterministic machine-level advanced settings only and removed the unsupported audio/max-volume automation branch.
- Added `28-copy-user-settings` to seed the repo-owned Windows user/app settings from `manager` into `assistant`, `C:\Users\Default`, and `HKU\.DEFAULT` with explicit exclusions for volatile caches, tokens, and credential stores.
- Reworked `28-copy-user-settings` after live hang/debug cycles so `assistant` now receives repo-owned HKCU and user-class settings through its own password-logon seed step instead of conflicting offline hive mounts, while default-profile seeding keeps the offline main-hive path only and excludes non-settings-heavy branches such as `AppData\Local\Programs`, `Microsoft\WindowsApps`, and default-profile `LocalLow` to avoid long robocopy stalls on runtime binaries and alias placeholders.
- Hardened `20-private-local-task` with staging extraction, `version.dll` hash verification, per-file roaming copy, and explicit missing-file detection after live validation exposed a false-success path.
- Reworked `09-install-ollama` to short-circuit healthy existing installs, detach `ollama serve` stdout/stderr from the SSH session, clear stale installer locks before `winget`, and bound the `winget` wait so interrupted e2e runs no longer hang indefinitely on `waiting another install to complete`.
- Hardened `18-docker-desktop-install-and-configure` so it now clears stale installer processes before `winget install Docker.DockerDesktop` and terminates leftover installer locks when bounded install waits time out.
- Updated `25-install-microsoft-vscode` so it now short-circuits when a healthy existing Code executable is already present instead of re-entering `winget` during resumed e2e runs.
- Normalized spinner-prefixed `AZ_VM_*` protocol markers in the persistent SSH transport so long-running Windows package installs do not hide task-end or session-error markers behind progress spinners.

### Documentation
- Rebuilt `AGENTS.md` as the repository engineering contract for architecture, workflow, logging, testing, and documentation maintenance.
- Upgraded `README.md` into a fuller operator and contributor guide aligned with the current CLI, step flow, task model, and configuration contract.
- Added `CHANGELOG.md`, `release-notes.md`, `roadmap.md`, and `docs/prompt-history.md` to formalize project history, release context, future direction, and dialog traceability.
- Adopted commit-count version labels across `CHANGELOG.md` and `release-notes.md`.
- Normalized `CHANGELOG.md` and `release-notes.md` to LF line endings and pinned that expectation in `.gitattributes` so documentation-contract checks behave consistently.
- Removed the retired `docs/reconstruction/` artifact set after its remaining value had been folded into the maintained documentation set.
- Added an explicit repository-context assimilation rule to `AGENTS.md` so each prompt implementation starts with codebase/documentation/test baseline scanning and alignment.
- Relaxed the prompt-history rule so non-mutating prompts are only recorded on explicit user opt-in, while repo-changing prompts remain mandatory prompt-history entries with a commit.

### Tests
- Renamed `tests/powershell-smoke.ps1` to `tests/az-vm-smoke-tests.ps1` because it validates `az-vm` runtime contracts and smoke behavior rather than generic PowerShell behavior.
- Renamed `tests/docs-contract.ps1` to `tests/documentation-contract-check.ps1` for clearer intent and kept it as the documentation-contract gate for current command naming, prompt-history structure, and legacy-token removal.
- Split static quality responsibilities into `tests/code-quality-check.ps1`, `tests/bash-syntax-check.ps1`, and `tests/powershell-compatibility-check.ps1`.
- Renamed the `tests/` scripts to clearer dash-separated names and updated all live references across hooks, workflow, and docs.
- Moved the manual git-history regression replay tool to `tools/scripts/git-history-replay.ps1` so it lives with helper tooling instead of the primary test entrypoints.
- Fixed `tools/scripts/git-history-replay.ps1` to use the quality entrypoint that exists inside each replayed worktree instead of forcing the latest script onto historical commits.
- Added a smoke-contract case for catalog fallback behavior: missing entries default to `priority=1000` and missing timeouts default to `180`.
- Added smoke coverage for renamed Windows vm-update private local-only accessibility tasks, zip asset layout, and runtime asset-copy resolution.
- Added smoke coverage for the new `do` command parser/help contract, lifecycle-state normalization, action eligibility checks, and interactive action selection.
- Added smoke coverage for `resize --vm-name`, direct-request detection, platform-flag validation, and same-region interactive size selection.
- Added smoke coverage for direct `exec --vm-name` task targeting, the new minimal `exec` runtime path, and the strengthened Ollama HTTP readiness check.
- Added smoke coverage for persistent SSH spinner-marker normalization plus the new stale-installer and bounded-timeout guards in Windows tasks `09` and `18`.
- Added smoke coverage for the new Windows UX helper-asset model, removal of reboot-resume task metadata, `TaskManager\settings.json` validation, and removal of legacy audio tuning from task `05`.
- Added smoke coverage for the new `28-copy-user-settings` task, taskbar-hide registry contract in task `04`, the `29-health-snapshot` rename, and the public desktop banking shortcut set.
- Completed isolated live `exec` validation for Windows update tasks `04`, `05`, and `20` against `rg-examplevm-ate1-g1/examplevm`, including an idempotent rerun of task `04` plus private local-only accessibility `version.dll` hash and roaming-manifest readback checks.
- Completed additional isolated live repair validation for Windows update tasks `04`, `28`, and `29` after the Windows UX/user-settings hardening changes, including repeated interrupted-task recovery, assistant/default-profile propagation checks, and a final successful `27 -> 28 -> 29` late-stage chain on `rg-examplevm-ate1-g1/examplevm`.
- Completed isolated live `exec` sweeps for every Windows `vm-init` and `vm-update` task against `rg-examplevm-ate1-g1/examplevm` in effective catalog priority/timeout order, then reran task `09` after the Ollama hardening change to prove `11434` API readiness.
- Completed isolated live reruns of Windows update tasks `09` and `18`, then reran `create --auto --windows --perf --from-step=vm-update` successfully to the end on `rg-examplevm-ate1-g1/examplevm` with `WIN_VM_SIZE=Standard_D4as_v5`, confirming a running VM and reachable RDP port `3389`.

### Refactors
- Removed runtime task-catalog auto-sync/auto-write behavior; catalogs are now read-only inputs at execution time.
- Added catalog-level default consumption (`defaults.priority`, `defaults.timeout`) with fallback `priority=1000`, `timeout=180`.
- Renamed the Windows private local-only accessibility vm-update task to `20-private-local-task`, aligned the update catalog with the new `19/20/28` task names, and moved both private local-only accessibility assets to zip-based packaging under `windows/update/local-private-assets/`.
- Merged the user-adjusted Windows vm-update catalog ordering back onto the renamed task set by keeping `27-windows-ux-public-desktop-shortcuts` at priority `98`, inserting `28-copy-user-settings` at priority `99`, and moving `29-health-snapshot` to priority `100`.
- Extended `27-windows-ux-public-desktop-shortcuts` and `29-health-snapshot` so the late-stage Windows UX flow now creates and inventories eight bank shortcuts that launch Chrome with the requested `examplevm` profile and URLs.
- Replaced the Windows interactive reboot-resume plumbing with a repo-managed scheduled-task helper under `tools/windows/` and returned isolated `exec` task execution to the normal bounded SSH path.

### Chores
- Replaced the one-way hook installer with `tools/enable-git-hooks.ps1` and `tools/disable-git-hooks.ps1`.
- Added `.github/workflows/quality-gate.yml` for non-live static quality enforcement on GitHub Actions.

## [2026.3.7.223] - 2026-03-07

### Features
- Finalize public desktop shortcut coverage and ordering
- Support vm-name overrides and harden vm-deploy validation flow
- Add external ssh and rdp connection commands
- Enable nested virtualization during post-deploy feature setup

### Fixes
- Support deferred app shortcuts on public desktop
- Stabilize isolated vm-update task recovery flows
- Harden vm feature enablement and recover pyssh bootstrap
- Enforce repo-wide no-bytecode python execution
- Disable pyssh bytecode cache generation
- Always execute vm-init during full create and update flows
- Honor task outcome mode across init and update stages
- Add early naming guards and catalog-driven task timeouts
- Validate region and vm name before provisioning
- Rename vscode public desktop shortcut
- Resolve repo-root config loading and remove run-command legacy naming
- Enforce auto-option scope and align config command contract
- Add platform task-dir env fallbacks and reset-ready config docs

### Refactors
- Cut over config command and step contract to configure
- Defer vm-update reboot handling to end-of-stage reporting
- Rename task outcome mode config to vm-scoped key
- Activate template indexing for managed resource names
- Remove unused naming profile setting
- Make vm name the single naming seed
- Remove generic task directory config handling
- Remove legacy compatibility fallbacks across runtime and tooling
- Rename admin credential env keys to VM_ADMIN_*
- Split orchestrator into domain modules with function-level comments

### Documentation
- Clarify vm name semantics across prompts and help

### Tests
- Align env contract with current local source of truth

### Chores
- Report failed vm-update tasks in stage summary
- List reboot-requesting vm-update tasks in stage summary
- Normalize task catalog json formatting after modular refactor

## [2026.3.6.191] - 2026-03-06

### Features
- Add group command and group-aware command targeting
- Add catalog-driven task ordering, native exec shell, and expanded Windows update tasks
- Finalize new CLI surface and remove legacy wording
- Add show command for full Azure VM and resource configuration dump
- Expand perf telemetry across command, step, action, and task flows
- Add interactive config preview command and simplify help syntax
- Add global --help and detailed help topic workflow
- Add delete command and interactive change/exec flows
- Implement snapshot-based region change and regional naming templates

### Fixes
- Restore winget source reset --force in bootstrap task
- Remove winget --force usage from vm-update tasks
- Make sysinternals update task robust against checksum drift
- Refactor orchestrator to 7-step flow and restore vm-init single-step task execution
- Make step4 network checks non-erroring and ensure resource group exists
- Preserve config step1 context for step2 region precheck
- Harden interactive region selection against empty az_location
- Handle retail pricing nextPageLink top bug causing 400 responses
- Harden retail pricing API calls with cache and throttling-aware retry
- Render region picker grid in 9 columns per row

### Refactors
- Enforce region-required flow and platform vm env keys
- Switch task catalogs to priority-driven execution with on-demand reconciliation
- Rename CoVm markers to AzVm and optimize show command performance

### Documentation
- Align create description in quick help overview

### Tests
- Expand help contracts and add quality replay audit scripts

## [2026.3.5.167] - 2026-03-05

### Features
- Add multi-action and single-action execution modes for create/update
- Add command-based CLI flow with create/update/change/exec
- Default interactive runs to destructive rebuild mode
- Make pyssh venv-based and verify with isolated ssh test

### Fixes
- Harden region-change resource mover orchestration and stale cleanup
- Default exec command to auto mode
- Make pyssh installer recreate requirements as utf8 without bom
- Support lowercase ssh_port config with uppercase fallback
- Cap VM running-state retry attempts at three
- Remove step value usage heading from console logs
- Remove [new]/[updated] suffixes from console value logs
- Filter spinner transcript noise and harden pyssh reconnect flow
- Prevent Step8 task stalls by sanitizing SSH stream markers and stabilize health snapshot

### Refactors
- Rename pyssh installer and disable connection test by default
- Simplify step 8 task logs and hide protocol noise lines
- Remove legacy SSH/run-command leftovers and harden windows auto update flow

### Documentation
- Align init execution wording with run-command task-batch flow

### Tests
- Add update task 51 local-diagnostic for exec validation
- Validate NSG multi-port create on PowerShell 5.1 and 7

### Chores
- Verify env templates and prune obsolete local env keys

## [2026.3.4.147] - 2026-03-04

### Features
- Reuse single SSH session for Windows Step 8 substeps and bootstrap winget via choco
- Add SSH Step 8 executor and resilient update/reboot flow
- Allow returning from SKU picker to region selection with r
- Expand guest update tasks with tools, UX tuning, and post-reboot probe

### Fixes
- Stabilize combined init run-command and resume auto flow
- Use choco winget upgrade + PATH-based winget private local-only accessibility install
- Harden step8 guest task execution after auto-mode e2e
- Stabilize Step 8 persistent SSH protocol on PowerShell 5 and remove substep lockups
- Switch to portable pyssh client and stabilize windows substeps

### Refactors
- Split init/update tasks, remove output suppression, and optimize docker/wsl checks
- Unify linux/windows flow into az-vm.ps1 with task-file catalogs
- Adopt default/update/destructive rebuild flow and pyssh-first step8

## [2026.3.3.135] - 2026-03-03

### Features
- Add Windows UX/performance tuning task to VM update flow
- Add contextual first-use value tracing across orchestration steps
- Print full runtime configuration snapshot in auto mode
- Add assistant power-admin account and dual-user connection output
- Align existing VM handling with interactive/auto delete confirmation flow
- Add two-stage y/n confirmation to interactive vm sku flow
- Add interactive region and sku picker with pricing and .env persistence
- Add full windows vm orchestration with ssh and rdp
- Add guest init and update powershell artifacts
- Add full linux vm orchestration script with step flow
- Add guest bootstrap artifacts for cloud-init and update

### Fixes
- Make Windows local group membership idempotent in VM update flow
- Prevent auto-mode snapshot lockups with az account timeouts
- Harden ps5.1 and pwsh json handling across region/sku and vm parsing flows
- Make interactive sku filtering consistent across Windows PowerShell and pwsh
- Show effective partial vm filter and count in interactive sku selection
- Format interactive region labels as n-region and mark default with star prefix
- Make interactive vm sku partial search robust for quotes and separator variants
- Limit interactive region picker to physical azure deployment regions
- Render interactive region list as visible 10-column grid and host-print sku table

### Refactors
- Centralize guest task catalogs and Step 5/6/8 script generation
- Centralize Step 8 run-command orchestration and token expansion
- Centralize shared orchestration steps in co-vm
- Rename step mode to substep and add tracked az command timing
- Introduce co-vm modules for core azure and run-command reuse

### Documentation
- Add end-to-end README with quick start, architecture, configuration, and usage guide
- Add codex evidence index with az-vm related jsonl references
- Add era index for faster navigation of reconstructed history
- Append final codex evidence checkpoint for reconstructed commit chain
- Register windows step8 diagnostics timeline and deadlock mitigation context
- Capture verified successful auto-run outcomes in austriaeast
- Add AGENTS.md with cross-platform vm scripting conventions

### Chores
- Deduplicate runtime value logging and print only new/changed values
- Ignore auto-generated vm init/update artifacts
- Add interactive RG delete confirmation in Step 3 workflow
- Refine SKU partial filtering with strict wildcard semantics
- Standardize UTF-8 no-BOM writes and enforce deterministic line endings
- Harden PS5/PS7 compatibility and add non-live matrix smoke tests
- Add linux and windows environment templates
- Add elevated root launchers for linux and windows flows
- Initialize az-vm repository with ignore and reconstruction scaffolding

## [2026.3.1.94] - 2026-03-01

### Features
- Capture auto-mode deletion prompt wording correction
- Track global ssh port migration from 443 to 444
- Record mandatory port 11434 addition across linux and windows
- Log request to observe auto-only performance impact after fixes
- Track optimization request for step mode run-command batching
- Capture precedence policy cli override env default
- Track windows disk size update to 128gb in env and script
- Record env-based variable management on both platforms
- Capture temporary windows disk size move to 80gb
- Log windows network parity requirement with linux port model
- Capture linux firewall expansion sync from user edits
- Track --step parameter request for granular diagnostics
- Record region move to austriaeast for both platforms
- Track linux region sync to westindia and parity push
- Capture request to avoid indefinite interactive waits during test runs
- Record two-mode runtime model interactive plus auto
- Log graceful user-friendly exception and exit behavior requirement
- Capture server-side filtered region-size lookup optimization
- Document az rest preference over slow list-skus path
- Track early region-sku availability precheck requirement
- Record west india default location investigation and assignment
- Document win11 25h2 avd m365 image selection request
- Record india-proximate region preference change
- Document unattended chocolatey bootstrap requirement
- Note vm size standard_b2as_v2 requirement for windows
- Capture storage sku and disk-size optimization request
- Record datacenter compatibility image requirement for windows
- Track rdp enablement and broad client compatibility requirement
- Record initial windows script parity request

### Fixes
- Record single-location rule for choco global confirmation
- Capture choco global confirmation setup requirement
- Log duplicate refreshenv cleanup requirement in windows flow
- Log windows tcp port exposure parity check across nsg and guest firewall
- Log combine-mode requirement to run generated az-vm-win-update.ps1 file
- Capture critical semantic correction for step vs combined behavior
- Capture system error 1378 mitigation by pre-check before add
- Track run-command success-gating before advancing tasks
- Record rg-reset-plus-step rerun requirement for root-cause analysis
- Record windows step8 console-lock investigation demand
- Log vm naming contract otherexamplevm and examplevm confirmation
- Document linux auto mode graceful early exit in step2 conditions
- Capture duplicate-safe machine path augmentation mechanism
- Log refreshenv after each package installation and retest flow
- Track all-package installation standardization via chocolatey
- Capture refreshenv-before-path-check requirement
- Capture strict python install command requirement
- Capture filename suffix correction to lin.* convention

### Refactors
- Capture launcher relocation request to repository root
- Record shared co-vm architecture extraction for max code reuse
- Capture request to port latest windows combine-mode behavior to linux
- Track step-aware bash and powershell run-command strategy
- Capture linux task decomposition request to mirror windows structure
- Log request to carry latest windows fixes into linux script
- Capture linux-side adoption of step-task semantics
- Record step-task wording rollout across code ui and comments
- Capture auto and step parity expectation across both scripts
- Log request to port same task-array strategy to linux
- Track win step-mode and non-step-mode structural unification
- Record step-to-task terminology correction requirement
- Capture code-only sync request with deferred testing
- Capture cross-platform identical behavior requirement
- Capture sh-to-powershell guest update conversion for windows
- Track rename request from az-vm to linux-specific naming

### Documentation
- Align reconstruction notes with current co-vm lin-vm win-vm layout
- Finalize comprehensive reconstructed timeline index
- Capture requirement to mine codex jsonl for az-vm chronology
- Capture request for real .env.example templates with active variables
- Log unused-file detection and approval-gated deletion request
- Log parity-diff check request beyond os-specific behavior
- Capture completion status confirmation request
- Record fallback-presence and westindia sku inquiry
- Track inquiry for windows11 plus office365 combined image
- Record windows11 pro image availability inquiry
- Log regression check for rename and content updates
- Record non-interactive linux deployment and ssh validation request

### Tests
- Record request to run parallel auto-only tests for both platforms
- Capture windows auto-only execution request after parity updates
- Record request to run windows in auto mode only for syntax confidence
- Capture explicit verification request for windows auto-step completion
- Record windows auto-step iterative rebuild and fix loop
- Record linux auto-step iterative rebuild and fix loop
- Capture parallel full rebuild request for both platforms
- Record directive to postpone e2e until bulk fixes complete

### Chores
- Record mandatory commit-before-summary assistant workflow rule
- Log repository bootstrap and AGENTS documentation request
- Track second implement-plan handoff for full reuse architecture
- Record explicit implement-plan handoff for parity refactor
- Record instruction to defer both platform tests after refactor
- Note explicit request to skip tests for semantic correction phase
- Log anti-regression requirement for env and language refactor
- I18n(history): capture english-only ui strings comments and messages request
- Capture no-fallback directive for region and image checks
- Log repository structure regrouping under lin-vm and win-vm
- Document windows vm identity requirement as examplevm
