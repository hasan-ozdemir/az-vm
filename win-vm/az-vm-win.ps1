<#
Script Filename: az-vm-win.ps1
Script Description    :
#>

param(
    [Alias('a','NonInteractive')]
    [switch]$Auto,
    [Alias('s')]
    [switch]$Substep
)

$script:AutoMode = [bool]$Auto
$script:SubstepMode = [bool]$Substep
$script:TranscriptStarted = $false
$script:HadError = $false
$script:ExitCode = 0
$script:ConfigOverrides = @{}

$script:DefaultErrorSummary = "An unexpected error occurred."
$script:DefaultErrorHint = "Review the error line and check script parameters and Azure connectivity."

$coVmRoot = Join-Path (Split-Path -Path $PSScriptRoot -Parent) "co-vm"
$coVmScripts = @(
    "az-vm-co-core.ps1",
    "az-vm-co-config.ps1",
    "az-vm-co-azure.ps1",
    "az-vm-co-orchestration.ps1",
    "az-vm-co-runcommand.ps1",
    "az-vm-co-sku-picker.ps1"
)
foreach ($coVmScript in $coVmScripts) {
    $coVmPath = Join-Path $coVmRoot $coVmScript
    if (-not (Test-Path -LiteralPath $coVmPath)) {
        throw "Required shared script was not found: $coVmPath"
    }
    . $coVmPath
}

try {
# 0) Start:
chcp 65001 | Out-Null
$Host.UI.RawUI.WindowTitle = "az vm win"
Write-Host "script filename: az-vm-win.ps1"
Write-Host "script description:
- A Windows 11 25H2 AVD M365 virtual machine is created.
- The virtual machine is configured with init + vm-update scripts.
- SSH (444) and RDP (3389) access are prepared.
- All command output is written to both console and 'az-vm-win-log.txt'.
- Run mode: interactive (default), auto (--auto / -a).
- Diagnostic mode: substep (--substep / -s), Step 8 runs tasks one-by-one.
- Without --substep, Step 8 runs the VM update script file in a single run-command call."
if (-not $script:AutoMode) {
    Read-Host -Prompt "Press Enter to start..."
}

$envFilePath = Join-Path $PSScriptRoot ".env"
$configMap = Read-DotEnvFile -Path $envFilePath

# 1) PARAMETERS / VARIABLES
Start-Transcript -Path "$PSScriptRoot\az-vm-win-log.txt" -Force
$script:TranscriptStarted = $true
Invoke-Step "Step 1/9 - initial parameters will be configured..." {
    $step1Context = Invoke-CoVmStep1Common `
        -ConfigMap $configMap `
        -EnvFilePath $envFilePath `
        -AutoMode:$script:AutoMode `
        -ScriptRoot $PSScriptRoot `
        -ServerNameDefault "examplevm" `
        -VmImageDefault "MicrosoftWindowsDesktop:office-365:win11-25h2-avd-m365:latest" `
        -VmDiskSizeDefault "128" `
        -VmInitConfigKey "VM_INIT_SCRIPT_FILE" `
        -VmInitDefault "az-vm-win-init.ps1" `
        -VmUpdateConfigKey "VM_UPDATE_SCRIPT_FILE" `
        -VmUpdateDefault "az-vm-win-update.ps1" `
        -ConfigOverrides $script:ConfigOverrides

    $serverName = [string]$step1Context.ServerName
    $resourceGroup = [string]$step1Context.ResourceGroup
    $defaultAzLocation = [string]$step1Context.DefaultAzLocation
    $VNET = [string]$step1Context.VNET
    $SUBNET = [string]$step1Context.SUBNET
    $NSG = [string]$step1Context.NSG
    $nsgRule = [string]$step1Context.NsgRule
    $IP = [string]$step1Context.IP
    $NIC = [string]$step1Context.NIC
    $vmName = [string]$step1Context.VmName
    $vmImage = [string]$step1Context.VmImage
    $vmStorageSku = [string]$step1Context.VmStorageSku
    $defaultVmSize = [string]$step1Context.DefaultVmSize
    $azLocation = [string]$step1Context.AzLocation
    $vmSize = [string]$step1Context.VmSize
    $vmDiskName = [string]$step1Context.VmDiskName
    $vmDiskSize = [string]$step1Context.VmDiskSize
    $vmUser = [string]$step1Context.VmUser
    $vmPass = [string]$step1Context.VmPass
    $sshPort = [string]$step1Context.SshPort
    $vmInitScriptFile = [string]$step1Context.VmInitScriptFile
    $vmUpdateScriptFile = [string]$step1Context.VmUpdateScriptFile
    $tcpPorts = @($step1Context.TcpPorts)
}

# 2) Resource availability check:
Invoke-Step "Step 2/9 - region, image, and VM size availability will be checked..." {
    Invoke-CoVmPrecheckStep -Context $step1Context
}

# 3) Resource group check:
Invoke-Step "Step 3/9 - resource group will be checked..." {
    Invoke-CoVmResourceGroupStep -Context $step1Context -AutoMode:$script:AutoMode
}

# 4) Network components provisioning:
Invoke-Step "Step 4/9 - VNet, subnet, NSG, NSG rules, public IP, and NIC will be created..." {
    Invoke-CoVmNetworkStep -Context $step1Context
}

# 5) VM init PowerShell script preparation:
Invoke-Step "Step 5/9 - VM init PowerShell script will be prepared..." {
$vmInitScript = @'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Output "Init phase started."
Set-TimeZone -Id "UTC" -ErrorAction SilentlyContinue
Write-Output "Init phase completed."
'@
Write-TextFileNormalized `
    -Path $vmInitScriptFile `
    -Content $vmInitScript `
    -Encoding "utf8NoBom" `
    -LineEnding "crlf" `
    -EnsureTrailingNewline
}

# 6) VM update PowerShell script preparation:
Invoke-Step "Step 6/9 - VM update PowerShell script will be prepared..." {
$tcpPortsPsArray = ($tcpPorts -join ",")
$updateTemplate = @'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$vmUser = "__VM_USER__"
$vmPass = "__VM_PASS__"
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
    $portRules = @(__TCP_PORTS_PS_ARRAY__)
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
        $machinePathLatest = [Environment]::GetEnvironmentVariable("Path", "Machine")
        $userPathLatest = [Environment]::GetEnvironmentVariable("Path", "User")
        if ([string]::IsNullOrWhiteSpace($userPathLatest)) {
            $env:Path = $machinePathLatest
        }
        else {
            $env:Path = "$machinePathLatest;$userPathLatest"
        }
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

    $versionInfo = Get-CommandVersion -CommandName $CommandName -VersionArgs $VersionArgs
    if ($versionInfo) {
        Write-Output $versionInfo
        return
    }

    Write-Output "$CommandName was not found in PATH; installation folders will be added to PATH."
    Add-PathsToSystemPath -Paths $CandidatePaths
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
    Invoke-RefreshEnv
    Assert-CommandAvailable -CommandName "git" -VersionArgs "--version" -CandidatePaths @(
        "C:\Program Files\Git\cmd",
        "C:\Program Files\Git\bin"
    )

    Invoke-ChocoUpgrade -PackageName "python312"
    Invoke-RefreshEnv
    Assert-CommandAvailable -CommandName "python" -VersionArgs "--version" -CandidatePaths @(
        "C:\Python312",
        "C:\Python312\Scripts"
    )

    Invoke-ChocoUpgrade -PackageName "nodejs-lts"
    Invoke-RefreshEnv
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

Set-OrAddConfigLine -Path $sshdConfig -Key "Port" -Value "__SSH_PORT__"
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

if (-not (Get-NetFirewallRule -DisplayName "Allow-SSH-__SSH_PORT__" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow-SSH-__SSH_PORT__" -Direction Inbound -Action Allow -Protocol TCP -LocalPort __SSH_PORT__ -RemoteAddress Any -Profile Any | Out-Null
}

Enable-RdpCompatibility
Ensure-FirewallRules
Ensure-CommonTools
Show-AppPathChecks

Write-Output "Version Info:"
Get-ComputerInfo | Select-Object WindowsProductName,WindowsVersion,OsBuildNumber | Format-List

Write-Output "OPEN Ports:"
Get-NetTCPConnection -LocalPort 3389,__SSH_PORT__ -State Listen | Select-Object LocalAddress,LocalPort,OwningProcess | Format-Table -AutoSize

Write-Output "Firewall STATUS:"
Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction | Format-Table -AutoSize

Write-Output "RDP STATUS:"
Get-Service TermService | Select-Object Name,Status,StartType | Format-List

Write-Output "SSHD STATUS:"
Get-Service sshd | Select-Object Name,Status,StartType | Format-List

Write-Output "SSHD CONFIG:"
Get-Content $sshdConfig | Select-String -Pattern "^(Port|PasswordAuthentication|PubkeyAuthentication|PermitEmptyPasswords|AllowTcpForwarding|GatewayPorts)" | ForEach-Object { $_.Line }
'@

$updateScript = $updateTemplate.Replace("__VM_USER__", $vmUser).Replace("__VM_PASS__", $vmPass).Replace("__TCP_PORTS_PS_ARRAY__", $tcpPortsPsArray).Replace("__SSH_PORT__", $sshPort)
Write-TextFileNormalized `
    -Path $vmUpdateScriptFile `
    -Content $updateScript `
    -Encoding "utf8NoBom" `
    -LineEnding "crlf" `
    -EnsureTrailingNewline
}

# 7) Virtual machine creation:
Invoke-Step "Step 7/9 - virtual machine will be created..." {
    Invoke-CoVmVmCreateStep `
        -Context $step1Context `
        -AutoMode:$script:AutoMode `
        -CreateVmAction {
            az vm create `
                --resource-group $resourceGroup `
                --name $vmName `
                --image $vmImage `
                --size $vmSize `
                --storage-sku $vmStorageSku `
                --os-disk-name $vmDiskName `
                --os-disk-size-gb $vmDiskSize `
                --admin-username $vmUser `
                --admin-password $vmPass `
                --authentication-type password `
                --nics $NIC `
                -o json
        }
}

# 8) VM init/update script execution:
Invoke-Step "Step 8/9 - VM init and update scripts will be executed..." {
    $tcpPortsPsArray = ($tcpPorts -join ",")
    $vmInitBody = Get-Content -Path $vmInitScriptFile -Raw
    $taskBlocks = @(
        @{
            Name = "00-init-script"
            Script = $vmInitBody
        },
        @{
            Name = "01-ensure-local-admin-user"
            Script = @'
$ErrorActionPreference = "Stop"
$vmUser = "__VM_USER__"
$vmPass = "__VM_PASS__"

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

if (-not (Get-LocalUser -Name $vmUser -ErrorAction SilentlyContinue)) {
    $securePass = ConvertTo-SecureString $vmPass -AsPlainText -Force
    New-LocalUser -Name $vmUser -Password $securePass -PasswordNeverExpires -AccountNeverExpires -FullName $vmUser -Description "Azure VM Power Admin user" | Out-Null
}
else {
    net user $vmUser $vmPass | Out-Null
}
Ensure-GroupMembership -GroupName "Administrators" -MemberName $vmUser
Ensure-GroupMembership -GroupName "Remote Desktop Users" -MemberName $vmUser
Write-Output "local-admin-user-ready"
'@
        },
        @{
            Name = "02-openssh-install-service"
            Script = @'
$ErrorActionPreference = "Stop"
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Test-Path $chocoExe)) {
        Set-ExecutionPolicy Bypass -Scope Process -Force
        Invoke-Expression ((New-Object System.Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1"))
    }
    $chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
    if (-not (Test-Path $chocoExe)) { throw "choco was not found." }
    & $chocoExe upgrade openssh -y --no-progress | Out-Null
    $openSshExit = $LASTEXITCODE
    if ($openSshExit -ne 0 -and $openSshExit -ne 2) { throw "choco upgrade openssh failed with exit code $openSshExit." }

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
}
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) { throw "OpenSSH setup completed but sshd service was not found." }
Set-Service -Name sshd -StartupType Automatic
if (Get-Service ssh-agent -ErrorAction SilentlyContinue) { Set-Service -Name ssh-agent -StartupType Automatic }
Write-Output "openssh-ready"
'@
        },
        @{
            Name = "03-sshd-config-port"
            Script = @'
$ErrorActionPreference = "Stop"
$sshdConfig = "C:\ProgramData\ssh\sshd_config"
if (-not (Test-Path $sshdConfig)) { New-Item -Path $sshdConfig -ItemType File -Force | Out-Null }
$content = @(Get-Content -Path $sshdConfig -ErrorAction SilentlyContinue)
function Set-OrAdd([string]$Key,[string]$Value) {
    $regex = "^\s*#?\s*" + [regex]::Escape($Key) + "\s+.*$"
    $replacement = "$Key $Value"
    $updated = $false
    for ($i = 0; $i -lt $content.Count; $i++) {
        if ($content[$i] -match $regex) {
            $content[$i] = $replacement
            $updated = $true
        }
    }
    if (-not $updated) { $script:content += $replacement }
}
Set-OrAdd -Key "Port" -Value "__SSH_PORT__"
Set-OrAdd -Key "PasswordAuthentication" -Value "yes"
Set-OrAdd -Key "PubkeyAuthentication" -Value "no"
Set-OrAdd -Key "PermitEmptyPasswords" -Value "no"
Set-OrAdd -Key "AllowTcpForwarding" -Value "yes"
Set-OrAdd -Key "GatewayPorts" -Value "yes"
Set-Content -Path $sshdConfig -Value $content -Encoding ascii
New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null
Set-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name "DefaultShell" -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
Restart-Service -Name sshd -Force
if (-not (Get-NetFirewallRule -DisplayName "Allow-SSH-__SSH_PORT__" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "Allow-SSH-__SSH_PORT__" -Direction Inbound -Action Allow -Protocol TCP -LocalPort __SSH_PORT__ -RemoteAddress Any -Profile Any | Out-Null
}
Write-Output "sshd-config-ready"
'@
        },
        @{
            Name = "04-rdp-firewall"
            Script = @'
$ErrorActionPreference = "Stop"
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
foreach ($port in @(__TCP_PORTS_PS_ARRAY__)) {
    $name = "Allow-TCP-$port"
    if (-not (Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $name -Direction Inbound -Action Allow -Protocol TCP -LocalPort $port -RemoteAddress Any -Profile Any | Out-Null
    }
}
Write-Output "rdp-firewall-ready"
'@
        },
        @{
            Name = "05-choco-bootstrap"
            Script = @'
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) {
    Set-ExecutionPolicy Bypass -Scope Process -Force
    Invoke-Expression ((New-Object System.Net.WebClient).DownloadString("https://community.chocolatey.org/install.ps1"))
}
$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) { throw "choco setup could not be completed." }
& $chocoExe feature enable -n allowGlobalConfirmation | Out-Null
& $chocoExe feature enable -n useRememberedArgumentsForUpgrades | Out-Null
& $chocoExe feature enable -n useEnhancedExitCodes | Out-Null
& $chocoExe config set --name commandExecutionTimeoutSeconds --value 14400 | Out-Null
& $chocoExe config set --name cacheLocation --value "$env:ProgramData\chocolatey\cache" | Out-Null
$refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
& $chocoExe --version
'@
        },
        @{
            Name = "06-git-install-check"
            Script = @'
$ErrorActionPreference = "Stop"
$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) { throw "choco was not found." }
& $chocoExe upgrade git -y --no-progress | Out-Null
$refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git command was not found." }
git --version
'@
        },
        @{
            Name = "07-python-install-check"
            Script = @'
$ErrorActionPreference = "Stop"
$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) { throw "choco was not found." }
& $chocoExe upgrade python312 -y --no-progress | Out-Null
$refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
if (-not (Get-Command python -ErrorAction SilentlyContinue)) { throw "python command was not found." }
python --version
'@
        },
        @{
            Name = "08-node-install-check"
            Script = @'
$ErrorActionPreference = "Stop"
$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) { throw "choco was not found." }
& $chocoExe upgrade nodejs-lts -y --no-progress | Out-Null
$refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw "node command was not found." }
node --version
'@
        },
        @{
            Name = "09-health-snapshot"
            Script = @'
$ErrorActionPreference = "Stop"
$sshdConfig = "C:\ProgramData\ssh\sshd_config"
Write-Output "OPEN Ports:"
Get-NetTCPConnection -LocalPort 3389,__SSH_PORT__ -State Listen | Select-Object LocalAddress,LocalPort,OwningProcess | Format-Table -AutoSize
Write-Output "Firewall STATUS:"
Get-NetFirewallProfile | Select-Object Name,Enabled,DefaultInboundAction,DefaultOutboundAction | Format-Table -AutoSize
Write-Output "RDP STATUS:"
Get-Service TermService | Select-Object Name,Status,StartType | Format-List
Write-Output "SSHD STATUS:"
Get-Service sshd | Select-Object Name,Status,StartType | Format-List
Write-Output "SSHD CONFIG:"
Get-Content $sshdConfig | Select-String -Pattern "^(Port|PasswordAuthentication|PubkeyAuthentication|PermitEmptyPasswords|AllowTcpForwarding|GatewayPorts)" | ForEach-Object { $_.Line }
'@
        }
    )

    $taskBlocks = Apply-CoVmTaskBlockReplacements `
        -TaskBlocks $taskBlocks `
        -Replacements @{
            VM_USER = $vmUser
            VM_PASS = $vmPass
            TCP_PORTS_PS_ARRAY = $tcpPortsPsArray
            SSH_PORT = $sshPort
        }

    Invoke-CoVmStep8RunCommand `
        -SubstepMode:$script:SubstepMode `
        -ResourceGroup $resourceGroup `
        -VmName $vmName `
        -CommandId "RunPowerShellScript" `
        -ScriptFilePath $vmUpdateScriptFile `
        -TaskBlocks $taskBlocks `
        -CombinedShell "powershell"
}

# 9) VM connection details:
Invoke-Step "Step 9/9 - VM connection details will be printed..." {
    $vmConnectionInfo = Get-CoVmVmDetails -Context $step1Context
    $publicIP = [string]$vmConnectionInfo.PublicIP
    $vmFqdn = [string]$vmConnectionInfo.VmFqdn

    Write-Host "VM Public IP Address:"
    Write-Host "$publicIP"
    Write-Host "SSH Connection Command:"
    Write-Host "ssh -p $sshPort $vmUser@$vmFqdn"
    Write-Host "RDP Connection Command:"
    Write-Host "mstsc /v:${vmFqdn}:3389"
    Write-Host "RDP Username:"
    Write-Host ".\$vmUser"
}

# End of setup:
Write-Host "All console output was saved to 'az-vm-win-log.txt'."
}
catch {
    $resolvedError = Resolve-CoVmFriendlyError `
        -ErrorRecord $_ `
        -DefaultErrorSummary $script:DefaultErrorSummary `
        -DefaultErrorHint $script:DefaultErrorHint

    Write-Host ""
    Write-Host "Script exited gracefully." -ForegroundColor Yellow
    Write-Host "Reason: $($resolvedError.Summary)" -ForegroundColor Red
    Write-Host "Detail: $($resolvedError.ErrorMessage)"
    Write-Host "Suggested action: $($resolvedError.Hint)" -ForegroundColor Cyan
    $script:HadError = $true
    $script:ExitCode = [int]$resolvedError.Code
}
finally {
    if ($script:TranscriptStarted) {
        Stop-Transcript | Out-Null
        $script:TranscriptStarted = $false
    }
    if (-not $script:AutoMode) {
        Read-Host -Prompt "Press Enter to exit." | Out-Null
    }
}

if ($script:HadError) {
    exit $script:ExitCode
}





