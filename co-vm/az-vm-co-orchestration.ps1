function Invoke-CoVmStep1Common {
    param(
        [hashtable]$ConfigMap,
        [string]$EnvFilePath,
        [switch]$AutoMode,
        [string]$ScriptRoot,
        [string]$ServerNameDefault,
        [string]$VmImageDefault,
        [string]$VmDiskSizeDefault,
        [string]$VmCloudInitConfigKey = "",
        [string]$VmCloudInitDefault = "",
        [string]$VmInitConfigKey = "",
        [string]$VmInitDefault = "",
        [string]$VmUpdateConfigKey,
        [string]$VmUpdateDefault,
        [hashtable]$ConfigOverrides
    )

    if ([string]::IsNullOrWhiteSpace($VmUpdateConfigKey)) {
        throw "VmUpdateConfigKey is required."
    }

    $serverNameDefaultResolved = Get-ConfigValue -Config $ConfigMap -Key "SERVER_NAME" -DefaultValue $ServerNameDefault
    $serverName = $serverNameDefaultResolved
    do {
        if ($AutoMode) {
            $userInput = $serverNameDefaultResolved
        }
        else {
            $userInput = Read-Host "Enter server name (default=$serverNameDefaultResolved)"
        }

        if ([string]::IsNullOrWhiteSpace($userInput)) {
            $userInput = $serverNameDefaultResolved
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
    if ($ConfigOverrides) {
        $ConfigOverrides["SERVER_NAME"] = $serverName
    }
    if (-not $AutoMode) {
        Set-DotEnvValue -Path $EnvFilePath -Key "SERVER_NAME" -Value $serverName
    }

    Write-Host "Server name '$serverName' will be used." -ForegroundColor Green

    $resourceGroup = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "RESOURCE_GROUP" -DefaultValue "rg-{SERVER_NAME}") -ServerName $serverName
    $defaultAzLocation = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "AZ_LOCATION" -DefaultValue "austriaeast") -ServerName $serverName
    $VNET = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VNET_NAME" -DefaultValue "vnet-{SERVER_NAME}") -ServerName $serverName
    $SUBNET = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "SUBNET_NAME" -DefaultValue "subnet-{SERVER_NAME}") -ServerName $serverName
    $NSG = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "NSG_NAME" -DefaultValue "nsg-{SERVER_NAME}") -ServerName $serverName
    $nsgRule = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "NSG_RULE_NAME" -DefaultValue "nsg-rule-{SERVER_NAME}") -ServerName $serverName

    $IP = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "PUBLIC_IP_NAME" -DefaultValue "ip-{SERVER_NAME}") -ServerName $serverName
    $NIC = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "NIC_NAME" -DefaultValue "nic-{SERVER_NAME}") -ServerName $serverName
    $vmName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_NAME" -DefaultValue "{SERVER_NAME}") -ServerName $serverName
    $vmImage = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_IMAGE" -DefaultValue $VmImageDefault) -ServerName $serverName
    $vmStorageSku = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_STORAGE_SKU" -DefaultValue "StandardSSD_LRS") -ServerName $serverName
    $defaultVmSize = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_SIZE" -DefaultValue "Standard_B2as_v2") -ServerName $serverName
    $azLocation = $defaultAzLocation
    $vmSize = $defaultVmSize
    if (-not $AutoMode) {
        $priceHours = Get-PriceHoursFromConfig -Config $ConfigMap -DefaultHours 730
        $azLocation = Select-AzLocationInteractive -DefaultLocation $defaultAzLocation
        $vmSize = Select-VmSkuInteractive -Location $azLocation -DefaultVmSize $defaultVmSize -PriceHours $priceHours
        if ($ConfigOverrides) {
            $ConfigOverrides["AZ_LOCATION"] = $azLocation
            $ConfigOverrides["VM_SIZE"] = $vmSize
        }

        Set-DotEnvValue -Path $EnvFilePath -Key "AZ_LOCATION" -Value $azLocation
        Set-DotEnvValue -Path $EnvFilePath -Key "VM_SIZE" -Value $vmSize
        Write-Host "Interactive selection -> AZ_LOCATION='$azLocation', VM_SIZE='$vmSize'." -ForegroundColor Green
    }

    $vmDiskName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_DISK_NAME" -DefaultValue "disk-{SERVER_NAME}") -ServerName $serverName
    $vmDiskSize = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_DISK_SIZE_GB" -DefaultValue $VmDiskSizeDefault) -ServerName $serverName
    $vmUser = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_USER" -DefaultValue "manager") -ServerName $serverName
    $vmPass = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_PASS" -DefaultValue "<runtime-secret>") -ServerName $serverName
    $vmAssistantUser = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_ASSISTANT_USER" -DefaultValue "assistant") -ServerName $serverName
    $vmAssistantPass = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "VM_ASSISTANT_PASS" -DefaultValue "<runtime-secret>") -ServerName $serverName
    $sshPort = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key "SSH_PORT" -DefaultValue "444") -ServerName $serverName

    $vmCloudInitScriptFile = $null
    if (-not [string]::IsNullOrWhiteSpace($VmCloudInitConfigKey)) {
        $vmCloudInitScriptName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key $VmCloudInitConfigKey -DefaultValue $VmCloudInitDefault) -ServerName $serverName
        $vmCloudInitScriptFile = Resolve-ConfigPath -PathValue $vmCloudInitScriptName -RootPath $ScriptRoot
    }

    $vmInitScriptFile = $null
    if (-not [string]::IsNullOrWhiteSpace($VmInitConfigKey)) {
        $vmInitScriptName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key $VmInitConfigKey -DefaultValue $VmInitDefault) -ServerName $serverName
        $vmInitScriptFile = Resolve-ConfigPath -PathValue $vmInitScriptName -RootPath $ScriptRoot
    }

    $vmUpdateScriptName = Resolve-ServerTemplate -Value (Get-ConfigValue -Config $ConfigMap -Key $VmUpdateConfigKey -DefaultValue $VmUpdateDefault) -ServerName $serverName
    $vmUpdateScriptFile = Resolve-ConfigPath -PathValue $vmUpdateScriptName -RootPath $ScriptRoot

    $defaultPortsCsv = "80,443,444,8444,3389,389,5173,3000,3001,8080,5432,3306,6837,4000,4001,5000,5001,6000,6001,6060,7000,7001,7070,8000,8001,9000,9001,9090,2222,3333,4444,5555,6666,7777,8888,9999,11434"
    $tcpPortsCsv = Get-ConfigValue -Config $ConfigMap -Key "TCP_PORTS" -DefaultValue $defaultPortsCsv
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

    return [ordered]@{
        ServerName = $serverName
        ResourceGroup = $resourceGroup
        AzLocation = $azLocation
        DefaultAzLocation = $defaultAzLocation
        VNET = $VNET
        SUBNET = $SUBNET
        NSG = $NSG
        NsgRule = $nsgRule
        IP = $IP
        NIC = $NIC
        VmName = $vmName
        VmImage = $vmImage
        VmStorageSku = $vmStorageSku
        VmSize = $vmSize
        DefaultVmSize = $defaultVmSize
        VmDiskName = $vmDiskName
        VmDiskSize = $vmDiskSize
        VmUser = $vmUser
        VmPass = $vmPass
        VmAssistantUser = $vmAssistantUser
        VmAssistantPass = $vmAssistantPass
        SshPort = $sshPort
        TcpPorts = @($tcpPorts)
        VmCloudInitScriptFile = $vmCloudInitScriptFile
        VmInitScriptFile = $vmInitScriptFile
        VmUpdateScriptFile = $vmUpdateScriptFile
    }
}

function Invoke-CoVmPrecheckStep {
    param(
        [hashtable]$Context
    )

    Assert-LocationExists -Location $Context.AzLocation
    Assert-VmImageAvailable -Location $Context.AzLocation -ImageUrn $Context.VmImage
    Assert-VmSkuAvailableViaRest -Location $Context.AzLocation -VmSize $Context.VmSize
    Assert-VmOsDiskSizeCompatible -Location $Context.AzLocation -ImageUrn $Context.VmImage -VmDiskSizeGb $Context.VmDiskSize
}

function Invoke-CoVmResourceGroupStep {
    param(
        [hashtable]$Context,
        [switch]$AutoMode
    )

    $resourceGroup = [string]$Context.ResourceGroup
    Write-Host "'$resourceGroup'"
    $resourceExists = az group exists -n $resourceGroup
    Assert-LastExitCode "az group exists"
    if ($resourceExists -eq 'true') {
        Write-Host "Resource group '$resourceGroup' will be deleted."
        $shouldDelete = $true
        if ($AutoMode) {
            Write-Host "Auto mode: deletion was confirmed automatically."
        }
        else {
            $shouldDelete = Confirm-YesNo -PromptText "Are you sure you want to delete resource group '$resourceGroup'?" -DefaultYes $false
        }

        if ($shouldDelete) {
            Invoke-TrackedAction -Label "az group delete -n $resourceGroup --yes --no-wait" -Action {
                az group delete -n $resourceGroup --yes --no-wait
                Assert-LastExitCode "az group delete"
            } | Out-Null
            Invoke-TrackedAction -Label "az group wait -n $resourceGroup --deleted" -Action {
                az group wait -n $resourceGroup --deleted
                Assert-LastExitCode "az group wait deleted"
            } | Out-Null
            Write-Host "Resource group '$resourceGroup' was deleted."
        }
        else {
            Write-Host "Resource group '$resourceGroup' was not deleted by user choice; continuing with existing resource group." -ForegroundColor Yellow
        }
    }

    Write-Host "Creating resource group '$resourceGroup'..."
    Invoke-TrackedAction -Label "az group create -n $resourceGroup -l $($Context.AzLocation)" -Action {
        az group create -n $resourceGroup -l $Context.AzLocation
        Assert-LastExitCode "az group create"
    } | Out-Null
}

function Invoke-CoVmNetworkStep {
    param(
        [hashtable]$Context
    )

    Invoke-TrackedAction -Label "az network vnet create -g $($Context.ResourceGroup) -n $($Context.VNET)" -Action {
        az network vnet create -g $Context.ResourceGroup -n $Context.VNET --address-prefix 10.20.0.0/16 `
            --subnet-name $Context.SUBNET --subnet-prefix 10.20.0.0/24 -o table
        Assert-LastExitCode "az network vnet create"
    } | Out-Null

    Invoke-TrackedAction -Label "az network nsg create -g $($Context.ResourceGroup) -n $($Context.NSG)" -Action {
        az network nsg create -g $Context.ResourceGroup -n $Context.NSG -o table
        Assert-LastExitCode "az network nsg create"
    } | Out-Null

    $priority = 101
    $ports = @($Context.TcpPorts)
    Invoke-TrackedAction -Label "az network nsg rule create -g $($Context.ResourceGroup) --nsg-name $($Context.NSG) --name $($Context.NsgRule)" -Action {
        az network nsg rule create `
            -g $Context.ResourceGroup `
            --nsg-name $Context.NSG `
            --name "$($Context.NsgRule)" `
            --priority $priority `
            --direction Inbound `
            --protocol Tcp `
            --access Allow `
            --destination-port-ranges $ports `
            --source-address-prefixes "*" `
            --source-port-ranges "*" `
            -o table
        Assert-LastExitCode "az network nsg rule create"
    } | Out-Null

    Write-Host "Creating public IP '$($Context.IP)'..."
    Invoke-TrackedAction -Label "az network public-ip create -g $($Context.ResourceGroup) -n $($Context.IP)" -Action {
        az network public-ip create -g $Context.ResourceGroup -n $Context.IP --allocation-method Static --sku Standard --dns-name $Context.VmName -o table
        Assert-LastExitCode "az network public-ip create"
    } | Out-Null

    Write-Host "Creating network NIC '$($Context.NIC)'..."
    Invoke-TrackedAction -Label "az network nic create -g $($Context.ResourceGroup) -n $($Context.NIC)" -Action {
        az network nic create -g $Context.ResourceGroup -n $Context.NIC --vnet-name $Context.VNET --subnet $Context.SUBNET `
            --network-security-group $Context.NSG `
            --public-ip-address $Context.IP `
            -o table
        Assert-LastExitCode "az network nic create"
    } | Out-Null
}

function Invoke-CoVmVmCreateStep {
    param(
        [hashtable]$Context,
        [switch]$AutoMode,
        [scriptblock]$CreateVmAction
    )

    if (-not $CreateVmAction) {
        throw "CreateVmAction is required."
    }

    $resourceGroup = [string]$Context.ResourceGroup
    $vmName = [string]$Context.VmName

    $existingVM = az vm list `
        --resource-group $resourceGroup `
        --query "[?name=='$vmName'].name | [0]" `
        -o tsv
    Assert-LastExitCode "az vm list"

    $shouldDeleteVm = $false
    if ($existingVM) {
        Write-Host "VM '$vmName' exists in resource group '$resourceGroup'."
        if ($AutoMode) {
            $shouldDeleteVm = $true
            Write-Host "Auto mode: VM deletion was confirmed automatically."
        }
        else {
            $shouldDeleteVm = Confirm-YesNo -PromptText "Are you sure you want to delete VM '$vmName'?" -DefaultYes $false
        }

        if ($shouldDeleteVm) {
            Write-Output "VM '$vmName' will be deleted..."
            Invoke-TrackedAction -Label "az vm delete --name $vmName --resource-group $resourceGroup --yes" -Action {
                az vm delete --name $vmName --resource-group $resourceGroup --yes -o table
                Assert-LastExitCode "az vm delete"
            } | Out-Null
            Write-Output "VM '$vmName' was deleted from resource group '$resourceGroup'."
        }
        else {
            Write-Host "VM '$vmName' was not deleted by user choice; continuing with az vm create on existing VM." -ForegroundColor Yellow
        }
    }
    else {
        Write-Output "VM '$vmName' is not present in resource group '$resourceGroup'. Creating..."
    }

    $vmCreateJson = Invoke-TrackedAction -Label "az vm create --resource-group $resourceGroup --name $vmName" -Action {
        $result = & $CreateVmAction
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "az vm create returned a non-zero code; checking VM existence."
            $vmExistsAfterCreate = az vm show -g $resourceGroup -n $vmName --query "id" -o tsv 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($vmExistsAfterCreate)) {
                Write-Host "VM exists; details will be retrieved via az vm show -d."
                $result = az vm show -g $resourceGroup -n $vmName -d -o json
                Assert-LastExitCode "az vm show -d after vm create non-zero"
            }
            else {
                throw "az vm create failed with exit code $LASTEXITCODE."
            }
        }

        $result
    }

    $vmCreateObj = ConvertFrom-JsonCompat -InputObject $vmCreateJson
    if (-not $vmCreateObj.id) {
        throw "az vm create completed but VM id was not returned."
    }

    Write-Host "Printing az vm create output..."
    Write-Host $vmCreateJson
}

function Get-CoVmVmDetails {
    param(
        [hashtable]$Context
    )

    $vmDetailsJson = Invoke-TrackedAction -Label "az vm show -g $($Context.ResourceGroup) -n $($Context.VmName) -d" -Action {
        $result = az vm show -g $Context.ResourceGroup -n $Context.VmName -d -o json
        Assert-LastExitCode "az vm show -d"
        $result
    }

    $vmDetails = ConvertFrom-JsonCompat -InputObject $vmDetailsJson
    if (-not $vmDetails) {
        throw "VM detail output could not be parsed."
    }

    $publicIP = $vmDetails.publicIps
    $vmFqdn = $vmDetails.fqdns
    if ([string]::IsNullOrWhiteSpace($vmFqdn)) {
        $vmFqdn = "$($Context.VmName).$($Context.AzLocation).cloudapp.azure.com"
    }

    return [ordered]@{
        VmDetails = $vmDetails
        PublicIP = $publicIP
        VmFqdn = $vmFqdn
    }
}

function Resolve-CoVmFriendlyError {
    param(
        [object]$ErrorRecord,
        [string]$DefaultErrorSummary,
        [string]$DefaultErrorHint
    )

    $errorMessage = [string]$ErrorRecord.Exception.Message
    $summary = $DefaultErrorSummary
    $hint = $DefaultErrorHint
    $code = 99

    if ($ErrorRecord.Exception.Data -and $ErrorRecord.Exception.Data.Contains("ExitCode")) {
        $code = [int]$ErrorRecord.Exception.Data["ExitCode"]
        if ($ErrorRecord.Exception.Data.Contains("Summary")) {
            $summary = [string]$ErrorRecord.Exception.Data["Summary"]
        }
        if ($ErrorRecord.Exception.Data.Contains("Hint")) {
            $hint = [string]$ErrorRecord.Exception.Data["Hint"]
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
        $summary = "A task failed in substep mode."
        $hint = "Review the task name in the error detail and fix the related command."
        $code = 51
    }
    elseif ($errorMessage -match "^VM task batch execution failed") {
        $summary = "One or more tasks failed in auto mode."
        $hint = "Review the related task in the log file and fix the command."
        $code = 52
    }

    return [ordered]@{
        ErrorMessage = $errorMessage
        Summary = $summary
        Hint = $hint
        Code = $code
    }
}
