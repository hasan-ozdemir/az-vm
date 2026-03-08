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
- `windows/init/`, `windows/update/`: Windows guest task catalogs.
- `linux/init/`, `linux/update/`: Linux guest task catalogs.
- `windows/*/disabled/`: intentionally disabled guest tasks.
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
- Current public commands are: `configure`, `create`, `update`, `group`, `show`, `exec`, `ssh`, `rdp`, `move`, `resize`, `set`, `delete`, `help`.
- Do not preserve removed commands or aliases once the repo has cut over to a new surface.
- If a command or option is renamed, remove the old form cleanly and update all docs/tests in the same change.
- Use `step` for top-level orchestration phases and `task` for guest task execution. Do not revive removed terms such as `substep`.
- Keep help output, README examples, and runtime messages aligned with the actual parser contract.

## Configuration Rules
- Runtime precedence is: CLI override > `.env` value > hard-coded default.
- `.env` is local-only and must remain untracked.
- `.env.example` is the committed configuration contract and must stay current.
- Use generic env keys whenever possible.
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
- Task files use `NN-verb-topic.ext`.
- `NN` is a two-digit task number.
- The task catalog JSON files are the execution-order and timeout source of truth.
- Task priority is catalog-driven, not inferred from directory scans at runtime.
- Runtime code must not auto-write, auto-sync, or auto-reconcile catalog JSON files.
- For discovered tasks that are missing from catalog entries, use defaults: `priority=1000`, `enabled=true`, `timeout=180`.
- For catalog entries missing `priority`, default to `1000`.
- For catalog entries missing `timeout`, default to `180`.
- Disabled tasks belong under `disabled/` and must be ignored by execution logic.
- Init and update catalogs may diverge by platform, but the orchestration model should remain parallel in concept.

## Reliability and Error-Handling Rules
- Validate before mutating Azure resources.
- Prefer fast, filtered Azure checks over broad slow listings.
- Fail gracefully with:
  - a short reason
  - a precise corrective hint
  - no ambiguous extra noise
- Avoid retry storms. Retry policies must stay explicit and intentionally bounded.
- Prefer isolated diagnosis and targeted reruns over destructive full rebuild loops unless the user explicitly wants a rebuild.

## Logging and UX Rules
- Keep user-facing strings, comments, and UI wording in English.
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
- Update audit/contract checks when command names, docs, env keys, or task catalog behavior change.

## Documentation Responsibilities
- `AGENTS.md`: engineering contract and collaboration rules.
- `README.md`: operator and contributor guide.
- `CHANGELOG.md`: full project history from first day to today.
- `release-notes.md`: current release-oriented summary.
- `roadmap.md`: forward-looking project plan.
- `docs/prompt-history.md`: human-readable prompt ledger with raw prompts and assistant summaries.

## Release Versioning Rule
- `CHANGELOG.md` and `release-notes.md` must use `YYYY.M.D.N`.
- `N` is the cumulative repository commit count at the documented release point.
- Keep changelog and release-notes version labels aligned for the current documented release.

## Prompt-History Rule
- For every completed user prompt that causes code or repo file changes, append the user's raw prompt and the assistant's final summary to `docs/prompt-history.md`.
- For user prompts that do not cause any repo file changes, do not update `docs/prompt-history.md` automatically.
- For non-mutating prompts, the assistant must answer normally and then ask whether the user wants that prompt recorded in the repo history.
- If the user replies yes or gives another clearly positive confirmation, append the most recent user-assistant dialog to `docs/prompt-history.md` and create the corresponding git commit as a special exception.
- Maintain full two-way dialog continuity for recorded turns.
- Do not omit completed turns that changed repo files.
- Keep the file appendable, chronologically ordered, and human-readable.
- Use the relevant `.codex` JSONL files as the primary source when reconstructing past turns.

## Commit and Change Discipline
- Make small, contextual, developer-friendly English commits.
- Use prefixes such as `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`.
- Reflect the real scope of the change.
- Do not batch unrelated changes into one commit.
- Before presenting the final summary to the user, create the commit for the completed prompt.
- Use `tools/enable-git-hooks.ps1` and `tools/disable-git-hooks.ps1` for local hook management; do not reintroduce one-way hook installers.

## Required Assistant Workflow
- Explore before mutating.
- Prefer `rg` / `rg --files` for search.
- Use non-interactive git commands.
- Never use destructive git resets or checkouts unless explicitly requested.
- If unexpected third-party edits appear, stop and ask the user how to proceed.
- When a change affects docs, config contract, or command surface, update the corresponding contract files in the same prompt.
