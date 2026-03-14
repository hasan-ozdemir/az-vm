# Changelog

All notable changes to `az-vm` are documented here. The structure follows a Keep a Changelog style, while the content is curated from the repository commit history and the reconstructed Codex development record.
Documented versions use `YYYY.M.D.N`, where `N` is the cumulative repository commit count at the documented release point.

## [2026.3.14.310] - 2026-03-14

### Added
- Added a shared vm-update app-state plugin manager under `modules/core/tasks/` that now resolves per-task app-state payloads only from stage-local `app-states/<task-name>/app-state.zip`, validates the embedded manifest, stages the zip to the guest, and replays it as a non-blocking post-process after builtin and local-only vm-update tasks.
- Added `docs/windows-store-migration-audit.md` to capture the current Windows installer-source matrix, explicitly separating Store-backed apps, approval-gated `winget + msstore` migration candidates, and apps that should stay on their current installer source.

### Changed
- Replaced the old tracked restore-task plus local overlay layout with one strict app-state contract: builtin and local vm-update tasks now share the same git-ignored stage-local plugin root, `.../update/app-states/<task-name>/app-state.zip`, and no other app-state source path is considered valid.
- Reorganized the local Windows app-state disk layout around per-task zip plugins, migrated the current ignored payloads into `windows/update/app-states/`, removed the old `app-state-overlays` restore path, and retired the dedicated local overlay replay task.
- Moved the local app-state export helper into `modules/core/tasks/` so builtin and local-only vm-update tasks now share one repo-level app-state orchestration path instead of mixing stage-local helper locations with the shared post-process.
- Reworked `10002-create-shortcuts-public-desktop.ps1` so Store-backed public desktop shortcuts now prefer `explorer.exe` plus `shell:AppsFolder\<AUMID>` launch contracts, while `a11MS Edge` stays a direct `msedge.exe` shortcut with the repo-managed shared argument profile rooted at `C:\Users\Public\AppData\Local\Microsoft\msedge\userdata`.
- Hardened shortcut reconciliation so same-name legacy `.lnk` files are no longer treated as healthy by name alone; normalization now rechecks target and argument contracts, which allowed Codex, WhatsApp Business, Edge, and Google Drive shortcuts to self-heal on the live VM.
- Hardened `113-install-wsl2-system.ps1` and `10099-capture-snapshot-health.ps1` so the repo now logs explicit WSL feature-state evidence, surfaces Docker Desktop prerequisite readiness, and verifies the refreshed Edge shortcut contract in the live health snapshot.
- Refreshed the README business/outcome story and documentation set so the current docs now mention Store-aware shortcuts, per-task git-ignored app-state zip plugins, Docker/WSL readiness hardening, and the dedicated Store migration audit document.

### Fixed
- Narrowed the local-only WSL save/restore payload so only the `docker-desktop` distro registry state is exported and replayed; non-Docker WSL distro entries are now excluded from the payload and purged during local overlay replay before the filtered Lxss state is imported.
- Hardened the SSH task transport so persistent-session task execution now falls back to one-shot execution when bootstrap or mid-task CLR/session failures occur, while still applying the same per-task app-state post-process contract afterward.
- Added a bounded lifecycle repair path for VMs that stay in provisioning state `Updating`: connection/runtime flows now trigger one explicit `az vm redeploy` repair attempt before failing.
- Relaxed guest-side app-state replay so locked or in-use payload files are logged as copy skips instead of breaking the whole replay, which keeps live app-state deployment non-blocking for actively running desktop apps.

### Tests
- Revalidated the tracked non-live gate with `tests\\az-vm-smoke-tests.ps1`, `tests\\documentation-contract-check.ps1`, `tests\\powershell-compatibility-check.ps1`, `tests\\code-quality-check.ps1`, `tests\\bash-syntax-check.ps1`, and `tests\\pre-commit-release-doc-check.ps1`.
- Revalidated the full live isolated Windows vm-update task set on the active VM with per-task `exec --update-task=...` runs across builtin and local-only tasks after the shared post-task app-state plugin hook, SSH transport fallback, and provisioning-repair path were wired into the runtime.

## [2026.3.13.308] - 2026-03-13

### Changed
- Reframed the top of `README.md` around the repo's current Windows flagship outcome: a near-zero-touch remote workstation experience with curated apps, startup behavior, desktop shortcuts, UX tuning, advanced settings, and user-preference carryover where the current task catalogs already provide it.
- Strengthened the first four README sections with audience-specific value language for employees, administrative teams, workers, developers, customers, operators, visitors, and sponsors, while keeping Linux positioned honestly as a stable and fully extensible lighter path.
- Added proof-oriented PoC / PoE narratives and expanded the delivered-outcome matrix so the public README shows concrete end-user and business value rather than only command-surface depth.

### Tests
- Revalidated the documentation refresh with `tests\\documentation-contract-check.ps1`, `tests\\code-quality-check.ps1`, `tests\\az-vm-smoke-tests.ps1`, `tests\\powershell-compatibility-check.ps1`, `tests\\bash-syntax-check.ps1`, and `tests\\pre-commit-release-doc-check.ps1`.

## [2026.3.13.307] - 2026-03-13

### Changed
- Refined the prompt-history contract so very short approval/follow-up prompts and non-mutating question or analysis turns are no longer auto-recorded, while every other substantive prompt remains a mandatory English-normalized prompt-history entry.
- Updated `AGENTS.md`, `README.md`, and the documentation contract to require a short opt-in recording hint for excluded prompt types and to keep prompt-history focused on substantive work.

### Tests
- Revalidated the prompt-history contract update with `tests\\documentation-contract-check.ps1`, `tests\\code-quality-check.ps1`, `tests\\az-vm-smoke-tests.ps1`, `tests\\powershell-compatibility-check.ps1`, and `tests\\bash-syntax-check.ps1`.

## [2026.3.13.306] - 2026-03-13

### Changed
- Added a repo-wide sensitive-content guardrail for future work: local hooks, the non-live quality gate, and the engineering contract now require a dedicated audit that blocks obvious contact-style values, concrete identity leaks, and non-placeholder sensitive config drift before commits and pushes are shared.
- Added a dedicated `commit-msg` hook plus `tests/sensitive-content-check.ps1` so both repo-authored tracked files and commit messages receive the same high-signal hygiene checks.
- Documented the new guardrail in `AGENTS.md`, `README.md`, and the documentation contract so the rule stays visible and enforceable as part of normal developer workflow.

### Tests
- Revalidated the updated process guardrails with `tests\sensitive-content-check.ps1`, `tests\code-quality-check.ps1`, `tests\documentation-contract-check.ps1`, `tests\powershell-compatibility-check.ps1`, `tests\az-vm-smoke-tests.ps1`, and `tests\bash-syntax-check.ps1`.

## [2026.3.13.305] - 2026-03-13

### Changed
- Polished the post-cleanup maintained docs so the current repository surface no longer restates retired tokens, removed sample values, or replacement metadata explicitly in release-facing text.
- Reworded the reconstructed prompt ledger entry for the repository-wide cleanup pass so the current tracked documentation stays aligned with the sanitized public surface.

### Tests
- Revalidated the maintained tip with `tests/az-vm-smoke-tests.ps1`, `tests/documentation-contract-check.ps1`, `tests/powershell-compatibility-check.ps1`, `tests/code-quality-check.ps1`, and `tests/bash-syntax-check.ps1`.

## [2026.3.13.304] - 2026-03-13

### Changed
- Removed the retired destructive-rebuild shortcut from the create contract, runtime wiring, help output, tests, and maintained docs. Rebuild guidance is now expressed consistently as an explicit `delete` followed by `create`.
- Redacted the current tracked repository surface so concrete contact-style values, secret samples, organization-style example names, live acceptance target names, and real subscription identifiers no longer remain in shared code, docs, or tests. The remaining examples are now generic placeholders or neutral sample targets.
- Tightened the current docs and smoke contracts so the cleaned public surface stays aligned with the repo's current command contract and no longer reintroduces retired rebuild wording or legacy product residue.

### Security
- Rewrote the reachable git history in a controlled offline clone with the same replacement map applied to blob contents and commit messages, removing retired wording, legacy product residue, and concrete sensitive-looking sample values from reachable history.
- Standardized rewritten author and committer metadata to the configured maintainer identity while preserving original commit timestamps for the rewritten repository history.

### Tests
- Revalidated the rewritten current tip with `tests/az-vm-smoke-tests.ps1`, `tests/documentation-contract-check.ps1`, `tests/powershell-compatibility-check.ps1`, `tests/code-quality-check.ps1`, and `tests/bash-syntax-check.ps1`.

## [2026.3.13.302] - 2026-03-13

### Changed
- Reorganized `README.md` into an audience-first flow that now opens with a stronger at-a-glance introduction, a merged `Quick Start Guide`, `Customer Business Value`, `Executive Summary`, `Value By Audience`, and a richer delivered-outcome matrix before the deeper technical sections.
- Added a new top-level `Operational Command Matrix` to `README.md` so operators, customers, executives, developers, visitors, and sponsors can scan every public command, global option, and practical command variation from tables before diving into the deeper narrative guide.
- Polished the README presentation end to end so the same document now works better as an operator manual, stakeholder-facing overview, and public project landing page without reducing the underlying technical depth.

### Tests
- Updated `tests/documentation-contract-check.ps1` to enforce the new README heading hierarchy and the merged quick-start plus command-matrix structure.
- Revalidated the non-live documentation-facing gate with `tests/documentation-contract-check.ps1`, `tests/az-vm-smoke-tests.ps1`, `tests/powershell-compatibility-check.ps1`, `tests/code-quality-check.ps1`, and `tests/bash-syntax-check.ps1`.

## [2026.3.13.301] - 2026-03-13

### Changed
- Narrowed `10005-copy-settings-user.ps1` so the Windows user-settings mirror now copies only explicit user roots and selected app-state paths instead of sweeping broad `AppData\Roaming` and `AppData\Local` trees. The managed copy set is now limited to known profile folders plus targeted Task Manager, VS Code, Chrome, and repo-managed CLI-wrapper settings.
- Hardened the Windows live create/update path around fresh-VM findings: the OpenSSH init tasks now recover missing `sshd` registration on clean builds, the persistent SSH task runner restores dead sessions between update tasks, the portable winget bootstrap keeps a stable path for later package tasks, and the health snapshot now refreshes PATH plus resolves `az`, `docker`, and `ollama` through explicit fallback paths before probing them.
- Tightened the long-running Windows package contracts so Ollama now probes both `127.0.0.1` and `localhost` with a longer cold-start readiness window, and VLC now follows the same bounded winget-install plus post-install verification model already used for noninteractive AnyDesk and WhatsApp installs.

### Fixed
- Fixed fresh-create validation so duplicate VM names in other managed resource groups no longer block a fresh create in the new target group; only the target managed group is now treated as a hard conflict.
- Fixed the Azure location/SKU discovery path under forced subscription targeting by bypassing injected `--subscription` on Azure CLI account-level location lookups, preventing false region validation failures during `create` and managed-name generation.
- Fixed `104-install-node-system.ps1` so `refreshenv` output can no longer pollute the post-install `node.exe` verification path, which previously caused a false "command not recognized" failure on fresh VMs.
- Fixed `116-install-ollama-system.ps1` so it no longer shadows PowerShell's built-in `$Host`, and so first-run API readiness has enough bounded time to survive the clean-install cold-start path.
- Fixed `124-install-vlc-system.ps1` so a clean `winget install VideoLAN.VLC` no longer times out against an unrealistically short task budget; the task now verifies the resulting executable or package registration before deciding success or failure.
- Fixed `10099-capture-snapshot-health.ps1` formatting and command-resolution issues so the Ollama API JSON echo, Docker CLI probes, and general path readback no longer produce false negatives during late-stage health capture.

### Tests
- Revalidated the non-live gate with `tests/az-vm-smoke-tests.ps1`, `tests/documentation-contract-check.ps1`, `tests/powershell-compatibility-check.ps1`, `tests/code-quality-check.ps1`, and `tests/bash-syntax-check.ps1`.
- Completed the exact live Windows release-bar acceptance on subscription `<subscription-guid>`: cleaned drifted `rg-examplevm-ate1-g2`, reran fresh `create --auto --windows --vm-name=examplevm --vm-region=austriaeast --vm-size=Standard_D4as_v5`, validated `show`, VM status, SSH, and RDP, applied the required post-create restart barrier, and then completed `update --auto --windows --group=rg-examplevm-ate1-g2 --vm-name=examplevm` with zero failed tasks.

## [2026.3.13.300] - 2026-03-13

### Changed
- Added shared Azure subscription targeting across every Azure-touching public command: `create`, `update`, `configure`, `list`, `show`, `do`, `move`, `resize`, `set`, `exec`, `ssh`, `rdp`, and `delete` now support `--subscription-id=<subscription-guid>` plus `-s <subscription-guid>` / `-s=<subscription-guid>`.
- Added a shared Azure subscription resolver with the committed precedence `CLI --subscription-id/-s -> .env azure_subscription_id -> active Azure CLI subscription`, and updated interactive `create` and `update` so they prompt for subscription selection before any Azure-backed discovery when no CLI subscription override is supplied.
- Updated the shared Azure CLI wrapper, diagnostics, create/update review summaries, `configure`, `list`, quick help, README, AGENTS, and `.env.example` so the resolved subscription context is visible, `azure_subscription_id` is documented as the repo-local default selector, and Azure-touching commands now state explicitly that `az login` is required.

### Fixed
- Fixed the shared `subscription-id` option validator so it only enforces a value when the option is actually present, instead of tripping unrelated command contracts that omitted `-s`.
- Fixed subscription precedence resolution so stale in-memory overrides no longer outrank `.env azure_subscription_id` during later command resolution or smoke testing.
- Fixed the smoke contract for subscription-aware commands so `delete` is validated with its required `--target` option while `task` and `help` continue to reject subscription targeting.

### Tests
- Revalidated the non-live gate with `tests/az-vm-smoke-tests.ps1`, `tests/documentation-contract-check.ps1`, `tests/powershell-compatibility-check.ps1`, `tests/code-quality-check.ps1`, and `tests/bash-syntax-check.ps1`.

## [2026.3.13.299] - 2026-03-13

### Changed
- Reworked `configure` into the managed target-selection and `.env` synchronization command: it now selects one az-vm-managed VM target, reads actual Azure state, validates optional platform flags against the real VM OS type, and writes only target-derived values back to `.env`.
- Added the new read-only `list` command and removed the public `group` command. Managed inventory is now exposed through `az-vm list` with `--type=group,vm,disk,vnet,subnet,nic,ip,nsg,nsg-rule` plus optional exact `--group` filtering.
- Updated interactive `create` so the VM OS choice is prompted first whenever `--windows` or `--linux` is omitted, and the platform-specific size, disk, and image defaults now flow from that explicit selection instead of silently reusing `.env VM_OS_TYPE`.

### Fixed
- Fixed the configure command entry so it no longer relies on the retired step-1 precheck/preview path or the removed `Get-AzVmConfigPersistenceMap` helper.
- Fixed the command surface cutover by removing the retired `group` command files and shared `select` option module from the runtime manifest after the new `list` command took over the managed inventory role.

### Tests
- Revalidated the non-live gate with `tests/az-vm-smoke-tests.ps1`, `tests/documentation-contract-check.ps1`, `tests/powershell-compatibility-check.ps1`, `tests/code-quality-check.ps1`, and `tests/bash-syntax-check.ps1`.

## [2026.3.13.298] - 2026-03-13

### Changed
- Split the interactive lifecycle contract more strictly: `create` now stays fresh-only with new managed target generation, while `update` stays existing-target-only with managed-target validation and review-first execution through the shared main workflow.
- Hardened managed naming so resource groups keep a globally increasing `gX` suffix and every generated managed resource now consumes a globally unique `nX` suffix across all resource types without reusing ids.
- Moved `108-install-sysinternals-suite` and `130-autologon-manager-user` into the Windows `vm-init` catalog and kept the Windows main flow restart barrier between `vm-init` and `vm-update`.
- Reworked the Windows startup, public-shortcut, copy-user, Docker Desktop, Ollama, and snapshot-health tasks around live-VM findings so orphan managed shortcuts are skipped, startup artifacts are verified after writing, excluded profile-cache targets are pruned safely on reruns, and the health snapshot reports richer target-health, startup, Docker, Ollama, WSL, and autologon state.

### Fixed
- Fixed fresh create naming so configure-time managed resource-group generation now uses the real next global `gX` suffix instead of falling back to `g1` when the template still contains `{N}`.
- Fixed fresh create resource naming so persisted `.env` managed resource names no longer leak into new-create planning unless they were explicitly overridden for the current invocation.
- Fixed the managed `nX` allocator registration path so a logical resource can re-register its own reserved id idempotently without falsely colliding with itself.
- Fixed `10005-copy-settings-user.ps1` rerun safety by pruning stale excluded target files and directories before and after the robocopy branch, preventing stale locked-cache content from surviving into later verification steps.
- Fixed the autologon health contract so Sysinternals Autologon and visible Winlogon password storage are both reported accurately instead of producing false negative health output.

### Tests
- Revalidated the non-live gate with `tests/az-vm-smoke-tests.ps1`, `tests/documentation-contract-check.ps1`, `tests/powershell-compatibility-check.ps1`, `tests/code-quality-check.ps1`, and `tests/bash-syntax-check.ps1`.
- Revalidated the hardened live Windows path with isolated task/task-group runs on `rg-examplevm-sec1-g1/examplevm`, including `exec --init-task=108`, `exec --init-task=130`, `exec --update-task=114`, `exec --update-task=116`, `exec --update-task=10001`, `exec --update-task=10002`, `exec --update-task=10005`, and `exec --update-task=10099`, plus non-mutating `create --step=configure` and `update --step=configure` contract probes.

## [2026.3.13.297] - 2026-03-13

### Changed
- Realigned the maintained help and README contract with the current create/update/resize behavior: `create` is documented as fresh-only, `update` is documented as existing-managed-target only, `create --auto` and `update --auto` now document their strict required option sets explicitly, and the review-first UX now states that only `group`, `vm-deploy`, `vm-init`, and `vm-update` ask `yes/no/cancel` while `configure` and `vm-summary` always render.
- Updated the maintained naming contract so managed resource groups now describe globally increasing `gX` suffixes and managed resources now describe globally increasing `nX` suffixes that are never reused across resource types.
- Tightened the resize help/docs wording so `--disk-size` is documented as requiring exactly one intent flag, with `--shrink` remaining a non-mutating Azure-guidance path.

### Tests
- Refreshed the smoke and documentation-contract checks to enforce the fresh-only create contract, existing-only update contract, strict auto-mode wording, global `gX`/`nX` naming language, and the current autologon health snapshot contract without expecting yet-unimplemented `DefaultPasswordPresent` output from the health task.

## [2026.3.12.296] - 2026-03-12

### Fixed
- Fixed `tests/az-vm-smoke-tests.ps1` so the CI-facing smoke doubles now shadow runtime functions in the active test scope instead of leaking to the real Azure/.env-backed implementations through `global:` declarations.
- Restored the non-live smoke gate to the expected fast path by removing the accidental real Azure CLI calls from the create, update, resize, reapply, and hibernate-stop smoke scenarios that GitHub Actions was waiting on.

### Tests
- Revalidated the full non-live gate with `tests/az-vm-smoke-tests.ps1`, `tests/documentation-contract-check.ps1`, `tests/powershell-compatibility-check.ps1`, `tests/code-quality-check.ps1`, `tests/bash-syntax-check.ps1`, and `tests/pre-commit-release-doc-check.ps1`.

## [2026.3.12.295] - 2026-03-12

### Fixed
- Fixed `.github/workflows/quality-gate.yml` so every checkout now uses `fetch-depth: 0`, allowing the commit-count-based changelog and release-notes contract to validate correctly on GitHub Actions instead of seeing a shallow-history count of `1`.

### Release
- Published the repository to the public GitHub remote, pushed aligned `main` and `dev`, and removed all remaining local backup/preserve branches so only the two canonical branches remain.

## [2026.3.12.294] - 2026-03-12

### Fixed
- Closed the remaining live Windows publish blockers by raising the tracked timeout budgets for `104-install-node-system` and `111-install-edge-browser`, then hardening both tasks with bounded post-install verification so first-time installs can finish without weakening the healthy-install contract.
- Hardened `10005-copy-settings-user.ps1` so `AppData\Local\Microsoft\Windows\WebCacheLock.dat` is excluded consistently during profile replication and the robocopy fallback now tolerates the same live lock signature across the observed error return codes.

### Tests
- Revalidated the non-live gate with `tests/code-quality-check.ps1`, `tests/documentation-contract-check.ps1`, `tests/powershell-compatibility-check.ps1`, `tests/az-vm-smoke-tests.ps1`, and `tests/bash-syntax-check.ps1`.
- Revalidated live Windows behavior on `rg-examplevm-sec1-g1/examplevm` with isolated `exec --update-task=104`, `exec --update-task=111`, and `exec --update-task=10005` runs, then a full `update --auto --windows --perf` pass that finished `success=45, failed=0, warning=0, error=0, reboot=0`, followed by `show`, `do --vm-action=status`, `ssh --test`, and `rdp --test`.

## [2026.3.12.293] - 2026-03-12

### Added
- Added explicit managed OS disk resize intent flags for `resize`: `--disk-size=<number>gb|mb --expand` now performs the supported in-place OS disk growth path, while `--disk-size=<number>gb|mb --shrink` stops before mutation and prints supported rebuild and migration alternatives because Azure does not support shrinking an existing managed OS disk in place.
- Standardized destructive rebuild guidance around an explicit `delete` followed by `create` flow so rebuild intent stays separate from the default fresh-create path.

### Changed
- Renamed the public step selectors for `create` and `update` from `--single-step`, `--from-step`, and `--to-step` to `--step`, `--step-from`, and `--step-to`, then removed the retired forms from the parser, manifest, parameter modules, help output, README examples, and smoke coverage.
- Continued the command-surface refresh around `create` and `update`, keeping destructive rebuild guidance explicit while the managed-target contract moved toward the current fresh-only `create` model.
- Changed `update` so it now requires an existing managed resource group and existing VM before orchestration begins, and the VM deploy stage now redeploys an existing VM after the create-or-update pass.
- Refreshed README, AGENTS, changelog wording, release notes, and prompt-history normalization so the maintained documentation now reflects the current release surface with stronger business-value, developer-benefit, and publish-readiness guidance.

### Tests
- Revalidated the non-live gate with `tests/code-quality-check.ps1`, `tests/documentation-contract-check.ps1`, `tests/powershell-compatibility-check.ps1`, `tests/az-vm-smoke-tests.ps1`, and `tests/bash-syntax-check.ps1`.

## [2026.3.12.291] - 2026-03-12

### Changed
- Synchronized the publish-facing repository surface with the current release-readiness contract by updating the GitHub issue templates, pull-request template, README guidance, contributing guidance, and support guidance around live Azure acceptance and public release reporting.
- Extended `.github/workflows/quality-gate.yml` with an explicit `documentation-contract` job so the existing documentation contract check now runs in GitHub Actions alongside the rest of the non-live gate.
- Hardened `Invoke-AzVmVmCreateStep` so transient non-zero `az vm create` results now trigger a bounded VM-presence probe before failing, reducing false negatives when Azure finishes the deployment shortly after the CLI returns a temporary error code.

### Tests
- Revalidated the non-live gate with `tests/code-quality-check.ps1`, `tests/documentation-contract-check.ps1`, `tests/powershell-compatibility-check.ps1`, `tests/az-vm-smoke-tests.ps1`, and `tests/bash-syntax-check.ps1`.

## [2026.3.12.290] - 2026-03-12

### Changed
- Completed a second Windows `vm-update` performance-tuning pass focused on the remaining slow paths from live perf logs, using bounded noninteractive behavior instead of repeated waits and retries.
- Reworked `114-install-docker-desktop.ps1` again so already-installed Docker Desktop no longer burns time on daemon retry probes inside SSH sessions. The task now verifies the client, starts Docker Desktop once, and immediately registers an interactive `RunOnce` start instead of retrying engine readiness in a noninteractive guest session.
- Reworked `121-install-whatsapp-system.ps1` so it checks fast local Store-registration evidence before expensive `winget list` calls and short-circuits immediately when a deferred `RunOnce` install is already registered, preventing the same failed Store install attempt from being repeated on every update run.
- Shortened the registry-hive unload waits in `10001-configure-apps-startup.ps1` and `10099-capture-snapshot-health.ps1`, and shortened the Task Manager / Explorer settle waits in `10003-configure-ux-windows.ps1`, keeping those tasks bounded without retry-heavy idle time.
- Updated the Windows smoke contract so Docker Desktop is now validated against the new bounded noninteractive deferred-start model rather than the retired daemon-probe loop.

### Performance
- Revalidated live Windows behavior on `rg-examplevm-sec1-g1/examplevm` and confirmed concrete improvements: `114-install-docker-desktop` dropped from about `16.2s` to about `3.2s`, `121-install-whatsapp-system` dropped from about `9.8s` to about `3.5s` on deferred reruns, `10099-capture-snapshot-health` dropped from about `9.8s` to about `6.1s`, and the full `vm-update` step dropped from about `234.7s` to about `198.0s`.

### Tests
- Revalidated live Windows task behavior with targeted `exec --update-task=114`, `121`, `10003`, `10001`, and `10099` runs plus a full `update --step=vm-update --auto --windows --perf` pass on `rg-examplevm-sec1-g1/examplevm`.
- Revalidated the non-live gate with `tests/powershell-compatibility-check.ps1` and `tests/az-vm-smoke-tests.ps1`.

## [2026.3.12.288] - 2026-03-12

### Added
- Added `do --vm-action=hibernate-stop`, which resolves the managed VM target, verifies SSH reachability, runs `shutdown /h /f` through the repo-managed pyssh path, and waits until the guest is no longer running without Azure deallocation.

### Changed
- Renamed the Azure-backed hibernation action from `do --vm-action=hibernate` to `do --vm-action=hibernate-deallocate` so the public command surface now states explicitly that Azure hibernation still uses the deallocation-based path.
- Updated the `do` parser, interactive action picker, validation rules, CLI help, README examples, and smoke coverage so the old `hibernate` action is rejected with a direct migration hint to `hibernate-deallocate` or `hibernate-stop`.

### Tests
- Revalidated the non-live gate with `tests/code-quality-check.ps1`, `tests/documentation-contract-check.ps1`, `tests/powershell-compatibility-check.ps1`, and `tests/az-vm-smoke-tests.ps1`.

## [2026.3.12.287] - 2026-03-12

### Changed
- Tuned `114-install-docker-desktop.ps1` for noninteractive Windows guest sessions by replacing the old longer daemon wait path with two short bounded `docker version` probes, removing the blocking `docker info` readiness gate, shortening stale-installer cleanup waits, and falling back immediately to a deferred interactive `RunOnce` start when the engine is not yet ready.
- Tuned `10005-copy-settings-user.ps1` by replacing the old fixed five-second wait with a short settle loop that watches user sessions and processes, cutting registry-hive unload retries and wait intervals, and keeping the copy path bounded instead of retry-heavy.
- Fixed `10002-create-shortcuts-public-desktop.ps1` so Public Desktop inspection no longer exits the whole task early on unrelated shortcut entries, added a no-op fast path for already-normalized desktops, and expanded duplicate cleanup coverage to installer-created `AnyDesk`, `Windscribe`, `VLC media player`, `iTunes`, `IObit Unlocker`, and `NVDA` shortcuts.
- Removed every `--force` command-line flag from tracked Windows `vm-update` task scripts and shifted the install tasks to explicit install-if-missing / skip-if-healthy behavior, including the winget bootstrap path which now avoids forceful source reset and uses only one bounded source-update recovery attempt.

### Tests
- Revalidated the non-live gate with `tests/code-quality-check.ps1`, `tests/documentation-contract-check.ps1`, `tests/powershell-compatibility-check.ps1`, and `tests/az-vm-smoke-tests.ps1`.
- Revalidated live Windows behavior on `rg-examplevm-sec1-g1/examplevm` with targeted `exec --update-task=114`, `exec --update-task=10005`, `exec --update-task=10002`, `exec --update-task=10099`, and a full `update --step=vm-update --auto --windows` pass. The tuned tasks now complete quickly, and the latest Public Desktop readback leaves only the intentionally unmanaged local-only accessibility shortcuts outside the tracked managed set.

## [2026.3.12.286] - 2026-03-12

### Added
- Restored tracked Public Desktop shortcuts `q1SourTimes`, `s15{TitleCase(company_name)} Web`, and `s16{TitleCase(company_name)} Blog` so the managed shortcut set again owns those browser entry points explicitly.

### Changed
- Renamed the tracked Windows Public Desktop web/app labels from the old Turkish `Kurumsal`/`Bireysel` wording to the approved English `Business`/`Personal` contract, including the approved brand-specific overrides such as `s18NextSosyal Business`, `r13CicekSepeti Business`, `r14CicekSepeti Personal`, `r17PTTAVM Business`, and `r18PTTAVM Personal`.
- Renamed the remaining approved quick-access labels to `m1Digital Tax Office`, `q4eGovernment`, `q6AJet Flights`, `q7TCDD Train`, and `q8OBilet Bus`, while keeping `q2Spotify` and `q3Netflix` unchanged.
- Reworked `10002-create-shortcuts-public-desktop` so Chrome profile routing is metadata-based instead of name-text-based, and both `company_name` and `employee_email_address` local-part values are normalized to lowercase before being written into `--profile-directory`.
- Hardened Public Desktop normalization so the tracked shortcut task now removes semantic duplicates by name alias, target executable, and browser destination matching for installer-created overlaps such as Google Chrome, Microsoft Edge, AnyDesk, and Visual Studio 2022, while preserving unrelated unmanaged Public Desktop shortcuts.
- Moved `az-vm-interactive-session-helper.ps1` from `tools/windows/` to `tools/scripts/` and updated runtime asset resolution to use the new helper location without changing the guest-side remote helper path.
- Updated the tracked health snapshot, `.env.example`, README, AGENTS contract, and smoke coverage to enforce the new English shortcut labels, lowercase Chrome profile normalization, restored shortcuts, and semantic duplicate-cleanup model.

### Tests
- Revalidated the non-live gate with `tests/code-quality-check.ps1`, `tests/documentation-contract-check.ps1`, `tests/powershell-compatibility-check.ps1`, and `tests/az-vm-smoke-tests.ps1`.

## [2026.3.12.284] - 2026-03-12

### Added
- Added `az-vm do --vm-action=reapply`, which calls `az vm reapply` for the resolved managed VM target and then prints a refreshed lifecycle status snapshot.

### Changed
- Expanded the `do` command contract so parser hints, interactive action selection, CLI help, and README examples all include `reapply` as a first-class lifecycle action.
- Kept `reapply` available as the Azure repair path even when provisioning is not currently in the succeeded state, while the existing power-action validation rules remain unchanged for `start`, `restart`, `stop`, `deallocate`, and `hibernate`.

### Tests
- Revalidated the full non-live gate with `tests/code-quality-check.ps1`, `tests/documentation-contract-check.ps1`, `tests/powershell-compatibility-check.ps1`, and `tests/az-vm-smoke-tests.ps1`.

## [2026.3.12.283] - 2026-03-12

### Added
- Added committed `employee_email_address` and `employee_full_name` config placeholders, plus runtime token materialization for employee identity and generic host autostart discovery data used by operator-local flows.
- Added tracked Windows task `132-install-vs2022community.ps1` and extended tracked npm bootstrap task `115-install-npm-packages-global.ps1` to install the GitHub Copilot CLI prerequisite.

### Changed
- Expanded the tracked Public Desktop shortcut contract so Windows update now creates `i1Internet Kurumsal`, `i2Internet Bireysel`, `r11-r22`, `k3Github Copilot CLI`, `v1VS2022Com`, and the renamed `t10Azd CLI`, while `e1Mail` and every Chrome shortcut labeled `Bireysel` now derive their personal profile routing from the employee email local-part.
- Updated tracked shortcut health capture, smoke assertions, README contract, and engineering contract rules so the new employee-based Chrome profile behavior, renamed shortcuts, new task timeouts, and new prerequisite tasks are all enforced explicitly.
- Shifted the tracked startup/profile-copy surface to a generic local-accessibility ownership model by removing vendor-specific behavior from startup mirroring, tracked profile-copy exclusions, tracked startup configuration, and maintained docs; tracked code now only provides generic host autostart discovery and unmanaged-shortcut preservation for one private local-only accessibility flow.

### Tests
- Revalidated the full non-live gate with `tests/code-quality-check.ps1`, `tests/documentation-contract-check.ps1`, `tests/powershell-compatibility-check.ps1`, and `tests/az-vm-smoke-tests.ps1`.
- Completed live Windows acceptance on `rg-examplevm-sec1-g1/examplevm`: isolated `exec --update-task=1001..1005` reruns for one private local-only accessibility flow, a full `update --step=vm-update --auto --windows` pass with `success=45, failed=0, warning=0, error=0, reboot=0`, `do --vm-action=restart`, SSH/RDP connectivity checks, and post-reboot guest readback confirming the manager startup shortcut, automatic utility service, active console session, and running local accessibility processes.

## [2026.3.11.282] - 2026-03-11

### Changed
- Changed the `Invoke-AzVmMain` startup banner so `script description:` is rendered on a single line instead of opening a multi-line bullet block.
- Added an explicit live release-acceptance requirement to `README.md`, `AGENTS.md`, and the documentation contract: release-readiness now requires a real create/update/status/show/connection verification cycle when live confidence is part of the claim.

### Fixed
- Fixed the post-deploy provisioning readiness check so existing-VM feature verification now reads `az vm get-instance-view` from `instanceView.statuses` and honors the top-level `provisioningState`, removing the false blank retry loop seen during live create/update runs.
- Fixed `10005-copy-settings-user` so live Windows update runs now classify required profile roots separately, skip deterministic blocker aliases and reparse-point shell paths, tolerate missing HKCU source branches during assistant hive seeding, and ignore access/in-use failures only for best-effort profile artifacts instead of failing the whole stage.

### Tests
- Revalidated the runtime and docs with `tests/az-vm-smoke-tests.ps1`, `tests/powershell-compatibility-check.ps1`, and `tests/documentation-contract-check.ps1`.
- Completed a live Windows acceptance rerun with `az-vm update --auto --windows`; the full natural-order `vm-update` stage finished `success=41, failed=0, warning=0, error=0, reboot=0`.

## [2026.3.11.281] - 2026-03-11

### Changed
- Removed the transitional root loader layer from `modules/` so `az-vm.ps1` now loads a single ordered `modules/azvm-runtime-manifest.ps1` and dot-sources the refactored leaf files directly.
- Deleted the old root runtime wrapper files under `modules/core/`, `modules/config/`, `modules/tasks/`, `modules/ui/`, and `modules/commands/`, so the active runtime now executes only the modern modular tree.
- Refreshed the smoke contract and current architecture documentation so they enforce the manifest-based direct-load model and fail fast if any legacy root loader path reappears.

### Tests
- Revalidated the direct-load cutover with `tests/code-quality-check.ps1`, `tests/az-vm-smoke-tests.ps1`, and `tests/powershell-compatibility-check.ps1`.

## [2026.3.11.280] - 2026-03-11

### Changed
- Refactored the `modules/` runtime into compatibility loaders plus a deeper domain tree under `modules/core/`, `modules/config/`, `modules/commands/`, `modules/ui/`, and `modules/tasks/`, keeping the existing root import paths and public function surface intact while moving implementation into smaller leaf files.
- Split the public command runtime by command ownership so each supported command now lives under its own subtree with `entry.ps1`, `contract.ps1`, `runtime.ps1`, and command-scoped `parameters/` files, while shared create/update orchestration now lives in dedicated `context`, `steps`, `features`, `pipeline`, and shared-runtime helpers.
- Restricted `modules/ui/` to prompts, selection flows, show/report rendering, and connection presentation concerns, and moved non-UI command/runtime logic out of the former monolithic UI/runtime paths.
- Updated the operator and release documentation to describe the new modular runtime layout and the compatibility-loader contract accurately.

### Tests
- Revalidated the refactor with `tests/code-quality-check.ps1`, `tests/az-vm-smoke-tests.ps1`, and `tests/powershell-compatibility-check.ps1`, and refreshed the smoke assertions so they target the new leaf-file locations instead of the old monolithic root files.

## [2026.3.11.279] - 2026-03-11

### Added
- Added non-interactive connection test modes for `az-vm ssh --test` and `az-vm rdp --test`, so the repo can validate SSH authentication and RDP reachability without launching external clients.

### Changed
- Changed post-deploy feature handling so `create`, `update`, and `set` now treat `VM_ENABLE_HIBERNATION=true` and `VM_ENABLE_NESTED_VIRTUALIZATION=true` as verified desired outcomes: hibernation is checked through Azure instance state, while nested virtualization is validated from inside the running guest instead of relying on the removed single-VM Azure property path.
- Changed `az-vm show` so password-bearing config values are redacted in the rendered report and running-VM inventory now includes guest-validated nested-virtualization status plus supporting evidence.
- Refreshed the README and documentation contract to document the natural `vm-init` / `vm-update` order as builtin `initial`, builtin `normal`, local untracked tasks, then builtin `final`, and to describe the new connection-test and feature-validation behavior accurately.
- Hardened the Windows interactive-session helper and Store-backed tasks so Be My Eyes and iCloud now detect whether an interactive desktop is available, fall back to deferred `RunOnce` registration when needed, and use interactive-token execution when a user desktop is already active.
- Hardened several Windows update tasks and UX helpers by quieting registry hive load/unload noise, improving shell-sort validation, excluding unstable Ollama WebView cache paths from profile copies, retrying or settling installer descendants where needed, and normalizing non-fatal native exit codes in Docker Desktop and AnyDesk flows.
- Raised the tracked timeouts for `126-install-be-my-eyes` and `10005-copy-settings-user` to match the longer real-world execution windows observed in the refreshed task implementations.

### Fixed
- Fixed `az vm create` argument selection during create-or-update paths so security-type create arguments are omitted automatically when the target VM already exists, avoiding Azure failures on existing managed VMs.

### Tests
- Kept the smoke and documentation contracts aligned with the new runtime surface, including connection-test parsing, show redaction, nested-virtualization guest validation, task-order guarantees, and the hardened Windows task contracts.

## [2026.3.11.278] - 2026-03-11

### Fixed
- Fixed an avoidable compatibility-matrix slowdown in `tests/az-vm-smoke-tests.ps1`: the two post-deploy feature-enable smoke tests now stub `az vm get-instance-view` as `Provisioning succeeded` immediately, so the compatibility run no longer burns minutes inside artificial provisioning waits after the new feature-verification gate was added.

### Tests
- Revalidated the compatibility path with `tests/az-vm-smoke-tests.ps1` and `tests/powershell-compatibility-check.ps1`; the smoke suite now completes in seconds and the compatibility matrix no longer times out due to the synthetic wait loop.

## [2026.3.11.277] - 2026-03-11

### Added
- Added short-help alias support across the public CLI so `az-vm -h` and `az-vm <command> -h` now work alongside the existing `--help` contract.
- Added a publish-facing GitHub community surface with `CONTRIBUTING.md`, `SUPPORT.md`, `SECURITY.md`, `CODE_OF_CONDUCT.md`, issue templates, and a pull-request template aligned to the repo's contact-first contribution model and custom non-commercial license.

### Changed
- Refreshed the public help and README contract so command examples, global options, support paths, and publish-facing workflow guidance now reflect the current runtime and the new `-h` shorthand.
- Extended `.github/workflows/quality-gate.yml` so GitHub Actions now also runs the non-live `tests/az-vm-smoke-tests.ps1` suite in addition to the existing static and compatibility checks.
- Redacted publish-inappropriate literals in maintained history docs, replacing environment-specific VM names, profile names, local paths, and similar concrete examples with neutral placeholders while preserving chronology and technical meaning.
- Normalized tracked Linux `.sh` files to LF and pinned that expectation in `.gitattributes` so the repository's bash-syntax gate passes consistently across environments.

### Tests
- Expanded CLI parse and help smoke coverage for `-h`, updated documentation-contract checks for the new community files and GitHub workflow coverage, and kept the existing non-live validation gates aligned with the refreshed publish surface.

## [2026.3.11.276] - 2026-03-11

### Changed
- Changed `10002-create-shortcuts-public-desktop` from a full Public Desktop mirror into a managed-shortcut reconcile pass, so it now removes and recreates only the tracked shortcut names while preserving unmanaged Public Desktop entries such as local-only accessibility shortcuts; the same task still clears the manager, assistant, and default desktop roots.
- Restored host startup-profile discovery in `azvm-core-foundation`, replaced the static Windows auto-start snapshot with host-driven method mirroring in `10001-configure-apps-startup`, and added a guest compatibility layer for LocalMachine startup apps so the guest now applies the host-observed startup surfaces and approval state instead of relying on a hard-coded list.
- Expanded `10099-capture-snapshot-health` so Windows late-stage health snapshots now inventory unmanaged Public Desktop shortcuts and host-driven startup entries instead of treating extra Public Desktop shortcuts as unexpected removable artifacts.

### Tests
- Extended the Windows smoke and compatibility contracts so the host startup-profile token flow, the managed-only Public Desktop cleanup behavior, the unmanaged shortcut inventory, and the startup compatibility scaffolding are all enforced together with the existing task contracts.

## [2026.3.11.275] - 2026-03-11

### Changed
- Expanded `10002-create-shortcuts-public-desktop` so the managed Public Desktop set now also adds the requested `g1-g4` developer links and `q2-q8` quick-access web shortcuts, all using the same Chrome launcher contract as `i1Internet`.
- Expanded `10099-capture-snapshot-health` so the late-stage Windows health snapshot now inventories the new `g` and `q` shortcut names together with the rest of the managed Public Desktop set.

### Tests
- Extended the Windows public-desktop smoke contract so the new shortcut names and URLs are enforced together with the existing launcher fragments and health inventory expectations.

## [2026.3.11.274] - 2026-03-11

### Changed
- Added the tracked Windows `130-autologon-manager-user` update task immediately after `129-configure-unlocker-io`, moved the tracked iCloud install task to `131-install-icloud-system`, and configured the new task to validate the `manager` credentials locally before calling Sysinternals `autologon /accepteula <user> . <password>`.
- Expanded `10099-capture-snapshot-health` so Windows late-stage health snapshots now inventory the Winlogon autologon state for the `manager` user in addition to the existing UX and Public Desktop state.

### Tests
- Extended the Windows tracked-task timeout contract, the install-task contract, and the late-stage health contract so the new autologon task, the renumbered iCloud task, and the new autologon health readback are all enforced.

## [2026.3.11.273] - 2026-03-11

### Changed
- Expanded `10002-create-shortcuts-public-desktop` again so the managed Public Desktop set now also restores the requested `e1`, `m1`, `n1`, `r1-r10`, and `u7Network and Sharing` shortcuts while preserving the existing Chrome-profile, run-maximized, run-as-admin, full-mirror, and per-user desktop cleanup contracts.

### Tests
- Extended the Windows public-desktop smoke contract and health inventory expectations so the new `e/m/n/r/u7` shortcuts and their launcher fragments are validated together with the existing Public Desktop set.

## [2026.3.11.272] - 2026-03-11

### Changed
- Moved the per-user desktop cleanup into `10002-create-shortcuts-public-desktop` itself, so the Public Desktop mirroring task now also removes lingering entries from the manager, assistant, and default desktop roots instead of relying on later tasks to restore that contract.

### Tests
- Tightened the Windows public-desktop smoke contract so `10002-create-shortcuts-public-desktop` must own the manager/assistant/default desktop cleanup path in addition to the Public Desktop mirror.

## [2026.3.11.271] - 2026-03-11

### Changed
- Updated `10002-create-shortcuts-public-desktop` so `z1Google Account Setup` now launches Chrome through `C:\Windows\System32\cmd.exe /c start "" ...` with the requested shared Public Desktop Chrome user-data directory and direct `chrome://settings/syncSetup` target, instead of binding the shortcut directly to `chrome.exe`.

### Tests
- Tightened the Windows public-desktop smoke contract so `z1Google Account Setup` must target `cmd.exe` and carry the requested `start "" "chrome.exe" ... syncSetup` argument shape.

## [2026.3.11.270] - 2026-03-11

### Added
- Added the tracked Windows update task `130-install-icloud-system` so the Store-backed iCloud install now follows the repo's unattended `winget` pattern and resolves `iCloudHome.exe` for shortcut and health-readback use.

### Changed
- Reworked the Windows final update flow so `10002-create-shortcuts-public-desktop`, `10003-configure-ux-windows`, `10005-copy-settings-user`, and `10099-capture-snapshot-health` now enforce the new public-desktop contract: `company_name` is required with no `VM_NAME` fallback, the shortcut set uses the requested 1-based naming scheme, managed `.lnk` files are rebuilt with full Public Desktop mirroring, and per-user desktops are kept empty.
- Expanded the public shortcut manifest to the requested final `a/b/c/d/i/k/o/s/t/u/v/z` layout, including iCloud, dynamic `s15/s16` company shortcuts, the new `s17/s18` web entries, updated CLI targets, NVDA hotkey handling, run-maximized defaults, run-as-admin link flags, and `%UserProfile%` start-in handling for console shortcuts.
- Extended Windows UX tuning to disable System Restore and existing shadow copies, keep RDP NLA off for maximum compatibility, suppress `desktop.ini` / `Thumbs.db` artifacts on known desktop roots, hide shell-managed desktop icons in favor of custom `u1/u2/u3` shortcuts, and reinforce Explorer details/no-group defaults across seeded user hives.
- Reworked `10005-copy-settings-user` so the assistant/default profile propagation now uses deterministic hive-based registry seeding and stricter file-copy exclusions instead of the slower interactive HKCU path, and raised the late-stage Windows task timeouts to match observed exec runtimes.

### Documentation
- Updated `.env.example`, `README.md`, release history, and prompt history to reflect the required `company_name` contract and the new Windows UX/public desktop update behavior.

### Tests
- Expanded smoke and compatibility coverage for the iCloud task contract, the no-fallback `company_name` requirement, the final shortcut manifest and timeout values, and explicit hidden shell desktop icon propagation checks.
- Validated the Windows update changes live with isolated `exec` reruns of `130`, `10003`, `10002`, `10005`, and `10099`, plus idempotency reruns of `10002` and `10003`.

## [2026.3.11.269] - 2026-03-11

### Added
- Added the read-only `task` command so operators can list the real discovered `vm-init` and `vm-update` inventory in execution order, filter by stage, and inspect disabled tracked/local tasks before running orchestration.

### Changed
- Reworked the task-number contract across Windows and Linux so tracked tasks now use the shared bands `01-99` (`initial`), `101-999` (`normal`), and `10001-10099` (`final`), while intentionally local-only tasks use `1001-9999`.
- Renamed the tracked Linux init/update files and the tracked Windows update files to the new banded numbering scheme, including moving the Windows health snapshot task to `10099-capture-snapshot-health`.
- Updated tracked task catalogs on all four stage roots so they now carry explicit `taskType` values alongside the new band-aligned priorities and existing timeout values.
- Updated task discovery so local-only priority resolution now follows `script metadata -> filename task number -> deterministic auto-detect`, instead of treating local metadata as the only ordering source.
- Standardized tracked task fallback defaults end to end so missing catalog entries and catalog entries without explicit priority now resolve to `priority=1000`, while all missing timeout values continue to resolve to `180` for both tracked and local task paths.
- Updated runtime help, `exec` task selection, and the regional move health gate so variable-length task numbers now work consistently across direct execution, diagnostics, and move cutover validation.

### Documentation
- Updated `AGENTS.md` and `README.md` to document the new 2-5 digit task-number bands, the `task` command, and the revised tracked/local task-priority rules.

### Tests
- Refreshed smoke coverage for variable-length task selection, the new `task` command listing path, the new tracked Windows/Linux task names, and the updated local-task priority precedence.

## [2026.3.10.267] - 2026-03-10

### Changed
- Moved intentionally local-only stage tasks under `local/` and local-only disabled tasks under `local/disabled/`, while keeping tracked root tasks catalog-driven.
- Restored the Windows local accessibility asset layout under the update local subtree and kept local asset resolution relative to the local task file directory.
- Extended task discovery so stage roots now accept `local/*` and `local/disabled/*` script locations, ignore catalog state for local-only tasks, and fail fast on duplicate tracked/local task names.

### Documentation
- Updated the repository contract and operator guide to document the new `local/` / `local/disabled/` layout, the metadata-only behavior of local tasks, and the relative asset-resolution rule for local task payloads.

### Tests
- Refreshed smoke coverage for local-only task discovery, duplicate-name detection, nested-path rejection, and local asset resolution.
- Simplified `.gitignore` so stage-specific ignore rules now target only the init/update `local/` trees.

## [2026.3.10.266] - 2026-03-10

### Fixed
- Completed the Windows `vm-update` `31/32` swap by renaming the tracked task files as well as the catalog entries, so `31-configure-unlocker-io` now owns the IObit Unlocker task and `32-configure-apps-startup` now owns the startup-configuration task.

### Documentation
- Updated release history and prompt-history records to reflect the final `31=unlocker`, `32=app-startup` naming contract.

### Tests
- Updated smoke coverage so the tracked Windows update order and startup-task path assertions now target `31-configure-unlocker-io` and `32-configure-apps-startup`.

## [2026.3.10.265] - 2026-03-10

### Fixed
- Swapped the Windows `vm-update` execution priorities of `31-configure-apps-startup` and `32-configure-unlocker-io` so the unlocker task now runs first while both tasks keep their existing timeout values.

### Tests
- Updated smoke coverage so the tracked Windows update order assertion now expects `32-configure-unlocker-io` before `31-configure-apps-startup`.

## [2026.3.10.264] - 2026-03-10

### Changed
- Renamed the tracked Windows `vm-init` and `vm-update` scripts to the normalized `NN-verb-noun-target` pattern and rebuilt the tracked Windows update order around tooling-first early tasks plus the requested late-stage UX, user-settings, and health tasks.
- Moved selected private local-only Windows tasks and payloads out of source control while keeping them available on disk through ignored local-only files and script-local metadata.

### Refactoring
- Added generic script-local task metadata parsing for intentionally local-only Windows tasks, including `priority`, `enabled`, `timeout`, and asset declarations, while keeping tracked catalog values authoritative whenever both exist.
- Replaced the old task-specific Windows asset-copy special case with metadata-driven asset resolution so tracked runtime code no longer needs custom knowledge of local-only private payloads.
- Rewrote the active `main` and `dev` histories to remove the selected private local-only Windows paths and scrub their tracked textual references, while leaving the backup branches untouched.

### Documentation
- Updated `AGENTS.md`, `README.md`, `roadmap.md`, `CHANGELOG.md`, `release-notes.md`, and `docs/prompt-history.md` to describe the normalized Windows task naming scheme and the local-only metadata model without carrying the removed tracked identifiers.

### Tests
- Expanded smoke and documentation-contract coverage for normalized Windows task ordering, script-local metadata discovery, generic asset resolution, and the absence of the removed tracked task identifiers from the maintained repo surface.

## [2026.3.10.263] - 2026-03-10

### Fixed
- Simplified the `set` command so it now resolves the target VM directly instead of depending on the heavier Step-1 command runtime path, which removes unrelated configuration requirements from feature-toggle updates.
- Ensured `set` now persists the resolved `RESOURCE_GROUP`, `VM_NAME`, and any successfully applied `VM_ENABLE_HIBERNATION` / `VM_ENABLE_NESTED_VIRTUALIZATION` changes back into the local `.env` file.

### Documentation
- Updated `README.md` and command help text so the `set` command now explicitly documents its direct-target behavior and `.env` synchronization semantics.

### Tests
- Added smoke coverage that verifies `set` applies both Azure toggle updates, persists the changed values to `.env`, and keeps `.env` aligned even when one later toggle update fails after an earlier success.

## [2026.3.10.262] - 2026-03-10

### Changed
- Changed the committed pyssh client default so `PYSSH_CLIENT_PATH` now resolves to the repo-relative `tools/pyssh/ssh_client.py` path instead of starting empty in the `.env` contract.
- Standardized the default NSG rule naming prefix across the repo on `nsg-rule-`, including the committed template defaults and sample/test contracts.
- Added shared `.env` feature-intent keys `VM_ENABLE_HIBERNATION` and `VM_ENABLE_NESTED_VIRTUALIZATION` so create/update flows can explicitly enable or skip those post-deploy feature paths with `true` or `false`.

### Refactoring
- Updated orchestration and UI runtime defaults to consume the shared non-empty pyssh client default instead of duplicating empty `PYSSH_CLIENT_PATH` fallbacks.
- Extended post-deploy feature enablement so hibernation and nested virtualization can now be skipped cleanly when the shared `.env` feature toggles are set to `false`, while preserving the current Azure enablement path when they are `true`.

### Documentation
- Updated `README.md`, `AGENTS.md`, and `.env.example` to document the new shared VM feature toggles, the non-empty pyssh client default, and the `nsg-rule-` naming contract.

### Tests
- Expanded smoke and documentation checks to enforce the new pyssh default path, the shared feature-toggle env keys, and the `nsg-rule-` template contract.

## [2026.3.10.261] - 2026-03-10

### Changed
- Removed shared runtime fallback defaults for committed VM identity and credential values such as the old sample VM names and demo passwords; non-interactive flows now fail fast when `VM_NAME`, `VM_ADMIN_USER`, `VM_ADMIN_PASS`, `VM_ASSISTANT_USER`, or `VM_ASSISTANT_PASS` are missing or left on placeholder values.
- Centralized shared default resolution for SSH port, RDP port, and default TCP port lists so the orchestration and UI runtimes stop duplicating mutable network defaults.
- Changed `tools/install-pyssh-tool.ps1` so its optional test-host derivation now depends only on real `.env` values instead of inventing a committed VM/region fallback.

### Documentation
- Clarified the configuration split across `AGENTS.md`, `README.md`, and `.env.example`: app-wide identity, secrets, and reusable operator overrides belong in `.env`, while task-only literals belong in a clearly labeled config block at the top of the owning task script.
- Updated `.env.example` to require explicit VM identity and credential placeholders, removed the old committed password examples, and documented `company_name` with a neutral example.

### Refactoring
- Introduced shared config-validation helpers in `modules/core/azvm-core-foundation.ps1` so orchestration and UI contexts can reject empty or placeholder-sensitive values consistently.
- Refactored key Windows update tasks to move task-specific constants into top-of-file config blocks instead of scattering mutable literals through task bodies, including private local-only accessibility work, Ollama, Docker Desktop, VS Code, Be My Eyes, OneDrive, auto-start apps, and public desktop shortcuts.
- Moved the repo-managed Windows public web-shortcut bundles into the shortcut task's local config section so company-specific and user-specific web targets are isolated from shared runtime code.

### Tests
- Expanded smoke coverage to verify the new required-config helper behavior, confirm that shared runtime modules no longer carry the old personal/demo defaults, and align Docker Desktop task assertions with the new task-local config structure.

## [2026.3.10.260] - 2026-03-10

### Documentation
- Rewrote `README.md` into a much broader operator and contributor manual with a hierarchical table of contents, quick-start flow, architecture narrative, command guide, task model, troubleshooting guidance, developer workflow notes, and license/sponsorship coverage.
- Reworked `roadmap.md` around business value, relaxed delivery horizons, explicit promotion rules, and concrete done criteria.
- Added a root `LICENSE` file with the repository's custom non-commercial terms, including learning/teaching/evaluation allowance, private non-commercial modification allowance, commercial-use restrictions, and sponsorship/contact language.
- Updated `AGENTS.md` so maintained docs, help text, comments, and user-facing runtime wording must stay in English, while explicit literal display-label exceptions remain allowed.
- Switched `docs/prompt-history.md` from a raw-language ledger to an English-normalized ledger and translated the existing historical entries into English while preserving structure and chronology.

### Tests
- Added `tests/pre-commit-release-doc-check.ps1` and wired it into `.githooks/pre-commit` so repo-changing staged work now requires `CHANGELOG.md` and `release-notes.md` in the same final change set, without recursing on release-history-only updates.
- Expanded `tests/documentation-contract-check.ps1` to require `LICENSE`, enforce the English documentation contract, validate the English-normalized prompt-history rule, and confirm the pre-commit release-doc gate plus the current GitHub Actions PowerShell compatibility entrypoint.

### Chores
- Updated `tools/enable-git-hooks.ps1` to describe the stronger pre-commit gate accurately.
- Fixed `.github/workflows/quality-gate.yml` to use `tests/powershell-compatibility-check.ps1` instead of the removed `tests/powershell-matrix.ps1`.

## [2026.3.10.259] - 2026-03-10

### Features
- Added a new `do` operator command for `status`, `start`, `restart`, `stop`, `deallocate`, and `hibernate` actions against one managed VM.
- Made the new `do` command state-aware so it inspects Azure power/provisioning/hibernation state before mutating and exits politely with a non-zero code when the requested action is not valid for the current VM state.
- Added Windows `vm-update` install tasks `27-install-itunes-system`, `28-install-be-my-eyes`, `29-install-nvda-system`, `13-install-edge-browser`, `26-install-vlc-system`, `30-install-rclone-system`, `21-install-onedrive-system`, and `22-install-google-drive`, each following the existing repo pattern of bounded `winget` install plus explicit post-install verification.
- Added Windows `vm-update` task `19-install-codex-app` to install the Store-backed Codex desktop app through `winget install codex -s msstore`, verify it via AppX/StartApps/winget readback, and register a deferred RunOnce retry when the noninteractive Store session cannot complete immediately.
- Added Windows `vm-update` task `32-configure-apps-startup` to apply a static snapshot of the current approved auto-start application set on the guest VM by creating machine startup shortcuts for Docker Desktop, Ollama, OneDrive, Teams, one private local-only accessibility launcher, and iTunesHelper.

### Fixes
- Hardened `32-configure-apps-startup` after isolated live `exec` validation showed that existing startup shortcuts could fail approval when `HKLM\...\StartupApproved\StartupFolder` was missing: the task now creates the missing parent/leaf registry keys before marking shortcuts enabled, so reruns succeed cleanly against already-provisioned desktops.
- Replaced the Windows public-desktop Chrome shortcut profile binding so repo-managed web shortcuts now resolve `--profile-directory` from `.env` `company_name` instead of `VM_NAME`, while still falling back to `VM_NAME` if the new key is left empty.
- Switched both `move` and `set` to the `--vm-name` contract and removed the last public `--vm` usage from those commands.
- Hardened the snapshot-based region-move path so it now deallocates the source VM before snapshot creation, validates that the source resource group is safe for automatic purge, creates target-region public IPs with explicit zonal intent to avoid Azure CLI warning noise, attaches copied OS disks without invalid admin-credential flags, and preserves hibernation flags on the target disk and VM.
- Tightened the move cutover gate so the post-target `37-capture-snapshot-health` validation now runs through strict task-outcome semantics instead of allowing warning-mode continuation to delete the old source group.
- Increased the Windows `37-capture-snapshot-health` catalog timeout from `10s` to `30s` after live regional-move validation on `swedencentral` showed that the old bound could produce false timeout warnings during the target health gate.
- Restored `do --vm-action=hibernate` as the single public hibernation action while keeping the underlying Azure behavior unchanged: hibernation still runs through Azure's deallocation-based hibernate path.
- Made `ssh` and `rdp` state-aware so they now refuse politely when the target VM is not running and point operators to `az-vm do --vm-action=start`.
- Updated `resize` to use `--vm-name` instead of legacy `--vm`, added `--windows`/`--linux` support, and kept no-parameter invocation interactive.
- Split `resize` away from the generic move/resize prompt flow so interactive resize stays in the current region and direct fully specified resize runs without an extra confirmation prompt.
- Streamlined isolated `exec` task runs so they now accept `--vm-name`, resolve only the selected VM/task context, and skip the broader Step-1 managed-resource inventory path before pyssh execution.
- Refreshed `33-create-shortcuts-public-desktop` so the public desktop set now uses the new canonical `a1/i0/i1/i2/z1/z2/t*` naming, removes legacy `i7whatsapp`, adds shared Chrome-profile launchers for ChatGPT, internet, WhatsApp Web, and account setup, dynamically resolves the WhatsApp desktop executable with a fixed fallback path, and wraps command-style launchers through `cmd.exe` so `.cmd`-backed tools do not open in Notepad.
- Extended the Windows public-desktop contract again so `33-create-shortcuts-public-desktop` now adds `a3CodexApp` with the requested `OpenAI.Codex_26.306.996.0_x64__2p2nqsd0c76g0\app\Codex.exe` target fallback, while `37-capture-snapshot-health` inventories the new shortcut during late-stage validation.
- Extended the late Windows validation path so `37-capture-snapshot-health` now also inventories the static auto-start shortcut contract that `32-configure-apps-startup` writes under the machine Startup folder.
- Expanded `37-capture-snapshot-health` to inventory the refreshed public desktop shortcut set and read back the updated target-path and argument contracts during late Windows validation.
- Recalibrated all Windows `vm-update` task catalog timeouts from live transcript data and successful isolated reruns using a `max_success_seconds * 1.3` buffer rule, including new bounded values for tasks `27` and `29` after live `exec` confirmation at `7.2s` and `6.7s`.
- Expanded the late-stage public desktop contract again so the canonical set now also includes normalized social-media links, app launchers for Be My Eyes/NVDA/Edge/VLC/iTunes/OneDrive/Google Drive, one private local-only accessibility shortcut hotkey, dynamic app-path fallback resolution, and Unicode-safe `q1Eksisozluk` creation plus readback through `Shell.Application`.
- Recalibrated Windows `vm-update` catalog timeouts for the new install tasks and refreshed late-stage tasks from successful isolated live durations with a 30% buffer, including final bounded values for tasks `30` through `37`, plus rerun-confirmed `27=10s` and `29=10s`.
- Replaced the fragile reboot/autologon path for Windows `vm-update` tasks `04` and `05` with a bounded `manager` password-logon scheduled-task helper so isolated `exec` runs no longer stall in interactive-session retry loops.
- Reworked `34-configure-ux-windows` so it now enforces and readback-validates hibernate-menu visibility, Explorer details/no-group defaults, desktop name sort plus auto-arrange/grid alignment, Control Panel small icons, file-copy details, keyboard repeat delay, and Task Manager full view through `TaskManager\settings.json`.
- Repaired `34-configure-ux-windows` so it now verifies Task Manager can really launch before and after patching `TaskManager\settings.json`, restores the prior store on failure, and also hides the taskbar Search, Widgets, and Task View controls.
- Reworked `34-configure-ux-windows` again after live `exec` failures so user-hive writes now run through the bounded password-logon helper, registry writes use writable .NET registry handles instead of `New-ItemProperty`/`reg add`, Task Manager no longer synthesizes a minimal `settings.json`, and Widgets hiding now uses the supported `HKLM\SOFTWARE\Policies\Microsoft\Dsh\AllowNewsAndInterests=0` policy path instead of the failing `TaskbarDa` value.
- Simplified `35-configure-settings-advanced-system` down to deterministic machine-level advanced settings only and removed the unsupported audio/max-volume automation branch.
- Added `36-copy-settings-user` to seed the repo-owned Windows user/app settings from `manager` into `assistant`, `C:\Users\Default`, and `HKU\.DEFAULT` with explicit exclusions for volatile caches, tokens, and credential stores.
- Reworked `36-copy-settings-user` after live hang/debug cycles so `assistant` now receives repo-owned HKCU and user-class settings through its own password-logon seed step instead of conflicting offline hive mounts, while default-profile seeding keeps the offline main-hive path only and excludes non-settings-heavy branches such as `AppData\Local\Programs`, `Microsoft\WindowsApps`, and default-profile `LocalLow` to avoid long robocopy stalls on runtime binaries and alias placeholders.
- Hardened one private local-only accessibility settings task with staging extraction, `version.dll` hash verification, per-file roaming copy, and explicit missing-file detection after live validation exposed a false-success path.
- Reworked `18-install-ollama-system` to short-circuit healthy existing installs, detach `ollama serve` stdout/stderr from the SSH session, clear stale installer locks before `winget`, and bound the `winget` wait so interrupted e2e runs no longer hang indefinitely on `waiting another install to complete`.
- Hardened `16-install-docker-desktop` so it now clears stale installer processes before `winget install Docker.DockerDesktop` and terminates leftover installer locks when bounded install waits time out.
- Updated `12-install-vscode-system` so it now short-circuits when a healthy existing Code executable is already present instead of re-entering `winget` during resumed e2e runs.
- Normalized spinner-prefixed `AZ_VM_*` protocol markers in the persistent SSH transport so long-running Windows package installs do not hide task-end or session-error markers behind progress spinners.

### Documentation
- Rebuilt `AGENTS.md` as the repository engineering contract for architecture, workflow, logging, testing, and documentation maintenance.
- Upgraded `README.md` into a fuller operator and contributor guide aligned with the current CLI, step flow, task model, and configuration contract.
- Documented the new `.env` `company_name` key in the config contract so Windows Chrome-based public desktop shortcuts can share a company-named default profile directory such as `orgprofile`.
- Added move timing/process guidance to `README.md` and `az-vm help move`, using the observed live `austriaeast -> swedencentral` `Standard_D4as_v5` / `127 GB` OS-disk move as an operator reference for expected duration and cutover phases.
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
- Added smoke coverage for renamed Windows vm-update private local-only task metadata, zip asset layout, and runtime asset-copy resolution.
- Added smoke coverage for the new `do` command parser/help contract, lifecycle-state normalization, action eligibility checks, and interactive action selection.
- Added smoke coverage for `resize --vm-name`, direct-request detection, platform-flag validation, and same-region interactive size selection.
- Added smoke coverage for direct `exec --vm-name` task targeting, the new minimal `exec` runtime path, and the strengthened Ollama HTTP readiness check.
- Added smoke coverage for persistent SSH spinner-marker normalization plus the new stale-installer and bounded-timeout guards in Windows tasks `09` and `18`.
- Added smoke coverage for the new Windows UX helper-asset model, removal of reboot-resume task metadata, `TaskManager\settings.json` validation, and removal of legacy audio tuning from task `05`.
- Added smoke coverage for the new `36-copy-settings-user` task, taskbar-hide registry contract in task `04`, the `37-capture-snapshot-health` rename, and the public desktop banking shortcut set.
- Added smoke coverage for the new Windows app-install tasks `30` through `37`, the expanded canonical public desktop shortcut set, the shared Unicode-safe `q1Eksisozluk` variable contract, Be My Eyes helper-asset publication, and one private local-only accessibility hotkey assignment.
- Completed isolated live `exec` validation for Windows update tasks `04`, `05`, and one private local-only late-stage task against `rg-examplevm-ate1-g1/examplevm`, including an idempotent rerun of task `04` plus private local-only payload hash and roaming-manifest readback checks.
- Completed additional isolated live repair validation for Windows update tasks `04`, `28`, and `29` after the Windows UX/user-settings hardening changes, including repeated interrupted-task recovery, assistant/default-profile propagation checks, and a final successful `27 -> 28 -> 29` late-stage chain on `rg-examplevm-ate1-g1/examplevm`.
- Completed isolated live `exec` sweeps for every Windows `vm-init` and `vm-update` task against `rg-examplevm-ate1-g1/examplevm` in effective catalog priority/timeout order, then reran task `09` after the Ollama hardening change to prove `11434` API readiness.
- Completed isolated live `exec` validation for Windows update tasks `30` through `37`, then reran `33-create-shortcuts-public-desktop` and `37-capture-snapshot-health` to confirm the expanded shortcut contract, app-target resolution, one private local-only accessibility hotkey, and Unicode-safe `q1Eksisozluk` readback on `rg-examplevm-ate1-g1/examplevm`.
- Completed isolated live reruns of Windows update tasks `09` and `18`, then reran `create --auto --windows --perf --step-from=vm-update` successfully to the end on `rg-examplevm-ate1-g1/examplevm` with `WIN_VM_SIZE=Standard_D4as_v5`, confirming a running VM and reachable RDP port `3389`.

### Refactors
- Removed runtime task-catalog auto-sync/auto-write behavior; catalogs are now read-only inputs at execution time.
- Added catalog-level default consumption (`defaults.priority`, `defaults.timeout`) with fallback `priority=1000`, `timeout=180`.
- Moved private local-only Windows accessibility assets to zip-based packaging and aligned the surrounding update catalog entries with the revised late-stage task naming.
- Merged the user-adjusted Windows vm-update catalog ordering back onto the renamed task set by keeping `33-create-shortcuts-public-desktop` at priority `98`, inserting `36-copy-settings-user` at priority `99`, and moving `37-capture-snapshot-health` to priority `100`.
- Extended `33-create-shortcuts-public-desktop` and `37-capture-snapshot-health` so the late-stage Windows UX flow now creates and inventories eight bank shortcuts that launch Chrome with the requested `examplevm` profile and URLs.
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
- Refactor orchestrator to 7-step flow and restore targeted vm-init step execution
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
- Default interactive runs to the destructive rebuild mode used at that point in history
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
- Adopt default/update/destructive-rebuild flow and pyssh-first step8

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
- Log vm naming contract examplelinuxvm and examplevm confirmation
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
- Capture explicit verification request for windows auto-run completion
- Record windows auto-run iterative rebuild and fix loop
- Record linux auto-run iterative rebuild and fix loop
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
