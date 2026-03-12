# AGENTS.md - az-vm Engineering Contract

## Purpose
This repository manages Azure VM provisioning and lifecycle operations for Windows and Linux through one entrypoint. The project optimizes for parity, deterministic behavior, strong validation before mutation, and operator-visible outcomes.

## Source of Truth Hierarchy
Use these sources in this order when maintaining the repo:
1. Current code and task catalogs for runtime behavior.
2. Current CLI/help output for command-surface truth.
3. Current `.env.example` for committed configuration contract.
4. Current local `.env` only when a user explicitly states that their local runtime configuration is the temporary source of truth for alignment work.
5. Git history for project evolution.
6. Relevant `.codex` session JSONL files for workflow, decision, and prompt-history reconstruction.

## Repository Context Assimilation Rule
- For every user prompt implementation, scan the current repo context before coding:
  - codebase structure (`modules/`, task directories, tools, tests)
  - active documentation contract (`AGENTS.md`, `README.md`, `CHANGELOG.md`, `release-notes.md`, `docs/prompt-history.md`)
  - test and quality entrypoints
- Treat this scan as mandatory pre-work, not optional discovery.
- Implement changes so they align with:
  - existing architecture and naming conventions
  - current command and configuration contracts
  - established workflow and validation patterns
- Do not introduce behavior that conflicts with repository standards when a compatible approach already exists in the codebase.
- At the start of a new coding session, the assistant must re-assimilate repository context (code, docs, tests, recent history) before making edits.
- Prefer extending existing patterns over creating parallel patterns.
- Respect repository continuity: keep behavior and terminology coherent with prior development unless the user explicitly requests a contract-breaking change.

## Repository Map
- `az-vm.cmd`: elevated launcher for Windows operators.
- `az-vm.ps1`: unified orchestrator entrypoint.
- `modules/`: runtime modules grouped by domain.
- `windows/init/`, `windows/update/`: Windows stage roots with tracked catalog-driven tasks at the root, tracked disabled tasks under `disabled/`, and local-only metadata-driven tasks under `local/` and `local/disabled/`.
- `linux/init/`, `linux/update/`: Linux stage roots with tracked catalog-driven tasks at the root, tracked disabled tasks under `disabled/`, and local-only metadata-driven tasks under `local/` and `local/disabled/`.
- `tools/`: helper tooling, pyssh bootstrap, git-hook toggles, and support scripts.
- `tests/`: static, compatibility, audit, and contract checks.
- `docs/prompt-history.md`: human-readable prompt ledger for this repo.

## Architecture Invariants
- Keep one orchestrator entrypoint: `az-vm.ps1`.
- Keep Linux and Windows flow and wording as identical as possible.
- Allow differences only where platform requirements genuinely differ:
  - image selection and guest OS behavior
  - init/update task language
  - Windows-only RDP and Windows service configuration
- Prefer explicit orchestration steps over hidden side effects.
- Prefer task catalogs over hard-coded ad hoc execution order.
- Keep command behavior deterministic across interactive and auto flows.

## Command-Surface Rules
- Current public commands are: `configure`, `create`, `update`, `group`, `show`, `do`, `task`, `exec`, `ssh`, `rdp`, `move`, `resize`, `set`, `delete`, `help`.
- Do not preserve removed commands or aliases once the repo has cut over to a new surface.
- If a command or option is renamed, remove the old form cleanly and update all docs/tests in the same change.
- When a public option is renamed, rename the owning parameter files, manifest entries, parser lookups, help text, README examples, and smoke coverage in the same change; do not leave retired parameter-module filenames behind.
- Use `step` for top-level orchestration phases and `task` for guest task execution. Do not revive removed terms such as `substep`.
- Keep help output, README examples, and runtime messages aligned with the actual parser contract.

## Configuration Rules
- Runtime precedence is: CLI override > `.env` value > hard-coded default.
- `.env` is local-only and must remain untracked.
- `.env.example` is the committed configuration contract and must stay current.
- Keep app-wide customization, secrets, operator identity, and reusable overrides in `.env`.
- Keep task-only customization in a clearly labeled config block at the top of the owning `vm-init` or `vm-update` script.
- Do not hard-code personal, company-specific, or secret fallback values in runtime code or shared orchestration paths.
- Use generic env keys whenever possible.
- Use `company_name` for repo-managed Windows business web shortcuts and `employee_email_address` local-part for repo-managed Windows personal web shortcuts.
- Normalize repo-managed Windows Chrome `--profile-directory` values to lowercase even when `.env` casing differs.
- Keep `employee_full_name` in `.env` as required operator identity metadata for the Windows public desktop shortcut contract.
- Use shared keys such as `VM_ENABLE_HIBERNATION` and `VM_ENABLE_NESTED_VIRTUALIZATION` for cross-platform VM feature intent instead of inventing platform-specific duplicates.
- Use `WIN_` or `LIN_` keys only for true platform-specific settings.
- Remove deprecated env keys instead of keeping compatibility fallbacks.
- Validate region, VM naming, SKU, image, and other mutation-critical config before Azure create/update/delete operations.

## Naming and Resource Rules
- `VM_NAME` is the single naming seed.
- Template-driven resource names must derive from `VM_NAME`, region code, and the committed templates.
- Resource-group uniqueness is suffix-based and deterministic.
- Managed resource name generation must remain explicit, predictable, and validation-backed.
- If naming rules change, update README, tests, and any naming-related summaries in the same change.

## Task Catalog Rules
- Task files use `<task-number>-verb-noun-target.ext`.
- Task-number bands are:
  - `01-99` for `initial`
  - `101-999` for `normal`
  - `1001-9999` for intentionally local-only tasks
  - `10001-10099` for `final`
- The task catalog JSON files are the execution-order and timeout source of truth for tracked tasks at the stage root.
- Intentionally local-only tasks live under `local/`, are discovered from disk at runtime, and use script metadata only.
- Intentionally local-only disabled tasks live under `local/disabled/` and remain disabled by location.
- Root `disabled/` remains for tracked disabled tasks.
- Script-local metadata may supply `priority`, `enabled`, `timeout`, and `assets` for intentionally local-only tasks that stay out of source control.
- When both a task catalog entry and script metadata exist, the catalog entry wins for `priority`, `enabled`, and `timeout`.
- Task priority is catalog-driven for tracked tasks and metadata-driven first for intentionally local-only tasks.
- Local-only task priority precedence is: script metadata `priority` -> filename task number -> deterministic auto-detect in the `1001+` band.
- Runtime code must not auto-write, auto-sync, or auto-reconcile catalog JSON files.
- For tracked tasks that are missing from catalog entries, runtime defaults to `priority=1000`, `enabled=true`, `timeout=180`.
- For catalog entries missing `priority`, default to `1000`.
- For catalog entries missing `timeout`, default to `180`.
- Disabled tasks belong under `disabled/` and must be ignored by execution logic.
- Init and update catalogs may diverge by platform, but the orchestration model should remain parallel in concept.

## Reliability and Error-Handling Rules
- Validate before mutating Azure resources.
- Prefer fast, filtered Azure checks over broad slow listings.
- If Azure does not support a requested operation safely, fail before mutation with the explicit platform reason and list the supported alternatives.
- Fail gracefully with:
  - a short reason
  - a precise corrective hint
  - no ambiguous extra noise
- Avoid retry storms. Retry policies must stay explicit and intentionally bounded.
- Prefer isolated diagnosis and targeted reruns over destructive full rebuild loops unless the user explicitly wants a rebuild.

## Logging and UX Rules
- Keep user-facing strings, comments, help text, and UI wording in English.
- Keep maintained repository documentation in English.
- The only allowed language exception is for literal user-defined display labels or product/site names that are intentionally preserved as-is, such as specific desktop shortcut titles.
- Keep Linux and Windows wording aligned for equivalent behavior.
- Keep logs contextual, singular, and readable.
- Do not emit duplicate informational lines without a real state change.
- Show durations for long-running operations when the feature exists, but avoid noisy transcript spam.
- When a stage produces warnings, failures, or reboot requests, summarize them clearly at stage end.

## Windows Package and Path Rules
- Bootstrap Chocolatey unattended when missing.
- Enable `allowGlobalConfirmation` exactly once immediately after Chocolatey bootstrap.
- Call `refreshenv.cmd` after Chocolatey bootstrap and after each package installation verification step that depends on updated PATH resolution.
- Keep package-install behavior explicit. Do not add silent fallback installers unless the user explicitly requests them.

## Python Tooling Rules
- Repo-managed Python execution must not generate `__pycache__`, `.pyc`, or `.pyo` artifacts.
- Use repo-owned execution wrappers and environment guards for Python-based helpers.
- Keep pyssh tooling self-contained under `tools/pyssh` and bootstrappable from the repo.

## Testing and Quality Rules
- Maintain PowerShell 5.1 and PowerShell 7 compatibility.
- Keep non-live quality checks runnable locally.
- Keep CI non-destructive and non-live; do not run real Azure provisioning in GitHub Actions.
- Maintain a local hook path and a GitHub Actions quality gate together.
- For live publish or release-readiness claims, require one successful end-to-end live acceptance cycle against the active profile: clean `create` when safe, full natural-order `update`, `show` redaction check, `do --vm-action=status`, connection tests, and enabled feature verification.
- Update audit/contract checks when command names, docs, env keys, or task catalog behavior change.

## Documentation Responsibilities
- `AGENTS.md`: engineering contract and collaboration rules.
- `README.md`: operator and contributor guide.
- `LICENSE`: repository licensing terms.
- `CONTRIBUTING.md`: contributor workflow, expectations, and review hygiene.
- `SUPPORT.md`: operator/support routing and escalation guidance.
- `SECURITY.md`: vulnerability-reporting policy and private disclosure path.
- `CODE_OF_CONDUCT.md`: participation expectations for repository spaces.
- `CHANGELOG.md`: full project history from first day to today.
- `release-notes.md`: current release-oriented summary.
- `roadmap.md`: forward-looking project plan.
- `docs/prompt-history.md`: human-readable prompt ledger with English-normalized user prompts and assistant summaries.

## Release Versioning Rule
- `CHANGELOG.md` and `release-notes.md` must use `YYYY.M.D.N`.
- `N` is the cumulative repository commit count at the documented release point.
- Keep changelog and release-notes version labels aligned for the current documented release.

## Prompt-History Rule
- For every completed user prompt that causes code or repo file changes, append the user prompt and the assistant's final summary to `docs/prompt-history.md`.
- For user prompts that do not cause any repo file changes, do not update `docs/prompt-history.md` automatically.
- For non-mutating prompts, the assistant must answer normally and then ask whether the user wants that prompt recorded in the repo history.
- If the user replies yes or gives another clearly positive confirmation, append the most recent user-assistant dialog to `docs/prompt-history.md` and create the corresponding git commit as a special exception.
- Maintain full two-way dialog continuity for recorded turns.
- Do not omit completed turns that changed repo files.
- Keep the file appendable, chronologically ordered, and human-readable.
- Record prompt-history entries in English.
- If the original user prompt or assistant summary is not English, translate it to English before recording it in `docs/prompt-history.md`.
- If the original user prompt or assistant summary is already English, record it unchanged.
- Use the relevant `.codex` JSONL files as the primary source when reconstructing past turns.

## Commit and Change Discipline
- Make small, contextual, developer-friendly English commits.
- Use prefixes such as `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`.
- Reflect the real scope of the change.
- Do not batch unrelated changes into one commit.
- Before creating the final commit for a repo-changing prompt, update `CHANGELOG.md` and `release-notes.md` in the same final change set whenever the prompt changed shipped behavior, docs, configuration contract, workflow, or engineering process.
- Treat that changelog/release-notes update as part of the same prompt deliverable, not as a new follow-up change that triggers another recursive documentation pass.
- Before presenting the final summary to the user, create the commit for the completed prompt.
- Use `tools/enable-git-hooks.ps1` and `tools/disable-git-hooks.ps1` for local hook management; do not reintroduce one-way hook installers.

## Required Assistant Workflow
- Explore before mutating.
- Prefer `rg` / `rg --files` for search.
- Use non-interactive git commands.
- Never use destructive git resets or checkouts unless explicitly requested.
- If unexpected third-party edits appear, stop and ask the user how to proceed.
- When a change affects docs, config contract, or command surface, update the corresponding contract files in the same prompt.
