Set-StrictMode -Version 2.0

function Ensure-AzVmDirectory {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        throw "Directory path is empty."
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Open-AzVmWritableRegistryKey {
    param(
        [string]$Path
    )

    $regPath = Convert-AzVmRegistryProviderPathToRegExePath -Path $Path
    $baseKey = $null
    $subKey = ''

    switch -regex ($regPath) {
        '^HKEY_CURRENT_USER(?:\\(?<sub>.*))?$' {
            $baseKey = [Microsoft.Win32.Registry]::CurrentUser
            $subKey = [string]$Matches['sub']
            break
        }
        '^HKEY_LOCAL_MACHINE(?:\\(?<sub>.*))?$' {
            $baseKey = [Microsoft.Win32.Registry]::LocalMachine
            $subKey = [string]$Matches['sub']
            break
        }
        '^HKEY_USERS(?:\\(?<sub>.*))?$' {
            $baseKey = [Microsoft.Win32.Registry]::Users
            $subKey = [string]$Matches['sub']
            break
        }
        '^HKEY_CLASSES_ROOT(?:\\(?<sub>.*))?$' {
            $baseKey = [Microsoft.Win32.Registry]::ClassesRoot
            $subKey = [string]$Matches['sub']
            break
        }
        '^HKEY_CURRENT_CONFIG(?:\\(?<sub>.*))?$' {
            $baseKey = [Microsoft.Win32.Registry]::CurrentConfig
            $subKey = [string]$Matches['sub']
            break
        }
        default {
            throw ("Unsupported registry hive: {0}" -f $regPath)
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$subKey)) {
        return $baseKey
    }

    $key = $baseKey.OpenSubKey($subKey, $true)
    if ($null -ne $key) {
        return $key
    }

    return $baseKey.CreateSubKey($subKey)
}

function Set-AzVmRegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [Microsoft.Win32.RegistryValueKind]$Kind
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    if ((Get-Item -LiteralPath $Path).PSProvider.Name -eq 'Registry') {
        $isDefaultValue = ([string]::IsNullOrWhiteSpace([string]$Name) -or [string]::Equals([string]$Name, '(default)', [System.StringComparison]::OrdinalIgnoreCase))
        $registryValueName = if ($isDefaultValue) { '' } else { [string]$Name }
        $key = $null
        try {
            $key = Open-AzVmWritableRegistryKey -Path $Path
            $key.SetValue($registryValueName, $Value, $Kind)
            return
        }
        catch [System.UnauthorizedAccessException] {
            Set-AzVmRegistryValueWithRegExe -Path $Path -Name $Name -Value $Value -Kind $Kind -IsDefaultValue:$isDefaultValue
            return
        }
        finally {
            if ($key -is [System.IDisposable]) {
                $key.Dispose()
            }
        }
    }

    throw ("Unsupported registry path: {0}" -f $Path)
}

function Convert-AzVmRegistryProviderPathToRegExePath {
    param([string]$Path)

    $candidate = [string]$Path
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
        throw "Registry path is empty."
    }

    if ($candidate.StartsWith('Registry::', [System.StringComparison]::OrdinalIgnoreCase)) {
        return $candidate.Substring(10)
    }

    if ($candidate -match '^(HKLM|HKCU|HKCR|HKU|HKCC):\\') {
        return ($candidate -replace '^(HKLM):', 'HKEY_LOCAL_MACHINE' `
                            -replace '^(HKCU):', 'HKEY_CURRENT_USER' `
                            -replace '^(HKCR):', 'HKEY_CLASSES_ROOT' `
                            -replace '^(HKU):', 'HKEY_USERS' `
                            -replace '^(HKCC):', 'HKEY_CURRENT_CONFIG')
    }

    return $candidate
}

function Convert-AzVmRegistryValueKindToRegExeType {
    param([Microsoft.Win32.RegistryValueKind]$Kind)

    switch ($Kind) {
        ([Microsoft.Win32.RegistryValueKind]::String) { return 'REG_SZ' }
        ([Microsoft.Win32.RegistryValueKind]::ExpandString) { return 'REG_EXPAND_SZ' }
        ([Microsoft.Win32.RegistryValueKind]::DWord) { return 'REG_DWORD' }
        ([Microsoft.Win32.RegistryValueKind]::QWord) { return 'REG_QWORD' }
        ([Microsoft.Win32.RegistryValueKind]::MultiString) { return 'REG_MULTI_SZ' }
        ([Microsoft.Win32.RegistryValueKind]::Binary) { return 'REG_BINARY' }
        default { throw ("Unsupported registry value kind for reg.exe fallback: {0}" -f [string]$Kind) }
    }
}

function Convert-AzVmRegistryValueToRegExeData {
    param(
        [object]$Value,
        [Microsoft.Win32.RegistryValueKind]$Kind
    )

    switch ($Kind) {
        ([Microsoft.Win32.RegistryValueKind]::String) { return [string]$Value }
        ([Microsoft.Win32.RegistryValueKind]::ExpandString) { return [string]$Value }
        ([Microsoft.Win32.RegistryValueKind]::DWord) { return [string]([uint32]$Value) }
        ([Microsoft.Win32.RegistryValueKind]::QWord) { return [string]([uint64]$Value) }
        ([Microsoft.Win32.RegistryValueKind]::MultiString) { return ((@($Value) | ForEach-Object { [string]$_ }) -join '\0') }
        ([Microsoft.Win32.RegistryValueKind]::Binary) { return ((@($Value) | ForEach-Object { '{0:x2}' -f [byte]$_ }) -join ',') }
        default { throw ("Unsupported registry value data for reg.exe fallback: {0}" -f [string]$Kind) }
    }
}

function Set-AzVmRegistryValueWithRegExe {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [Microsoft.Win32.RegistryValueKind]$Kind,
        [switch]$IsDefaultValue
    )

    $regPath = Convert-AzVmRegistryProviderPathToRegExePath -Path $Path
    $regType = Convert-AzVmRegistryValueKindToRegExeType -Kind $Kind
    $regData = Convert-AzVmRegistryValueToRegExeData -Value $Value -Kind $Kind

    & reg.exe add $regPath /f | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw ("reg add failed while creating key '{0}'." -f $regPath)
    }

    $arguments = @('add', $regPath)
    if ($IsDefaultValue) {
        $arguments += '/ve'
    }
    else {
        $arguments += '/v'
        $arguments += [string]$Name
    }
    $arguments += '/t'
    $arguments += $regType
    $arguments += '/d'
    $arguments += [string]$regData
    $arguments += '/f'

    & reg.exe @arguments | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw ("reg add failed for '{0}'." -f $regPath)
    }
}

function Get-AzVmInteractivePaths {
    param(
        [string]$TaskName
    )

    $taskNameText = [string]$TaskName
    if ([string]::IsNullOrWhiteSpace([string]$taskNameText)) {
        throw "Interactive task name is empty."
    }

    $safeTaskName = ($taskNameText -replace '[^a-zA-Z0-9\-]', '-').Trim('-')
    if ([string]::IsNullOrWhiteSpace([string]$safeTaskName)) {
        throw "Interactive task name became empty after sanitization."
    }

    $rootPath = Join-Path 'C:\ProgramData\az-vm\interactive' $safeTaskName
    return [pscustomobject]@{
        RootPath = $rootPath
        WorkerPath = Join-Path $rootPath 'worker.ps1'
        ResultPath = Join-Path $rootPath 'result.json'
        LogPath = Join-Path $rootPath 'worker.log'
        ScheduledTaskName = ('AzVmInteractive-' + $safeTaskName)
        TaskName = $safeTaskName
    }
}

function Write-AzVmJsonFile {
    param(
        [string]$Path,
        [object]$Value
    )

    $parentPath = Split-Path -Path $Path -Parent
    Ensure-AzVmDirectory -Path $parentPath
    $jsonText = [string]($Value | ConvertTo-Json -Depth 8)
    [System.IO.File]::WriteAllText($Path, $jsonText, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-AzVmJsonFile {
    param(
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw ("JSON file was not found: {0}" -f $Path)
    }

    $text = [string](Get-Content -LiteralPath $Path -Raw -ErrorAction Stop)
    if ([string]::IsNullOrWhiteSpace([string]$text)) {
        throw ("JSON file is empty: {0}" -f $Path)
    }

    return (ConvertFrom-Json -InputObject $text)
}

function Write-AzVmInteractiveResult {
    param(
        [string]$ResultPath,
        [string]$TaskName,
        [bool]$Success,
        [string]$Summary,
        [string[]]$Details = @()
    )

    $payload = [ordered]@{
        TaskName = [string]$TaskName
        Success = [bool]$Success
        Summary = [string]$Summary
        Details = @($Details | ForEach-Object { [string]$_ })
        CompletedUtc = [DateTime]::UtcNow.ToString('o')
    }

    Write-AzVmJsonFile -Path $ResultPath -Value $payload
}

function Wait-AzVmFileReady {
    param(
        [string]$Path,
        [int]$TimeoutSeconds = 600,
        [int]$PollSeconds = 2
    )

    if ($TimeoutSeconds -lt 5) {
        $TimeoutSeconds = 5
    }
    if ($PollSeconds -lt 1) {
        $PollSeconds = 1
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-Path -LiteralPath $Path) {
            $fileInfo = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
            if ($null -ne $fileInfo -and [int64]$fileInfo.Length -gt 0) {
                return $true
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }

    return $false
}

function Get-AzVmPowerShellExePath {
    $cmd = Get-Command powershell.exe -ErrorAction SilentlyContinue
    if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        return [string]$cmd.Source
    }

    $fallback = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $fallback) {
        return [string]$fallback
    }

    throw "powershell.exe was not found."
}

function Get-AzVmLocalPrincipalName {
    param(
        [string]$UserName
    )

    if ([string]::IsNullOrWhiteSpace([string]$UserName)) {
        throw "User name is empty."
    }

    return ("{0}\{1}" -f $env:COMPUTERNAME, [string]$UserName)
}

function Test-AzVmUserInteractiveDesktopReady {
    param(
        [string]$UserName
    )

    if ([string]::IsNullOrWhiteSpace([string]$UserName)) {
        return $false
    }

    $principalName = Get-AzVmLocalPrincipalName -UserName $UserName
    try {
        $explorerProcesses = @(Get-Process -Name 'explorer' -IncludeUserName -ErrorAction Stop)
        foreach ($process in @($explorerProcesses)) {
            $ownerName = [string]$process.UserName
            if ([string]::IsNullOrWhiteSpace([string]$ownerName)) {
                continue
            }

            if ([string]::Equals($ownerName, $principalName, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    catch {
    }

    $processes = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue)
    foreach ($process in @($processes)) {
        try {
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwner -ErrorAction Stop
            if ($null -eq $owner -or [int]$owner.ReturnValue -ne 0) {
                continue
            }

            $ownerUser = [string]$owner.User
            $ownerDomain = [string]$owner.Domain
            if ([string]::Equals($ownerUser, $UserName, [System.StringComparison]::OrdinalIgnoreCase) -and `
                [string]::Equals($ownerDomain, $env:COMPUTERNAME, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
        catch {
        }
    }

    return $false
}

function Remove-AzVmInteractiveScheduledTask {
    param(
        [string]$TaskName
    )

    if ([string]::IsNullOrWhiteSpace([string]$TaskName)) {
        return
    }

    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $root = $service.GetFolder('\')
    try {
        $root.DeleteTask($TaskName, 0)
    }
    catch {
        if ($_.Exception.Message -notmatch '(?i)cannot find the file specified|does not exist') {
            throw
        }
    }
}

function Register-AzVmInteractiveScheduledTask {
    param(
        [string]$TaskName,
        [string]$RunAsUser,
        [string]$WorkerPath,
        [string]$RunAsPassword,
        [string]$RunAsMode = 'password'
    )

    Remove-AzVmInteractiveScheduledTask -TaskName $TaskName

    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $root = $service.GetFolder('\')
    $definition = $service.NewTask(0)

    $definition.RegistrationInfo.Description = ("az-vm interactive automation for {0}" -f [string]$TaskName)
    $definition.Settings.Enabled = $true
    $definition.Settings.Hidden = $true
    $definition.Settings.StartWhenAvailable = $true
    $definition.Settings.AllowDemandStart = $true
    $definition.Settings.DisallowStartIfOnBatteries = $false
    $definition.Settings.StopIfGoingOnBatteries = $false
    $definition.Settings.ExecutionTimeLimit = 'PT1H'
    $definition.Settings.MultipleInstances = 0

    $runAsUserText = [string]$RunAsUser
    $isServiceAccount = [string]::Equals($runAsUserText, 'SYSTEM', [System.StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($runAsUserText, 'NT AUTHORITY\SYSTEM', [System.StringComparison]::OrdinalIgnoreCase)
    $useInteractiveToken = [string]::Equals([string]$RunAsMode, 'interactiveToken', [System.StringComparison]::OrdinalIgnoreCase)
    if ($isServiceAccount) {
        $principalName = 'SYSTEM'
        $definition.Principal.UserId = $principalName
        $definition.Principal.LogonType = 5
        $definition.Principal.RunLevel = 1
    }
    elseif ($useInteractiveToken) {
        $principalName = Get-AzVmLocalPrincipalName -UserName $runAsUserText
        $definition.Principal.UserId = $principalName
        $definition.Principal.LogonType = 3
        $definition.Principal.RunLevel = 1
    }
    else {
        $principalName = Get-AzVmLocalPrincipalName -UserName $runAsUserText
        $definition.Principal.UserId = $principalName
        $definition.Principal.LogonType = 1
        $definition.Principal.RunLevel = 1
    }

    $action = $definition.Actions.Create(0)
    $action.Path = Get-AzVmPowerShellExePath
    $action.Arguments = ('-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f [string]$WorkerPath)
    $action.WorkingDirectory = (Split-Path -Path $WorkerPath -Parent)

    $trigger = $definition.Triggers.Create(1)
    $trigger.StartBoundary = ([DateTime]::Now.AddMinutes(10).ToString('s'))

    if (-not $isServiceAccount -and -not $useInteractiveToken -and [string]::IsNullOrWhiteSpace([string]$RunAsPassword)) {
        throw "Interactive scheduled task password is empty."
    }

    if ($isServiceAccount) {
        $null = $root.RegisterTaskDefinition($TaskName, $definition, 6, $principalName, $null, 5, $null)
        return
    }

    if ($useInteractiveToken) {
        $null = $root.RegisterTaskDefinition($TaskName, $definition, 6, $null, $null, 3, $null)
        return
    }

    $null = $root.RegisterTaskDefinition($TaskName, $definition, 6, $principalName, [string]$RunAsPassword, 1, $null)
}

function Start-AzVmInteractiveScheduledTask {
    param(
        [string]$TaskName
    )

    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $root = $service.GetFolder('\')
    $task = $root.GetTask($TaskName)
    if ($null -eq $task) {
        throw ("Scheduled task was not found: {0}" -f $TaskName)
    }

    $null = $task.Run($null)
}

function Get-AzVmInteractiveScheduledTaskSnapshot {
    param(
        [string]$TaskName
    )

    if ([string]::IsNullOrWhiteSpace([string]$TaskName)) {
        return $null
    }

    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $root = $service.GetFolder('\')
    try {
        $task = $root.GetTask($TaskName)
    }
    catch {
        if ($_.Exception.Message -match '(?i)cannot find the file specified|does not exist') {
            return $null
        }
        throw
    }

    return [pscustomobject]@{
        State = [int]$task.State
        LastTaskResult = [int]$task.LastTaskResult
        LastRunTime = [DateTime]$task.LastRunTime
    }
}

function Invoke-AzVmInteractiveDesktopAutomation {
    param(
        [string]$TaskName,
        [string]$RunAsUser,
        [string]$RunAsPassword,
        [string]$WorkerScriptText,
        [int]$WaitTimeoutSeconds = 900,
        [string]$RunAsMode = 'password'
    )

    if ([string]::IsNullOrWhiteSpace([string]$WorkerScriptText)) {
        throw "Interactive worker script text is empty."
    }
    $runAsUserText = [string]$RunAsUser
    $isServiceAccount = [string]::Equals($runAsUserText, 'SYSTEM', [System.StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($runAsUserText, 'NT AUTHORITY\SYSTEM', [System.StringComparison]::OrdinalIgnoreCase)
    $useInteractiveToken = [string]::Equals([string]$RunAsMode, 'interactiveToken', [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $isServiceAccount -and -not $useInteractiveToken -and [string]::IsNullOrWhiteSpace([string]$RunAsPassword)) {
        throw "Interactive worker cannot run because the run-as password is empty."
    }

    $paths = Get-AzVmInteractivePaths -TaskName $TaskName
    Ensure-AzVmDirectory -Path $paths.RootPath

    if (Test-Path -LiteralPath $paths.ResultPath) {
        Remove-Item -LiteralPath $paths.ResultPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $paths.WorkerPath) {
        Remove-Item -LiteralPath $paths.WorkerPath -Force -ErrorAction SilentlyContinue
    }

    [System.IO.File]::WriteAllText($paths.WorkerPath, [string]$WorkerScriptText, (New-Object System.Text.UTF8Encoding($false)))
    try {
        Register-AzVmInteractiveScheduledTask -TaskName $paths.ScheduledTaskName -RunAsUser $RunAsUser -WorkerPath $paths.WorkerPath -RunAsPassword $RunAsPassword -RunAsMode $RunAsMode
        Start-AzVmInteractiveScheduledTask -TaskName $paths.ScheduledTaskName

        $completed = Wait-AzVmFileReady -Path $paths.ResultPath -TimeoutSeconds $WaitTimeoutSeconds -PollSeconds 2
        if (-not $completed) {
            $snapshot = Get-AzVmInteractiveScheduledTaskSnapshot -TaskName $paths.ScheduledTaskName
            if ($null -eq $snapshot) {
                throw ("Interactive worker timed out without a result file: {0}" -f $paths.ResultPath)
            }

            throw ("Interactive worker timed out without a result file: state={0}; last-task-result={1}; last-run-time={2}" -f [int]$snapshot.State, [int]$snapshot.LastTaskResult, [string]$snapshot.LastRunTime)
        }

        $result = Read-AzVmJsonFile -Path $paths.ResultPath
        $summary = if ($result.PSObject.Properties.Match('Summary').Count -gt 0) { [string]$result.Summary } else { 'Interactive desktop worker reported failure.' }
        if ($result.PSObject.Properties.Match('Success').Count -eq 0 -or -not [bool]$result.Success) {
            $detailText = ''
            if ($result.PSObject.Properties.Match('Details').Count -gt 0 -and $null -ne $result.Details) {
                $detailText = ((@($result.Details | ForEach-Object { [string]$_ }) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ' | ')
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$detailText)) {
                throw ("{0} ({1})" -f $summary, $detailText)
            }
            throw $summary
        }

        $modeLabel = 'password-logon'
        if ($isServiceAccount) {
            $modeLabel = 'service-account'
        }
        elseif ($useInteractiveToken) {
            $modeLabel = 'interactive-token'
        }

        Write-Host ("interactive-session-bootstrap: {0} scheduled task completed for {1}" -f $modeLabel, [string]$RunAsUser)
    }
    finally {
        try {
            Remove-AzVmInteractiveScheduledTask -TaskName $paths.ScheduledTaskName
        }
        catch {
            Write-Warning ("interactive-task-cleanup-warning: {0}" -f $_.Exception.Message)
        }
        Remove-Item -LiteralPath $paths.WorkerPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $paths.ResultPath -Force -ErrorAction SilentlyContinue
    }
}
