# Release Notes

This document uses `YYYY.M.D.N`, where `N` is the cumulative repository commit count at the documented release point.

## Release 2026.3.16.327 - 2026-03-16

### Summary
This release finishes the JAWS task-state handoff by making `131-install-jaws-screen-reader` the sole builtin owner of JAWS settings replay. The task-local payload now captures the full JAWS 2025 settings tree plus the full `Freedom Scientific` HKLM/HKCU surface, local-machine saves normalize the portable payload to the canonical managed profile token `manager` instead of preserving the operator's local profile name, and the Windows health snapshot now reports JAWS settings and registry presence for both managed profiles. The release was validated non-live and again live with isolated JAWS task reruns on the active managed VM.

### Highlights
- Kept JAWS auto-start isolated in `10001-configure-apps-startup` but moved all other builtin JAWS settings replay responsibility onto `131-install-jaws-screen-reader`, which now owns the full task-local settings and registry payload.
- Normalized portable local JAWS app-state saves so the task-local zip rewrites profile payload folders, manifest source paths, and HKCU registry path markers to `manager`, eliminating source-machine user tokens such as `hasan` from the reusable payload.
- Extended `10006-capture-snapshot-health` with JAWS settings and registry readback for `manager`, `assistant`, `HKLM\Software\Freedom Scientific`, and `HKLM\Software\WOW6432Node\Freedom Scientific`.
- Revalidated the change non-live with the smoke and PowerShell compatibility gates, regenerated the live task-local JAWS payload from the local machine, reran `task --run-vm-update 131` in isolation on `bizyum`, and confirmed the expected settings and registry surface on the target VM with isolated readback commands.

## Release 2026.3.16.326 - 2026-03-16

### Summary
This release hardens the live Windows create path around the exact `create --auto --windows --perf` publish flow. Windows task asset delivery now uses a verified SCP path instead of the slower base64 chunk transport, step review redacts password- and token-shaped values reliably, task-scoped app-state capture/replay preserves exact file destinations for overlays like JAWS `version.dll`, and several narrow task timeouts were widened so healthy installs do not degrade into warning-only runs. The release was validated by completing a full live Windows publish cycle and the normal post-create acceptance checks.

### Highlights
- Replaced the Windows task asset upload path with host-key-validated `pscp.exe` SCP plus remote size and SHA-256 verification, removing the chunk-heavy transfer mode that had been inflating live create time.
- Added generic sensitive-key redaction in the effective configuration review so passwords, secrets, and tokens render as `[redacted]` instead of appearing in plaintext during operator review output.
- Fixed app-state file capture/replay and wildcard destination expansion on both local-machine and guest paths, and trimmed the WhatsApp payload contract so large transfer/AppCenter residue no longer bloats uploads.
- Raised the timeout ceilings for Python, GitHub CLI, 7-Zip, and rclone install tasks, then verified the Python task in isolation before rerunning the exact Windows create and confirming the resulting VM with `show`, status, SSH, and RDP checks.

## Release 2026.3.16.325 - 2026-03-16

### Summary
This release removes all remaining on-disk disabled `vm-init` and `vm-update` task folders while preserving the empty `disabled/` directory contract. The stage trees now keep only placeholder `.gitkeep` files where the disabled roots must remain visible, and the stale Windows local disabled task folders no longer show up as leftover cleanup residue.

### Highlights
- Removed the remaining disabled task folders from the repository disk layout so disabled task cleanup now means an actually empty disabled tree, not a tree that still carries stale task folders.
- Standardized empty `disabled/` roots for both Linux and Windows stage trees by keeping only `.gitkeep` placeholders where the directory contract should remain explicit.
- Revalidated the result non-live with direct disabled-inventory checks plus the smoke, documentation-contract, and release-doc gates.

## Release 2026.3.16.324 - 2026-03-16

### Summary
This release hardens `task --restore-app-state` around real backup, verification, and rollback behavior. Local-machine restore now writes task-adjacent `backup-app-states/<task-name>/` snapshots plus `restore-journal.json` and `verify-report.json`, verifies the replayed files and registry before declaring success, and rolls back automatically if replay or verification fails. The Windows VM restore path now follows the same safety model on the guest side with temporary backup staging and post-restore verification.

### Highlights
- Moved local-machine restore backups from temp-only roots to task-adjacent `backup-app-states/<task-name>/` and `local/backup-app-states/<task-name>/`, keeping the restore journal and verify report beside the active snapshot.
- Added post-restore verification for local-machine replay so declared files, directories, and registry payloads are checked after restore and automatically rolled back when drift remains.
- Added Windows guest-side backup, verification, and rollback to the shared VM restore helper so direct VM app-state replay no longer assumes restore success after import/copy alone.
- Revalidated the backup/verify/rollback contract non-live with the smoke, documentation-contract, and PowerShell compatibility gates.

## Release 2026.3.16.323 - 2026-03-16

### Summary
This release adds first-class JAWS support to the tracked Windows update flow. The repo now has a builtin `131-install-jaws-screen-reader` task for JAWS 2025, task-local JAWS app-state capture for the full `Freedom Scientific` registry surface plus the JAWS 2025 settings directory, one managed `j0Jaws` Public Desktop shortcut, and a managed startup exception that writes the same machine `Run` entry shape observed on the local reference machine.

### Highlights
- Added tracked Windows update task `131-install-jaws-screen-reader` with bounded `winget` install-and-verify behavior for `FreedomScientific.JAWS.2025`.
- Added JAWS task-local app-state coverage for `AppData\Roaming\Freedom Scientific\JAWS\2025\Settings`, `HKCU\Software\Freedom Scientific`, `HKLM\Software\Freedom Scientific`, and `HKLM\Software\WOW6432Node\Freedom Scientific`, and extended the local app-state export helper with the same JAWS contract.
- Added the managed `j0Jaws` Public Desktop shortcut with `Ctrl+Shift+J`, normalized stale `JAWS` aliases during shortcut cleanup, extended the health snapshot with JAWS install/startup readback, and added one explicit managed auto-start exception so JAWS is always written as `HKLM\Software\Microsoft\Windows\CurrentVersion\Run\JAWS="C:\Program Files\Freedom Scientific\JAWS\2025\jfw.exe" /run`.
- Revalidated the shipped contract non-live through the smoke, documentation-contract, code-quality, PowerShell compatibility, and release-doc gates.

## Release 2026.3.16.322 - 2026-03-16

### Summary
This release completes a three-part portability and maintenance pass. Vm-init and vm-update now use portable task folders instead of flat stage-root task files and stage-root catalog JSON files, task-scoped app-state save/restore now supports both the managed VM default surface and a new Windows local-machine surface, and maintained documentation timestamps now standardize on UTC. The runtime, help, docs, and tests now describe one task-owned contract consistently: the folder names the task, `task.json` owns its runtime metadata, and `<task-folder>/app-state/app-state.zip` owns its reusable settings payload.

### Highlights
- Replaced tracked stage-root task scripts with portable task folders across Windows and Linux init/update stages, renumbered the stage inventories without band gaps, and kept missing portable task folders hot-swap-safe so absent tasks are skipped cleanly instead of breaking the workflow.
- Added `task --save-app-state --source=lm|vm` and `task --restore-app-state --target=lm|vm`, kept `vm` as the default behavior, added `.all.`, `.current.`, and comma-separated multi-user support, and hardened local restore with allow-list validation, backups, per-user journals, and rollback.
- Converted the maintained UTC policy from a forward-only rule into a current-tree standard by updating AGENTS, README, prompt-history formatting rules, and the existing `docs/prompt-history.md` headings to UTC.
- Revalidated the feature set with the non-live smoke, documentation-contract, code-quality, PowerShell compatibility, and release-doc gates only; live isolated reruns were intentionally deferred because the active managed VM had already been deleted.

## Release 2026.3.16.321 - 2026-03-16

### Summary
This release finishes the runtime cutover to the selected-only configuration contract and cleans up the Windows SSH transport path that was inflating live `create` and isolated `task` runs. The runtime now resolves and logs one effective configuration snapshot with explicit value sources, Windows asset delivery now uses one direct base64 chunk transport instead of falling through layered fallback paths, and Windows app-state replay now stages unique zip paths, waits for the zip to become readable, and exposes replay phases and remote errors clearly. The same pass trims the managed browser app-state contract down to lightweight settings payloads and raises the Sysinternals init timeout so isolated reruns behave deterministically.

### Highlights
- Removed the old `.env` compatibility surface from the live runtime so only current `SELECTED_*` names, current naming placeholders, and `AZURE_COMMAND_TIMEOUT_SECONDS` remain in the active configuration contract.
- Replaced repeated config review dumps with one canonical `KEY=value (source)` snapshot so operators see every effective setting once without losing visibility into where the value came from.
- Reworked Windows SSH execution and asset staging so the repo now uses a single bounded base64 upload path with grouped progress logs, direct stdout and stderr capture, remote hash reuse, and no per-chunk pyssh noise.
- Tightened Windows app-state replay by using unique remote zip names, zip-readiness waits, clearer replay-phase logging, and lighter Chrome and Edge settings payloads, then verified the new path live with isolated `vm-init` and `vm-update` task reruns on the active managed Windows VM.

## Release 2026.3.16.320 - 2026-03-16

### Summary
This release is a documentation-and-tests alignment pass for the current selected-only configuration surface. The maintained docs and contract checks now describe the public runtime with `SELECTED_*` config names, `{SELECTED_VM_NAME}` managed-resource templates, `__SELECTED_*__` task placeholders, `AZURE_COMMAND_TIMEOUT_SECONDS`, the `180` second Sysinternals init timeout, and the current Windows public-desktop shortcut validation wording.

### Highlights
- Updated `README.md` to describe the current template and task-placeholder contract, including `{SELECTED_VM_NAME}` and `__SELECTED_*__`.
- Updated the smoke suite so create override assertions, `.env.example` template checks, task token replacement checks, and the Sysinternals init timeout all match the selected-only contract.
- Updated the documentation-contract gate to keep the README wording aligned with the current Windows shortcut validation messages and selected-name placeholder model.

## Release 2026.3.15.319 - 2026-03-15

### Summary
This release hardens the Windows SSH task transport for environments where the OpenSSH command channel is healthy but the SFTP subsystem refuses negotiation. Windows SSH asset uploads now retry SFTP briefly and then fall back to a chunked PowerShell `exec` transfer that can stage helper modules and larger task scripts without tripping the remote Windows command-line limit, keeping `vm-update` moving instead of aborting at the first `pyssh copy asset` failure.

### Highlights
- Added a Windows-specific no-SFTP asset-transfer fallback in the shared SSH asset helper so `vm-update` can keep using one-shot SSH execution even when Paramiko cannot open an SFTP channel.
- Reduced the inline chunk size used by the fallback transport so larger staged task scripts and helper modules avoid the remote `The command line is too long.` failure while still reconstructing the remote file deterministically.
- Revalidated the behavior live by rebuilding the managed Windows target, then confirming the resulting VM is in `Provisioning succeeded` / `VM running` state and that both `connect --ssh --test` and `connect --rdp --test` pass against the new managed VM.

## Release 2026.3.15.318 - 2026-03-15

### Summary
This release unifies task-scoped app-state restore behavior across vm-init, vm-update, and the direct `task --restore-app-state` surface. Vm-init now runs one task at a time over Azure Run Command so it can invoke the same shared post-task app-state restore helper after each init task when a matching plugin zip exists, while direct vm-init restore uses that same shared helper through a run-command transport instead of depending on SSH readiness. The same pass also adds a small unconditional banner to the CLI entrypoint so every `az-vm` invocation starts with version and feature context before command parsing begins.

### Highlights
- Reworked the vm-init runner from one combined Run Command batch into one-task-at-a-time execution so init-stage post-task app-state replay can use the same shared helper contract as vm-update.
- Expanded the shared app-state restore helper with a run-command transport and routed `task --restore-app-state --vm-init-task ...` through it, giving init restore and init post-task replay the same plugin resolver and replay core that update restore already uses over SSH.
- Added an unconditional `AZ-VM CLI V<version>` welcome banner with a two-line feature summary that prints before valid, invalid, parameterized, and parameterless invocations alike.

## Release 2026.3.15.317 - 2026-03-15

### Summary
This release adds one more explicit lifecycle repair path to `az-vm do`: `--vm-action=redeploy`. Operators can now request a direct Azure host redeploy from the same lifecycle command that already handles status, power-state changes, reapply, and hibernation flows, while the runtime waits for provisioning recovery and then restores the original started/stopped lifecycle state when Azure reports it deterministically.

### Highlights
- Added `do --vm-action=redeploy` to the public lifecycle contract, help surface, README command matrix, and smoke validation.
- Reused the same tracked Azure-action wrapper as the rest of the `do` command so manual redeploy stays visible, audited, and consistent with the existing lifecycle UX.
- Added isolated smoke coverage that verifies the redeploy action calls `az vm redeploy`, waits for provisioning recovery, restores the original lifecycle state, and prints the refreshed VM status.

## Release 2026.3.15.316 - 2026-03-15

### Summary
This release cuts the persisted configuration contract over to a selected-only model. `.env` now stores active targeting, operator identity, company metadata, subscription choice, and region choice exclusively through `SELECTED_*` keys, while the shared runtime still materializes the same internal canonical fields for orchestration. The same pass makes unattended `az-vm create --auto` runnable from `.env` alone when the selected values and platform defaults are complete, and it removes the older persisted output-key contract from configure/create/update/move/set writeback.

### Highlights
- Added `SELECTED_RESOURCE_GROUP` as the persisted existing-target selector so unattended update, configure, delete, set, move, task, exec, and connection flows can resolve the active managed VM target from `.env` without reviving the old output-key contract.
- Reworked `.env.example`, README, AGENTS, help output, smoke coverage, and documentation contracts so the committed configuration model is now `SELECTED_*` plus the shared and platform-specific VM defaults.
- Updated the create runtime so `az-vm create --auto` can resolve platform, VM name, Azure region, and VM size from `.env` `SELECTED_VM_OS`, `SELECTED_VM_NAME`, `SELECTED_AZURE_REGION`, and the matching `WIN_*` or `LIN_*` defaults without requiring explicit CLI `--vm-name`, `--vm-region`, `--vm-size`, or platform flags.
- Updated the runtime persistence path so configure/create/update/move/set flows now remove the retired persisted keys after writing the selected contract, keeping `.env` aligned with the current committed model instead of accumulating both generations side by side.

## Release 2026.3.15.315 - 2026-03-15

### Summary
This release narrows the managed app-state system from a broad machine snapshot into a stricter settings-first contract. Managed save and restore now target only the `manager` and `assistant` OS profiles, the shared capture/replay runtime no longer enumerates `default` or arbitrary local users, and the tracked Windows capture specs now prune generated browser caches, installer/update payloads, telemetry trees, embedded WebView runtime content, and other low-value artifacts before they can bloat new payloads. The same pass also sanitizes the current ignored `windows/update/app-states/*/app-state.zip` payload set so the existing operator-owned zips match the new contract instead of carrying older foreign-profile drift forward.

### Highlights
- Added `tools\\scripts\\app-state-audit.ps1` as a manual payload-inspection helper that reports zip sizes, foreign profile targets, and the heaviest entries inside each stage-local app-state payload.
- Locked the shared app-state runtime to the managed `manager` and `assistant` OS-user targets across Windows and Linux, removing the old `default` and arbitrary-local-profile replay/capture behavior.
- Tightened the tracked Windows app-state capture specs so Chrome, Edge, Azure CLI, azd, Docker Desktop, GitHub CLI, Ollama, Office settings, npm-managed CLI state, and Visual Studio now exclude the biggest generated caches, model stores, telemetry folders, installer binaries, and other low-value artifacts.
- Rewrote the current ignored app-state payloads in place so the managed zip set no longer carries foreign profile targets and so the heaviest payloads are cut down to a reusable settings baseline.

## Release 2026.3.15.314 - 2026-03-15

### Summary
This release completes the CLI surface cutover that separates task execution, direct shell execution, and user-facing connection flows cleanly. `az-vm task` now owns isolated `vm-init` and `vm-update` task runs, `az-vm exec` is now only the SSH shell/remote-command surface, and the old standalone `ssh` and `rdp` commands are replaced by one explicit `az-vm connect --ssh|--rdp` contract. The same pass also standardizes target selectors on `--group` / `-g`, `--vm-name` / `-v`, and `--subscription-id` / `-s`, and tightens parser/help/docs alignment so value-taking options consistently accept both `--option=value` and `--option value`.

### Highlights
- Added `task --run-vm-init` and `task --run-vm-update`, moving isolated task execution out of `exec` and into the command that already owns task inventory and task app-state maintenance.
- Added the new `connect` command so SSH and RDP launch/test behavior now lives under one explicit transport-selected surface: `connect --ssh` or `connect --rdp`.
- Reduced `exec` to two deliberate modes only: bare `exec` for the interactive SSH shell and `exec --command` / `-c` for one-shot remote commands.
- Standardized the canonical selector names and option-shape handling across the app, then updated help, README, AGENTS, and smoke/docs contract coverage to remove the retired public forms in the same cutover.
- Kept the full reachable-history sensitive-content audit available through `tests\sensitive-content-check.ps1`, while focusing automated local gate and commit-message checks on the current tree and the current commit message.

## Release 2026.3.15.313 - 2026-03-15

### Summary
This release opens a new live-maintenance surface for task-owned app-state payloads and aligns the surrounding Windows operator contract with it. `az-vm task` can now save and restore per-task app-state zips over SSH, task `115-install-npm-packages-global` now captures richer per-user CLI state including full `.codex` trees, the default VM name can now derive from the local-part of `employee_email_address`, and the Windows public desktop surface now takes its business web root from `company_web_address` while using refreshed iCloud and Codex CLI shortcut contracts. The same pass also hardens Windows app-state capture internals and adds a Chrome-specific pre-restore close hook so app-state replay can reduce file-in-use conflicts instead of trying to restore over running Chrome windows.

### Highlights
- Added live `task --save-app-state` and `task --restore-app-state` flows that target one init or update task at a time and read or write the existing per-task `app-state.zip` payload under the stage-local `app-states/` tree.
- Added one shared capture-spec registry plus one shared capture engine, backed by new `fetch` support in the repo-owned pyssh client, so app-state payloads can now be refreshed directly from the live VM instead of being authored only by hand.
- Updated the Windows shortcut surface so `i1Internet Business` comes from `company_web_address`, `k1Codex CLI` uses the richer Codex CLI invocation, and `d4ICloud` resolves through the real iCloud launch contract instead of the File Picker fallback.
- Hardened task app-state capture and restore with fixed plan merging, shorter Windows scratch paths for deep `.codex` trees, safer legacy-registry deduplication, and a Chrome pre-restore process-close step that runs before task `02-check-install-chrome` replay.

## Release 2026.3.14.312 - 2026-03-14

### Summary
This release tightens the Windows desktop-finish path around three operational edges: overlong Public Desktop shortcut invocations, fragmented local screen-reader execution, and transcript housekeeping. Overlong Chrome and Edge shortcut commands now collapse into managed short launchers without changing the effective browser/profile/URL behavior, the local screen-reader workflow now runs as one self-contained local vm-update task instead of several loosely chained tasks, and the retro log audit helper moves into `tools/scripts/` as a manual maintenance tool while the current local transcript files are cleaned from the repo working tree.

### Highlights
- Added a shared managed shortcut launcher helper so Public Desktop shortcut creation and late health validation now use the same short-launcher contract.
- Merged the local screen-reader install, settings, shortcut, autostart, and verify-repair flow into one local task, with one matching app-state plugin name.
- Moved `retro-log-audit.ps1` to `tools/scripts/` and removed it from the default non-live gate so it stays available for targeted maintenance runs without being auto-triggered.
- Cleaned the current untracked `az-vm-log-*.txt` files from the repo root while keeping `.gitignore` coverage in place.

## Release 2026.3.14.311 - 2026-03-14

### Summary
This release closes the retro-log hardening pass without reintroducing any next-boot follow-up behavior. The affected Windows vm-update tasks now stay strictly one-shot, Store-backed installs write an explicit launch-ready or degraded state instead of leaving RunOnce-style continuation work behind, the SSH stage summary reports warning signals more honestly, Linux app-state replay now covers the supported file-copy contract, and the late Windows health snapshot reads back the same Store-install state ledger that the install and shortcut tasks now use.

### Highlights
- Added a shared Store install-state helper module so the touched Windows Store-backed tasks now share one centralized contract for PATH refresh, `winget` discovery, stale RunOnce cleanup, and launch-ready state persistence.
- Added a deterministic retro-log audit helper so the historical `az-vm-log-*.txt` corpus can be rescanned for the noisy or degraded patterns that drove this hardening pass.
- Updated the touched Store-backed install tasks so they now fail or degrade explicitly when an interactive Store-capable session is missing, instead of scheduling any next-boot or next-sign-in continuation work.
- Updated Teams startup so the managed startup surface now prefers the packaged `AppsFolder` launch contract, matching the healthy Store shortcut model.
- Fixed Python verification, copy-settings skip accounting, local screen-reader autostart self-heal, and benign transcript noise filtering in the SSH task pipeline.
- Revalidated the changes with isolated live task runs on the active managed Windows VM, including the touched builtin tasks plus the local-only screen-reader autostart tasks, ending with healthy Docker, Ollama, Teams startup, refreshed public shortcuts, and zero managed shortcut or stage-summary failures.

## Release 2026.3.14.310 - 2026-03-14

### Summary
This release replaces the old Windows app-state replay surface with a more extensible plugin model. Vm-update tasks now look only for `.../update/app-states/<task-name>/app-state.zip`, replay that payload when it exists, and continue cleanly when it does not. The shared post-process now serves builtin and local-only tasks alike, connection and direct-task flows can repair a VM that remains stuck in provisioning state `Updating` through one bounded `az vm redeploy`, Store-backed public desktop shortcuts still normalize through `AppsFolder` launches, and the local WSL payload still keeps only the `docker-desktop` distro state.

### Highlights
- Added a shared vm-update app-state plugin manager and guest replay helper so builtin and local-only update tasks can both consume one exact per-task app-state zip contract without a dedicated restore task.
- Standardized the only valid app-state source path to `.../update/app-states/<task-name>/app-state.zip` and removed the old tracked restore task plus the old local overlay replay path.
- Moved the local app-state export helper into `modules/core/tasks/` so builtin and local-only update tasks now share one orchestration layer for save/restore helpers and post-task replay.
- Added `docs/windows-store-migration-audit.md` so the repo now documents which Windows apps are already Store-backed, which Store migrations are credible but still approval-gated, and which installers should stay on their current source.
- Updated the Windows public desktop shortcut contract so Store-backed apps such as Codex, Teams, WhatsApp, and Be My Eyes prefer `explorer.exe` with `shell:AppsFolder\<AUMID>`, while `a11MS Edge` stays on the requested direct `msedge.exe` launch contract and Google Drive now refreshes to the newest versioned executable path.
- Hardened the WSL/Docker path with explicit feature-state health evidence and narrowed the local-only WSL overlay replay so only `docker-desktop` remains in the exported and replayed distro state.
- Added one bounded redeploy repair path when Azure leaves the VM stuck in provisioning state `Updating`, and hardened task execution so persistent SSH session drops can fall back to one-shot execution without skipping per-task app-state replay.
- Revalidated the change set with isolated live task runs on the active Windows VM across the full builtin and local-only vm-update task set, including the refreshed shortcut normalization, the per-task app-state post-process hook, the SSH transport fallback path, and the filtered WSL payload behavior.

## Release 2026.3.13.308 - 2026-03-13

### Summary
This release turns the top of the README into a much stronger public value story. The repo now presents `az-vm` more clearly as a Windows-first, near-zero-touch remote workstation delivery path while still describing Linux accurately as a lighter but fully extensible platform under the same operator model.

### Highlights
- Rewrote the opening README funnel so the first sections emphasize the prepared remote-computer outcome: installed applications, curated startup behavior, desktop shortcuts, UX tuning, advanced settings, and task-driven customization.
- Added concrete PoC / PoE-style stories for customer demos, employee workstations, developer workstations, and support-oriented machines.
- Expanded the audience framing so customers, executives, employees, administrative teams, workers, developers, operators, visitors, and sponsors can all see a credible value proposition quickly.

## Release 2026.3.13.307 - 2026-03-13

### Summary
This release narrows prompt-history auto-recording to the turns that matter most. Very short approval/follow-up nudges and non-mutating question or analysis turns are now excluded from automatic ledger recording, while substantive prompts still remain mandatory English-normalized history entries.

### Highlights
- Updated `AGENTS.md` so excluded prompt types are explicit and the assistant must end those turns with a short opt-in recording hint.
- Updated `README.md` and the documentation contract so the refined prompt-history policy stays visible and test-enforced.
- Kept the standing sensitive-content guardrail in place while making prompt-history output more signal-dense and easier to maintain.

## Release 2026.3.13.306 - 2026-03-13

### Summary
This release turns the recent cleanup discipline into a standing engineering control. The repo now has an always-on sensitive-content audit in local hooks and in the non-live quality gate, so obvious contact-style values, concrete identity leaks, and non-placeholder sensitive config drift are blocked before they become shared history.

### Highlights
- Added `tests\sensitive-content-check.ps1` as a dedicated repo-authored hygiene audit for tracked files, committed configuration placeholders, and reachable commit messages.
- Added a native `commit-msg` hook so commit messages are checked before the commit is accepted, not only after the content reaches CI.
- Updated `AGENTS.md`, `README.md`, and the documentation contract so contributors see the rule clearly and the repo keeps enforcing it automatically.

## Release 2026.3.13.305 - 2026-03-13

### Summary
This release is a final documentation polish pass on top of the repository-wide cleanup work. The maintained repo surface now avoids restating retired tokens, removed sample values, and replacement metadata explicitly in the release-facing docs, so the current public tree stays aligned with the sanitized content policy end to end.

### Highlights
- Reworded the maintained release documents so they describe the cleanup outcome without reintroducing any retired surface tokens or removed sample terms in current tracked text.
- Rewrote the matching prompt-history entry in neutral language so the human-readable ledger stays consistent with the cleaned repository surface.
- Revalidated the maintained tip with the full non-live gate: smoke, documentation contract, PowerShell compatibility, code quality, and bash syntax.

## Release 2026.3.13.304 - 2026-03-13

### Summary
This release finalizes the repository cleanup pass for public history and current content. The obsolete destructive-rebuild shortcut is gone, rebuild guidance now uses explicit `delete` plus `create`, and the tracked repo plus reachable git history were redacted so concrete contact-style values, secret samples, organization-style example names, and real live-target identifiers no longer remain in the public history that the repo exposes.

### Highlights
- Removed the retired destructive-rebuild shortcut from runtime code, help, README, smoke coverage, and release docs, and aligned the operator contract around an explicit `delete` then `create` rebuild flow.
- Replaced concrete-looking contact values, secret samples, live target names, and subscription identifiers in the current tracked repo with generic placeholders or neutral examples so the maintained surface is safer to publish and easier to reuse.
- Rewrote reachable history in a controlled offline clone with the same replacement map applied to blobs and commit messages, then standardized rewritten author and committer metadata to the configured maintainer identity while preserving timestamps.
- Revalidated the rewritten current tip with the full local non-live gate: smoke, documentation contract, PowerShell compatibility, code quality, and bash syntax.

## Release 2026.3.13.302 - 2026-03-13

### Summary
This release is a documentation presentation refresh focused on readability, audience fit, and public-facing clarity. `README.md` now opens with a faster value story for customers and executives, keeps the technical depth for operators and maintainers, and adds a table-driven operational command reference so the full command surface is easier to scan and adopt.

### Highlights
- Merged the old quick-start and quick-accelerator material into one stronger `Quick Start Guide` and moved business impact to the top of the document through `Customer Business Value`, a standalone `Executive Summary`, and the new `Value By Audience` section.
- Added the new `Operational Command Matrix` so every public command, important parameter group, and practical usage variation is visible in one pragmatic table-driven section before the deeper narrative command guide.
- Updated the README information architecture to work better for customers, executives, developers, operators, visitors, and potential sponsors while preserving the repo's exact contract-heavy command and workflow wording.
- Extended the documentation contract checks so the new heading order, the merged quick-start structure, and the new command-matrix sections remain enforced.

## Release 2026.3.13.301 - 2026-03-13

### Summary
This release closes the fresh Windows release-bar loop on the current Azure subscription and stabilizes the remaining first-run guest tasks that blocked a clean `create -> update` cycle. The Windows user-settings copy task now mirrors only the known user folders and explicit app settings that matter, the long-running Ollama and VLC installers now follow bounded verification paths that survive clean-build cold starts, and the live create/update path now recovers more cleanly from OpenSSH bootstrap and transient SSH-session loss on a brand-new VM.

### Highlights
- `10005-copy-settings-user.ps1` now copies only explicit profile roots plus selected Task Manager, VS Code, Chrome, and repo-managed CLI-wrapper state, removing the old shallow broad-AppData mirroring that was slow, fragile, and noisy around ACLs, locked files, and reparse points.
- Fresh Windows `create` now survives the previously observed first-run failures because `03-install-openssh-service.ps1`, `04-configure-sshd-port.ps1`, and the shared persistent SSH task runner now recover missing `sshd` service registration and restore the transport session after transient installer drops.
- `116-install-ollama-system.ps1` now uses a stronger bounded cold-start API readiness contract for `/api/version`, including both `127.0.0.1` and `localhost` probes plus longer bounded grace windows, and `124-install-vlc-system.ps1` now uses a bounded winget-install plus executable verification model instead of failing on a short runner timeout.
- `10099-capture-snapshot-health.ps1` now refreshes PATH and resolves `az`, `docker`, and `ollama` through explicit fallback paths, which removes the earlier false `not-found` signals from late-stage health capture on fresh VMs.
- Live acceptance completed successfully against subscription `<subscription-guid>`: a fresh `create --auto --windows --vm-name=examplevm --vm-region=austriaeast --vm-size=Standard_D4as_v5` rebuilt `rg-examplevm-ate1-g2`, a controlled reboot satisfied the post-create WSL restart requirement, and the follow-up `update --auto --windows --group=rg-examplevm-ate1-g2 --vm-name=examplevm` finished with `failed=0` and `warning=0`.

## Release 2026.3.13.300 - 2026-03-13

### Summary
This release closes the Azure subscription-selection gap across the command surface. Every Azure-touching command now accepts `--subscription-id` / `-s`, the runtime resolves subscriptions with the committed `CLI -> .env -> active Azure CLI` precedence, interactive `create` and `update` now ask for the subscription before Azure-backed discovery when no CLI override is present, and the docs/help/tests now treat `az login` as a strict prerequisite for Azure operations.

### Highlights
- Added shared subscription targeting for `create`, `update`, `configure`, `list`, `show`, `do`, `move`, `resize`, `set`, `exec`, `ssh`, `rdp`, and `delete`, while keeping `task` and `help` local-only and intentionally outside the subscription-aware contract.
- Added the repo-local `azure_subscription_id` configuration key to `.env.example` and documented the exact precedence rule everywhere the operator contract lives: CLI `--subscription-id` / `-s` wins first, `.env azure_subscription_id` wins next, and the active Azure CLI subscription is the final fallback.
- Updated the shared Azure CLI wrapper so normal `az` calls inherit the resolved subscription automatically through Azure CLI's global `--subscription` argument, while account-discovery helpers can still bypass forced subscription injection when they need to inspect the full accessible subscription set.
- Interactive `create` and `update` now show a numbered Azure subscription picker before region, SKU, managed resource-group, or VM discovery when `--subscription-id` is omitted, and successful CLI `-s` usage persists `azure_subscription_id` back into `.env`.
- Revalidated the entire non-live gate after the contract landed: smoke, documentation contract, PowerShell compatibility, code quality, and bash syntax all pass against the subscription-aware surface.

## Release 2026.3.13.299 - 2026-03-13

### Summary
This release finishes the `configure` and public inventory command-surface refresh. `configure` now acts as the managed target selector and `.env` synchronization command for existing az-vm-managed VMs, interactive `create` now asks for the VM OS first when no platform flag is supplied, and the old `group` command has been replaced by the new read-only `list` command.

### Highlights
- `az-vm configure` now accepts `--group` and `--vm-name`, selects only az-vm-managed targets, reads actual Azure VM, disk, and network state, validates optional platform flags against the real VM OS type, and writes only target-derived `.env` values.
- `az-vm list` now exposes managed inventory sections through `--type=group,vm,disk,vnet,subnet,nic,ip,nsg,nsg-rule` with optional exact `--group` filtering, replacing the removed public `group` command.
- Interactive `create` no longer silently inherits `.env VM_OS_TYPE` when platform flags are missing; it now prompts for the VM OS first and scopes image, size, and disk defaults from that explicit choice.
- Help, README, AGENTS, and smoke/documentation/code-quality checks were all updated together so the repo no longer documents or tests the removed `group` command surface.

## Release 2026.3.13.298 - 2026-03-13

### Summary
This release finishes the runtime side of the fresh-create, existing-update, and live-grounded Windows hardening work. The create/update workflow now stays aligned with the review-first UX contract, managed naming keeps globally unique `gX` and `nX` ids, and the Windows init/update tasks were tightened using read-only findings from the current live VM so new VMs come up with fewer shortcut, startup, autologon, Docker, Ollama, and profile-copy regressions.

### Highlights
- Fresh `create` planning now always proposes a new managed resource group with the next global `gX` suffix, and every generated managed resource now consumes a globally unique `nX` suffix across all managed resource types instead of reusing per-type counters.
- `create` no longer reuses persisted managed resource names from `.env` during fresh planning unless the current invocation explicitly overrides them, while `update` continues to target the existing managed RG and VM path.
- Windows tracked task catalogs now place `108-install-sysinternals-suite` and `130-autologon-manager-user` in `vm-init`, with the Windows workflow keeping a restart barrier before `vm-update` when init ran.
- `10001-configure-apps-startup.ps1`, `10002-create-shortcuts-public-desktop.ps1`, `114-install-docker-desktop.ps1`, `116-install-ollama-system.ps1`, `10005-copy-settings-user.ps1`, and `10099-capture-snapshot-health.ps1` now follow the live VM findings more closely: startup artifacts are written-and-verified, orphan managed shortcuts are skipped, packaged apps resolve through real executables or `shell:AppsFolder`, excluded profile-cache targets are pruned on reruns, and the health snapshot reports richer Docker/Ollama/WSL/autologon state.
- The isolated live validation set completed successfully on `rg-examplevm-sec1-g1/examplevm`, including targeted init/update task reruns plus non-mutating `create --step=configure` and `update --step=configure` probes that confirmed the fresh naming and existing-target contracts.

## Release 2026.3.13.297 - 2026-03-13

### Summary
This release finishes the help/docs/tests side of the in-progress command-surface refresh. The maintained documentation now describes `create` as a fresh-only flow, `update` as an existing-managed-target flow, the review-first interactive UX, globally unique managed `gX`/`nX` naming, and the strict auto-mode requirements without carrying the earlier reuse-oriented wording.

### Highlights
- Updated `modules/core/cli/azvm-help.ps1` and `README.md` so `create --auto` now documents the required explicit platform plus `--vm-name`, `--vm-region`, and `--vm-size`, while `update --auto` documents the required explicit platform plus `--group` and `--vm-name`.
- Documented the review-first UX more precisely: only `group`, `vm-deploy`, `vm-init`, and `vm-update` use `yes/no/cancel`, while `configure` and `vm-summary` always render even when a partial step window skips interior stages.
- Updated the naming guidance so managed resource groups use globally increasing `gX` ids and managed resources use globally increasing `nX` ids that are never reused across resource types.
- Refreshed the smoke/documentation contracts to match the current in-progress implementation, including the current autologon health snapshot output rather than a future `DefaultPasswordPresent` health-field expectation.

## Release 2026.3.12.296 - 2026-03-12

### Summary
This release fixes the remaining GitHub Actions quality-gate blocker after publication by making the smoke suite fully non-live again. The slow `smoke-contracts` job was not a runner deadlock; it was accidentally executing real Azure-dependent code paths because several test doubles were declared in the wrong scope.

### Highlights
- Updated `tests/az-vm-smoke-tests.ps1` so the create, update, resize, reapply, and hibernate-stop smoke doubles now override the runtime functions in the active test scope instead of falling through to `.env` and Azure CLI backed implementations on GitHub-hosted runners.
- Restored the smoke suite to the expected short non-live execution profile, eliminating CI waits caused by unintended `az login` prompts and unexpected Azure calls inside the smoke contract job.
- Revalidated the full local non-live gate before the follow-up push: smoke, documentation contract, PowerShell compatibility, code quality, bash syntax, and pre-commit release-doc checks all pass.

## Release 2026.3.12.295 - 2026-03-12

### Summary
This release fixes the GitHub Actions publish gate for the new public repository by switching every workflow checkout to full-history mode, which restores the commit-count-based release-document validation on CI after the initial public push.

### Highlights
- Updated `.github/workflows/quality-gate.yml` so every `actions/checkout@v6` step uses `fetch-depth: 0`, preventing the release-document checks from seeing a shallow clone count of `1` on GitHub-hosted runners.
- Published the repo to the public GitHub remote, pushed aligned `main` and `dev`, and removed all remaining non-canonical local branches so the repo now keeps only the two intended long-lived branches.
- The previous failing `main` workflow run was traced to shallow checkout depth rather than the actual code or docs contract; the follow-up push from this release is intended to produce the clean authoritative `main` Actions result.

## Release 2026.3.12.294 - 2026-03-12

### Summary
This release closes the last live Windows publish blockers from the recreate-and-update acceptance cycle by fixing the remaining Node, Edge, and profile-copy task failures, then rerunning the full live update validation to a clean finish.

### Highlights
- Raised the tracked timeout budgets for `104-install-node-system` and `111-install-edge-browser`, and added short bounded post-install verification so the tasks still require a real healthy install but no longer time out during first-run package setup.
- Hardened `10005-copy-settings-user.ps1` so `AppData\Local\Microsoft\Windows\WebCacheLock.dat` is excluded from the local profile copy path and the robocopy fallback now tolerates the same live lock signature across the observed return codes.
- Revalidated the live Windows path on `rg-examplevm-sec1-g1/examplevm` with isolated reruns of tasks `104`, `111`, and `10005`, then a full `az-vm update --auto --windows --perf` pass that finished `success=45, failed=0, warning=0, error=0, reboot=0`.
- Completed the release-closeout checks with `az-vm show --group=rg-examplevm-sec1-g1`, `az-vm do --vm-action=status`, `az-vm ssh --test`, and `az-vm rdp --test`, all passing against the live VM after the clean full update.

## Release 2026.3.12.293 - 2026-03-12

### Summary
This release finishes the command-surface refresh for publish-readiness: step selectors are renamed to the new `--step` family, destructive rebuild guidance is made explicit through a `delete` then `create` flow while the broader create/update contract continues toward the current fresh-only create model, `update` now requires an existing managed VM and redeploys it during the VM deploy stage, and `resize` gains a safe managed OS disk expand path plus an explicit non-mutating shrink guidance path.

### Highlights
- Renamed the create/update step selectors from `--single-step`, `--from-step`, and `--to-step` to `--step`, `--step-from`, and `--step-to`, then removed the retired option forms throughout the parser, manifest, parameter modules, help output, README, and smoke contract.
- Standardized destructive rebuild guidance around an explicit `delete` followed by `create`, keeping destructive rebuild intent separate from the evolving default create/update contract.
- Changed `update` so it fails early when the managed resource group or VM is missing, then uses Azure create-or-update plus `az vm redeploy` once an existing VM is confirmed.
- Added `resize --disk-size=<number>gb|mb --expand` for the supported managed OS disk growth path, and `resize --disk-size=<number>gb|mb --shrink` as a fail-fast guidance path that explains Azure's OS disk shrink limit and lists supported rebuild alternatives.
- Refreshed README and AGENTS with a stronger quick-start, business-value, developer-benefit, and practical-usage narrative while keeping the documentation contract aligned with the runtime surface.

## Release 2026.3.12.291 - 2026-03-12

### Summary
This release synchronizes the publish-facing repository contract with the current live-acceptance workflow and hardens Windows VM creation against transient Azure CLI create failures that can still result in a successfully deployed VM.

### Highlights
- Updated the GitHub issue templates, pull-request template, README, contributing guide, and support guide so live Azure acceptance and release-readiness claims now follow the same documented reporting contract everywhere.
- Added an explicit `documentation-contract` job to `.github/workflows/quality-gate.yml`, bringing the existing documentation contract check into the GitHub Actions gate alongside the rest of the non-live validation suite.
- Hardened `Invoke-AzVmVmCreateStep` so transient non-zero `az vm create` results now trigger a short bounded VM-presence probe instead of immediately failing when Azure may still complete the deployment moments later.
- Revalidated the non-live publish gate with code-quality, documentation-contract, PowerShell compatibility, smoke, and bash-syntax checks before recording this release point.

## Release 2026.3.12.290 - 2026-03-12

### Summary
This release completes a second Windows `vm-update` performance-tuning pass against live perf logs by removing the remaining retry-heavy noninteractive waits, shortening bounded settle windows, and making repeated deferred Store installs short-circuit instead of trying the same failing path again.

### Highlights
- Reworked `114-install-docker-desktop.ps1` so the task no longer waits on repeated Docker daemon probes in SSH sessions; it now verifies the Docker client, starts Docker Desktop once, and immediately registers an interactive `RunOnce` start for the next sign-in.
- Reworked `121-install-whatsapp-system.ps1` so it prefers fast local registration checks over `winget list`, and skips the whole install attempt when a deferred `RunOnce` Store install is already registered.
- Shortened registry-hive unload waits in `10001-configure-apps-startup.ps1` and `10099-capture-snapshot-health.ps1`, and reduced Task Manager / Explorer settle waits in `10003-configure-ux-windows.ps1`.
- Updated smoke coverage so the Docker Desktop task is enforced against the new bounded deferred-start model rather than the old daemon-probe loop.
- Revalidated the live Windows path on `rg-examplevm-sec1-g1/examplevm`: `114-install-docker-desktop` fell from about `16.2s` to about `3.2s`, `121-install-whatsapp-system` now short-circuits deferred reruns at about `3.5s`, `10099-capture-snapshot-health` fell to about `6.1s`, and the full `vm-update` step fell from about `234.7s` to about `198.0s`.

## Release 2026.3.12.288 - 2026-03-12

### Summary
This release splits the old `do --vm-action=hibernate` contract into two explicit operator choices: `hibernate-stop` for guest-triggered SSH hibernation without Azure deallocation, and `hibernate-deallocate` for Azure's existing deallocation-based hibernation path.

### Highlights
- Added `do --vm-action=hibernate-stop`, which connects through the repo-managed pyssh path, runs `shutdown /h /f` inside the running guest, and waits until the VM is no longer accepting SSH without treating Azure deallocation as success.
- Renamed the Azure-backed hibernation action from `hibernate` to `hibernate-deallocate`, making the deallocation behavior explicit instead of hiding it behind the old shorter action name.
- Updated the `do` action parser, interactive picker, help output, README examples, and smoke suite so the retired `hibernate` action now fails with a precise migration hint to `hibernate-stop` or `hibernate-deallocate`.

## Release 2026.3.12.287 - 2026-03-12

### Summary
This release fine-tunes the slowest Windows `vm-update` paths by making Docker Desktop readiness checks non-blocking in SSH sessions, shortening user-settings copy waits, removing retry-heavy shortcut normalization behavior, and enforcing a repo-wide no-`--force` install contract for tracked Windows update tasks.

### Highlights
- Reworked `114-install-docker-desktop.ps1` so it uses only two short `docker version` probes, skips the old blocking `docker info` gate, and registers a deferred interactive `RunOnce` start instead of waiting for the daemon indefinitely inside a noninteractive guest session.
- Reworked `10005-copy-settings-user.ps1` so assistant logoff/process cleanup settles through a short bounded session/process watcher rather than a fixed five-second sleep, and registry-hive unload retries now use fewer attempts with much shorter waits.
- Fixed and accelerated `10002-create-shortcuts-public-desktop.ps1` by adding an already-normalized fast path, removing the accidental early-return behavior during Public Desktop inspection, and broadening duplicate cleanup coverage to installer-created `AnyDesk`, `Windscribe`, `VLC media player`, `iTunes`, `IObit Unlocker`, and `NVDA` shortcuts.
- Removed every tracked Windows `vm-update` `--force` flag and aligned the install tasks with an install-if-missing, skip-if-healthy model; the winget bootstrap task now avoids forceful source resets and uses only one bounded `source update` recovery attempt.
- Completed a live Windows validation cycle on `rg-examplevm-sec1-g1/examplevm`, including isolated reruns of the tuned tasks plus a full `update --step=vm-update --auto --windows` pass; the latest Public Desktop readback leaves only the intentionally unmanaged local-only accessibility shortcuts outside the tracked managed set.

## Release 2026.3.12.286 - 2026-03-12

### Summary
This release renames the tracked Windows Public Desktop shortcut set into the approved English `Business`/`Personal` vocabulary, restores the managed `SourTimes` and company-branded Web/Blog shortcuts, lowercases every repo-managed Chrome profile-directory value, and upgrades Public Desktop cleanup from exact-name replacement to semantic duplicate normalization.

### Highlights
- Renamed the tracked Public Desktop labels to the approved English contract, including the explicit overrides `s18NextSosyal Business`, `r13CicekSepeti Business`, `r14CicekSepeti Personal`, `r17PTTAVM Business`, and `r18PTTAVM Personal`.
- Restored `q1SourTimes`, `s15{TitleCase(company_name)} Web`, and `s16{TitleCase(company_name)} Blog` as tracked managed shortcuts while keeping `q2Spotify` and `q3Netflix` intact.
- Refactored Chrome shortcut profile routing so business/personal intent is carried by shortcut metadata instead of old label text, and both `company_name` and the email local-part are normalized to lowercase before being emitted into `--profile-directory`.
- Hardened `10002-create-shortcuts-public-desktop` so installer-created overlaps such as Google Chrome, Microsoft Edge, AnyDesk, and Visual Studio 2022 are removed by semantic duplicate matching, while unrelated unmanaged Public Desktop shortcuts remain untouched.
- Moved `az-vm-interactive-session-helper.ps1` into `tools/scripts/` and updated runtime helper-asset resolution to load it from the new repo path while keeping the guest-side helper copy target unchanged.
- Updated the tracked health snapshot, `.env.example`, README, AGENTS contract, and smoke assertions so the new label set, lowercase Chrome profile rule, restored shortcuts, and duplicate-normalization behavior are enforced together.

## Release 2026.3.12.284 - 2026-03-12

### Summary
This release adds `az-vm do --vm-action=reapply` as a repo-managed VM repair action, keeps it available when Azure provisioning is not currently succeeded, and aligns the interactive selector, help output, README examples, and smoke coverage with the new lifecycle-action contract.

### Highlights
- Added `do --vm-action=reapply`, which resolves the managed VM target, runs `az vm reapply`, and then prints a refreshed lifecycle status report.
- Expanded the `do` parser hints, interactive action picker, CLI help pages, and README examples so `reapply` is documented alongside the existing lifecycle actions.
- Added smoke coverage for the new action, including parser acceptance, provisioning-guard bypass behavior, interactive selection, help/docs visibility, and the concrete `az vm reapply` invocation path.

## Release 2026.3.12.283 - 2026-03-12

### Summary
This release expands the tracked Windows shortcut/update contract with employee-aware Chrome profile routing, new marketplace and tooling shortcuts, new prerequisite install tasks, and a generic local-accessibility boundary that removes vendor-specific ownership from the tracked repo surface while preserving local-only flexibility.

### Highlights
- Added committed `employee_email_address` and `employee_full_name` placeholders and wired employee-aware token replacement through the command runtime and task materialization layer.
- Expanded the tracked Public Desktop shortcut task with `i1Internet Kurumsal`, `i2Internet Bireysel`, `r11-r22`, `k3Github Copilot CLI`, `v1VS2022Com`, and the renamed `t10Azd CLI`; `e1Mail` and every `Bireysel` Chrome shortcut now use the employee email local-part for `--profile-directory`, while `Kurumsal` shortcuts continue using `company_name`.
- Added tracked Windows task `132-install-vs2022community.ps1`, raised tracked task `115-install-npm-packages-global` to the new timeout contract, and extended it to install the GitHub Copilot CLI prerequisite.
- Reworked the tracked startup/profile-copy surface so one private local-only accessibility flow is handled generically: tracked code now provides neutral host autostart discovery, keeps unmanaged public shortcuts intact, and no longer contains vendor-specific startup or profile-copy ownership.
- Revalidated the whole non-live gate and completed a live Windows acceptance cycle on `rg-examplevm-sec1-g1/examplevm`, including isolated local-only accessibility reruns, a full `update --step=vm-update --auto --windows` pass with `success=45`, repo-managed restart validation, and post-reboot SSH/process readback confirming the active manager session, startup shortcut, automatic utility service, and running local accessibility processes.

## Release 2026.3.11.282 - 2026-03-11

### Summary
This release closes the live Windows publish-gate blockers uncovered during end-to-end acceptance, tightens the `copy-settings-user` profile-sync rules around deterministic skip paths, fixes the provisioning-ready poll used by post-deploy feature verification, documents the required live release bar, and compresses the startup `script description:` banner into a single line.

### Highlights
- Fixed the provisioning-ready wait so post-deploy feature verification now reads `az vm get-instance-view` from `instanceView.statuses` and the top-level `provisioningState`, eliminating the false empty-state retry loop observed on real existing VMs.
- Hardened Windows task `10005-copy-settings-user` so required profile roots are copied explicitly, compatibility-alias/reparse-point paths are skipped deterministically, missing HKCU source branches no longer abort assistant hive seeding, and best-effort profile artifacts can be skipped safely on ACL or in-use failures.
- Added a written live release-acceptance gate to `README.md`, `AGENTS.md`, and the documentation contract checks, requiring a real create/update/status/show/connection verification cycle whenever live release-readiness is claimed.
- Changed the startup banner in `Invoke-AzVmMain` so `script description:` now stays on one line with the rest of its explanatory text.
- Revalidated the change set with `tests/az-vm-smoke-tests.ps1`, `tests/powershell-compatibility-check.ps1`, and `tests/documentation-contract-check.ps1`, then completed a live `az-vm update --auto --windows` acceptance run with `vm-update` finishing `success=41, failed=0, warning=0, error=0, reboot=0`.

## Release 2026.3.11.281 - 2026-03-11

### Summary
This release finishes the modular-runtime cutover by removing the transitional root loaders entirely. `az-vm.ps1` now loads one ordered manifest and then dot-sources the refactored leaf files directly, so the active runtime path is fully modernized with no legacy root-wrapper layer left in `modules/`.

### Highlights
- Added `modules/azvm-runtime-manifest.ps1` as the single ordered source of truth for runtime leaf-file loading.
- Removed the old root wrapper files from `modules/core/`, `modules/config/`, `modules/tasks/`, `modules/ui/`, and `modules/commands/`, so current execution no longer flows through compatibility-loader scripts.
- Updated the smoke suite to assert that the deleted root loader paths do not exist and that `az-vm.ps1` and the manifest do not reference them.
- Revalidated the cutover with `tests/code-quality-check.ps1`, `tests/az-vm-smoke-tests.ps1`, and `tests/powershell-compatibility-check.ps1`.

## Release 2026.3.11.280 - 2026-03-11

### Summary
This release is a behavior-preserving modularization of the `modules/` runtime: the historical root module paths stay loadable as compatibility shims, but the implementation now lives in smaller domain files with command-level and parameter-level ownership, so the repo is easier to extend without reintroducing large monolithic PowerShell files.

### Highlights
- Kept the existing entrypoint and root runtime file paths, then turned those roots into deterministic compatibility loaders that dot-source the new leaf files in a fixed order.
- Split `modules/commands/` by public command so each supported command now has its own `entry.ps1`, `contract.ps1`, `runtime.ps1`, and `parameters/` directory, with reusable shared parameter logic staying under `modules/commands/shared/parameters/`.
- Moved create/update orchestration internals into dedicated `context`, `steps`, `features`, `pipeline`, and shared-runtime helpers, and limited `modules/ui/` to prompts, selection flows, show rendering, and connection-facing helpers.
- Split task transport internals into `modules/tasks/run-command/` and `modules/tasks/ssh/`, while isolating shared system, config, naming, runtime, and task-discovery helpers under `modules/core/` and `modules/config/`.
- Revalidated the refactor with the full non-live gate: `tests/code-quality-check.ps1`, `tests/az-vm-smoke-tests.ps1`, and `tests/powershell-compatibility-check.ps1`.

## Release 2026.3.11.279 - 2026-03-11

### Summary
This release hardens the live publish-gate surface by adding non-interactive SSH/RDP validation, turning hibernation and nested virtualization into verified post-deploy outcomes, redacting password-bearing values from `az-vm show`, and making the Windows interactive/update tasks more resilient under real guest conditions.

### Highlights
- Added `az-vm ssh --test` and `az-vm rdp --test` so the repo can prove connection readiness without launching `ssh.exe` or `mstsc.exe`.
- Changed post-deploy feature reconciliation so `VM_ENABLE_HIBERNATION=true` and `VM_ENABLE_NESTED_VIRTUALIZATION=true` now require successful verification instead of best-effort warnings; nested virtualization is validated from inside the running guest.
- Updated `az-vm show` to redact password-bearing config values and to print nested-virtualization state, validation source, and evidence when available.
- Improved the Windows interactive desktop helper plus the Be My Eyes and iCloud tasks so they can use an existing interactive desktop when present and register deferred `RunOnce` installs when Store-backed flows cannot complete headlessly.
- Hardened Windows UX/profile-copy, Ollama, Docker Desktop, and AnyDesk tasks to reduce avoidable noise, stale-installer waits, and non-fatal native exit-code regressions during real update runs.

## Release 2026.3.11.278 - 2026-03-11

### Summary
This release removes an artificial compatibility-test bottleneck by fixing the smoke-test stubs behind the new provisioning-ready gate, so the PowerShell compatibility matrix no longer spends minutes waiting on fake Azure provisioning and now finishes in normal time again.

### Highlights
- Fixed the two post-deploy feature-enable smoke tests so their local `az` stubs now answer `az vm get-instance-view` with an immediate `Provisioning succeeded` snapshot.
- Eliminated the repeated synthetic provisioning wait loop that had stretched `tests/powershell-compatibility-check.ps1` into multi-minute runs and timeout-prone output floods.
- Revalidated the fix with a direct smoke rerun and a full compatibility-matrix rerun after the stub update.

## Release 2026.3.11.277 - 2026-03-11

### Summary
This release makes the repo publish-ready for GitHub by adding `-h` as a first-class help alias, expanding the public community/support files, extending the non-live CI smoke gate, and redacting publish-inappropriate literals from maintained history docs without changing the product's current runtime contract.

### Highlights
- Added `-h` support next to `--help` for the global CLI surface and command-specific help pages, then refreshed the README and help examples so operators can rely on either form consistently.
- Added `CONTRIBUTING.md`, `SUPPORT.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, issue templates, and a pull-request template shaped around the current custom non-commercial license, maintainer-curated contact-first workflow, and sponsorship/commercial-contact path.
- Extended `.github/workflows/quality-gate.yml` so GitHub now runs the non-live smoke-contract suite alongside the existing static audit, PowerShell compatibility, Linux shell syntax, and workflow lint checks.
- Redacted environment-specific VM names, profile examples, local filesystem paths, and other publish-unnecessary literals from `CHANGELOG.md`, `release-notes.md`, and `docs/prompt-history.md` while preserving the repo's technical history.
- Normalized tracked Linux shell scripts to LF and added `*.sh text eol=lf` to `.gitattributes`, removing the CRLF-induced `bash -n` failures from the publish gate.

## Release 2026.3.11.276 - 2026-03-11

### Summary
This release changes the Windows Public Desktop shortcut task from a destructive full mirror into a managed-only reconcile pass, restores host-driven startup mirroring for installed guest apps, and expands the late health snapshot so preserved unmanaged shortcuts and host-observed startup surfaces are both inventoried explicitly.

### Highlights
- Updated `10002-create-shortcuts-public-desktop` so it now preserves unmanaged Public Desktop shortcuts such as local-only accessibility shortcuts while still rebuilding the tracked managed shortcut set and clearing the manager, assistant, and default desktop roots.
- Restored dynamic host startup-profile discovery and moved `10001-configure-apps-startup` to method-based host parity, including guest compatibility scaffolding for host apps that start from LocalMachine surfaces.
- Expanded `10099-capture-snapshot-health` and the smoke contract so unmanaged Public Desktop shortcuts are inventoried instead of flagged as unexpected, and startup verification now reads back the decoded host startup profile instead of a static guest snapshot.

## Release 2026.3.11.275 - 2026-03-11

### Summary
This release expands the managed Public Desktop contract again by adding the requested `g1-g4` developer shortcuts and `q2-q8` quick-access web shortcuts, all reusing the same Chrome launcher shape as `i1Internet`.

### Highlights
- Extended `10002-create-shortcuts-public-desktop` with `g1Apple Developer`, `g2Google Developer`, `g3Microsoft Developer`, `g4Azure Portal`, `q2Spotify`, `q3Netflix`, `q4EDevlet`, `q5Apple Account`, `q6AJet Flights`, `q7TCDD Train`, and `q8OBilet Bus`, each using the existing Public Desktop Chrome target and argument contract.
- Expanded `10099-capture-snapshot-health` and the smoke contract so the new shortcut names and URLs are now read back and enforced together with the rest of the managed Public Desktop set.

## Release 2026.3.11.274 - 2026-03-11

### Summary
This release adds a tracked Windows autologon task right after the IO Unlocker step, validates the configured `manager` credentials before applying Sysinternals Autologon, renumbers the tracked iCloud task to keep the catalog order contiguous, and extends the Windows late health snapshot with explicit autologon readback.

### Highlights
- Added `130-autologon-manager-user` so the Windows update flow now resolves `autologon.exe`, validates `VM_ADMIN_USER` and `VM_ADMIN_PASS` locally, runs `autologon /accepteula <user> . <password>`, and then verifies the resulting Winlogon state.
- Renamed the tracked iCloud task from `130-install-icloud-system` to `131-install-icloud-system` so the new autologon task can run immediately after `129-configure-unlocker-io`.
- Expanded `10099-capture-snapshot-health` and the smoke contract so autologon status is now inventoried together with the rest of the Windows late-stage machine state.

## Release 2026.3.11.273 - 2026-03-11

### Summary
This release expands the managed Public Desktop contract again by restoring the requested `e1`, `m1`, `n1`, `r1-r10`, and `u7Network and Sharing` shortcuts while keeping the existing Chrome-profile, mirroring, admin-flag, and per-user desktop cleanup behavior unchanged.

### Highlights
- Extended `10002-create-shortcuts-public-desktop` with the new Outlook inbox launcher, Notepad shortcut, marketplace and tax-portal Chrome shortcuts, and a direct `control.exe /name Microsoft.NetworkAndSharingCenter` shortcut for `u7Network and Sharing`.
- Expanded `10099-capture-snapshot-health` and the smoke contract so the new shortcut names, URLs, and launcher fragments are now read back and enforced together with the existing Public Desktop set.

## Release 2026.3.11.272 - 2026-03-11

### Summary
This release closes the remaining `public-desktop-icons` gap by making `10002-create-shortcuts-public-desktop` clear the manager, assistant, and default desktop roots itself, so the Public Desktop mirror task now enforces the shared-desktop contract end to end on its own.

### Highlights
- Extended `10002-create-shortcuts-public-desktop` so it now deletes lingering entries from `C:\Users\<manager>\Desktop`, `C:\Users\<assistant>\Desktop`, and `C:\Users\Default\Desktop` as part of the same mirror pass that rebuilds the managed Public Desktop shortcut set.
- Updated smoke coverage so the shortcut task must continue to own both the Public Desktop mirror and the per-user desktop cleanup contract.

## Release 2026.3.11.271 - 2026-03-11

### Summary
This release adjusts the `z1Google Account Setup` public desktop shortcut so it now opens Chrome through the exact requested `cmd.exe /c start "" "chrome.exe" ... chrome://settings/syncSetup` launcher shape while keeping the shared Public Desktop Chrome profile contract intact.

### Highlights
- Changed `10002-create-shortcuts-public-desktop` so `z1Google Account Setup` now targets `C:\Windows\System32\cmd.exe` and uses a `start "" "C:\Program Files\Google\Chrome\Application\chrome.exe"` wrapper with `--new-window`, `--start-maximized`, the shared Public Desktop `--user-data-dir`, and the direct `chrome://settings/syncSetup` URL.
- Updated smoke coverage so the Windows shortcut contract now explicitly checks the new `z1` target/argument layout.

## Release 2026.3.11.270 - 2026-03-11

### Summary
This release hardens the Windows late-stage update flow around the requested public desktop, iCloud, and UX contract: `company_name` is now mandatory for repo-managed Windows web shortcuts, the public desktop is rebuilt as a fully mirrored managed set, iCloud is installed through a tracked Store task, user desktops are emptied in favor of Public Desktop, and the UX/readback tasks now cover System Restore shutdown, RDP compatibility, Explorer no-group defaults, and best-effort desktop artifact suppression.

### Highlights
- Added `130-install-icloud-system` and wired it into the tracked Windows update catalog so iCloud for Windows is installed unattended from the Microsoft Store path and exposed to the new `d4ICloud` desktop shortcut.
- Rebuilt `10002-create-shortcuts-public-desktop` around one manifest-driven shortcut contract with the requested 1-based naming, full Public Desktop mirroring, required `company_name`, dynamic `s15/s16`, new `s17/s18`, updated CLI targets, `Ctrl+Alt+N` for NVDA, run-maximized defaults, run-as-admin link flags, and `%UserProfile%` start-in handling for console entries.
- Extended `10003-configure-ux-windows` to disable System Restore and shadow copies, keep RDP NLA off, suppress thumbnail artifacts on known desktop roots, hide shell desktop icons, and reinforce Explorer details/no-group defaults for `This PC` and seeded user settings.
- Reworked `10005-copy-settings-user` so assistant/default settings propagation is now deterministic and fast enough for isolated exec loops, while keeping manager, assistant, and default desktops empty and preserving the helper-asset contract.
- Expanded `10099-capture-snapshot-health` so it now inventories the final shortcut set, target/args/hotkey/start-in/show/admin state, unexpected Public Desktop entries, per-user desktop emptiness, artifact scans, RDP/System Restore state, and Explorer bag values.
- Verified the release live on the Windows VM with isolated `exec` runs of `130`, `10003`, `10002`, `10005`, and `10099`, then repeated `10002` and `10003` for idempotency before the final health pass.

## Release 2026.3.11.269 - 2026-03-11

### Summary
This release introduces the new shared task-band model across Windows and Linux, adds the read-only `task --list` inventory command, renames the tracked task files/catalogs to the new numbering scheme, moves the Windows health snapshot task to `10099`, and standardizes fallback task defaults across tracked and local discovery.

### Highlights
- Added `az-vm task --list` with `--vm-init`, `--vm-update`, and `--disabled`, using the same tracked/local discovery pipeline as real orchestration.
- Renamed tracked Windows and Linux task files so the repo now uses the shared task-number bands `01-99`, `101-999`, `1001-9999`, and `10001-10099`.
- Updated tracked catalogs with explicit `taskType` metadata and band-aligned priorities while keeping the existing timeout values unchanged.
- Updated local-task ordering so runtime now resolves priority from script metadata first, then filename number, then deterministic `1001+` auto-detection.
- Standardized tracked fallback defaults to `priority=1000` and `timeout=180`, while local tasks continue to default missing timeout values to `180` and keep metadata-first priority resolution.
- Moved the Windows late health check to `10099-capture-snapshot-health` and updated move-cutover and `exec` selectors to target the new number.

## Release 2026.3.10.267 - 2026-03-10

### Summary
This release moves intentionally local-only stage tasks under explicit `local/` directories, keeps them metadata-driven and disk-discovered, restores the local accessibility asset layout, and simplifies stage-related `.gitignore` rules around that model.

### Highlights
- Added `local/` and `local/disabled/` task locations to the stage loader while keeping tracked root tasks catalog-driven and duplicate tracked/local task names invalid.
- Restored the Windows local accessibility asset layout under `local/` and kept asset resolution relative to the local task file directory.
- Updated `AGENTS.md`, `README.md`, and smoke/documentation checks so the repo now documents and enforces the new local-only task contract.

## Release 2026.3.10.266 - 2026-03-10

### Summary
This release completes the Windows update `31/32` correction by renaming the tracked task files and catalog entries, not just their priorities: `31` is now the Unlocker task and `32` is now the app-startup task.

### Highlights
- Renamed the tracked Windows files so `31-configure-unlocker-io.ps1` now contains the IObit Unlocker task and `32-configure-apps-startup.ps1` now contains the startup-configuration task.
- Updated the Windows update catalog to match the new file names while keeping the existing timeout values.
- Refreshed smoke coverage and release history so the tracked repo now consistently documents `31=unlocker`, `32=app-startup`.

## Release 2026.3.10.265 - 2026-03-10

### Summary
This release makes one catalog-order correction on the Windows update flow: `32-configure-unlocker-io` now runs before `31-configure-apps-startup`, while both tasks keep their previous timeout values.

### Highlights
- Swapped only the catalog priority values of `31-configure-apps-startup` and `32-configure-unlocker-io`.
- Kept both task names, scripts, and timeout values unchanged.
- Updated smoke coverage so the tracked Windows update order assertion matches the corrected priority order.

## Release 2026.3.10.264 - 2026-03-10

### Summary
This release removes selected private local-only Windows tasks and payloads from tracked history, normalizes the tracked Windows task naming/order, and moves the remaining local-only behavior behind script-level metadata instead of hardcoded runtime special cases.

### Highlights
- Renamed tracked Windows `vm-init` and `vm-update` scripts to the shared `NN-verb-noun-target` convention and reordered the tracked Windows update flow so bootstrap/package tasks start first while late-stage UX, user-settings, and health tasks run last.
- Moved selected private local-only Windows tasks and payloads out of source control while keeping them runnable from disk through ignored local-only files.
- Added generic script-local metadata support for local-only Windows tasks so they can declare `priority`, `enabled`, `timeout`, and asset copy requirements without re-entering tracked catalogs.
- Replaced the runtime's old task-specific Windows asset-copy branch with generic metadata-driven asset resolution.
- Rewrote the active `main` and `dev` histories to remove the selected private local-only tracked paths and their tracked textual references, while preserving `backup-main` and `backup-dev` as untouched backups.
- Expanded smoke and documentation checks to cover the normalized naming/order model, local-only metadata discovery, and the cleaned tracked surface.

## Release 2026.3.10.263 - 2026-03-10

### Summary
This release hardens the `set` command so its public parameters now map cleanly to real behavior and every successful feature-toggle change is reflected back into the local `.env` contract.

### Highlights
- Removed the `set` command's dependency on the heavier Step-1 runtime initialization path and switched it to direct managed-VM target resolution.
- `set` now writes the resolved `RESOURCE_GROUP`, `VM_NAME`, and any successfully applied `VM_ENABLE_HIBERNATION` / `VM_ENABLE_NESTED_VIRTUALIZATION` values back to `.env`.
- Added smoke coverage for both the full-success and partial-success-then-failure cases so `.env` stays aligned with the actual Azure-side result.

## Release 2026.3.10.262 - 2026-03-10

### Summary
This release tightens three shared configuration contracts at once: the repo-managed pyssh client path now has a non-empty default, NSG rule naming now consistently uses the `nsg-rule-` prefix, and create/update flows now honor shared `.env` booleans for hibernation and nested-virtualization intent.

### Highlights
- Set the committed `PYSSH_CLIENT_PATH` default to `tools/pyssh/ssh_client.py` and updated runtime call sites to use that shared default consistently.
- Standardized `NSG_RULE_NAME_TEMPLATE` and related defaults/tests on the `nsg-rule-` prefix.
- Added shared `VM_ENABLE_HIBERNATION=true|false` and `VM_ENABLE_NESTED_VIRTUALIZATION=true|false` keys to the `.env` contract and wired them into create/update post-deploy feature handling.
- Updated `README.md`, `AGENTS.md`, `.env.example`, and validation coverage so the new config contract is documented and enforced together.

### Reliability And Process Notes
- Setting `VM_ENABLE_HIBERNATION=false` now skips create/update hibernation enablement cleanly, even when the chosen SKU supports it.
- Setting `VM_ENABLE_NESTED_VIRTUALIZATION=false` now suppresses the create/update nested-virtualization enablement/validation path without changing the separate `set` command surface.

## Release 2026.3.10.261 - 2026-03-10

### Summary
This release hardens the repository's configuration contract by removing committed runtime identity and password defaults, making required VM identity and credential inputs fail fast when they are missing or left on placeholders, and drawing a sharper line between app-wide `.env` configuration and task-local config blocks inside guest-task scripts.

### Highlights
- Removed shared runtime fallback defaults for legacy sample VM names and demo passwords from the orchestration/UI paths; non-interactive flows now require real `VM_NAME`, `VM_ADMIN_USER`, `VM_ADMIN_PASS`, `VM_ASSISTANT_USER`, and `VM_ASSISTANT_PASS` values.
- Added shared config-resolution helpers so placeholder-sensitive values are rejected consistently with precise remediation hints.
- Updated `.env.example` to use neutral placeholders only, document the new config split, and keep `company_name` as the app-wide brand/profile override for repo-managed Chrome web shortcuts.
- Refactored key Windows update tasks so mutable task-only constants live in explicit top-of-file config blocks instead of being embedded through the task body.
- Kept user-specific shortcut bundles and similar task-only values local to their owning task instead of widening the global `.env` surface unnecessarily.
- Expanded smoke coverage to verify the new required-config behavior and to confirm that shared runtime modules no longer carry the old personal/demo defaults.

### Reliability And Process Notes
- This change intentionally surfaces missing `.env` values earlier: auto/non-interactive orchestration no longer invents VM identity or secret defaults on the operator's behalf.
- The repository now documents a stricter config split: use `.env` for app-wide customization and secrets, and use task-local config blocks for values that matter only to a single init/update task.

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
- Windows Chrome-based public desktop shortcuts now take their default `--profile-directory` from `.env` `company_name`, so shared web shortcuts can target a stable company profile such as `orgprofile` instead of deriving the profile name from `VM_NAME`.
- Snapshot-based regional move now deallocates the source VM before snapshotting, validates that the source group is safe for automatic purge, creates target public IPs with explicit zonal intent to avoid Azure CLI warning noise, attaches copied OS disks without invalid admin-credential flags, and keeps post-cutover task validation strict before old-source cleanup.
- `README.md` and `az-vm help move` now document the move cutover sequence and include an observed live timing reference: the `austriaeast -> swedencentral` move of a `Standard_D4as_v5` VM with a `127 GB` OS disk took about `25-30 minutes`, with cross-region snapshot copy as the dominant phase.
- `ssh` and `rdp` now refuse politely unless the target VM is already running, with a direct hint to start it through `do`.
- External `ssh` and `rdp` connection commands for managed VMs.
- Windows update task `18-install-ollama-system` now short-circuits healthy existing installs, detaches `ollama serve` from the SSH transcript, clears stale installer locks before `winget`, and bounds installer wait time with explicit timeout diagnostics.
- Windows update task `16-install-docker-desktop` now clears stale installer locks before `winget install Docker.DockerDesktop` and reports timed-out installer waits without hanging indefinitely.
- Windows update task `12-install-vscode-system` now short-circuits healthy existing installs instead of re-entering `winget` during resumed e2e runs.
- Windows update task `04` now applies and validates `manager` UX settings through a bounded password-logon scheduled task instead of a reboot/autologon loop.
- Windows update task `04` now enforces hibernate-menu visibility, Explorer details/no-group defaults, desktop name-sort plus auto-arrange/grid alignment, Control Panel small icons, file-copy details, keyboard repeat delay, Task Manager full view via `TaskManager\settings.json`, and hidden Search/Widgets/Task View taskbar controls.
- Windows update task `04` now also uses writable .NET registry handles for user-hive writes, avoids generating a synthetic minimal Task Manager store, and hides Widgets through the supported `AllowNewsAndInterests` machine policy after live `TaskbarDa` failures showed that the prior path was not reliable.
- Windows update task `05` now keeps only deterministic machine-level advanced settings and no longer carries unsupported audio/max-volume automation.
- Windows update task `36-copy-settings-user` now propagates the repo-owned manager user settings into `assistant`, the default profile, and the logon-screen hive with explicit exclusions for volatile and identity-bound stores.
- Windows update task `36-copy-settings-user` was further hardened so `assistant` receives its HKCU/user-class seed through a dedicated password-logon worker while default-profile seeding skips heavyweight non-settings branches such as `AppData\\Local\\Programs`, `Microsoft\\WindowsApps`, and default-profile `LocalLow`, removing the live robocopy stalls seen during repeated isolated `exec` validation.
- Windows update task `33-create-shortcuts-public-desktop` now creates the refreshed public shortcut set for ChatGPT, internet, WhatsApp desktop/web, Google and Office account setup, banking links, and command-style tool launchers with canonical `a1/i0/i1/i2/z1/z2/t*` names, dynamic WhatsApp desktop resolution, and `cmd.exe` wrappers for `.cmd` launchers.
- Windows update tasks `30` through `37` now install and verify iTunes, Be My Eyes, NVDA, Microsoft Edge, VLC, rclone, OneDrive, and Google Drive through the same bounded install-and-readback pattern used elsewhere in the repo.
- Windows update task `19-install-codex-app` now installs the Store-backed Codex desktop app through `winget install codex -s msstore`, verifies it through AppX/StartApps/winget readback, and registers a deferred RunOnce retry when a noninteractive Store session cannot finish immediately.
- Windows update task `32-configure-apps-startup` now applies a static startup snapshot for Docker Desktop, Ollama, OneDrive, Teams, one private local-only accessibility launcher, and iTunesHelper onto the guest VM and writes the resulting launchers into the machine Startup folder.
- Windows update task `32-configure-apps-startup` now also creates missing `StartupApproved` registry keys before it marks existing startup shortcuts enabled, after isolated live `exec` validation exposed that reruns on an already-provisioned VM could otherwise fail on Docker Desktop approval.
- Windows update task `33-create-shortcuts-public-desktop` now also normalizes the broader Public Desktop set with social-media links, app launchers, dynamic app-path fallbacks, one private local-only accessibility hotkey, and Unicode-safe `q1Eksisozluk` handling.
- Windows update task `33-create-shortcuts-public-desktop` now also adds `a3CodexApp` and keeps the requested `OpenAI.Codex_26.306.996.0_x64__2p2nqsd0c76g0\app\Codex.exe` fallback target in the public shortcut contract, while `37-capture-snapshot-health` inventories that shortcut during late-stage validation.
- Windows update task `37-capture-snapshot-health` now also reads back the static machine-startup shortcut set so late-stage validation can show exactly which auto-start launchers were expected and present.
- Windows update task `37-capture-snapshot-health` now inventories the expanded public desktop shortcut set and reads back the exact target-path, argument, hotkey, and Unicode shortcut contracts during late-stage validation.
- Windows update task `37-capture-snapshot-health` now uses a `30s` catalog timeout so live move cutover validation does not produce false timeout warnings on a healthy target VM.
- Windows `vm-update` task catalog timeouts are now derived from observed successful live durations with a 30% buffer, including isolated rerun calibration for tasks `27` and `29`.
- Windows `vm-update` task catalog timeouts are now also calibrated for tasks `30` through `37` from successful isolated live durations, with rerun-confirmed bounded values applied back into the catalog.
- Hardened naming, env-key, and validation contracts across provisioning flows.
- Post-deploy feature enablement for hibernation and nested-virtualization support checks.
- Broader Windows guest update coverage, including UX tuning and public desktop shortcut generation.
- One private local-only Windows accessibility payload now deploys from local zip packages, including staged version replacement, roaming settings restore, and stricter post-copy verification.

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
- The merged Windows update catalog now preserves the late-stage ordering intent by keeping public desktop shortcuts at priority `98`, running `copy-settings-user` at priority `99`, and moving health snapshot to priority `100`.
- Windows interactive UX tasks no longer depend on reboot-resume metadata or autologon cleanup; isolated `exec` runs stay on the normal bounded SSH flow.
- Isolated live validation now covers tasks `04`, `05`, and one private local-only late-stage task on `rg-examplevm-ate1-g1/examplevm`, including idempotent rerun of `04` and private local-only hash/manifest readbacks.
- Isolated live validation now also covers the repaired Windows UX/user-settings late-stage chain: task `04` succeeds after the registry-write fix, task `28` completes without hive-unload or default-profile copy hangs, and task `29` confirms the post-copy machine state on `rg-examplevm-ate1-g1/examplevm`.
- Isolated live validation now also covers full Windows `vm-init` and `vm-update` sweeps plus a focused Ollama rerun that confirms HTTP readiness on port `11434`.
- Isolated live validation now also covers tasks `30` through `37` plus rerun-confirmed `27` and `29`, proving the new package installs, app-backed Public Desktop shortcuts, one private local-only accessibility hotkey assignment, and Unicode-safe `q1Eksisozluk` readback on `rg-examplevm-ate1-g1/examplevm`.
- Persistent SSH task parsing now strips spinner prefixes from `AZ_VM_*` protocol markers so long-running Windows installers cannot hide task-completion signals.
- A fresh `create --auto --windows --perf --step-from=vm-update` rerun now completes successfully on `rg-examplevm-ate1-g1/examplevm` with `Standard_D4as_v5`, and the rebuilt VM answers on RDP port `3389`.

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
