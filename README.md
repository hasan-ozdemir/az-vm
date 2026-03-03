# az-vm

Azure VM provisioning automation for Linux and Windows, with shared orchestration modules, deterministic run modes, and strong operational logging.

## Quick Start

### 1) Prerequisites
- Windows host with PowerShell 5.1+ (or PowerShell 7+).
- Azure CLI installed (`az`) and authenticated (`az login`).
- Sufficient Azure permissions to create/delete resource groups, network resources, and VMs.
- Run from an elevated terminal (admin) when using `.cmd` launchers.

### 2) Prepare config
- Linux template: `lin-vm/.env.example`
- Windows template: `win-vm/.env.example`
- Create local runtime files:

```powershell
Copy-Item lin-vm/.env.example lin-vm/.env
Copy-Item win-vm/.env.example win-vm/.env
```

### 3) Run in auto mode (recommended for unattended)

```powershell
.\az-vm-lin.cmd --auto
.\az-vm-win.cmd --auto
```

### 4) Optional: run Step 8 tasks one-by-one for diagnostics

```powershell
.\az-vm-lin.cmd --auto --step
.\az-vm-win.cmd --auto --step
```

### 5) Read outputs
- Linux log: `lin-vm/az-vm-lin-log.txt`
- Windows log: `win-vm/az-vm-win-log.txt`
- Final outputs include public IP/FQDN and ready-to-run connection commands.

---

## What This Project Is

`az-vm` is a script-driven provisioning toolkit that creates and configures Azure VMs end-to-end:
- Creates or recreates resource group and network resources.
- Creates VM with controlled image/size/disk options.
- Applies guest-side configuration through Azure Run Command.
- Exposes configured TCP ports both at NSG and OS firewall levels.
- Emits connection commands and logs for operators.

## Who It Is For
- Platform/devops engineers who need reproducible VM setup.
- Developers who need quick Linux/Windows lab VMs with consistent network rules.
- Teams wanting script parity across Linux and Windows VM deployment flows.

## When It Is Useful
- Repeatable environment bootstrap in test/lab subscriptions.
- Regression checks for VM provisioning and guest hardening tasks.
- Fast provisioning where infra-as-code overhead is unnecessary.

---

## Repository Structure

```text
az-vm/
  az-vm-lin.cmd                # Elevated launcher -> lin-vm/az-vm-lin.ps1
  az-vm-win.cmd                # Elevated launcher -> win-vm/az-vm-win.ps1
  AGENTS.md                    # Development conventions
  co-vm/                       # Shared cross-platform orchestration modules
    az-vm-co-core.ps1
    az-vm-co-config.ps1
    az-vm-co-azure.ps1
    az-vm-co-runcommand.ps1
  lin-vm/
    az-vm-lin.ps1              # Linux orchestration script
    az-vm-lin-cloud-init.yaml  # Generated/managed cloud-init content
    az-vm-lin-update.sh        # Linux guest update script (combined mode)
    .env.example
  win-vm/
    az-vm-win.ps1              # Windows orchestration script
    az-vm-win-init.ps1         # Windows init script artifact
    az-vm-win-update.ps1       # Windows guest update script (combined mode)
    .env.example
```

---

## Runtime Modes

Both Linux and Windows scripts support the same CLI flags:

- `interactive` (default)
  - Step-by-step confirmation model via `Invoke-Step`.
- `--auto` / `-a`
  - Non-interactive execution path.
- `--step` / `-s`
  - Diagnostic mode for Step 8 guest tasks.

### Step vs Task semantics
- `Step 1..9` = top-level orchestration stages.
- Step 8 contains guest-side `Task` blocks.

Execution behavior in Step 8:
- With `--step`: tasks run one-by-one via run-command.
- Without `--step`: whole update script runs in a single run-command call.

---

## Configuration

### Precedence
Runtime configuration order is:
1. CLI/user override (for values prompted/overridden in runtime)
2. `.env` value
3. hard-coded script default

### Environment files
- Local `.env` files are runtime inputs and should stay untracked.
- `.env.example` files are the templates to share.

### Key variables (Linux and Windows)

| Variable | Purpose |
|---|---|
| `SERVER_NAME` | Base server identity (`otherexamplevm` for Linux, `examplevm` for Windows by default). |
| `RESOURCE_GROUP` | Resource group name template (supports `{SERVER_NAME}`). |
| `AZ_LOCATION` | Azure region (default currently `austriaeast`). |
| `VNET_NAME`, `SUBNET_NAME`, `NSG_NAME`, `NSG_RULE_NAME`, `PUBLIC_IP_NAME`, `NIC_NAME` | Network resource names. |
| `VM_NAME` | VM name template. |
| `VM_IMAGE` | Image URN. |
| `VM_STORAGE_SKU` | Disk SKU (`StandardSSD_LRS`). |
| `VM_SIZE` | VM size (default `Standard_B2as_v2`). |
| `VM_DISK_NAME`, `VM_DISK_SIZE_GB` | OS disk naming/size. |
| `VM_USER`, `VM_PASS` | Login account credentials. |
| `SSH_PORT` | SSH port (default `444`). |
| `TCP_PORTS` | Comma-separated inbound TCP ports applied to NSG + guest firewall. |

Platform-specific:
- Linux: `VM_CLOUD_INIT_FILE`, `VM_UPDATE_SCRIPT_FILE`
- Windows: `VM_INIT_SCRIPT_FILE`, `VM_UPDATE_SCRIPT_FILE`

---

## End-to-End Provisioning Flow

### Step 1
Resolve parameters from `.env` + defaults and validate key inputs.

### Step 2
Pre-check availability (fail fast):
- Region exists.
- Image available in region.
- VM size available in region (REST-based check).
- Configured disk size is compatible with image minimum OS disk size.

### Step 3
Resource group handling:
- If target RG exists, script deletes it and waits for deletion.
- Creates fresh RG.

### Step 4
Network provisioning:
- VNet + Subnet
- NSG + inbound rule for configured `TCP_PORTS`
- Static Public IP + NIC attachment

### Step 5/6
Guest script preparation:
- Linux: cloud-init + bash update script.
- Windows: init PowerShell + update PowerShell script.

### Step 7
VM create (with existence/return checks).

### Step 8
Guest configuration execution via Azure Run Command:
- Linux command id: `RunShellScript`
- Windows command id: `RunPowerShellScript`

### Step 9
Print final connection details:
- Public IP
- SSH command
- RDP command (Windows)

---

## Network and Access Model

- `TCP_PORTS` is the single source list for inbound ports.
- Same port set is applied in two layers:
  - Azure NSG inbound allow rule
  - Guest OS firewall rules

Defaults include common dev/service ports, plus:
- `3389` for RDP (Windows)
- `444` for SSH
- `11434` included in both platform defaults

---

## Windows Guest Configuration Details

Windows Step 8 tasks include:
- Local admin user assurance.
- OpenSSH install/config/service enablement.
- RDP enablement and compatibility-friendly settings.
- Chocolatey bootstrap (unattended).
- Package installs via Chocolatey:
  - `git`
  - `python312`
  - `nodejs-lts`
- `refreshenv.cmd` invocation after choco bootstrap and after each package install/check step.
- Health snapshot of ports/services/firewall/sshd config.

---

## Linux Guest Configuration Details

Linux Step 8 tasks include:
- User/password setup for VM user and root.
- Apt package update/install baseline.
- SSH daemon configuration updates.
- UFW inbound policy and TCP port rules from `TCP_PORTS`.
- Capability and service handling for SSH/Node scenarios.
- Health snapshot (open ports, firewall status, sshd config).

---

## Usage Examples

### Linux, unattended combined mode
```powershell
.\az-vm-lin.cmd --auto
```

### Linux, unattended task-by-task diagnostics
```powershell
.\az-vm-lin.cmd --auto --step
```

### Windows, unattended combined mode
```powershell
.\az-vm-win.cmd --auto
```

### Windows, unattended task-by-task diagnostics
```powershell
.\az-vm-win.cmd --auto --step
```

### Direct PowerShell script invocation
```powershell
powershell -ExecutionPolicy Bypass -File .\lin-vm\az-vm-lin.ps1 --auto
powershell -ExecutionPolicy Bypass -File .\win-vm\az-vm-win.ps1 --auto
```

---

## Logs, Exit Behavior, and Error Handling

- Console output is transcribed to per-platform log files.
- Failures are mapped to user-friendly summary/hint text and non-zero exit codes.
- Script exits gracefully and prints:
  - reason summary
  - detailed failing message
  - suggested corrective action

Representative failure classes:
- invalid/unavailable region
- image unavailability in selected region
- unsupported VM size in selected region
- incompatible OS disk size
- VM create failures
- run-command task or batch failures

---

## Safety and Cost Notes

- The scripts may delete an existing target resource group before recreation.
- VM, disk, public IP, and network resources create Azure costs.
- Use non-production subscriptions unless you intentionally target production.
- Replace default/sample credentials in `.env` before real use.

---

## Developer Notes

- Shared logic belongs in `co-vm/`.
- Keep Linux/Windows top-level flow aligned; diverge only for OS-specific needs.
- Prefer updating `.env.example` when introducing/changing config keys.
- Follow `AGENTS.md` for project conventions and commit discipline.

---

## FAQ

### Why do I get prompted in interactive mode?
Interactive is the default mode and asks per-step confirmation. Use `--auto` for non-interactive runs.

### Why does Step 8 sometimes run slower?
`--step` runs each task individually for diagnostics. Combined mode runs a single run-command call and is generally faster.

### Can I change SSH port and open-port list?
Yes. Set `SSH_PORT` and `TCP_PORTS` in platform `.env` files. The scripts sync these across NSG and guest firewall configuration.

### Can I use a different image or region?
Yes. Update `VM_IMAGE` and `AZ_LOCATION` in `.env`. Pre-checks fail fast if the combination is unsupported.
