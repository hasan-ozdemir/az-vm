<#
Script Filename: az-vm-win.ps1
Script Description    :
#>

param(
    [Alias('a','NonInteractive')]
    [switch]$Auto,
    [Alias('s')]
    [switch]$Step
)

$script:AutoMode = [bool]$Auto
$script:StepMode = [bool]$Step
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
- Diagnostic mode: step (--step / -s), Step 8 runs tasks one-by-one.
- Without --step, Step 8 runs the VM update script file in a single run-command call."
if (-not $script:AutoMode) {
    Read-Host -Prompt "Press Enter to start..."
}

$envFilePath = Join-Path $PSScriptRoot ".env"
$configMap = Read-DotEnvFile -Path $envFilePath

# 1) PARAMETERS / VARIABLES
Start-Transcript -Path "$PSScriptRoot\az-vm-win-log.txt" -Force
$script:TranscriptStarted = $true
Invoke-Step "Step 1/9 - initial parameters will be configured..." {
    $serverNameDefault = Get-ConfigValue -Config $configMap -Key "SERVER_NAME" -DefaultValue "examplevm"
    $serverName = $serverNameDefault
    do {
        if ($script:AutoMode) {
            $userInput = $serverNameDefault
        }
        else {
            $userInput = Read-Host "Enter server name (default=$serverNameDefault)"
        }

        if ([string]::IsNullOrWhiteSpace($userInput)) {
            $userInput = $serverNameDefault
        }

        if ($userInput -match '^[a-zA-Z][a-zA-Z0-9\-]{2,15}$') {
            $isValid = $true
        }
        else {
            Write-Host "Invalid VM name. Try again." -ForegroundColor Red
            $isValid = $false
        }
    } until ($isValid)

    $serverName = $userInput
    $script:ConfigOverrides["SERVER_NAME"] = $serverName
    if (-not $script:AutoMode) {
        Set-DotEnvValue -Path $envFilePath -Key "SERVER_NAME" -Value $serverName
    }
    Write-Host "Server name '$serverName' will be used." -ForegroundColor Green
    $resourceGroup = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "RESOURCE_GROUP" -DefaultValue "rg-{SERVER_NAME}") -ServerName $serverName
    $defaultAzLocation = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "AZ_LOCATION" -DefaultValue "austriaeast") -ServerName $serverName
    $VNET = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VNET_NAME" -DefaultValue "vnet-{SERVER_NAME}") -ServerName $serverName
    $SUBNET = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "SUBNET_NAME" -DefaultValue "subnet-{SERVER_NAME}") -ServerName $serverName
    $NSG = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "NSG_NAME" -DefaultValue "nsg-{SERVER_NAME}") -ServerName $serverName
    $nsgRule = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "NSG_RULE_NAME" -DefaultValue "nsg-rule-{SERVER_NAME}") -ServerName $serverName

    $IP = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "PUBLIC_IP_NAME" -DefaultValue "ip-{SERVER_NAME}") -ServerName $serverName
    $NIC = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "NIC_NAME" -DefaultValue "nic-{SERVER_NAME}") -ServerName $serverName
    $vmName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_NAME" -DefaultValue "{SERVER_NAME}") -ServerName $serverName
    $vmImage = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_IMAGE" -DefaultValue "MicrosoftWindowsDesktop:office-365:win11-25h2-avd-m365:latest") -ServerName $serverName
    $vmStorageSku = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_STORAGE_SKU" -DefaultValue "StandardSSD_LRS") -ServerName $serverName
    $defaultVmSize = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_SIZE" -DefaultValue "Standard_B2as_v2") -ServerName $serverName
    $azLocation = $defaultAzLocation
    $vmSize = $defaultVmSize
    if (-not $script:AutoMode) {
        $priceHours = Get-PriceHoursFromConfig -Config $configMap -DefaultHours 730
        $azLocation = Select-AzLocationInteractive -DefaultLocation $defaultAzLocation
        $vmSize = Select-VmSkuInteractive -Location $azLocation -DefaultVmSize $defaultVmSize -PriceHours $priceHours
        $script:ConfigOverrides["AZ_LOCATION"] = $azLocation
        $script:ConfigOverrides["VM_SIZE"] = $vmSize
        Set-DotEnvValue -Path $envFilePath -Key "AZ_LOCATION" -Value $azLocation
        Set-DotEnvValue -Path $envFilePath -Key "VM_SIZE" -Value $vmSize
        Write-Host "Interactive selection -> AZ_LOCATION='$azLocation', VM_SIZE='$vmSize'." -ForegroundColor Green
    }
    $vmDiskName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_DISK_NAME" -DefaultValue "disk-{SERVER_NAME}") -ServerName $serverName
    $vmDiskSize = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_DISK_SIZE_GB" -DefaultValue "128") -ServerName $serverName
    $vmUser = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_USER" -DefaultValue "manager") -ServerName $serverName
    $vmPass = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_PASS" -DefaultValue "<runtime-secret>") -ServerName $serverName
    $sshPort = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "SSH_PORT" -DefaultValue "444") -ServerName $serverName

    $vmInitScriptName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_INIT_SCRIPT_FILE" -DefaultValue "az-vm-win-init.ps1") -ServerName $serverName
    $vmUpdateScriptName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $configMap -Key "VM_UPDATE_SCRIPT_FILE" -DefaultValue "az-vm-win-update.ps1") -ServerName $serverName
    $vmInitScriptFile = Resolve-ConfigPath -PathValue $vmInitScriptName -RootPath $PSScriptRoot
    $vmUpdateScriptFile = Resolve-ConfigPath -PathValue $vmUpdateScriptName -RootPath $PSScriptRoot

    $defaultPortsCsv = "80,443,444,8444,3389,389,5173,3000,3001,8080,5432,3306,6837,4000,4001,5000,5001,6000,6001,6060,7000,7001,7070,8000,8001,9000,9001,9090,2222,3333,4444,5555,6666,7777,8888,9999,11434"
    $tcpPortsCsv = Get-ConfigValue -Config $configMap -Key "TCP_PORTS" -DefaultValue $defaultPortsCsv
    $tcpPorts = @($tcpPortsCsv -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })
    if (-not ($sshPort -match '^\d+$')) {
        throw "Invalid SSH port '$sshPort'."
    }
    if ($tcpPorts -notcontains $sshPort) {
        $tcpPorts += $sshPort
    }
    if (-not $tcpPorts -or $tcpPorts.Count -eq 0) {
        throw "No valid TCP ports were found in TCP_PORTS."
    }
}

# 2) Resource availability check:
Invoke-Step "Step 2/9 - region, image, and VM size availability will be checked..." {
    Assert-LocationExists -Location $azLocation
    Assert-VmImageAvailable -Location $azLocation -ImageUrn $vmImage
    Assert-VmSkuAvailableViaRest -Location $azLocation -VmSize $vmSize
    Assert-VmOsDiskSizeCompatible -Location $azLocation -ImageUrn $vmImage -VmDiskSizeGb $vmDiskSize
}

# 3) Resource group check:
Invoke-Step "Step 3/9 - resource group will be checked..." {
    Write-Host "'$resourceGroup'"
    $resourceExists = az group exists -n $resourceGroup
    Assert-LastExitCode "az group exists"
    if ($resourceExists -eq 'true') {
        if ($script:AutoMode) {
            Write-Host "Resource group '$resourceGroup' will be deleted (mode: auto)."
        }
        else {
            Write-Host "Resource group '$resourceGroup' will be deleted. Are you sure?"
        }
        az group delete -n $resourceGroup --yes --no-wait
        Assert-LastExitCode "az group delete"
        az group wait -n $resourceGroup --deleted
        Assert-LastExitCode "az group wait deleted"
    }
    Write-Host "Creating resource group '$resourceGroup'..."
    az group create -n $resourceGroup -l $azLocation
    Assert-LastExitCode "az group create"
}

# 4) Network components provisioning:
Invoke-Step "Step 4/9 - VNet, subnet, NSG, NSG rules, public IP, and NIC will be created..." {
    az network vnet create -g $resourceGroup -n $VNET --address-prefix 10.20.0.0/16 `
        --subnet-name $SUBNET --subnet-prefix 10.20.0.0/24 -o table
    Assert-LastExitCode "az network vnet create"
    az network nsg create -g $resourceGroup -n $NSG -o table
    Assert-LastExitCode "az network nsg create"

    $ports = $tcpPorts
    $priority = 101
    az network nsg rule create `
        -g $resourceGroup `
        --nsg-name $NSG `
        --name "$nsgRule" `
        --priority $priority `
        --direction Inbound `
        --protocol Tcp `
        --access Allow `
        --destination-port-ranges $ports `
        --source-address-prefixes "*" `
        --source-port-ranges "*" `
        -o table
    Assert-LastExitCode "az network nsg rule create"

    Write-Host "Creating public IP '$IP'..."
    az network public-ip create -g $resourceGroup -n $IP --allocation-method Static --sku Standard --dns-name $vmName -o table
    Assert-LastExitCode "az network public-ip create"

    Write-Host "Creating network NIC '$NIC'..."
    az network nic create -g $resourceGroup -n $NIC --vnet-name $VNET --subnet $SUBNET `
        --network-security-group $NSG `
        --public-ip-address $IP `
        -o table
    Assert-LastExitCode "az network nic create"
}

# 5) VM init PowerShell script preparation:
Invoke-Step "Step 5/9 - VM init PowerShell script will be prepared..." {
@'
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Write-Output "Init phase started."
Set-TimeZone -Id "UTC" -ErrorAction SilentlyContinue
Write-Output "Init phase completed."
'@ | Set-Content -Encoding UTF8 $vmInitScriptFile
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
$updateScript | Set-Content -Encoding UTF8 $vmUpdateScriptFile
}

# 7) Virtual machine creation:
Invoke-Step "Step 7/9 - virtual machine will be created..." {
    $existingVM = az vm list `
        --resource-group $resourceGroup `
        --query "[?name=='$vmName'].name | [0]" `
        -o tsv
    Assert-LastExitCode "az vm list"

    if ($existingVM) {
        Write-Output "VM '$vmName' exists in resource group '$resourceGroup' and will be deleted..."
        az vm delete --name $vmName --resource-group $resourceGroup --yes -o table
        Assert-LastExitCode "az vm delete"
        Write-Output "VM '$vmName' was deleted from resource group '$resourceGroup'."
    }
    else {
        Write-Output "VM '$vmName' is not present in resource group '$resourceGroup'. Creating..."
    }

    $vmCreateJson = az vm create `
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

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "az vm create returned a non-zero code; checking VM existence."
        $vmExistsAfterCreate = az vm show -g $resourceGroup -n $vmName --query "id" -o tsv 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($vmExistsAfterCreate)) {
            Write-Host "VM exists; details will be retrieved via az vm show -d."
            $vmCreateJson = az vm show -g $resourceGroup -n $vmName -d -o json
            Assert-LastExitCode "az vm show -d after vm create non-zero"
        }
        else {
            throw "az vm create failed with exit code $LASTEXITCODE."
        }
    }

    $vmCreateObj = $vmCreateJson | ConvertFrom-Json
    if (-not $vmCreateObj.id) {
        throw "az vm create completed but VM id was not returned."
    }

    Write-Host "Printing az vm create output..."
    Write-Host $vmCreateJson
}

# 8) VM init/update script execution:
Invoke-Step "Step 8/9 - VM init and update scripts will be executed..." {
    if (-not $script:StepMode) {
        Write-Host "Auto mode enabled: Step 8 tasks will run from the VM update script file."
        Invoke-VmRunCommandScriptFile `
            -ResourceGroup $resourceGroup `
            -VmName $vmName `
            -CommandId "RunPowerShellScript" `
            -ScriptFilePath $vmUpdateScriptFile `
            -ModeLabel "auto-mode update-script-file"
        return
    }

    Write-Host "Step mode enabled: Step 8 will execute tasks one-by-one."
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

    foreach ($taskBlock in $taskBlocks) {
        $taskBlock.Script = ([string]$taskBlock.Script).Replace("__VM_USER__", $vmUser).Replace("__VM_PASS__", $vmPass).Replace("__TCP_PORTS_PS_ARRAY__", $tcpPortsPsArray).Replace("__SSH_PORT__", $sshPort)
    }

    Invoke-VmRunCommandBlocks `
        -ResourceGroup $resourceGroup `
        -VmName $vmName `
        -CommandId "RunPowerShellScript" `
        -TaskBlocks $taskBlocks `
        -StepMode:$true `
        -CombinedShell "powershell"
}

# 9) VM connection details:
Invoke-Step "Step 9/9 - VM connection details will be printed..." {
    $vmDetailsJson = az vm show -g $resourceGroup -n $vmName -d -o json
    Assert-LastExitCode "az vm show -d"
    $vmDetails = $vmDetailsJson | ConvertFrom-Json
    if (-not $vmDetails) {
        throw "VM detail output could not be parsed."
    }

    $publicIP = $vmDetails.publicIps
    $vmFqdn = $vmDetails.fqdns
    if ([string]::IsNullOrWhiteSpace($vmFqdn)) {
        $vmFqdn = "$vmName.$azLocation.cloudapp.azure.com"
    }

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
    $errorMessage = $_.Exception.Message
    $summary = $script:DefaultErrorSummary
    $hint = $script:DefaultErrorHint
    $code = 99

    if ($_.Exception.Data -and $_.Exception.Data.Contains("ExitCode")) {
        $code = [int]$_.Exception.Data["ExitCode"]
        if ($_.Exception.Data.Contains("Summary")) {
            $summary = [string]$_.Exception.Data["Summary"]
        }
        if ($_.Exception.Data.Contains("Hint")) {
            $hint = [string]$_.Exception.Data["Hint"]
        }
    }
    elseif ($errorMessage -match "^VM size '(.+)' is available in region '(.+)' but not available for this subscription\.$") {
        $summary = "VM size exists in region but is not available for this subscription."
        $hint = "Choose another size in the same region or fix subscription quota/permissions."
        $code = 21
    }
    elseif ($errorMessage -match "^az group create failed with exit code") {
        $summary = "Resource group creation step failed."
        $hint = "Check region, policy, and subscription permissions."
        $code = 30
    }
    elseif ($errorMessage -match "^az vm create failed with exit code") {
        $summary = "VM creation step failed."
        $hint = "Check Step-2 precheck results, vmSize/image compatibility, and quota status."
        $code = 40
    }
    elseif ($errorMessage -match "^az vm run-command invoke") {
        $summary = "Configuration command inside VM failed."
        $hint = "Check VM running state and RunCommand availability."
        $code = 50
    }
    elseif ($errorMessage -match "^VM task '(.+)' failed:") {
        $summary = "A task failed in step mode."
        $hint = "Review the task name in the error detail and fix the related command."
        $code = 51
    }
    elseif ($errorMessage -match "^VM task batch execution failed") {
        $summary = "One or more tasks failed in auto mode."
        $hint = "Review the related task in the log file and fix the command."
        $code = 52
    }

    Write-Host ""
    Write-Host "Script exited gracefully." -ForegroundColor Yellow
    Write-Host "Reason: $summary" -ForegroundColor Red
    Write-Host "Detail: $errorMessage"
    Write-Host "Suggested action: $hint" -ForegroundColor Cyan
    $script:HadError = $true
    $script:ExitCode = $code
}
finally {
    if ($script:TranscriptStarted) {
        Stop-Transcript | Out-Null
        $script:TranscriptStarted = $false
    }
    if (-not $script:AutoMode) {
        pause
    }
}

if ($script:HadError) {
    exit $script:ExitCode
}





