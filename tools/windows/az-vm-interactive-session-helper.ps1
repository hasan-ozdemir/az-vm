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
        if ([string]::IsNullOrWhiteSpace([string]$Name) -or [string]::Equals([string]$Name, '(default)', [System.StringComparison]::OrdinalIgnoreCase)) {
            Set-Item -Path $Path -Value $Value -Force
            return
        }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Kind -Force | Out-Null
        return
    }

    throw ("Unsupported registry path: {0}" -f $Path)
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
        [string]$UserName,
        [string]$WorkerPath,
        [string]$Password
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

    $principalName = Get-AzVmLocalPrincipalName -UserName $UserName
    $definition.Principal.UserId = $principalName
    $definition.Principal.LogonType = 1
    $definition.Principal.RunLevel = 1

    $action = $definition.Actions.Create(0)
    $action.Path = Get-AzVmPowerShellExePath
    $action.Arguments = ('-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f [string]$WorkerPath)
    $action.WorkingDirectory = (Split-Path -Path $WorkerPath -Parent)

    $trigger = $definition.Triggers.Create(1)
    $trigger.StartBoundary = ([DateTime]::Now.AddMinutes(10).ToString('s'))

    if ([string]::IsNullOrWhiteSpace([string]$Password)) {
        throw "Interactive scheduled task password is empty."
    }

    $null = $root.RegisterTaskDefinition($TaskName, $definition, 6, $principalName, [string]$Password, 1, $null)
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
        [string]$ManagerUser,
        [string]$ManagerPassword,
        [string]$WorkerScriptText,
        [int]$WaitTimeoutSeconds = 900
    )

    if ([string]::IsNullOrWhiteSpace([string]$WorkerScriptText)) {
        throw "Interactive worker script text is empty."
    }
    if ([string]::IsNullOrWhiteSpace([string]$ManagerPassword)) {
        throw "Interactive worker cannot run because the manager password is empty."
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
        Register-AzVmInteractiveScheduledTask -TaskName $paths.ScheduledTaskName -UserName $ManagerUser -WorkerPath $paths.WorkerPath -Password $ManagerPassword
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

        Write-Host ("interactive-session-bootstrap: password-logon scheduled task completed for {0}" -f [string]$ManagerUser)
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
