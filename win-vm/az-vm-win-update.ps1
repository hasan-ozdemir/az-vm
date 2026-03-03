$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$vmUser = "manager"
$vmPass = "<runtime-secret>"
$sshdConfig = "C:\ProgramData\ssh\sshd_config"

function Ensure-LocalAdminUser {
    param(
        [string]$UserName,
        [string]$Password
    )

    function Ensure-GroupMembership {
        param(
            [string]$GroupName,
            [string]$MemberName
        )

        $memberAliases = @(
            "$env:COMPUTERNAME\$MemberName",
            ".\$MemberName",
            $MemberName
        ) | ForEach-Object { $_.ToLowerInvariant() }

        $alreadyMember = $false
        try {
            $members = Get-LocalGroupMember -Group $GroupName -ErrorAction Stop
            foreach ($member in $members) {
                $memberName = [string]$member.Name
                if ($memberAliases -contains $memberName.ToLowerInvariant()) {
                    $alreadyMember = $true
                    break
                }
            }
        }
        catch {
            $groupOutput = net localgroup "$GroupName" 2>&1
            if ($LASTEXITCODE -eq 0) {
                $escapedMember = [regex]::Escape($MemberName)
                if ($groupOutput -match ("(?im)^\s*(?:.+\\)?{0}\s*$" -f $escapedMember)) {
                    $alreadyMember = $true
                }
            }
        }

        if ($alreadyMember) {
            Write-Output "User '$MemberName' is already in local group '$GroupName'."
            return
        }

        net localgroup "$GroupName" $MemberName /add | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Adding '$MemberName' to '$GroupName' failed with exit code $LASTEXITCODE."
        }
    }

    if (-not (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
        $securePass = ConvertTo-SecureString $Password -AsPlainText -Force
        New-LocalUser -Name $UserName -Password $securePass -PasswordNeverExpires -AccountNeverExpires -FullName $UserName -Description "Azure VM Power Admin user" | Out-Null
    }
    else {
        net user $UserName $Password | Out-Null
    }

    try {
        Set-LocalUser -Name $UserName -PasswordNeverExpires $true
    }
    catch {
        Write-Output "Set-LocalUser PasswordNeverExpires could not be set, continuing."
    }

    Ensure-GroupMembership -GroupName "Administrators" -MemberName $UserName
    Ensure-GroupMembership -GroupName "Remote Desktop Users" -MemberName $UserName
}

function Ensure-OpenSshServer {
    if (Get-Service sshd -ErrorAction SilentlyContinue) {
        Write-Output "OpenSSH: sshd is already installed."
        return
    }

    if (-not $script:ChocoExe) {
        Ensure-Chocolatey
    }

    & $script:ChocoExe upgrade openssh -y --no-progress | Out-Null
    $openSshExit = $LASTEXITCODE
    if ($openSshExit -ne 0 -and $openSshExit -ne 2) {
        throw "choco upgrade openssh failed with exit code $openSshExit."
    }

    Invoke-RefreshEnv

    if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
        foreach ($installScript in @(
            "C:\Program Files\OpenSSH-Win64\install-sshd.ps1",
            "C:\ProgramData\chocolatey\lib\openssh\tools\install-sshd.ps1"
        )) {
            if (Test-Path $installScript) {
                & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installScript | Out-Null
                break
            }
        }
    }

    if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
        throw "OpenSSH setup completed but sshd service was not found."
    }
}

function Set-OrAddConfigLine {
    param(
        [string]$Path,
        [string]$Key,
        [string]$Value
    )

    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType File -Force | Out-Null
    }

    $content = @(Get-Content -Path $Path -ErrorAction SilentlyContinue)
    $regex = "^\s*#?\s*" + [regex]::Escape($Key) + "\s+.*$"
    $replacement = "$Key $Value"
    $updated = $false

    for ($i = 0; $i -lt $content.Count; $i++) {
        if ($content[$i] -match $regex) {
            $content[$i] = $replacement
            $updated = $true
        }
    }

    if (-not $updated) {
        $content += $replacement
    }

    Set-Content -Path $Path -Value $content -Encoding ascii
}

function Enable-RdpCompatibility {
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 0
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "SecurityLayer" -Value 1
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "MinEncryptionLevel" -Value 2
    if (-not (Get-NetFirewallRule -DisplayName "Allow-TCP-3389" -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName "Allow-TCP-3389" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -RemoteAddress Any -Profile Any | Out-Null
    }
    Set-Service -Name TermService -StartupType Automatic
    sc.exe start TermService | Out-Null
    $svcWait = [System.Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Seconds 2
        $svc = Get-Service -Name TermService -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq "Running") { break }
    } while ($svcWait.Elapsed.TotalSeconds -lt 60)
    if (-not $svc -or $svc.Status -ne "Running") {
        throw "TermService did not reach Running state within 60 seconds."
    }
}

function Ensure-FirewallRules {
    $portRules = @(80,443,444,8444,3389,389,5173,3000,3001,8080,5432,3306,6837,4000,4001,5000,5001,6000,6001,6060,7000,7001,7070,8000,8001,9000,9001,9090,2222,3333,4444,5555,6666,7777,8888,9999,11434)
    foreach ($port in $portRules) {
        $name = "Allow-TCP-$port"
        if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress Any -Profile Any | Out-Null
        }
    }
}

function Invoke-RefreshEnv {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (-not (Test-Path $refreshEnvCmd)) {
        throw "refreshenv.cmd was not found: $refreshEnvCmd"
    }

    Write-Output "Calling refreshenv.cmd: $refreshEnvCmd"
    cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1"

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) {
        $env:Path = $machinePath
    }
    else {
        $env:Path = "$machinePath;$userPath"
    }
}

function Add-PathsToSystemPath {
    param(
        [string[]]$Paths
    )

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $existing = @()
    if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
        $existing = $machinePath -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }

    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $existing) {
        [void]$set.Add($item.TrimEnd('\'))
    }

    $added = $false
    foreach ($candidate in $Paths) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }

        $cleanPath = $candidate.Trim().TrimEnd('\')
        if ((Test-Path $cleanPath) -and -not $set.Contains($cleanPath)) {
            $existing += $cleanPath
            [void]$set.Add($cleanPath)
            $added = $true
            Write-Output "PATH added: $cleanPath"
        }
    }

    if ($added) {
        [Environment]::SetEnvironmentVariable("Path", ($existing -join ';'), "Machine")
    }
    else {
        Write-Output "PATH update was not required."
    }
}

function Get-CommandVersion {
    param(
        [string]$CommandName,
        [string]$VersionArgs = "--version"
    )

    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
    if (-not $cmd) {
        return $null
    }

    try {
        $out = & $cmd.Source $VersionArgs 2>&1 | Select-Object -First 1
        if ($out) {
            return "$CommandName => $out"
        }
        return "$CommandName => command-found"
    }
    catch {
        return $null
    }
}

function Assert-CommandAvailable {
    param(
        [string]$CommandName,
        [string]$VersionArgs,
        [string[]]$CandidatePaths
    )

    Invoke-RefreshEnv
    $versionInfo = Get-CommandVersion -CommandName $CommandName -VersionArgs $VersionArgs
    if ($versionInfo) {
        Write-Output $versionInfo
        return
    }

    Write-Output "$CommandName was not found in PATH; installation folders will be added to PATH."
    Add-PathsToSystemPath -Paths $CandidatePaths
    Invoke-RefreshEnv
    $versionInfo = Get-CommandVersion -CommandName $CommandName -VersionArgs $VersionArgs
    if (-not $versionInfo) {
        throw "$CommandName was installed but the command is still unavailable."
    }
    Write-Output $versionInfo
}

function Invoke-ChocoUpgrade {
    param(
        [string]$PackageName
    )

    & $script:ChocoExe upgrade $PackageName -y --no-progress | Out-Null
    $chocoExit = $LASTEXITCODE
    if ($chocoExit -ne 0 -and $chocoExit -ne 2) {
        throw "choco upgrade $PackageName failed with exit code $chocoExit."
    }
}

function Ensure-Chocolatey {
    $script:ChocoExe = $null

    if (Test-Path "$env:ProgramData\chocolatey\bin\choco.exe") {
        $script:ChocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    }
    elseif (Get-Command choco -ErrorAction SilentlyContinue) {
        $script:ChocoExe = (Get-Command choco).Source
    }
    else {
        Write-Output "choco was not found; starting unattended installation."
        Set-ExecutionPolicy Bypass -Scope Process -Force
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1"))
        $script:ChocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    }

    if (-not (Test-Path $script:ChocoExe)) {
        throw "choco setup could not be completed."
    }

    & $script:ChocoExe feature enable -n allowGlobalConfirmation | Out-Null
    & $script:ChocoExe feature enable -n useRememberedArgumentsForUpgrades | Out-Null
    & $script:ChocoExe feature enable -n useEnhancedExitCodes | Out-Null
    & $script:ChocoExe config set --name commandExecutionTimeoutSeconds --value 14400 | Out-Null
    & $script:ChocoExe config set --name cacheLocation --value "$env:ProgramData\chocolatey\cache" | Out-Null

    Invoke-RefreshEnv
    $chocoVersion = Get-CommandVersion -CommandName "choco" -VersionArgs "--version"
    if (-not $chocoVersion) {
        throw "choco was installed but the command is not reachable."
    }
    Write-Output $chocoVersion
}

function Ensure-CommonTools {
    if (-not $script:ChocoExe) {
        Ensure-Chocolatey
    }

    Invoke-ChocoUpgrade -PackageName "git"
    Assert-CommandAvailable -CommandName "git" -VersionArgs "--version" -CandidatePaths @(
        "C:\Program Files\Git\cmd",
        "C:\Program Files\Git\bin"
    )

    Invoke-ChocoUpgrade -PackageName "python312"
    Assert-CommandAvailable -CommandName "python" -VersionArgs "--version" -CandidatePaths @(
        "C:\Python312",
        "C:\Python312\Scripts"
    )

    Invoke-ChocoUpgrade -PackageName "nodejs-lts"
    Assert-CommandAvailable -CommandName "node" -VersionArgs "--version" -CandidatePaths @(
        "C:\Program Files\nodejs"
    )
}

function Show-AppPathChecks {
    Write-Output "APP PATH CHECKS:"
    foreach ($commandName in @("choco", "git", "node", "python", "py")) {
        $cmd = Get-Command $commandName -ErrorAction SilentlyContinue
        if ($cmd) {
            Write-Output "$commandName => $($cmd.Source)"
        }
        else {
            Write-Output "$commandName => not-found"
        }
    }
}

Ensure-Chocolatey
Ensure-LocalAdminUser -UserName $vmUser -Password $vmPass
Ensure-OpenSshServer

Set-OrAddConfigLine -Path $sshdConfig -Key "Port" -Value "444"
Set-OrAddConfigLine -Path $sshdConfig -Key "PasswordAuthentication" -Value "yes"
Set-OrAddConfigLine -Path $sshdConfig -Key "PubkeyAuthentication" -Value "no"
Set-OrAddConfigLine -Path $sshdConfig -Key "PermitEmptyPasswords" -Value "no"
Set-OrAddConfigLine -Path $sshdConfig -Key "AllowTcpForwarding" -Value "yes"
Set-OrAddConfigLine -Path $sshdConfig -Key "GatewayPorts" -Value "yes"

New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name "DefaultShell" -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

if (Get-Service ssh-agent -ErrorAction SilentlyContinue) {
    Set-Service -Name ssh-agent -StartupType Automatic
}
Set-Service -Name sshd -StartupType Automatic
Restart-Service -Name sshd -Force

if (-not (Get-NetFirewallRule -DisplayName "Allow-SSH-444" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow-SSH-444" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 444 -RemoteAddress Any -Profile Any | Out-Null
}

Enable-RdpCompatibility
Ensure-FirewallRules
Ensure-CommonTools
Invoke-RefreshEnv
Show-AppPathChecks

Write-Output "Version Info:"
Get-ComputerInfo | Select-Object WindowsProductName,WindowsVersion,OsBuildNumber | Format-List

Write-Output "OPEN Ports:"
Get-NetTCPConnection -LocalPort 3389,444 -State Listen | Select-Object LocalAddress,LocalPort,OwningProcess | Format-Table -AutoSize

Write-Output "Firewall STATUS:"
Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction | Format-Table -AutoSize

Write-Output "RDP STATUS:"
Get-Service TermService | Select-Object Name,Status,StartType | Format-List

Write-Output "SSHD STATUS:"
Get-Service sshd | Select-Object Name,Status,StartType | Format-List

Write-Output "SSHD CONFIG:"
Get-Content $sshdConfig | Select-String -Pattern "^(Port|PasswordAuthentication|PubkeyAuthentication|PermitEmptyPasswords|AllowTcpForwarding|GatewayPorts)" | ForEach-Object { $_.Line }
