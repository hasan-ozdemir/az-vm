# Shared app-state capture specification helpers.

function New-AzVmAppStateCaptureSpec {
    param(
        [string]$TaskName,
        [object[]]$MachineDirectories = @(),
        [object[]]$MachineFiles = @(),
        [object[]]$ProfileDirectories = @(),
        [object[]]$ProfileFiles = @(),
        [object[]]$MachineRegistryKeys = @(),
        [object[]]$UserRegistryKeys = @()
    )

    return [ordered]@{
        taskName = [string]$TaskName
        machineDirectories = @($MachineDirectories)
        machineFiles = @($MachineFiles)
        profileDirectories = @($ProfileDirectories)
        profileFiles = @($ProfileFiles)
        machineRegistryKeys = @($MachineRegistryKeys)
        userRegistryKeys = @($UserRegistryKeys)
    }
}

function New-AzVmAppStatePathCaptureRule {
    param(
        [string]$Path,
        [string[]]$TargetProfiles = @(),
        [string[]]$ExcludeNames = @(),
        [string[]]$ExcludePathPatterns = @(),
        [string[]]$ExcludeFilePatterns = @()
    )

    return [ordered]@{
        path = [string]$Path
        targetProfiles = @($TargetProfiles | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        excludeNames = @($ExcludeNames | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        excludePathPatterns = @($ExcludePathPatterns | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        excludeFilePatterns = @($ExcludeFilePatterns | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
}

function New-AzVmAppStateRegistryCaptureRule {
    param(
        [string]$Path,
        [string[]]$TargetProfiles = @(),
        [string[]]$DistributionAllowList = @()
    )

    return [ordered]@{
        path = [string]$Path
        targetProfiles = @($TargetProfiles | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        distributionAllowList = @($DistributionAllowList | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    }
}

function Get-AzVmDefaultAppStateExcludeNames {
    return @('Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'Crashpad', 'CrashDumps', 'Temp', 'tmp', 'Logs')
}

function Get-AzVmDefaultAppStateExcludeFilePatterns {
    return @('*.lock', '*.tmp', '*.etl', '*.log')
}

function Get-AzVmTaskAppStateCaptureSpecRegistry {
    if ($script:AzVmTaskAppStateCaptureSpecRegistry) {
        return $script:AzVmTaskAppStateCaptureSpecRegistry
    }

    $defaultExcludeNames = Get-AzVmDefaultAppStateExcludeNames
    $defaultExcludeFilePatterns = Get-AzVmDefaultAppStateExcludeFilePatterns
    $browserExcludeNames = @(
        @($defaultExcludeNames) +
        @('optimization_guide_model_store', 'OnDeviceHeadSuggestModel', 'BrowserMetrics', 'GrShaderCache', 'GraphiteDawnCache', 'DawnWebGPUCache', 'ShaderCache', 'Service Worker', 'History', 'History-journal', 'Visited Links', 'Visited Links-journal', 'Top Sites', 'Top Sites-journal', 'SmartScreen', 'EdgeCoupons')
    ) | Select-Object -Unique
    $browserExcludeFilePatterns = @(
        @($defaultExcludeFilePatterns) +
        @('*.pma', '*.journal', '*.ldb-wal', '*.sqlite-wal')
    ) | Select-Object -Unique

    $script:AzVmTaskAppStateCaptureSpecRegistry = @{
        '02-check-install-chrome' = (New-AzVmAppStateCaptureSpec `
            -TaskName '02-check-install-chrome' `
            -ProfileDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Google\Chrome\User Data' -ExcludeNames $browserExcludeNames -ExcludeFilePatterns $browserExcludeFilePatterns)
            ) `
            -UserRegistryKeys @(
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Google\Chrome')
            ))
        '10001-configure-apps-startup' = (New-AzVmAppStateCaptureSpec `
            -TaskName '10001-configure-apps-startup' `
            -MachineDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup')
            ) `
            -ProfileDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup')
            ) `
            -MachineRegistryKeys @(
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKLM\Software\Microsoft\Windows\CurrentVersion\Run')
            ) `
            -UserRegistryKeys @(
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run')
            ))
        '10002-create-shortcuts-public-desktop' = (New-AzVmAppStateCaptureSpec `
            -TaskName '10002-create-shortcuts-public-desktop' `
            -MachineDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path 'C:\Users\Public\Desktop'),
                (New-AzVmAppStatePathCaptureRule -Path 'C:\ProgramData\az-vm\shortcut-launchers\public-desktop')
            ))
        '10003-configure-ux-windows' = (New-AzVmAppStateCaptureSpec `
            -TaskName '10003-configure-ux-windows' `
            -UserRegistryKeys @(
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Control Panel\Desktop'),
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Control Panel\Accessibility'),
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer'),
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Microsoft\Narrator')
            ))
        '10004-configure-settings-advanced-system' = (New-AzVmAppStateCaptureSpec `
            -TaskName '10004-configure-settings-advanced-system' `
            -MachineRegistryKeys @(
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies'),
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem')
            ) `
            -UserRegistryKeys @(
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Microsoft\Windows\CurrentVersion\Policies')
            ))
        '10005-copy-settings-user' = (New-AzVmAppStateCaptureSpec `
            -TaskName '10005-copy-settings-user' `
            -ProfileDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\Microsoft\Templates'),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\Microsoft\Signatures'),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\Microsoft\QuickStyles'),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\Microsoft\UProof'),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\Microsoft\Office' -ExcludeNames @('OfficeFileCache', 'Licensing', 'SolutionPackages', 'OTele', 'Telemetry')),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Microsoft\Office' -ExcludeNames @('OfficeFileCache', 'Licensing', 'Spw', 'SolutionPackages', 'OTele', 'Telemetry', 'webview2', 'EBWebView', 'BrowserMetrics') -ExcludeFilePatterns @('*.ost', '*.pst', '*.nst'))
            ) `
            -UserRegistryKeys @(
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Microsoft\Office\Common'),
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Microsoft\Office\16.0\Common'),
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Microsoft\Office\16.0\Word'),
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Microsoft\Office\16.0\Excel'),
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Microsoft\Office\16.0\PowerPoint'),
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Microsoft\Office\16.0\OneNote')
            ))
        '105-install-azure-cli' = (New-AzVmAppStateCaptureSpec -TaskName '105-install-azure-cli' -ProfileDirectories @((New-AzVmAppStatePathCaptureRule -Path '.azure' -ExcludeNames @('logs', '.azure', 'telemetry') -ExcludeFilePatterns @('*.log'))))
        '106-install-gh-cli' = (New-AzVmAppStateCaptureSpec -TaskName '106-install-gh-cli' -ProfileDirectories @((New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\GitHub CLI')))
        '110-install-vscode-system' = (New-AzVmAppStateCaptureSpec `
            -TaskName '110-install-vscode-system' `
            -ProfileDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\Code\User'),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\Code\Workspaces'),
                (New-AzVmAppStatePathCaptureRule -Path '.vscode\extensions' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns)
            ) `
            -UserRegistryKeys @((New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Microsoft\VSCommon')))
        '111-install-edge-browser' = (New-AzVmAppStateCaptureSpec `
            -TaskName '111-install-edge-browser' `
            -ProfileDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Microsoft\Edge\User Data' -ExcludeNames $browserExcludeNames -ExcludeFilePatterns $browserExcludeFilePatterns)
            ) `
            -UserRegistryKeys @((New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Microsoft\Edge')))
        '112-install-azd-cli' = (New-AzVmAppStateCaptureSpec -TaskName '112-install-azd-cli' -ProfileDirectories @((New-AzVmAppStatePathCaptureRule -Path '.azd' -ExcludeNames @('bin', 'telemetry', '.azd'))))
        '113-install-wsl2-system' = (New-AzVmAppStateCaptureSpec `
            -TaskName '113-install-wsl2-system' `
            -ProfileFiles @((New-AzVmAppStatePathCaptureRule -Path '.wslconfig')) `
            -UserRegistryKeys @((New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss' -DistributionAllowList @('docker-desktop'))))
        '114-install-docker-desktop' = (New-AzVmAppStateCaptureSpec `
            -TaskName '114-install-docker-desktop' `
            -MachineDirectories @((New-AzVmAppStatePathCaptureRule -Path 'C:\ProgramData\DockerDesktop')) `
            -ProfileDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path '.docker' -ExcludeNames (@($defaultExcludeNames) + @('bin')) -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\Docker' -ExcludeNames (@($defaultExcludeNames) + @('DawnGraphiteCache', 'DawnWebGPUCache', 'Network', 'Partitions', 'Service Worker', 'Shared Dictionary')) -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\Docker Desktop' -ExcludeNames (@($defaultExcludeNames) + @('DawnGraphiteCache', 'DawnWebGPUCache', 'Network', 'Partitions', 'Service Worker', 'Shared Dictionary')) -ExcludeFilePatterns $defaultExcludeFilePatterns)
            ) `
            -UserRegistryKeys @(
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Docker Desktop'),
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Docker Inc.')
            ))
        '115-install-npm-packages-global' = (New-AzVmAppStateCaptureSpec `
            -TaskName '115-install-npm-packages-global' `
            -ProfileDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path '.codex' -ExcludeNames @('vendor_imports', '.git', 'Cache', 'Code Cache', 'Logs', 'tmp') -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path '.gemini' -ExcludeNames @('tmp', 'bin', 'Cache', 'Code Cache', 'Logs') -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path '.config\github-copilot'),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\GitHub Copilot')
            ) `
            -ProfileFiles @(
                (New-AzVmAppStatePathCaptureRule -Path '.npmrc')
            ))
        '116-install-ollama-system' = (New-AzVmAppStateCaptureSpec `
            -TaskName '116-install-ollama-system' `
            -MachineDirectories @((New-AzVmAppStatePathCaptureRule -Path 'C:\ProgramData\Ollama')) `
            -ProfileDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path '.ollama' -ExcludeNames (@($defaultExcludeNames) + @('models')) -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Ollama' -ExcludeNames (@($defaultExcludeNames) + @('updates_v2')) -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\Ollama' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\ollama app.exe' -ExcludeNames (@($defaultExcludeNames) + @('EBWebView')) -ExcludeFilePatterns $defaultExcludeFilePatterns)
            ))
        '117-install-codex-app' = (New-AzVmAppStateCaptureSpec `
            -TaskName '117-install-codex-app' `
            -ProfileDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Packages\OpenAI.Codex_*\Settings'),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Packages\OpenAI.Codex_*\LocalState' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Packages\OpenAI.Codex_*\RoamingState' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns)
            ))
        '118-install-teams-system' = (New-AzVmAppStateCaptureSpec `
            -TaskName '118-install-teams-system' `
            -ProfileDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Packages\MSTeams_*\Settings'),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Packages\MSTeams_*\LocalState' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Packages\MSTeams_*\RoamingState' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns)
            ))
        '119-install-onedrive-system' = (New-AzVmAppStateCaptureSpec `
            -TaskName '119-install-onedrive-system' `
            -ProfileDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Microsoft\OneDrive' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\Microsoft\OneDrive' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns)
            ) `
            -UserRegistryKeys @((New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Microsoft\OneDrive')))
        '120-install-google-drive' = (New-AzVmAppStateCaptureSpec `
            -TaskName '120-install-google-drive' `
            -ProfileDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Google\DriveFS' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\Google\DriveFS' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns)
            ) `
            -UserRegistryKeys @((New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Google\DriveFS')))
        '121-install-whatsapp-system' = (New-AzVmAppStateCaptureSpec `
            -TaskName '121-install-whatsapp-system' `
            -ProfileDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Packages\5319275A.WhatsAppDesktop_*\Settings'),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Packages\5319275A.WhatsAppDesktop_*\LocalState' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Packages\5319275A.WhatsAppDesktop_*\RoamingState' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns)
            ))
        '122-install-anydesk-system' = (New-AzVmAppStateCaptureSpec `
            -TaskName '122-install-anydesk-system' `
            -ProfileDirectories @((New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\AnyDesk' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns)) `
            -UserRegistryKeys @((New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\AnyDesk')))
        '123-install-windscribe-system' = (New-AzVmAppStateCaptureSpec `
            -TaskName '123-install-windscribe-system' `
            -ProfileDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Windscribe' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\Windscribe' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns)
            ) `
            -UserRegistryKeys @((New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Windscribe')))
        '124-install-vlc-system' = (New-AzVmAppStateCaptureSpec `
            -TaskName '124-install-vlc-system' `
            -ProfileDirectories @((New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\vlc' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns)) `
            -UserRegistryKeys @((New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\VideoLAN\VLC')))
        '125-install-itunes-system' = (New-AzVmAppStateCaptureSpec `
            -TaskName '125-install-itunes-system' `
            -ProfileDirectories @((New-AzVmAppStatePathCaptureRule -Path 'Music\iTunes' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns)) `
            -UserRegistryKeys @((New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Apple Computer, Inc.')))
        '126-install-be-my-eyes' = (New-AzVmAppStateCaptureSpec `
            -TaskName '126-install-be-my-eyes' `
            -ProfileDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Packages\BeMyEyes.BeMyEyes_*\Settings'),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Packages\BeMyEyes.BeMyEyes_*\LocalState' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Packages\BeMyEyes.BeMyEyes_*\RoamingState' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns)
            ))
        '127-install-nvda-system' = (New-AzVmAppStateCaptureSpec `
            -TaskName '127-install-nvda-system' `
            -ProfileDirectories @((New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\nvda' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns)) `
            -UserRegistryKeys @((New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\NVDA')))
        '128-install-rclone-system' = (New-AzVmAppStateCaptureSpec `
            -TaskName '128-install-rclone-system' `
            -ProfileDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\rclone'),
                (New-AzVmAppStatePathCaptureRule -Path '.config\rclone')
            ))
        '131-install-icloud-system' = (New-AzVmAppStateCaptureSpec `
            -TaskName '131-install-icloud-system' `
            -ProfileDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\Apple Computer' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Apple Computer' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Packages\AppleInc.iCloud_*\Settings'),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Packages\AppleInc.iCloud_*\LocalState' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Packages\AppleInc.iCloud_*\RoamingState' -ExcludeNames $defaultExcludeNames -ExcludeFilePatterns $defaultExcludeFilePatterns)
            ) `
            -UserRegistryKeys @(
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Apple Inc.\iCloud'),
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Apple Computer, Inc.')
            ))
        '132-install-vs2022community' = (New-AzVmAppStateCaptureSpec `
            -TaskName '132-install-vs2022community' `
            -ProfileDirectories @(
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Roaming\Microsoft\VisualStudio' -ExcludeNames (@($defaultExcludeNames) + @('Packages', 'ImageLibrary', 'ImageLibrary.cache', 'Search', 'SettingsLogs', 'ComponentModelCache', 'vshub')) -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path 'AppData\Local\Microsoft\VisualStudio' -ExcludeNames (@($defaultExcludeNames) + @('Packages', 'ImageLibrary', 'ImageLibrary.cache', 'Search', 'SettingsLogs', 'ComponentModelCache', 'vshub')) -ExcludeFilePatterns $defaultExcludeFilePatterns),
                (New-AzVmAppStatePathCaptureRule -Path '.vs' -ExcludeNames (@($defaultExcludeNames) + @('Packages', 'ImageLibrary', 'ImageLibrary.cache', 'Search', 'SettingsLogs', 'ComponentModelCache', 'vshub')) -ExcludeFilePatterns $defaultExcludeFilePatterns)
            ) `
            -UserRegistryKeys @(
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Microsoft\VisualStudio'),
                (New-AzVmAppStateRegistryCaptureRule -Path 'HKCU\Software\Microsoft\VSCommon')
            ))
    }

    return $script:AzVmTaskAppStateCaptureSpecRegistry
}

function Get-AzVmTaskAppStateCaptureSpec {
    param([string]$TaskName)

    if ([string]::IsNullOrWhiteSpace([string]$TaskName)) {
        return $null
    }

    $registry = Get-AzVmTaskAppStateCaptureSpecRegistry
    foreach ($key in @($registry.Keys)) {
        if ([string]::Equals([string]$key, [string]$TaskName, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $registry[$key]
        }
    }

    return $null
}
