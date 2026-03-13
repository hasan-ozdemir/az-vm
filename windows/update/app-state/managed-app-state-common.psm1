$ErrorActionPreference = 'Stop'

function Convert-ToManagedAppStateLowerText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        return ''
    }

    return [string]$Value.Trim().ToLowerInvariant()
}

function Get-ManagedAppStateEmployeeEmailBaseName {
    param([string]$EmailAddress)

    if ([string]::IsNullOrWhiteSpace([string]$EmailAddress)) {
        return ''
    }

    $parts = @([string]$EmailAddress.Trim().Split('@'))
    if (@($parts).Count -lt 2) {
        return ''
    }

    return [string]$parts[0]
}

function Ensure-ManagedAppStateDirectory {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Ensure-ManagedAppStateFile {
    param(
        [string]$Path,
        [string]$Content = ''
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        return
    }

    Ensure-ManagedAppStateDirectory -Path (Split-Path -Path $Path -Parent)
    if (-not (Test-Path -LiteralPath $Path)) {
        Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
        return
    }

    $existingContent = [string](Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue)
    if ([string]::Equals($existingContent, $Content, [System.StringComparison]::Ordinal)) {
        return
    }

    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8
}

function Get-ManagedAppStateProfileTargets {
    param(
        [string]$ManagerUser,
        [string]$AssistantUser
    )

    $targets = New-Object 'System.Collections.Generic.List[object]'

    foreach ($row in @(
        @{ Label = 'manager'; Path = ('C:\Users\{0}' -f [string]$ManagerUser) },
        @{ Label = 'assistant'; Path = ('C:\Users\{0}' -f [string]$AssistantUser) },
        @{ Label = 'default'; Path = 'C:\Users\Default' }
    )) {
        $profilePath = [string]$row.Path
        if ([string]::IsNullOrWhiteSpace([string]$profilePath) -or -not (Test-Path -LiteralPath $profilePath)) {
            continue
        }

        $targets.Add([pscustomobject]@{
            Label = [string]$row.Label
            Path = [string]$profilePath
        }) | Out-Null
    }

    return @($targets.ToArray())
}

function Resolve-ManagedAppStateTemplate {
    param(
        [string]$Template,
        [hashtable]$Context
    )

    $resolved = [string]$Template
    foreach ($key in @($Context.Keys)) {
        $resolved = $resolved.Replace(('{' + [string]$key + '}'), [string]$Context[$key])
    }

    return [Environment]::ExpandEnvironmentVariables([string]$resolved)
}

function Invoke-ManagedAppStateRestore {
    param(
        [string]$ManifestPath,
        [string]$CompanyName,
        [string]$EmployeeEmailAddress,
        [string]$ManagerUser,
        [string]$AssistantUser
    )

    $manifestText = [string](Get-Content -LiteralPath $ManifestPath -Raw -ErrorAction Stop)
    if ([string]::IsNullOrWhiteSpace([string]$manifestText)) {
        throw ("Managed app-state manifest is empty: {0}" -f $ManifestPath)
    }

    $manifest = ConvertFrom-Json -InputObject $manifestText -ErrorAction Stop
    $appRows = @($manifest.apps)
    if (@($appRows).Count -lt 1) {
        throw ("Managed app-state manifest does not contain any app entries: {0}" -f $ManifestPath)
    }

    $businessProfileDirectory = Convert-ToManagedAppStateLowerText -Value $CompanyName
    $personalProfileDirectory = Convert-ToManagedAppStateLowerText -Value (Get-ManagedAppStateEmployeeEmailBaseName -EmailAddress $EmployeeEmailAddress)
    $templateContext = @{
        publicChromeRoot = 'C:\Users\Public\AppData\Local\Google\Chrome\UserData'
        publicEdgeRoot = 'C:\Users\Public\AppData\Local\Microsoft\msedge\userdata'
        businessProfileDirectory = [string]$businessProfileDirectory
        personalProfileDirectory = [string]$personalProfileDirectory
    }

    $profileTargets = @(Get-ManagedAppStateProfileTargets -ManagerUser $ManagerUser -AssistantUser $AssistantUser)
    $machineDirectoryCount = 0
    $profileDirectoryCount = 0
    $profileFileCount = 0

    foreach ($app in @($appRows)) {
        if ($null -eq $app) {
            continue
        }

        $appId = if ($app.PSObject.Properties.Match('id').Count -gt 0) { [string]$app.id } else { '' }
        $displayName = if ($app.PSObject.Properties.Match('displayName').Count -gt 0) { [string]$app.displayName } else { $appId }
        $installTask = if ($app.PSObject.Properties.Match('installTask').Count -gt 0) { [string]$app.installTask } else { '' }
        $stateMode = if ($app.PSObject.Properties.Match('stateMode').Count -gt 0) { [string]$app.stateMode } else { 'runtime-owned' }
        Write-Host ("managed-app-state-plan => {0} => mode={1}; install-task={2}" -f $displayName, $stateMode, $installTask)

        foreach ($machineDirectory in @($app.machineDirectories)) {
            $resolvedPath = Resolve-ManagedAppStateTemplate -Template ([string]$machineDirectory) -Context $templateContext
            if ([string]::IsNullOrWhiteSpace([string]$resolvedPath)) {
                continue
            }

            Ensure-ManagedAppStateDirectory -Path $resolvedPath
            $machineDirectoryCount++
            Write-Host ("managed-app-state-machine-dir => {0} => {1}" -f $appId, $resolvedPath)
        }

        foreach ($profileTarget in @($profileTargets)) {
            $profileRoot = [string]$profileTarget.Path
            foreach ($profileDirectory in @($app.profileDirectories)) {
                $relativePath = Resolve-ManagedAppStateTemplate -Template ([string]$profileDirectory) -Context $templateContext
                if ([string]::IsNullOrWhiteSpace([string]$relativePath)) {
                    continue
                }

                $resolvedPath = Join-Path $profileRoot $relativePath
                Ensure-ManagedAppStateDirectory -Path $resolvedPath
                $profileDirectoryCount++
                Write-Host ("managed-app-state-profile-dir => {0} => {1} => {2}" -f $appId, [string]$profileTarget.Label, $resolvedPath)
            }

            foreach ($profileFile in @($app.profileFiles)) {
                if ($null -eq $profileFile) {
                    continue
                }

                $relativeFilePath = if ($profileFile.PSObject.Properties.Match('relativePath').Count -gt 0) { [string]$profileFile.relativePath } else { '' }
                $fileContent = if ($profileFile.PSObject.Properties.Match('content').Count -gt 0) { [string]$profileFile.content } else { '' }
                $resolvedRelativeFilePath = Resolve-ManagedAppStateTemplate -Template $relativeFilePath -Context $templateContext
                if ([string]::IsNullOrWhiteSpace([string]$resolvedRelativeFilePath)) {
                    continue
                }

                $resolvedFilePath = Join-Path $profileRoot $resolvedRelativeFilePath
                Ensure-ManagedAppStateFile -Path $resolvedFilePath -Content $fileContent
                $profileFileCount++
                Write-Host ("managed-app-state-profile-file => {0} => {1} => {2}" -f $appId, [string]$profileTarget.Label, $resolvedFilePath)
            }
        }
    }

    return [pscustomobject]@{
        AppCount = [int]@($appRows).Count
        MachineDirectoryCount = [int]$machineDirectoryCount
        ProfileDirectoryCount = [int]$profileDirectoryCount
        ProfileFileCount = [int]$profileFileCount
    }
}

Export-ModuleMember -Function Invoke-ManagedAppStateRestore
