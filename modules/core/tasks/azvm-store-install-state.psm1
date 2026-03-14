$ErrorActionPreference = 'Stop'

function Invoke-AzVmRefreshSessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path -LiteralPath $refreshEnvCmd) {
        cmd.exe /d /c "`"$refreshEnvCmd`" >nul 2>&1" | Out-Null
    }

    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrWhiteSpace([string]$userPath)) {
        $env:Path = [string]$machinePath
    }
    else {
        $env:Path = ("{0};{1}" -f [string]$machinePath, [string]$userPath).Trim(';')
    }
}

function Resolve-AzVmWingetExe {
    param(
        [string]$PortableCandidate = 'C:\ProgramData\az-vm\tools\winget-x64\winget.exe'
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$PortableCandidate) -and (Test-Path -LiteralPath $PortableCandidate)) {
        return [string]$PortableCandidate
    }

    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    if ($cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) {
        return [string]$cmd.Source
    }

    return ''
}

function Get-AzVmStoreInstallStateRoot {
    $rootPath = 'C:\ProgramData\az-vm\state\store-installs'
    if (-not (Test-Path -LiteralPath $rootPath)) {
        New-Item -Path $rootPath -ItemType Directory -Force | Out-Null
    }

    return [string]$rootPath
}

function Get-AzVmStoreInstallStatePath {
    param([string]$TaskName)

    if ([string]::IsNullOrWhiteSpace([string]$TaskName)) {
        throw 'Store install state task name is empty.'
    }

    $safeName = (([string]$TaskName -replace '[^A-Za-z0-9\-]', '-').Trim('-'))
    if ([string]::IsNullOrWhiteSpace([string]$safeName)) {
        $safeName = 'task'
    }

    return (Join-Path (Get-AzVmStoreInstallStateRoot) ($safeName + '.json'))
}

function Read-AzVmStoreInstallState {
    param([string]$TaskName)

    $statePath = Get-AzVmStoreInstallStatePath -TaskName $TaskName
    if (-not (Test-Path -LiteralPath $statePath)) {
        return $null
    }

    $stateText = [string](Get-Content -LiteralPath $statePath -Raw -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace([string]$stateText)) {
        return $null
    }

    try {
        return (ConvertFrom-Json -InputObject $stateText -ErrorAction Stop)
    }
    catch {
        return $null
    }
}

function Remove-AzVmStoreInstallState {
    param([string]$TaskName)

    $statePath = Get-AzVmStoreInstallStatePath -TaskName $TaskName
    if (Test-Path -LiteralPath $statePath) {
        Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
    }
}

function Write-AzVmStoreInstallState {
    param(
        [string]$TaskName,
        [ValidateSet('installed','degraded')]
        [string]$State,
        [string]$Summary,
        [string]$PackageId = '',
        [string]$RunOnceName = '',
        [string]$LaunchTarget = '',
        [string]$LaunchKind = '',
        [string]$InstallSource = 'msstore'
    )

    $statePath = Get-AzVmStoreInstallStatePath -TaskName $TaskName
    $runOnceRegistered = $false
    if (-not [string]::IsNullOrWhiteSpace([string]$RunOnceName)) {
        $runOnceRegistered = Test-AzVmRunOnceEntryPresent -Name $RunOnceName
    }

    $payload = [ordered]@{
        taskName = [string]$TaskName
        state = [string]$State
        summary = [string]$Summary
        packageId = [string]$PackageId
        installSource = [string]$InstallSource
        runOnceName = [string]$RunOnceName
        runOnceRegistered = [bool]$runOnceRegistered
        launchKind = [string]$LaunchKind
        launchTarget = [string]$LaunchTarget
        updatedAtUtc = ((Get-Date).ToUniversalTime().ToString('o'))
    }

    $json = ($payload | ConvertTo-Json -Depth 6)
    Set-Content -LiteralPath $statePath -Value $json -Encoding UTF8
    return ([pscustomobject]$payload)
}

function Write-AzVmStoreInstallStateStatusLine {
    param(
        [string]$TaskName,
        [AllowNull()]
        [psobject]$StateRecord
    )

    if ($null -eq $StateRecord) {
        Write-Host ("store-install-state => task={0}; state=none" -f [string]$TaskName)
        return
    }

    $summary = ''
    if ($StateRecord.PSObject.Properties.Match('summary').Count -gt 0) {
        $summary = [string]$StateRecord.summary
    }
    $launchKind = ''
    if ($StateRecord.PSObject.Properties.Match('launchKind').Count -gt 0) {
        $launchKind = [string]$StateRecord.launchKind
    }
    $runOnceRegistered = $false
    if ($StateRecord.PSObject.Properties.Match('runOnceRegistered').Count -gt 0) {
        $runOnceRegistered = [bool]$StateRecord.runOnceRegistered
    }

    Write-Host ("store-install-state => task={0}; state={1}; launch-kind={2}; run-once={3}; summary={4}" -f [string]$TaskName, [string]$StateRecord.state, $launchKind, [bool]$runOnceRegistered, $summary)
}

function Test-AzVmRunOnceEntryPresent {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace([string]$Name)) {
        return $false
    }

    $runOncePath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path -LiteralPath $runOncePath)) {
        return $false
    }

    $property = Get-ItemProperty -Path $runOncePath -Name ([string]$Name) -ErrorAction SilentlyContinue
    if ($null -eq $property) {
        return $false
    }

    $value = $property.PSObject.Properties[[string]$Name].Value
    return (-not [string]::IsNullOrWhiteSpace([string]$value))
}

function Remove-AzVmRunOnceEntry {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace([string]$Name)) {
        return
    }

    $runOncePath = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path -LiteralPath $runOncePath)) {
        return
    }

    Remove-ItemProperty -Path $runOncePath -Name ([string]$Name) -ErrorAction SilentlyContinue
}

function Test-AzVmStoreInstallNeedsInteractiveCompletion {
    param(
        [string]$MessageText,
        [bool]$TimedOut = $false
    )

    if ([bool]$TimedOut) {
        return $true
    }

    if ([string]::IsNullOrWhiteSpace([string]$MessageText)) {
        return $false
    }

    return ([string]$MessageText -match '(?i)0x80070520|logon session|microsoft store|msstore|interactive')
}

Export-ModuleMember -Function @(
    'Invoke-AzVmRefreshSessionPath',
    'Resolve-AzVmWingetExe',
    'Get-AzVmStoreInstallStateRoot',
    'Get-AzVmStoreInstallStatePath',
    'Read-AzVmStoreInstallState',
    'Remove-AzVmStoreInstallState',
    'Write-AzVmStoreInstallState',
    'Write-AzVmStoreInstallStateStatusLine',
    'Test-AzVmRunOnceEntryPresent',
    'Remove-AzVmRunOnceEntry',
    'Test-AzVmStoreInstallNeedsInteractiveCompletion'
)
