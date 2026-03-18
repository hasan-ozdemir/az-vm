$ErrorActionPreference = "Stop"
Write-Host "Init task started: install-openssh-service"

$openSshCapabilityName = 'OpenSSH.Server~~~~0.0.1.0'

function Get-OpenSshService {
    return (Get-Service sshd -ErrorAction SilentlyContinue)
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

function Ensure-OpenSshServiceInstalled {
    $service = Get-OpenSshService
    if ($null -ne $service) {
        return [pscustomobject]@{
            Service = $service
            RebootRequired = $false
        }
    }

    $rebootRequired = Install-OpenSshCapability -CapabilityName $openSshCapabilityName
    $service = Wait-OpenSshServiceRegistration -TimeoutSeconds 20
    if ($null -ne $service) {
        return [pscustomobject]@{
            Service = $service
            RebootRequired = $rebootRequired
        }
    }

    $installScript = Get-OpenSshInstallScriptPath
    if ([string]::IsNullOrWhiteSpace([string]$installScript)) {
        throw ("OpenSSH capability was installed, but sshd service registration is still missing and install-sshd.ps1 was not found. capability-state={0}" -f (Get-OpenSshCapabilityState -CapabilityName $openSshCapabilityName))
    }

    Write-Host ("Running OpenSSH service installer: {0}" -f $installScript)
    powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $installScript
    if ($LASTEXITCODE -ne 0) {
        throw ("OpenSSH install-sshd.ps1 failed with exit code {0}." -f $LASTEXITCODE)
    }

    $service = Wait-OpenSshServiceRegistration -TimeoutSeconds 30
    if ($null -eq $service) {
        throw "OpenSSH setup completed but sshd service was not found."
    }

    return [pscustomobject]@{
        Service = $service
        RebootRequired = $rebootRequired
    }
}

$installResult = Ensure-OpenSshServiceInstalled
$sshdService = $installResult.Service
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
