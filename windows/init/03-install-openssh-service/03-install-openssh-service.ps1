$ErrorActionPreference = "Stop"
Write-Host "Init task started: install-openssh-service"

$openSshCapabilityName = 'OpenSSH.Server~~~~0.0.1.0'

function Get-OpenSshService {
    return (Get-Service sshd -ErrorAction SilentlyContinue)
}

function Get-OpenSshServiceExecutablePath {
    $openSshExecutableCandidates = @(
        'C:\Windows\System32\OpenSSH\sshd.exe',
        'C:\Program Files\OpenSSH-Win64\sshd.exe',
        'C:\Program Files\OpenSSH\sshd.exe'
    )

    return ($openSshExecutableCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
}

function Get-OpenSshKeyGenExecutablePath {
    $openSshKeyGenCandidates = @(
        'C:\Windows\System32\OpenSSH\ssh-keygen.exe',
        'C:\Program Files\OpenSSH-Win64\ssh-keygen.exe',
        'C:\Program Files\OpenSSH\ssh-keygen.exe'
    )

    return ($openSshKeyGenCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
}

function Get-OpenSshInstallScriptPath {
    $openSshInstallScriptCandidates = @(
        'C:\Windows\System32\OpenSSH\install-sshd.ps1',
        'C:\Program Files\OpenSSH-Win64\install-sshd.ps1',
        'C:\Program Files\OpenSSH\install-sshd.ps1'
    )

    return ($openSshInstallScriptCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
}

function Wait-OpenSshServiceRegistration {
    param([int]$TimeoutSeconds = 45)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $service = Get-OpenSshService
        if ($null -ne $service) {
            return $service
        }

        Start-Sleep -Seconds 1
    }

    return $null
}

function Get-OpenSshCapabilityState {
    param([string]$CapabilityName)

    if (-not (Get-Command Get-WindowsCapability -ErrorAction SilentlyContinue)) {
        return ''
    }

    try {
        $capability = Get-WindowsCapability -Online -Name $CapabilityName -ErrorAction Stop
        if ($null -ne $capability -and $capability.PSObject.Properties.Match('State').Count -gt 0) {
            return [string]$capability.State
        }
    }
    catch {
    }

    return ''
}

function Ensure-OpenSshHostKeyMaterial {
    $keyGenPath = Get-OpenSshKeyGenExecutablePath
    if ([string]::IsNullOrWhiteSpace([string]$keyGenPath)) {
        return
    }

    Write-Host ("Running OpenSSH host key generation: {0} -A" -f [string]$keyGenPath)
    & $keyGenPath -A
    if ($LASTEXITCODE -ne 0) {
        throw ("OpenSSH host key generation failed with exit code {0}." -f $LASTEXITCODE)
    }
}

function Install-OpenSshCapability {
    param([string]$CapabilityName)

    $capabilityState = Get-OpenSshCapabilityState -CapabilityName $CapabilityName
    if ($capabilityState -in @('Installed', 'InstallPending')) {
        Write-Host ("OpenSSH capability already present: {0}" -f $capabilityState)
        return ($capabilityState -eq 'InstallPending')
    }

    $rebootRequired = $false
    if (Get-Command Add-WindowsCapability -ErrorAction SilentlyContinue) {
        Write-Host ("Running: Add-WindowsCapability -Online -Name {0}" -f $CapabilityName)
        $result = Add-WindowsCapability -Online -Name $CapabilityName -ErrorAction Stop
        foreach ($propertyName in @('RestartNeeded', 'RebootRequired')) {
            if ($null -ne $result -and $result.PSObject.Properties.Match($propertyName).Count -gt 0 -and [bool]$result.$propertyName) {
                $rebootRequired = $true
            }
        }
    }
    else {
        Write-Host ("Running: dism.exe /online /add-capability /capabilityname:{0} /quiet /norestart" -f $CapabilityName)
        & dism.exe /online /add-capability "/capabilityname:$CapabilityName" /quiet /norestart
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
            throw ("OpenSSH capability installation failed with exit code {0}." -f $LASTEXITCODE)
        }

        if ($LASTEXITCODE -eq 3010) {
            $rebootRequired = $true
        }
    }

    $capabilityState = Get-OpenSshCapabilityState -CapabilityName $CapabilityName
    Write-Host ("openssh-capability-state => {0}" -f $(if ([string]::IsNullOrWhiteSpace([string]$capabilityState)) { 'unknown' } else { $capabilityState }))
    return ($rebootRequired -or ($capabilityState -eq 'InstallPending'))
}

function Repair-OpenSshServiceRegistration {
    $installScript = Get-OpenSshInstallScriptPath
    if (-not [string]::IsNullOrWhiteSpace([string]$installScript)) {
        Write-Host ("Running OpenSSH service installer: {0}" -f [string]$installScript)
        powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installScript
        if ($LASTEXITCODE -ne 0) {
            throw ("OpenSSH install-sshd.ps1 failed with exit code {0}." -f $LASTEXITCODE)
        }

        return (Wait-OpenSshServiceRegistration -TimeoutSeconds 30)
    }

    $sshdExecutablePath = Get-OpenSshServiceExecutablePath
    if ([string]::IsNullOrWhiteSpace([string]$sshdExecutablePath)) {
        return $null
    }

    Ensure-OpenSshHostKeyMaterial
    New-Item -Path 'C:\ProgramData\ssh' -ItemType Directory -Force | Out-Null

    $existingService = Get-OpenSshService
    if ($null -eq $existingService) {
        Write-Host ("Registering sshd service directly from executable: {0}" -f [string]$sshdExecutablePath)
        try {
            New-Service -Name 'sshd' -BinaryPathName ("`"{0}`"" -f [string]$sshdExecutablePath) -DisplayName 'OpenSSH SSH Server' -Description 'SSH protocol based service to provide secure encrypted communications between two untrusted hosts over an insecure network.' -StartupType Automatic | Out-Null
        }
        catch {
            if ($_.Exception.Message -notmatch '(?i)already exists') {
                throw
            }
        }
    }

    return (Wait-OpenSshServiceRegistration -TimeoutSeconds 30)
}

function Ensure-OpenSshServiceInstalled {
    $service = Get-OpenSshService
    if ($null -ne $service) {
        return [pscustomobject]@{
            Service = $service
            RebootRequired = $false
        }
    }

    $rebootRequired = Install-OpenSshCapability -CapabilityName $openSshCapabilityName
    $service = Wait-OpenSshServiceRegistration -TimeoutSeconds 45
    if ($null -ne $service) {
        return [pscustomobject]@{
            Service = $service
            RebootRequired = $rebootRequired
            PendingReason = ''
        }
    }

    $capabilityState = Get-OpenSshCapabilityState -CapabilityName $openSshCapabilityName
    $service = Repair-OpenSshServiceRegistration
    if ($null -ne $service) {
        return [pscustomobject]@{
            Service = $service
            RebootRequired = $rebootRequired
            PendingReason = ''
        }
    }

    if ($rebootRequired -or [string]::Equals([string]$capabilityState, 'InstallPending', [System.StringComparison]::OrdinalIgnoreCase)) {
        return [pscustomobject]@{
            Service = $null
            RebootRequired = $true
            PendingReason = ("capability-state={0}" -f $(if ([string]::IsNullOrWhiteSpace([string]$capabilityState)) { 'unknown' } else { [string]$capabilityState }))
        }
    }

    throw "OpenSSH setup completed but sshd service was not found."
}

$installResult = Ensure-OpenSshServiceInstalled
$sshdService = $installResult.Service
if ($null -eq $sshdService) {
    Write-Host ("openssh-service-pending-reboot: {0}" -f [string]$installResult.PendingReason)
    Write-Host "TASK_REBOOT_REQUIRED:install-openssh-service"
    Write-Host "openssh-ready"
    Write-Host "Init task completed: install-openssh-service"
    return
}

Set-Service -Name sshd -StartupType Automatic
if (Get-Service ssh-agent -ErrorAction SilentlyContinue) {
    Set-Service -Name ssh-agent -StartupType Automatic
}

Write-Host ("openssh-service-ready: status={0}; start-type={1}" -f [string]$sshdService.Status, [string]$sshdService.StartType)
if ([bool]$installResult.RebootRequired) {
    Write-Host "TASK_REBOOT_REQUIRED:install-openssh-service"
}
Write-Host "openssh-ready"
Write-Host "Init task completed: install-openssh-service"
