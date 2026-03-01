# az-vm Reconstruction Timeline

Format:
- [YYYY-MM-DD HH:mm] milestone

- [2026-03-01 09:00] Requested non-interactive execution of linux deployment script with default values and SSH verification.
- [2026-03-01 09:04] Requested renaming az-vm-* files to linux-focused naming to reflect linux-only deployment scope.
- [2026-03-01 09:08] Corrected naming convention so files should end with lin.* and not require deploy suffix.
- [2026-03-01 09:12] Requested static review to ensure two-stage rename/content updates caused no broken references.
- [2026-03-01 09:16] Requested az-vm-win.cmd and az-vm-win.ps1 with linux-equivalent behavior and windows adaptation.
- [2026-03-01 09:20] Added requirement for RDP readiness, broad client compatibility, and same user credentials as SSH.
- [2026-03-01 09:24] Required post-create guest update workflow conversion from .sh to PowerShell for windows VM.
- [2026-03-01 09:28] Set windows server/vm name requirement to examplevm while linux stays otherexamplevm.
- [2026-03-01 09:32] Requested highly compatible Windows Datacenter-oriented image strategy for server workloads.
- [2026-03-01 09:36] Requested optimal disk sizing and cost-efficient Standard SSD selection for windows flow.
- [2026-03-01 09:40] Set windows VM size target to Standard_B2as_v2 for practical performance baseline.
- [2026-03-01 09:44] Required explicit python install command via choco upgrade python312 -y without fallback path.
- [2026-03-01 09:48] Required automatic Chocolatey installation and unattended setup before package operations.
- [2026-03-01 09:52] Requested region move to nearest India location for better latency profile from Turkey.
- [2026-03-01 09:56] Added requirement to call refreshenv.cmd before PATH-based app checks.
