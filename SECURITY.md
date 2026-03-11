# Security Policy

## Supported Scope

This repository is maintained as a live Azure VM automation toolkit. Security-sensitive reports are welcome for:

- credential handling and configuration exposure
- Azure mutation safety gaps
- guest bootstrap or update paths that could introduce unintended privilege or persistence behavior
- workflow, script, or dependency issues that materially weaken repository safety

## Reporting a Vulnerability

Please do not open a public GitHub issue for a suspected vulnerability.

Instead, contact the maintainer through the repository or profile contact channel and include:

- a short summary of the issue
- affected files, commands, or workflows
- reproduction steps or a proof-of-concept if safe to share
- impact assessment
- any suggested mitigation

If the report involves secrets, credentials, subscription identifiers, hostnames, or sensitive VM details, sanitize them before sending whenever possible.

## Response Expectations

- Initial triage should focus on confirming scope, severity, and reproducibility.
- Fixes will favor validation-before-mutation, bounded behavior, and explicit operator messaging.
- Public disclosure, if any, should wait until the maintainer confirms that an appropriate fix or mitigation is available.

## Out of Scope

The following are generally out of scope unless they demonstrate a concrete exploit path in this repository:

- theoretical issues without a practical repo-specific impact
- Azure platform behavior that is outside this repo's control and not worsened by repo code
- support questions that are not security vulnerabilities

Use [SUPPORT.md](SUPPORT.md) for normal usage and troubleshooting requests.
