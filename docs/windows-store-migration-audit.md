# Windows Store Migration Audit

This audit captures the current `windows/update` application install surface and highlights which apps are already Store-backed, which ones have a plausible `winget + msstore` path that still needs explicit maintainer approval, and which ones should stay on their current installer source for now.

Status rules used here:
- `already-store-backed`: the current tracked task already installs from `msstore`.
- `candidate-awaiting-approval`: a credible `msstore` package was found, but the repo will not migrate the installer source until the maintainer explicitly approves the move.
- `keep-current-source`: the current source remains the recommended path for this repo at the moment.
- `not-a-store-app`: the app is not part of the Windows Store migration question for the current tracked task.

## Current Matrix

| App | Current task | Current source | msstore status | Recommendation | Notes |
| --- | --- | --- | --- | --- | --- |
| Google Chrome | `02-check-install-chrome` | direct installer / current browser check | no current Store migration plan | keep-current-source | Repo treats Chrome as a classic desktop browser and shared profile target. |
| PowerShell 7 | `101-install-powershell-core` | Chocolatey | not-a-store-app | keep-current-source | Classic developer runtime. |
| Git | `102-install-git-system` | Chocolatey | not-a-store-app | keep-current-source | Classic desktop/runtime install. |
| Python | `103-install-python-system` | Chocolatey | not-a-store-app | keep-current-source | Classic developer runtime. |
| Node.js | `104-install-node-system` | Chocolatey | not-a-store-app | keep-current-source | Classic developer runtime. |
| Azure CLI | `105-install-azure-cli` | Chocolatey | no useful Store path confirmed | keep-current-source | CLI state is better handled outside Store packaging. |
| GitHub CLI | `106-install-gh-cli` | Chocolatey | no useful Store path confirmed | keep-current-source | CLI state is better handled outside Store packaging. |
| 7-Zip | `107-install-7zip-system` | Chocolatey | not-a-store-app | keep-current-source | Classic utility install. |
| FFmpeg | `109-install-ffmpeg-system` | Chocolatey | not-a-store-app | keep-current-source | Classic utility install. |
| Visual Studio Code | `110-install-vscode-system` | classic installer | Store package found | candidate-awaiting-approval | `XP9KHM4BK9FZ7Q` was found via `winget search --source msstore`. |
| Microsoft Edge | `111-install-edge-browser` | classic installer | Store package found | candidate-awaiting-approval | `XPFFTQ037JWMHS` was found via `winget search --source msstore`. |
| Azure Developer CLI | `112-install-azd-cli` | winget/community | no useful Store path confirmed | keep-current-source | CLI state is better handled outside Store packaging. |
| WSL | `113-install-wsl2-system` | DISM + `Microsoft.WSL` bootstrap | no useful Store migration plan | keep-current-source | Repo already hardens the WSL 2 feature path directly. |
| Docker Desktop | `114-install-docker-desktop` | winget classic package | Store package found | candidate-awaiting-approval | `XP8CBJ40XLBWKX` was found via `winget search --source msstore`. |
| Global npm package set | `115-install-npm-packages-global` | npm registry | not-a-store-app | keep-current-source | CLI wrapper set, not a Store surface. |
| Ollama | `116-install-ollama-system` | winget classic package | no useful Store path confirmed | keep-current-source | Service/API workflow is already modeled around the classic install. |
| Codex App | `117-install-codex-app` | `winget + msstore` | already-store-backed | keep-current-source | Public desktop shortcut now prefers `shell:AppsFolder\<AUMID>`. |
| Microsoft Teams | `118-install-teams-system` | `winget + msstore` | already-store-backed | keep-current-source | Public desktop shortcut already uses `AppsFolder` launch. |
| OneDrive | `119-install-onedrive-system` | classic package | no useful Store migration plan | keep-current-source | Current install path is acceptable for repo automation. |
| Google Drive | `120-install-google-drive` | classic package | no useful Store path confirmed | keep-current-source | Versioned classic install path is already supported. |
| WhatsApp | `121-install-whatsapp-system` | `winget + msstore` | already-store-backed | keep-current-source | Public desktop shortcut now prefers `shell:AppsFolder\<AUMID>`. |
| AnyDesk | `122-install-anydesk-system` | winget classic package | no useful Store path confirmed | keep-current-source | Current verification remains classic-exe based. |
| Windscribe | `123-install-windscribe-system` | winget classic package | no current migration plan | keep-current-source | Repo keeps the current installer path. |
| VLC | `124-install-vlc-system` | winget/classic | no useful Store path confirmed | keep-current-source | Classic media install remains the stable path. |
| iTunes | `125-install-itunes-system` | winget/classic | no useful Store path confirmed | keep-current-source | Current repo flow remains classic-exe based. |
| Be My Eyes | `126-install-be-my-eyes` | `winget + msstore` | already-store-backed | keep-current-source | Public desktop shortcut already uses `AppsFolder` launch. |
| NVDA | `127-install-nvda-system` | winget/classic | no useful Store path confirmed | keep-current-source | Accessibility app stays on current source. |
| Rclone | `128-install-rclone-system` | winget/classic | no useful Store path confirmed | keep-current-source | CLI install stays outside Store packaging. |
| Io Unlocker | `129-configure-unlocker-io` | Chocolatey | not-a-store-app | keep-current-source | Classic utility install. |
| iCloud | `131-install-icloud-system` | `winget + msstore` | already-store-backed | keep-current-source | Public desktop shortcut now prefers `shell:AppsFolder\<AUMID>`. |
| Visual Studio 2022 Community | `132-install-vs2022community` | Chocolatey | no useful Store path confirmed | keep-current-source | Current install path remains the practical route. |

## Approval Gate

No installer-source migration was applied for these current Store candidates:
- `Microsoft Edge`
- `Docker Desktop`
- `Visual Studio Code`

If you approve any of them, the next change should update:
- the owning install task
- installer verification logic
- public desktop shortcut expectations when the app becomes Store-backed
- smoke tests and docs in the same patch
