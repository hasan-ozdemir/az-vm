# Reconstruction Eras

This index groups reconstructed commits into major delivery eras.

## Era 1 - Linux baseline and naming normalization
- non-interactive deploy flow
- linux-specific naming and suffix corrections
- static regression review requests

## Era 2 - Windows parity bootstrap
- windows script creation matching linux behavior
- RDP + SSH alignment and admin requirements
- guest update conversion to PowerShell

## Era 3 - Image, region, size and storage hardening
- region iterations (India preference, then austriaeast)
- image selection investigations (Windows 11 / M365)
- disk sizing and StandardSSD decisions
- VM size constraints and availability checks

## Era 4 - Package bootstrap and path reliability
- strict Chocolatey package installs
- refreshenv sequencing rules
- PATH repair and duplicate-safe handling
- global confirmation placement constraints

## Era 5 - Mode semantics and run-command behavior
- interactive vs auto mode introduction
- step diagnostics mode
- combined-mode Step 8 single invocation semantics
- step/task terminology correction

## Era 6 - Cross-platform consistency and code reuse
- linux/windows structural parity requirements
- shared `co-vm` extraction
- launcher relocation and folder normalization

## Era 7 - Network and security expansions
- extended TCP port matrix across NSG and guest firewall
- mandatory 11434 inclusion
- SSH port migration 443 -> 444

## Era 8 - Verification and stabilization
- repeated auto and step test loops
- windows Step 8 deadlock investigation context
- final auto-run evidence notes

## Notes
- This reconstruction is evidence-informed from prompt chronology and Codex JSONL sources.
- Where exact historical patch shape was unavailable, commits preserve intent and decision flow explicitly.
