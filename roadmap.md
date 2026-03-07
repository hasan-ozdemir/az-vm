# Roadmap

## Vision
Keep `az-vm` as a high-signal, parity-first Azure VM orchestration toolkit where operator workflows are explicit, recoverable, well-documented, and testable without relying on hidden guest-side behavior.

## Guiding Principles
- Preserve one orchestrator and one mental model across Windows and Linux.
- Prefer validation before mutation.
- Prefer deterministic task catalogs over implicit sequencing.
- Prefer process clarity over convenience fallbacks.
- Keep docs, tests, and runtime contracts synchronized.

## Now
- Finish documentation freshness workflows so README, changelog, release notes, roadmap, and prompt history stay aligned as commands evolve.
- Expand static contract checks for current CLI examples, docs wording drift, and env-key drift.
- Tighten Windows deferred-install verification flows so post-sign-in completions are easier to inspect and rerun.
- Keep quality gates fast enough for daily use while still covering PowerShell compatibility and doc integrity.
- Continue reducing duplicate logging and ambiguous operator messages.

## Next
- Improve `move` and `resize` safety reporting with clearer rollback-state visibility and operator summaries.
- Extend `show`, `set`, and `group` workflows with richer but still human-readable VM/resource metadata.
- Add more structured task metadata such as reboot expectations, connection prerequisites, or platform-specific warnings.
- Make isolated `exec` workflows easier to discover by showing task catalogs and descriptions more clearly.
- Harden Linux parity for newer operator-facing capabilities introduced first on the Windows side.

## Later
- Introduce a tag-driven release process with versioned release notes and reproducible packaged artifacts.
- Add richer non-destructive smoke harnesses for selected Azure read-only validation scenarios.
- Add per-resource-group or per-VM credential/profile separation where it improves operator safety.
- Generate more of the historical and release documentation from repo-owned tooling instead of one-off reconstruction work.
- Improve task-state persistence so deferred or partially completed guest-side work is easier to inspect and replay.

## Exploratory
- Optional drift reporting or export paths for Bicep/Terraform-oriented infrastructure consumers.
- Optional remote diagnostics bundle collection for failed guest task runs.
- Optional dashboard or web summary for managed resource groups and VM health inventory.
- More formal policy checks for naming, logging, task-catalog quality, and command-surface evolution.
- Optional scenario-based test harnesses for change, repair, and rollback workflows without requiring destructive live loops.

## Exit Criteria for Future Work
A roadmap item is considered complete only when the change includes:
- code or configuration updates where applicable
- matching test or audit coverage
- matching documentation updates
- changelog entry coverage
- prompt-history continuity for the interaction that delivered it
