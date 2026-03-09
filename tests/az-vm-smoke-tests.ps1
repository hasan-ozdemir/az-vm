param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$passCount = 0
$failCount = 0

function Invoke-Test {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    try {
        . $Action
        $script:passCount++
        Write-Host ("[PASS] {0}" -f $Name) -ForegroundColor Green
    }
    catch {
        $script:failCount++
        Write-Host ("[FAIL] {0}: {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
    }
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

$script:UnifiedScriptPath = Join-Path $RepoRoot "az-vm.ps1"
if (Test-Path -LiteralPath $script:UnifiedScriptPath) {
    . $script:UnifiedScriptPath
}

Invoke-Test -Name "Parse all .ps1 files" -Action {
    $ps1Files = Get-ChildItem -Path $RepoRoot -Recurse -Filter *.ps1 | Sort-Object FullName
    Assert-True -Condition ($ps1Files.Count -gt 0) -Message "No .ps1 files found."

    foreach ($file in $ps1Files) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            $firstError = $errors[0]
            throw ("Parse error in '{0}' at line {1}: {2}" -f $file.FullName, $firstError.Extent.StartLineNumber, $firstError.Message)
        }
    }
}

Invoke-Test -Name "Dot-source unified az-vm.ps1" -Action {
    Assert-True -Condition (Test-Path -LiteralPath $script:UnifiedScriptPath) -Message "az-vm.ps1 was not found."
    Assert-True -Condition ($null -ne (Get-Command Get-AzVmPlatformDefaults -ErrorAction SilentlyContinue)) -Message "Get-AzVmPlatformDefaults was not loaded."
    Assert-True -Condition ($null -ne (Get-Command Get-AzVmTaskBlocksFromDirectory -ErrorAction SilentlyContinue)) -Message "Get-AzVmTaskBlocksFromDirectory was not loaded."
}

Invoke-Test -Name "Platform defaults contract" -Action {
    $win = Get-AzVmPlatformDefaults -Platform windows
    $lin = Get-AzVmPlatformDefaults -Platform linux
    Assert-True -Condition ([string]$win.RunCommandId -eq "RunPowerShellScript") -Message "Windows RunCommandId mismatch."
    Assert-True -Condition ([string]$lin.RunCommandId -eq "RunShellScript") -Message "Linux RunCommandId mismatch."
    Assert-True -Condition ([bool]$win.IncludeRdp) -Message "Windows IncludeRdp should be true."
    Assert-True -Condition (-not [bool]$lin.IncludeRdp) -Message "Linux IncludeRdp should be false."
    Assert-True -Condition ([string]$win.VmSizeDefault -eq "Standard_B4as_v2") -Message "Windows VmSizeDefault mismatch."
    Assert-True -Condition ([string]$lin.VmSizeDefault -eq "Standard_B2as_v2") -Message "Linux VmSizeDefault mismatch."
}

Invoke-Test -Name "Azure location picker resolver contract" -Action {
    $catalog = @(
        [pscustomobject]@{ Name = "austriaeast"; DisplayName = "Austria East" },
        [pscustomobject]@{ Name = "centralindia"; DisplayName = "Central India" }
    )

    $entryWithLowercaseName = [pscustomobject]@{ name = "centralindia"; displayName = "Central India" }
    $resolvedFromLowercase = Resolve-AzVmLocationNameFromEntry -Entry $entryWithLowercaseName -Catalog $catalog -DefaultLocation ""
    Assert-True -Condition ([string]::Equals([string]$resolvedFromLowercase, "centralindia", [System.StringComparison]::OrdinalIgnoreCase)) -Message "Lowercase name location resolution failed."

    $entryWithOnlyDisplay = [pscustomobject]@{ Name = ""; DisplayName = "Austria East" }
    $resolvedFromDisplay = Resolve-AzVmLocationNameFromEntry -Entry $entryWithOnlyDisplay -Catalog $catalog -DefaultLocation ""
    Assert-True -Condition ([string]::Equals([string]$resolvedFromDisplay, "austriaeast", [System.StringComparison]::OrdinalIgnoreCase)) -Message "Display-name location resolution failed."

    $resolvedFromDefault = Resolve-AzVmLocationNameFromEntry -Entry $null -Catalog $catalog -DefaultLocation "centralindia"
    Assert-True -Condition ([string]::Equals([string]$resolvedFromDefault, "centralindia", [System.StringComparison]::OrdinalIgnoreCase)) -Message "Default location resolution failed."
}

Invoke-Test -Name "VM name format contract" -Action {
    Assert-True -Condition (Test-AzVmVmNameFormat -VmName "examplevm") -Message "Expected valid VM name to pass."
    Assert-True -Condition (Test-AzVmVmNameFormat -VmName "otherexamplevm-1") -Message "Expected valid VM name with hyphen to pass."
    Assert-True -Condition (-not (Test-AzVmVmNameFormat -VmName "1examplevm")) -Message "VM name starting with digit should fail."
    Assert-True -Condition (-not (Test-AzVmVmNameFormat -VmName "ab")) -Message "Too-short VM name should fail."
    Assert-True -Condition (-not (Test-AzVmVmNameFormat -VmName "examplevm_name")) -Message "VM name with underscore should fail."
}

Invoke-Test -Name "Managed resource naming contract" -Action {
    Assert-AzVmManagedResourceNamesValid -NameMap @{
        RESOURCE_GROUP = 'rg-examplevm-ate1-g1'
        VNET_NAME = 'net-examplevm-ate1-n1'
        SUBNET_NAME = 'subnet-examplevm-ate1-n1'
        NSG_NAME = 'nsg-examplevm-ate1-n1'
        NSG_RULE_NAME = 'nsgrule-examplevm-ate1-n1'
        PUBLIC_IP_NAME = 'ip-examplevm-ate1-n1'
        NIC_NAME = 'nic-examplevm-ate1-n1'
        VM_DISK_NAME = 'disk-examplevm-ate1-n1'
    }

    $invalidCases = @(
        @{ Key = 'RESOURCE_GROUP'; Value = 'rg-examplevm-ate1-g1.' },
        @{ Key = 'VNET_NAME'; Value = 'net examplevm' },
        @{ Key = 'NIC_NAME'; Value = 'nic/examplevm' }
    )
    foreach ($case in @($invalidCases)) {
        $threw = $false
        try {
            Assert-AzVmManagedResourceNamesValid -NameMap @{ ([string]$case.Key) = [string]$case.Value }
        }
        catch {
            $threw = $true
        }
        Assert-True -Condition $threw -Message ("Expected managed name validation to fail for {0}='{1}'." -f [string]$case.Key, [string]$case.Value)
    }
}

Invoke-Test -Name "Platform config precedence mapping" -Action {
    $legacyInitTaskDirKey = (@('VM','INIT','TASK','DIR') -join '_')
    $legacyUpdateTaskDirKey = (@('VM','UPDATE','TASK','DIR') -join '_')
    $platformOnlyConfig = @{
        VM_IMAGE = ""
        VM_SIZE = ""
        VM_DISK_SIZE_GB = ""
        WIN_VM_IMAGE = "win:image:latest"
        WIN_VM_SIZE = "Standard_B4as_v2"
        WIN_VM_DISK_SIZE_GB = "128"
        LIN_VM_IMAGE = "lin:image:latest"
        LIN_VM_SIZE = "Standard_B2as_v2"
        LIN_VM_DISK_SIZE_GB = "40"
    }

    $winMap = Resolve-AzVmPlatformConfigMap -ConfigMap $platformOnlyConfig -Platform windows
    $linMap = Resolve-AzVmPlatformConfigMap -ConfigMap $platformOnlyConfig -Platform linux

    Assert-True -Condition ([string]$winMap.VM_IMAGE -eq "win:image:latest") -Message "Windows VM_IMAGE platform mapping failed."
    Assert-True -Condition ([string]$winMap.VM_SIZE -eq "Standard_B4as_v2") -Message "Windows VM_SIZE platform mapping failed."
    Assert-True -Condition ([string]$winMap.VM_DISK_SIZE_GB -eq "128") -Message "Windows VM_DISK_SIZE_GB platform mapping failed."
    Assert-True -Condition ([string]$linMap.VM_IMAGE -eq "lin:image:latest") -Message "Linux VM_IMAGE platform mapping failed."
    Assert-True -Condition ([string]$linMap.VM_SIZE -eq "Standard_B2as_v2") -Message "Linux VM_SIZE platform mapping failed."
    Assert-True -Condition ([string]$linMap.VM_DISK_SIZE_GB -eq "40") -Message "Linux VM_DISK_SIZE_GB platform mapping failed."
    Assert-True -Condition (-not $winMap.ContainsKey($legacyInitTaskDirKey)) -Message "Legacy init task dir key should not be synthesized for windows."
    Assert-True -Condition (-not $winMap.ContainsKey($legacyUpdateTaskDirKey)) -Message "Legacy update task dir key should not be synthesized for windows."
    Assert-True -Condition (-not $linMap.ContainsKey($legacyInitTaskDirKey)) -Message "Legacy init task dir key should not be synthesized for linux."
    Assert-True -Condition (-not $linMap.ContainsKey($legacyUpdateTaskDirKey)) -Message "Legacy update task dir key should not be synthesized for linux."

    $genericFirstConfig = @{
        VM_IMAGE = "generic:image:latest"
        VM_SIZE = "Standard_D2as_v5"
        VM_DISK_SIZE_GB = "256"
        WIN_VM_IMAGE = "win:image:latest"
        WIN_VM_SIZE = "Standard_B4as_v2"
        WIN_VM_DISK_SIZE_GB = "128"
        LIN_VM_IMAGE = "lin:image:latest"
        LIN_VM_SIZE = "Standard_B2as_v2"
        LIN_VM_DISK_SIZE_GB = "40"
    }

    $genericWinMap = Resolve-AzVmPlatformConfigMap -ConfigMap $genericFirstConfig -Platform windows
    $genericLinMap = Resolve-AzVmPlatformConfigMap -ConfigMap $genericFirstConfig -Platform linux

    Assert-True -Condition ([string]$genericWinMap.VM_IMAGE -eq "generic:image:latest") -Message "Generic-first VM_IMAGE mapping failed on windows."
    Assert-True -Condition ([string]$genericWinMap.VM_SIZE -eq "Standard_D2as_v5") -Message "Generic-first VM_SIZE mapping failed on windows."
    Assert-True -Condition ([string]$genericWinMap.VM_DISK_SIZE_GB -eq "256") -Message "Generic-first VM_DISK_SIZE_GB mapping failed on windows."
    Assert-True -Condition ([string]$genericLinMap.VM_IMAGE -eq "generic:image:latest") -Message "Generic-first VM_IMAGE mapping failed on linux."
    Assert-True -Condition ([string]$genericLinMap.VM_SIZE -eq "Standard_D2as_v5") -Message "Generic-first VM_SIZE mapping failed on linux."
    Assert-True -Condition ([string]$genericLinMap.VM_DISK_SIZE_GB -eq "256") -Message "Generic-first VM_DISK_SIZE_GB mapping failed on linux."
    Assert-True -Condition (-not $genericWinMap.ContainsKey($legacyInitTaskDirKey)) -Message "Legacy init task dir key should remain unused on windows."
    Assert-True -Condition (-not $genericWinMap.ContainsKey($legacyUpdateTaskDirKey)) -Message "Legacy update task dir key should remain unused on windows."
    Assert-True -Condition (-not $genericLinMap.ContainsKey($legacyInitTaskDirKey)) -Message "Legacy init task dir key should remain unused on linux."
    Assert-True -Condition (-not $genericLinMap.ContainsKey($legacyUpdateTaskDirKey)) -Message "Legacy update task dir key should remain unused on linux."
}

Invoke-Test -Name "Platform task catalog keys stay platform-specific" -Action {
    $config = @{
        WIN_VM_INIT_TASK_DIR = "windows/init"
        WIN_VM_UPDATE_TASK_DIR = "windows/update"
        LIN_VM_INIT_TASK_DIR = "linux/init"
        LIN_VM_UPDATE_TASK_DIR = "linux/update"
    }

    $winInitKey = Get-AzVmPlatformTaskCatalogConfigKey -Platform windows -Stage 'init'
    $winUpdateKey = Get-AzVmPlatformTaskCatalogConfigKey -Platform windows -Stage 'update'
    $linInitKey = Get-AzVmPlatformTaskCatalogConfigKey -Platform linux -Stage 'init'
    $linUpdateKey = Get-AzVmPlatformTaskCatalogConfigKey -Platform linux -Stage 'update'

    Assert-True -Condition ([string]$winInitKey -eq 'WIN_VM_INIT_TASK_DIR') -Message "Windows init catalog key mapping failed."
    Assert-True -Condition ([string]$winUpdateKey -eq 'WIN_VM_UPDATE_TASK_DIR') -Message "Windows update catalog key mapping failed."
    Assert-True -Condition ([string]$linInitKey -eq 'LIN_VM_INIT_TASK_DIR') -Message "Linux init catalog key mapping failed."
    Assert-True -Condition ([string]$linUpdateKey -eq 'LIN_VM_UPDATE_TASK_DIR') -Message "Linux update catalog key mapping failed."
    Assert-True -Condition ([string](Get-ConfigValue -Config $config -Key $winInitKey -DefaultValue '') -eq 'windows/init') -Message "Windows init catalog path lookup failed."
    Assert-True -Condition ([string](Get-ConfigValue -Config $config -Key $winUpdateKey -DefaultValue '') -eq 'windows/update') -Message "Windows update catalog path lookup failed."
    Assert-True -Condition ([string](Get-ConfigValue -Config $config -Key $linInitKey -DefaultValue '') -eq 'linux/init') -Message "Linux init catalog path lookup failed."
    Assert-True -Condition ([string](Get-ConfigValue -Config $config -Key $linUpdateKey -DefaultValue '') -eq 'linux/update') -Message "Linux update catalog path lookup failed."
}

Invoke-Test -Name ".env.example runtime contract" -Action {
    $envExamplePath = Join-Path $RepoRoot '.env.example'
    Assert-True -Condition (Test-Path -LiteralPath $envExamplePath) -Message ".env.example was not found."

    $envExampleKeys = @(Get-Content $envExamplePath | Where-Object { $_ -match '^[A-Z0-9_]+=' } | ForEach-Object { ($_ -split '=', 2)[0] })
    $requiredKeys = @(
        'VM_OS_TYPE','VM_NAME','AZ_LOCATION',
        'RESOURCE_GROUP','VNET_NAME','SUBNET_NAME','NSG_NAME','NSG_RULE_NAME','PUBLIC_IP_NAME','NIC_NAME','VM_DISK_NAME',
        'RESOURCE_GROUP_TEMPLATE','VNET_NAME_TEMPLATE','SUBNET_NAME_TEMPLATE','NSG_NAME_TEMPLATE','NSG_RULE_NAME_TEMPLATE','PUBLIC_IP_NAME_TEMPLATE','NIC_NAME_TEMPLATE','VM_DISK_NAME_TEMPLATE',
        'VM_STORAGE_SKU','VM_SECURITY_TYPE','VM_ENABLE_SECURE_BOOT','VM_ENABLE_VTPM','PRICE_HOURS','VM_ADMIN_USER','VM_ADMIN_PASS','VM_ASSISTANT_USER','VM_ASSISTANT_PASS','VM_SSH_PORT','VM_RDP_PORT',
        'AZ_COMMAND_TIMEOUT_SECONDS','SSH_CONNECT_TIMEOUT_SECONDS','SSH_TASK_TIMEOUT_SECONDS',
        'WIN_VM_IMAGE','WIN_VM_SIZE','WIN_VM_DISK_SIZE_GB','LIN_VM_IMAGE','LIN_VM_SIZE','LIN_VM_DISK_SIZE_GB',
        'WIN_VM_INIT_TASK_DIR','WIN_VM_UPDATE_TASK_DIR','LIN_VM_INIT_TASK_DIR','LIN_VM_UPDATE_TASK_DIR',
        'VM_TASK_OUTCOME_MODE','SSH_MAX_RETRIES','PYSSH_CLIENT_PATH','TCP_PORTS'
    )

    foreach ($requiredKey in $requiredKeys) {
        Assert-True -Condition ($envExampleKeys -contains $requiredKey) -Message (".env.example is missing required key '{0}'." -f $requiredKey)
    }

    $legacyInitTaskDirKey = (@('VM','INIT','TASK','DIR') -join '_')
    $legacyUpdateTaskDirKey = (@('VM','UPDATE','TASK','DIR') -join '_')
    $legacySshPortKey = (@('SSH','PORT') -join '_')
    Assert-True -Condition (-not ($envExampleKeys -contains $legacyInitTaskDirKey)) -Message ".env.example must not contain the legacy generic init task dir key."
    Assert-True -Condition (-not ($envExampleKeys -contains $legacyUpdateTaskDirKey)) -Message ".env.example must not contain the legacy generic update task dir key."
    Assert-True -Condition (-not ($envExampleKeys -contains $legacySshPortKey)) -Message ".env.example must not contain the legacy SSH_PORT key."
}

Invoke-Test -Name "Task outcome mode is not platform-forced" -Action {
    $mainPath = Join-Path $RepoRoot 'modules\commands\azvm-command-main.ps1'
    $uiPath = Join-Path $RepoRoot 'modules\ui\azvm-ui-runtime.ps1'

    $mainText = Get-Content -LiteralPath $mainPath -Raw
    $uiText = Get-Content -LiteralPath $uiPath -Raw

    Assert-True -Condition ($mainText -notmatch "platform\s*-eq\s*'windows'[\s\S]{0,120}taskOutcomeMode\s*=\s*'strict'") -Message "Main command runtime must not force windows task outcome mode to strict."
    Assert-True -Condition ($uiText -notmatch "platform\s*-eq\s*'windows'[\s\S]{0,120}taskOutcomeMode\s*=\s*'strict'") -Message "UI runtime must not force windows task outcome mode to strict."

    $runCommandDefinition = Get-Command Invoke-VmRunCommandBlocks -CommandType Function
    Assert-True -Condition ($null -ne $runCommandDefinition) -Message "Run-command task runner function was not loaded."
    Assert-True -Condition ($runCommandDefinition.Parameters.ContainsKey('TaskOutcomeMode')) -Message "Run-command task runner must expose TaskOutcomeMode parameter."
}

Invoke-Test -Name "Create and update always execute vm-init stage" -Action {
    $mainPath = Join-Path $RepoRoot 'modules\commands\azvm-command-main.ps1'
    $mainText = Get-Content -LiteralPath $mainPath -Raw

    Assert-True -Condition ($mainText -notmatch [regex]::Escape('Default mode with existing VM: init tasks are skipped; proceeding directly to update tasks.')) -Message "Main command runtime must not skip vm-init for existing VMs in full create/update flow."
    Assert-True -Condition ($mainText -notmatch '\$shouldRunInitTasks\s*=') -Message "Main command runtime must not gate vm-init execution behind a should-run flag in full create/update flow."
}

Invoke-Test -Name "Task catalog discovery" -Action {
    $winInit = Get-AzVmTaskBlocksFromDirectory -DirectoryPath (Join-Path $RepoRoot "windows\init") -Platform windows -Stage init
    $winUpdate = Get-AzVmTaskBlocksFromDirectory -DirectoryPath (Join-Path $RepoRoot "windows\update") -Platform windows -Stage update
    $linInit = Get-AzVmTaskBlocksFromDirectory -DirectoryPath (Join-Path $RepoRoot "linux\init") -Platform linux -Stage init
    $linUpdate = Get-AzVmTaskBlocksFromDirectory -DirectoryPath (Join-Path $RepoRoot "linux\update") -Platform linux -Stage update

    Assert-True -Condition (@($winInit.ActiveTasks).Count -ge 1) -Message "Windows init active tasks are missing."
    Assert-True -Condition (@($winUpdate.ActiveTasks).Count -ge 1) -Message "Windows update active tasks are missing."
    Assert-True -Condition (@($linInit.ActiveTasks).Count -ge 1) -Message "Linux init active tasks are missing."
    Assert-True -Condition (@($linUpdate.ActiveTasks).Count -ge 1) -Message "Linux update active tasks are missing."

    foreach ($catalog in @($winInit, $winUpdate, $linInit, $linUpdate)) {
        foreach ($task in @($catalog.ActiveTasks)) {
            $hasTimeout = ($task.PSObject.Properties.Match('TimeoutSeconds').Count -gt 0)
            Assert-True -Condition $hasTimeout -Message ("Task '{0}' must expose TimeoutSeconds from catalog." -f [string]$task.Name)
            Assert-True -Condition ([int]$task.TimeoutSeconds -ge 5) -Message ("Task '{0}' has invalid TimeoutSeconds value '{1}'." -f [string]$task.Name, [string]$task.TimeoutSeconds)
        }
    }
}

Invoke-Test -Name "CLI parse help contracts" -Action {
    $parsedGlobalHelp = Parse-AzVmCliArguments -CommandToken "--help" -RawArgs @()
    Assert-True -Condition ([string]$parsedGlobalHelp.Command -eq "help") -Message "Global --help should resolve to help command."

    $parsedHelpTopic = Parse-AzVmCliArguments -CommandToken "help" -RawArgs @("create")
    Assert-True -Condition ([string]$parsedHelpTopic.Command -eq "help") -Message "help command parse failed."
    Assert-True -Condition ([string]$parsedHelpTopic.HelpTopic -eq "create") -Message "Help topic positional parse failed."

    $parsedDoTopic = Parse-AzVmCliArguments -CommandToken "help" -RawArgs @("do")
    Assert-True -Condition ([string]$parsedDoTopic.Command -eq "help") -Message "help do parse failed."
    Assert-True -Condition ([string]$parsedDoTopic.HelpTopic -eq "do") -Message "Help topic parse failed for do."

    $parsedCommandHelp = Parse-AzVmCliArguments -CommandToken "create" -RawArgs @("--help")
    Assert-True -Condition ([string]$parsedCommandHelp.Command -eq "create") -Message "Command with --help parse failed."
    Assert-True -Condition ($parsedCommandHelp.Options.ContainsKey("help")) -Message "Command --help option was not captured."

    $parsedConfigureHelp = Parse-AzVmCliArguments -CommandToken "configure" -RawArgs @("--help")
    Assert-True -Condition ([string]$parsedConfigureHelp.Command -eq "configure") -Message "Configure command with --help parse failed."

    $parsedSshHelp = Parse-AzVmCliArguments -CommandToken "ssh" -RawArgs @("--help")
    Assert-True -Condition ([string]$parsedSshHelp.Command -eq "ssh") -Message "SSH command with --help parse failed."

    $parsedRdpHelp = Parse-AzVmCliArguments -CommandToken "rdp" -RawArgs @("--help")
    Assert-True -Condition ([string]$parsedRdpHelp.Command -eq "rdp") -Message "RDP command with --help parse failed."

    $parsedDoHelp = Parse-AzVmCliArguments -CommandToken "do" -RawArgs @("--help")
    Assert-True -Condition ([string]$parsedDoHelp.Command -eq "do") -Message "Do command with --help parse failed."
    Assert-True -Condition ($parsedDoHelp.Options.ContainsKey("help")) -Message "Do command --help option was not captured."

    $parsedResizeHelp = Parse-AzVmCliArguments -CommandToken "resize" -RawArgs @("--help")
    Assert-True -Condition ([string]$parsedResizeHelp.Command -eq "resize") -Message "Resize command with --help parse failed."
    Assert-True -Condition ($parsedResizeHelp.Options.ContainsKey("help")) -Message "Resize command --help option was not captured."
}

Invoke-Test -Name "Task catalog fallback defaults" -Action {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("az-vm-catalog-test-" + [Guid]::NewGuid().ToString("N"))
    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    try {
        $task01 = Join-Path $tempRoot "01-default-fallback.ps1"
        $task02 = Join-Path $tempRoot "02-priority-override.ps1"
        Set-Content -Path $task01 -Value "Write-Host 'task01'" -Encoding UTF8
        Set-Content -Path $task02 -Value "Write-Host 'task02'" -Encoding UTF8

        $catalogPath = Join-Path $tempRoot "vm-init-task-catalog.json"
        $catalogJson = @'
{
  "defaults": {
    "priority": 1000,
    "timeout": 180
  },
  "tasks": [
    {
      "name": "02-priority-override",
      "priority": 5,
      "enabled": true
    }
  ]
}
'@
        Set-Content -Path $catalogPath -Value $catalogJson -Encoding UTF8

        $catalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath $tempRoot -Platform windows -Stage init
        $active = @($catalog.ActiveTasks)
        Assert-True -Condition ($active.Count -eq 2) -Message "Expected 2 active tasks."
        Assert-True -Condition ([string]$active[0].Name -eq "02-priority-override") -Message "Catalog priority override must be applied before filename order."
        Assert-True -Condition ([string]$active[1].Name -eq "01-default-fallback") -Message "Missing catalog entry must fall back to default priority."
        Assert-True -Condition ([int]$active[0].TimeoutSeconds -eq 180) -Message "Missing catalog timeout must default to 180."
        Assert-True -Condition ([int]$active[1].TimeoutSeconds -eq 180) -Message "Missing catalog entry timeout must default to 180."
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-Test -Name "CLI option assertions allow command help" -Action {
    Assert-AzVmCommandOptions -CommandName "create" -Options @{ help = $true }
    Assert-AzVmCommandOptions -CommandName "update" -Options @{ help = $true }
    Assert-AzVmCommandOptions -CommandName "configure" -Options @{ help = $true }
    Assert-AzVmCommandOptions -CommandName "show" -Options @{ help = $true }
    Assert-AzVmCommandOptions -CommandName "do" -Options @{ help = $true }
    Assert-AzVmCommandOptions -CommandName "move" -Options @{ help = $true }
    Assert-AzVmCommandOptions -CommandName "resize" -Options @{ help = $true }
    Assert-AzVmCommandOptions -CommandName "set" -Options @{ help = $true }
    Assert-AzVmCommandOptions -CommandName "exec" -Options @{ help = $true }
    Assert-AzVmCommandOptions -CommandName "ssh" -Options @{ help = $true }
    Assert-AzVmCommandOptions -CommandName "rdp" -Options @{ help = $true }
    Assert-AzVmCommandOptions -CommandName "delete" -Options @{ help = $true }
}

Invoke-Test -Name "Create and update accept vm-name override" -Action {
    Assert-AzVmCommandOptions -CommandName 'create' -Options @{ 'vm-name' = 'examplevm'; auto = $true }
    Assert-AzVmCommandOptions -CommandName 'update' -Options @{ 'vm-name' = 'examplevm'; auto = $true }
}

Invoke-Test -Name "Resize command accepts vm-name and platform flags" -Action {
    Assert-AzVmCommandOptions -CommandName 'resize' -Options @{ 'vm-name' = 'examplevm'; 'vm-size' = 'Standard_D4as_v5'; group = 'rg-examplevm-ate1-g1' }
    Assert-AzVmCommandOptions -CommandName 'resize' -Options @{ 'vm-name' = 'examplevm'; 'vm-size' = 'Standard_D2as_v5'; group = 'rg-examplevm-ate1-g1'; windows = $true }
    Assert-AzVmCommandOptions -CommandName 'resize' -Options @{ 'vm-name' = 'examplevm'; 'vm-size' = 'Standard_D2as_v5'; group = 'rg-examplevm-ate1-g1'; linux = $true }
}

Invoke-Test -Name "Exec command accepts vm-name for direct task targeting" -Action {
    Assert-AzVmCommandOptions -CommandName 'exec' -Options @{ 'init-task' = '01'; group = 'rg-examplevm-ate1-g1'; 'vm-name' = 'examplevm'; windows = $true }
    Assert-AzVmCommandOptions -CommandName 'exec' -Options @{ 'update-task' = '28'; group = 'rg-examplevm-ate1-g1'; 'vm-name' = 'examplevm'; windows = $true }
}

Invoke-Test -Name "Do command accepts vm-name and valid vm-action" -Action {
    Assert-AzVmCommandOptions -CommandName 'do' -Options @{ 'vm-name' = 'examplevm'; 'vm-action' = 'status' }
    Assert-AzVmCommandOptions -CommandName 'do' -Options @{ group = 'rg-examplevm-ate1-g1'; 'vm-name' = 'examplevm'; 'vm-action' = 'deallocate' }
    Assert-AzVmCommandOptions -CommandName 'do' -Options @{ group = 'rg-examplevm-ate1-g1'; 'vm-name' = 'examplevm'; 'vm-action' = 'hibernate' }
    Assert-AzVmCommandOptions -CommandName 'do' -Options @{ 'vm-action' = '' }
}

Invoke-Test -Name "Resize, Do, SSH, and RDP reject legacy vm option" -Action {
    foreach ($commandName in @('resize','do','ssh','rdp')) {
        $threw = $false
        try {
            Assert-AzVmCommandOptions -CommandName $commandName -Options @{ vm = 'examplevm' }
        }
        catch {
            $threw = $true
        }
        Assert-True -Condition $threw -Message ("Legacy --vm must be rejected for command '{0}'." -f $commandName)
    }
}

Invoke-Test -Name "Do command rejects retired or unknown power actions" -Action {
    foreach ($actionName in @('release','sleep')) {
        $threw = $false
        try {
            Assert-AzVmCommandOptions -CommandName 'do' -Options @{ 'vm-action' = $actionName }
        }
        catch {
            $threw = $true
        }
        Assert-True -Condition $threw -Message ("Do command must reject unsupported action '{0}'." -f $actionName)
    }
}

Invoke-Test -Name "Auto option scope contract" -Action {
    $invalidAutoCommands = @('configure','show','do','move','resize','set','exec','ssh','rdp','group','help')
    foreach ($commandName in $invalidAutoCommands) {
        $threw = $false
        try {
            Assert-AzVmCommandOptions -CommandName $commandName -Options @{ auto = $true }
        }
        catch {
            $threw = $true
        }
        Assert-True -Condition $threw -Message ("--auto must be rejected for command '{0}'." -f $commandName)
    }

    Assert-AzVmCommandOptions -CommandName 'create' -Options @{ auto = $true }
    Assert-AzVmCommandOptions -CommandName 'update' -Options @{ auto = $true }
    Assert-AzVmCommandOptions -CommandName 'delete' -Options @{ auto = $true; target = 'vm' }
}

Invoke-Test -Name "Resize direct request detection" -Action {
    Assert-True -Condition (Test-AzVmResizeDirectRequest -Options @{ group = 'rg-examplevm-ate1-g1'; 'vm-name' = 'examplevm'; 'vm-size' = 'Standard_D4as_v5' }) -Message "Fully specified resize request must be treated as direct."
    Assert-True -Condition (-not (Test-AzVmResizeDirectRequest -Options @{ group = 'rg-examplevm-ate1-g1'; 'vm-name' = 'examplevm' })) -Message "Resize request without vm-size must not be treated as direct."
    Assert-True -Condition (-not (Test-AzVmResizeDirectRequest -Options @{ group = 'rg-examplevm-ate1-g1'; vm = 'examplevm'; 'vm-size' = 'Standard_D4as_v5' })) -Message "Legacy vm option must not satisfy direct resize request detection."
}

Invoke-Test -Name "Help --command syntax was removed" -Action {
    $threw = $false
    try {
        Assert-AzVmCommandOptions -CommandName "help" -Options @{ command = "create" }
    }
    catch {
        $threw = $true
    }
    Assert-True -Condition $threw -Message "help --command must be rejected."
}

Invoke-Test -Name "Detailed help topic validation" -Action {
    Show-AzVmCommandHelp -Topic "create"
    Show-AzVmCommandHelp -Topic "configure"
    Show-AzVmCommandHelp -Topic "do"
    Show-AzVmCommandHelp -Topic "resize"
    Show-AzVmCommandHelp -Topic "ssh"
    Show-AzVmCommandHelp -Topic "rdp"
    Show-AzVmCommandHelp -Topic "show"
    Show-AzVmCommandHelp -Topic ""
    Show-AzVmCommandHelp -Overview
}

Invoke-Test -Name "Do lifecycle snapshot normalization" -Action {
    $vmObject = [pscustomobject]@{
        location = 'austriaeast'
        osType = 'Windows'
        hibernationEnabled = $true
    }

    $stoppedSnapshot = ConvertTo-AzVmVmLifecycleSnapshot `
        -ResourceGroup 'rg-examplevm-ate1-g1' `
        -VmName 'examplevm' `
        -VmObject $vmObject `
        -InstanceViewObject ([pscustomobject]@{
            instanceView = [pscustomobject]@{
                statuses = @(
                    [pscustomobject]@{ code = 'ProvisioningState/succeeded'; displayStatus = 'Provisioning succeeded' },
                    [pscustomobject]@{ code = 'PowerState/stopped'; displayStatus = 'VM stopped' }
                )
            }
        })
    Assert-True -Condition ([string]$stoppedSnapshot.NormalizedState -eq 'stopped') -Message "Stopped VM state normalization failed."

    $deallocatedSnapshot = ConvertTo-AzVmVmLifecycleSnapshot `
        -ResourceGroup 'rg-examplevm-ate1-g1' `
        -VmName 'examplevm' `
        -VmObject $vmObject `
        -InstanceViewObject ([pscustomobject]@{
            instanceView = [pscustomobject]@{
                statuses = @(
                    [pscustomobject]@{ code = 'ProvisioningState/succeeded'; displayStatus = 'Provisioning succeeded' },
                    [pscustomobject]@{ code = 'PowerState/deallocated'; displayStatus = 'VM deallocated' }
                )
            }
        })
    Assert-True -Condition ([string]$deallocatedSnapshot.NormalizedState -eq 'deallocated') -Message "Deallocated VM state normalization failed."

    $hibernatedSnapshot = ConvertTo-AzVmVmLifecycleSnapshot `
        -ResourceGroup 'rg-examplevm-ate1-g1' `
        -VmName 'examplevm' `
        -VmObject $vmObject `
        -InstanceViewObject ([pscustomobject]@{
            instanceView = [pscustomobject]@{
                statuses = @(
                    [pscustomobject]@{ code = 'ProvisioningState/succeeded'; displayStatus = 'Provisioning succeeded' },
                    [pscustomobject]@{ code = 'PowerState/deallocated'; displayStatus = 'VM deallocated' },
                    [pscustomobject]@{ code = 'HibernationState/hibernated'; displayStatus = 'Hibernated' }
                )
            }
        })
    Assert-True -Condition ([string]$hibernatedSnapshot.NormalizedState -eq 'hibernated') -Message "Hibernated VM state normalization failed."

    $otherSnapshot = ConvertTo-AzVmVmLifecycleSnapshot `
        -ResourceGroup 'rg-examplevm-ate1-g1' `
        -VmName 'examplevm' `
        -VmObject $vmObject `
        -InstanceViewObject ([pscustomobject]@{
            instanceView = [pscustomobject]@{
                statuses = @(
                    [pscustomobject]@{ code = 'ProvisioningState/succeeded'; displayStatus = 'Provisioning succeeded' },
                    [pscustomobject]@{ code = 'PowerState/starting'; displayStatus = 'VM starting' }
                )
            }
        })
    Assert-True -Condition ([string]$otherSnapshot.NormalizedState -eq 'other') -Message "Unknown VM state should normalize to other."
}

Invoke-Test -Name "Resize target size selection stays in current region" -Action {
    $script:ResizePickerCallCount = 0

    try {
        function global:Select-AzLocationInteractive {
            throw "Resize target size selection must not call region picker."
        }

        function global:Select-VmSkuInteractive {
            param(
                [string]$Location,
                [string]$DefaultVmSize,
                [int]$PriceHours
            )

            $script:ResizePickerCallCount++
            if ($script:ResizePickerCallCount -eq 1) {
                return (Get-AzVmSkuPickerRegionBackToken)
            }

            return 'Standard_D4as_v5'
        }

        $resolvedSize = Resolve-AzVmResizeTargetSize -Options @{} -CurrentRegion 'austriaeast' -CurrentSize 'Standard_D2as_v5' -ConfigMap @{ PRICE_HOURS = '730' }
        Assert-True -Condition ([string]$resolvedSize -eq 'Standard_D4as_v5') -Message "Resize interactive size selection returned unexpected value."
        Assert-True -Condition ($script:ResizePickerCallCount -eq 2) -Message "Resize interactive size selection should retry after back token without invoking region picker."
    }
    finally {
        Remove-Item Function:\global:Select-AzLocationInteractive -ErrorAction SilentlyContinue
        Remove-Item Function:\global:Select-VmSkuInteractive -ErrorAction SilentlyContinue
        Remove-Variable ResizePickerCallCount -Scope Script -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "Resize platform expectation" -Action {
    Assert-AzVmResizePlatformExpectation -ActualPlatform 'windows' -WindowsFlag -VmName 'examplevm' -ResourceGroup 'rg-examplevm-ate1-g1'
    Assert-AzVmResizePlatformExpectation -ActualPlatform 'linux' -LinuxFlag -VmName 'examplevm' -ResourceGroup 'rg-examplevm-ate1-g1'

    $invalidCases = @(
        @{ ActualPlatform = 'windows'; UseLinux = $true },
        @{ ActualPlatform = 'linux'; UseWindows = $true }
    )

    foreach ($case in @($invalidCases)) {
        $threw = $false
        try {
            Assert-AzVmResizePlatformExpectation `
                -ActualPlatform ([string]$case.ActualPlatform) `
                -WindowsFlag:([bool]$case.UseWindows) `
                -LinuxFlag:([bool]$case.UseLinux) `
                -VmName 'examplevm' `
                -ResourceGroup 'rg-examplevm-ate1-g1'
        }
        catch {
            $threw = $true
        }
        Assert-True -Condition $threw -Message ("Resize platform expectation should reject mismatched platform '{0}'." -f [string]$case.ActualPlatform)
    }
}

Invoke-Test -Name "Do action eligibility contract" -Action {
    function New-TestDoSnapshot {
        param(
            [string]$NormalizedState,
            [string]$PowerStateDisplay,
            [bool]$HibernationEnabled = $true,
            [string]$ProvisioningStateCode = 'ProvisioningState/succeeded',
            [string]$ProvisioningStateDisplay = 'Provisioning succeeded',
            [string]$HibernationStateDisplay = '',
            [string]$HibernationStateCode = ''
        )

        return [pscustomobject]@{
            ResourceGroup = 'rg-examplevm-ate1-g1'
            VmName = 'examplevm'
            NormalizedState = $NormalizedState
            PowerStateDisplay = $PowerStateDisplay
            PowerStateCode = ''
            HibernationEnabled = $HibernationEnabled
            ProvisioningStateCode = $ProvisioningStateCode
            ProvisioningStateDisplay = $ProvisioningStateDisplay
            HibernationStateDisplay = $HibernationStateDisplay
            HibernationStateCode = $HibernationStateCode
        }
    }

    Assert-AzVmDoActionAllowed -ActionName 'status' -Snapshot (New-TestDoSnapshot -NormalizedState 'other' -PowerStateDisplay 'VM starting')
    Assert-AzVmDoActionAllowed -ActionName 'restart' -Snapshot (New-TestDoSnapshot -NormalizedState 'started' -PowerStateDisplay 'VM running')
    Assert-AzVmDoActionAllowed -ActionName 'deallocate' -Snapshot (New-TestDoSnapshot -NormalizedState 'hibernated' -PowerStateDisplay 'VM deallocated' -HibernationStateDisplay 'Hibernated' -HibernationStateCode 'HibernationState/hibernated')
    Assert-AzVmDoActionAllowed -ActionName 'hibernate' -Snapshot (New-TestDoSnapshot -NormalizedState 'started' -PowerStateDisplay 'VM running')

    $invalidCases = @(
        @{ Action = 'start'; Snapshot = (New-TestDoSnapshot -NormalizedState 'started' -PowerStateDisplay 'VM running') },
        @{ Action = 'hibernate'; Snapshot = (New-TestDoSnapshot -NormalizedState 'started' -PowerStateDisplay 'VM running' -HibernationEnabled:$false) },
        @{ Action = 'stop'; Snapshot = (New-TestDoSnapshot -NormalizedState 'started' -PowerStateDisplay 'VM running' -ProvisioningStateCode 'ProvisioningState/updating' -ProvisioningStateDisplay 'Updating') }
    )

    foreach ($case in @($invalidCases)) {
        $threw = $false
        try {
            Assert-AzVmDoActionAllowed -ActionName ([string]$case.Action) -Snapshot $case.Snapshot
        }
        catch {
            $threw = $true
        }
        Assert-True -Condition $threw -Message ("Do action eligibility should reject invalid case '{0}'." -f [string]$case.Action)
    }
}

Invoke-Test -Name "Do interactive action selection" -Action {
    $snapshot = [pscustomobject]@{
        ResourceGroup = 'rg-examplevm-ate1-g1'
        VmName = 'examplevm'
        NormalizedState = 'stopped'
        PowerStateDisplay = 'VM stopped'
        PowerStateCode = 'PowerState/stopped'
        HibernationEnabled = $true
        ProvisioningStateCode = 'ProvisioningState/succeeded'
        ProvisioningStateDisplay = 'Provisioning succeeded'
        HibernationStateDisplay = ''
        HibernationStateCode = ''
    }

    try {
        function global:Read-Host { param([string]$Prompt) return '' }
        $defaultAction = Read-AzVmDoActionInteractive -Snapshot $snapshot
        Assert-True -Condition ([string]$defaultAction -eq 'status') -Message "Interactive do action default should be status."

        function global:Read-Host { param([string]$Prompt) return '5' }
        $pickedAction = Read-AzVmDoActionInteractive -Snapshot $snapshot
        Assert-True -Condition ([string]$pickedAction -eq 'deallocate') -Message "Interactive do action selection by number failed."

        function global:Read-Host { param([string]$Prompt) return '6' }
        $hibernateAction = Read-AzVmDoActionInteractive -Snapshot $snapshot
        Assert-True -Condition ([string]$hibernateAction -eq 'hibernate') -Message "Interactive do action selection must expose hibernate."
    }
    finally {
        Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue
        Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "Connection command running-state guard" -Action {
    function New-TestConnectionSnapshot {
        param(
            [string]$NormalizedState,
            [string]$PowerStateDisplay,
            [string]$HibernationStateDisplay = '',
            [string]$HibernationStateCode = ''
        )

        return [pscustomobject]@{
            ResourceGroup = 'rg-examplevm-ate1-g1'
            VmName = 'examplevm'
            NormalizedState = $NormalizedState
            PowerStateDisplay = $PowerStateDisplay
            PowerStateCode = ''
            HibernationEnabled = $true
            ProvisioningStateCode = 'ProvisioningState/succeeded'
            ProvisioningStateDisplay = 'Provisioning succeeded'
            HibernationStateDisplay = $HibernationStateDisplay
            HibernationStateCode = $HibernationStateCode
        }
    }

    Assert-AzVmConnectionVmRunning -OperationName 'ssh' -Snapshot (New-TestConnectionSnapshot -NormalizedState 'started' -PowerStateDisplay 'VM running')

    $invalidCases = @(
        @{ Operation = 'ssh'; Snapshot = (New-TestConnectionSnapshot -NormalizedState 'stopped' -PowerStateDisplay 'VM stopped') },
        @{ Operation = 'rdp'; Snapshot = (New-TestConnectionSnapshot -NormalizedState 'deallocated' -PowerStateDisplay 'VM deallocated') },
        @{ Operation = 'ssh'; Snapshot = (New-TestConnectionSnapshot -NormalizedState 'hibernated' -PowerStateDisplay 'VM deallocated' -HibernationStateDisplay 'Hibernated' -HibernationStateCode 'HibernationState/hibernated') }
    )

    foreach ($case in @($invalidCases)) {
        $threw = $false
        try {
            Assert-AzVmConnectionVmRunning -OperationName ([string]$case.Operation) -Snapshot $case.Snapshot
        }
        catch {
            $threw = $true
        }
        Assert-True -Condition $threw -Message ("Connection guard should reject non-running VM state for '{0}'." -f [string]$case.Operation)
    }
}

Invoke-Test -Name "Connection context checks VM state before credentials" -Action {
    $script:TestConnectionCredentialsCalled = $false
    try {
        function Test-AzVmLocalWindowsHost { return $true }
        function Get-AzVmRepoRoot { return $RepoRoot }
        function Read-DotEnvFile { param([string]$Path) return @{} }
        function Resolve-AzVmManagedVmTarget {
            param([hashtable]$Options, [hashtable]$ConfigMap, [string]$OperationName)
            return [pscustomobject]@{
                ResourceGroup = 'rg-examplevm-ate1-g1'
                VmName = 'examplevm'
            }
        }
        function Get-AzVmVmLifecycleSnapshot {
            param([string]$ResourceGroup, [string]$VmName)
            return [pscustomobject]@{
                ResourceGroup = $ResourceGroup
                VmName = $VmName
                OsType = 'Windows'
                Location = 'austriaeast'
                HibernationEnabled = $true
                ProvisioningStateCode = 'ProvisioningState/succeeded'
                ProvisioningStateDisplay = 'Provisioning succeeded'
                PowerStateCode = 'PowerState/stopped'
                PowerStateDisplay = 'VM stopped'
                HibernationStateCode = ''
                HibernationStateDisplay = ''
                NormalizedState = 'stopped'
            }
        }
        function Resolve-AzVmConnectionPortText { param([hashtable]$ConfigMap, [string]$Key, [string]$DefaultValue, [string]$Label) return [string]$DefaultValue }
        function Resolve-AzVmConnectionRoleName { param([hashtable]$Options) return 'manager' }
        function Resolve-AzVmConnectionCredentials {
            param([string]$RoleName, [hashtable]$ConfigMap, [string]$EnvFilePath)
            $script:TestConnectionCredentialsCalled = $true
            return [pscustomobject]@{
                Role = 'manager'
                UserName = 'manager'
                Password = 'secret'
            }
        }
        function Get-AzVmVmDetails { throw 'Get-AzVmVmDetails should not run when the VM is not running.' }

        $threw = $false
        try {
            Initialize-AzVmConnectionCommandContext -Options @{} -OperationName 'ssh' | Out-Null
        }
        catch {
            $threw = $true
        }

        Assert-True -Condition $threw -Message "Connection context should stop when the VM is not running."
        Assert-True -Condition (-not $script:TestConnectionCredentialsCalled) -Message "Connection context must reject non-running VMs before credential resolution."
    }
    finally {
        foreach ($functionName in @(
            'Test-AzVmLocalWindowsHost',
            'Get-AzVmRepoRoot',
            'Read-DotEnvFile',
            'Resolve-AzVmManagedVmTarget',
            'Get-AzVmVmLifecycleSnapshot',
            'Resolve-AzVmConnectionPortText',
            'Resolve-AzVmConnectionRoleName',
            'Resolve-AzVmConnectionCredentials',
            'Get-AzVmVmDetails'
        )) {
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name TestConnectionCredentialsCalled -Scope Script -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "Persistent SSH protocol normalizes spinner-prefixed markers" -Action {
    $normalizedEnd = Normalize-AzVmProtocolLine -Text '   / AZ_VM_TASK_END:24-install-microsoft-teams:4294967295'
    Assert-True -Condition ([string]$normalizedEnd -eq 'AZ_VM_TASK_END:24-install-microsoft-teams:4294967295') -Message 'Spinner-prefixed task end markers must normalize back to the protocol marker.'

    $normalizedError = Normalize-AzVmProtocolLine -Text '  - [stderr] AZ_VM_SESSION_TASK_ERROR:24-install-microsoft-teams:example'
    Assert-True -Condition ([string]$normalizedError -eq '[stderr] AZ_VM_SESSION_TASK_ERROR:24-install-microsoft-teams:example') -Message 'Spinner-prefixed stderr session markers must normalize back to the protocol marker.'

    Assert-True -Condition ((Convert-AzVmProtocolTaskExitCode -Text '0') -eq 0) -Message 'Task exit code parser must keep zero as zero.'
    Assert-True -Condition ((Convert-AzVmProtocolTaskExitCode -Text '4294967295') -eq -1) -Message 'Task exit code parser must normalize unsigned 32-bit -1 markers back to -1.'
}

Invoke-Test -Name "Exec command avoids full step1 context resolution" -Action {
    $script:ExecMinimalRuntimeUsed = $false
    $script:ExecRunCommandInvocation = $null
    try {
        function Initialize-AzVmCommandRuntimeContext { throw 'Full Step-1 runtime context must not be used by exec.' }
        function Initialize-AzVmExecCommandRuntimeContext {
            param([switch]$AutoMode, [switch]$WindowsFlag, [switch]$LinuxFlag)
            $script:ExecMinimalRuntimeUsed = $true
            return [pscustomobject]@{
                EnvFilePath = (Join-Path $RepoRoot '.env')
                ConfigMap = @{ RESOURCE_GROUP = 'rg-examplevm-ate1-g1'; VM_NAME = 'examplevm' }
                EffectiveConfigMap = @{ RESOURCE_GROUP = 'rg-examplevm-ate1-g1'; VM_NAME = 'examplevm' }
                Platform = 'windows'
                PlatformDefaults = [pscustomobject]@{ RunCommandId = 'RunPowerShellScript' }
                Context = [ordered]@{
                    ResourceGroup = 'rg-examplevm-ate1-g1'
                    VmName = 'examplevm'
                    VmInitTaskDir = 'windows/init'
                    VmUpdateTaskDir = 'windows/update'
                    VmUser = 'manager'
                    VmPass = 'secret'
                    VmAssistantUser = 'assistant'
                    VmAssistantPass = 'secret2'
                    SshPort = '444'
                    RdpPort = '3389'
                    TcpPorts = @('444','3389')
                    AzLocation = 'austriaeast'
                    VmSize = 'Standard_D2as_v5'
                    VmImage = 'example:image:urn'
                    VmDiskName = 'disk-examplevm'
                    VmDiskSize = '128'
                    VmStorageSku = 'StandardSSD_LRS'
                }
                TaskOutcomeMode = 'continue'
                ConfiguredPySshClientPath = ''
                SshTaskTimeoutSeconds = 180
                SshConnectTimeoutSeconds = 30
            }
        }
        function Resolve-AzVmManagedVmTarget {
            param([hashtable]$Options, [hashtable]$ConfigMap, [string]$OperationName)
            return [pscustomobject]@{
                ResourceGroup = 'rg-examplevm-ate1-g1'
                VmName = 'examplevm'
            }
        }
        function Get-AzVmTaskBlocksFromDirectory {
            param([string]$DirectoryPath, [string]$Platform, [string]$Stage)
            return [pscustomobject]@{
                ActiveTasks = @(
                    [pscustomobject]@{
                        Name = '01-ensure-local-admin-users'
                        Script = 'Write-Host ok'
                        TimeoutSeconds = 180
                    }
                )
            }
        }
        function Resolve-AzVmRuntimeTaskBlocks {
            param([object[]]$TemplateTaskBlocks, [hashtable]$Context)
            return @($TemplateTaskBlocks)
        }
        function Resolve-AzVmTaskSelection {
            param([object[]]$TaskBlocks, [string]$TaskNumberOrName, [string]$Stage, [switch]$AutoMode)
            return @($TaskBlocks)[0]
        }
        function Invoke-VmRunCommandBlocks {
            param(
                [string]$ResourceGroup,
                [string]$VmName,
                [string]$CommandId,
                [object[]]$TaskBlocks,
                [string]$CombinedShell,
                [string]$TaskOutcomeMode,
                [string]$PerfTaskCategory
            )

            $script:ExecRunCommandInvocation = [pscustomobject]@{
                ResourceGroup = $ResourceGroup
                VmName = $VmName
                CommandId = $CommandId
                CombinedShell = $CombinedShell
                TaskOutcomeMode = $TaskOutcomeMode
                PerfTaskCategory = $PerfTaskCategory
                TaskName = [string]@($TaskBlocks)[0].Name
            }
        }

        Invoke-AzVmExecCommand -Options @{ 'init-task' = '01' } -AutoMode:$false -WindowsFlag -LinuxFlag:$false

        Assert-True -Condition $script:ExecMinimalRuntimeUsed -Message 'Exec command must use the minimal exec runtime context.'
        Assert-True -Condition ($null -ne $script:ExecRunCommandInvocation) -Message 'Exec init task must invoke run-command blocks.'
        Assert-True -Condition ([string]$script:ExecRunCommandInvocation.ResourceGroup -eq 'rg-examplevm-ate1-g1') -Message 'Exec init task must preserve target resource group.'
        Assert-True -Condition ([string]$script:ExecRunCommandInvocation.VmName -eq 'examplevm') -Message 'Exec init task must preserve target VM name.'
        Assert-True -Condition ([string]$script:ExecRunCommandInvocation.CommandId -eq 'RunPowerShellScript') -Message 'Exec init task must preserve platform run-command id.'
        Assert-True -Condition ([string]$script:ExecRunCommandInvocation.TaskName -eq '01-ensure-local-admin-users') -Message 'Exec init task must preserve selected task.'
    }
    finally {
        foreach ($functionName in @(
            'Initialize-AzVmCommandRuntimeContext',
            'Initialize-AzVmExecCommandRuntimeContext',
            'Resolve-AzVmManagedVmTarget',
            'Get-AzVmTaskBlocksFromDirectory',
            'Resolve-AzVmRuntimeTaskBlocks',
            'Resolve-AzVmTaskSelection',
            'Invoke-VmRunCommandBlocks'
        )) {
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name ExecMinimalRuntimeUsed -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name ExecRunCommandInvocation -Scope Script -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "Task token replacement" -Action {
    $context = [ordered]@{
        VmUser = "manager"
        VmPass = "secret"
        VmAssistantUser = "assistant"
        VmAssistantPass = "secret2"
        SshPort = "444"
        RdpPort = "3389"
        TcpPorts = @("444","3389","11434")
        ResourceGroup = "rg-examplevm"
        VmName = "examplevm"
        AzLocation = "austriaeast"
        VmSize = "Standard_B2as_v2"
        VmImage = "example:image:urn"
        VmDiskName = "disk-examplevm"
        VmDiskSize = "128"
        VmStorageSku = "StandardSSD_LRS"
        HostStartupProfileJsonBase64 = "W10="
    }

    $templates = @(
        [pscustomobject]@{ Name = "01-test"; Script = "echo __VM_ADMIN_USER__ __SSH_PORT__ __RDP_PORT__ __VM_NAME__ __TCP_PORTS_BASH__ __HOST_STARTUP_PROFILE_JSON_B64__" }
    )

    $resolved = Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks $templates -Context $context
    $scriptBody = [string]$resolved[0].Script
    Assert-True -Condition ($scriptBody -like "*manager*") -Message "VM user token was not replaced."
    Assert-True -Condition ($scriptBody -like "*444*") -Message "SSH port token was not replaced."
    Assert-True -Condition ($scriptBody -like "*3389*") -Message "RDP port token was not replaced."
    Assert-True -Condition ($scriptBody -like "*examplevm*") -Message "VM name token was not replaced."
    Assert-True -Condition ($scriptBody -like "*W10=*") -Message "Host startup profile token was not replaced."
}

Invoke-Test -Name "Startup mirror profile resolution" -Action {
    $entries = @(
        [pscustomobject]@{ Name = 'Docker Desktop'; Command = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'; EntryType = 'Run'; Scope = 'CurrentUser'; Enabled = $true },
        [pscustomobject]@{ Name = 'Ollama.lnk'; Command = 'C:\Users\operator\AppData\Local\Programs\Ollama\ollama app.exe'; EntryType = 'StartupFolder'; Scope = 'CurrentUser'; Enabled = $true },
        [pscustomobject]@{ Name = 'Teams'; Command = '"C:\Users\operator\AppData\Local\Microsoft\WindowsApps\MSTeams_8wekyb3d8bbwe\ms-teams.exe" msteams:system-initiated'; EntryType = 'Run'; Scope = 'CurrentUser'; Enabled = $true },
        [pscustomobject]@{ Name = 'private local-only accessibility'; Command = '"C:\Program Files\local accessibility vendor\private local-only accessibility\2025\local-accessibility.exe" /run'; EntryType = 'Run'; Scope = 'LocalMachine'; Enabled = $true },
        [pscustomobject]@{ Name = 'iTunesHelper'; Command = '"C:\Program Files\iTunes\iTunesHelper.exe"'; EntryType = 'Run'; Scope = 'LocalMachine'; Enabled = $true },
        [pscustomobject]@{ Name = 'OneDrive'; Command = '"C:\Program Files\Microsoft OneDrive\OneDrive.exe" /background'; EntryType = 'Run'; Scope = 'CurrentUser'; Enabled = $true },
        [pscustomobject]@{ Name = '1Password'; Command = 'C:\Program Files\1Password\app\8\1Password.exe --auto-start'; EntryType = 'Run'; Scope = 'LocalMachine'; Enabled = $true },
        [pscustomobject]@{ Name = 'MicrosoftEdgeAutoLaunch'; Command = 'msedge.exe --no-startup-window'; EntryType = 'Run'; Scope = 'CurrentUser'; Enabled = $false }
    )

    $profile = @(Resolve-AzVmHostStartupMirrorProfileFromEntries -Entries $entries)
    $keys = @($profile | ForEach-Object { [string]$_.Key })

    foreach ($requiredKey in @('docker-desktop','ollama','teams','private local-only accessibility','itunes-helper','onedrive')) {
        Assert-True -Condition ($keys -contains $requiredKey) -Message ("Startup mirror profile must include '{0}'." -f $requiredKey)
    }

    Assert-True -Condition (-not ($keys -contains 'codex-app')) -Message "Startup mirror profile must not infer unsupported apps from unrelated entries."
    Assert-True -Condition (-not ($keys -contains 'microsoft-edge')) -Message "Disabled startup entries must not be mirrored."
}

Invoke-Test -Name "Windows vm-update renamed task catalog entries" -Action {
    $updateDir = Join-Path $RepoRoot 'windows\update'
    $catalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath $updateDir -Platform windows -Stage update
    $active = @($catalog.ActiveTasks)
    $activeNames = @($active | ForEach-Object { [string]$_.Name })
    $expectedTimeouts = [ordered]@{
        '01-winget-bootstrap' = 70
        '02-private-local-task' = 318
        '03-chrome-install-check' = 128
        '04-windows-ux-performance-tuning' = 13
        '05-windows-advanced-system-settings' = 5
        '06-git-install-check' = 131
        '07-python-install-check' = 105
        '08-node-install-check' = 27
        '09-install-ollama' = 376
        '10-install-sysinternals' = 82
        '11-install-powershell-core' = 37
        '12-install-io-unlocker' = 23
        '13-install-gh' = 11
        '14-install-ffmpeg' = 34
        '15-install-7zip' = 13
        '16-install-azure-cli' = 139
        '17-wsl2-install-update' = 137
        '18-docker-desktop-install-and-configure' = 1649
        '19-install-microsoft-azd' = 88
        '20-private-local-task' = 7
        '21-install-whatsapp' = 10
        '22-install-anydesk' = 20
        '23-install-windscribe' = 63
        '24-install-microsoft-teams' = 60
        '25-install-microsoft-vscode' = 104
        '26-install-global-npm-packages' = 363
        '27-windows-ux-public-desktop-shortcuts' = 10
        '28-copy-user-settings' = 27
        '29-health-snapshot' = 10
        '30-install-itunes' = 57
        '31-install-be-my-eyes' = 35
        '32-install-nvda' = 54
        '33-install-microsoft-edge' = 5
        '34-install-vlc' = 58
        '35-install-rclone' = 13
        '36-install-onedrive' = 5
        '37-install-google-drive' = 103
        '38-install-codex-app' = 120
        '39-auto-start-apps' = 45
    }

    Assert-True -Condition ($activeNames -contains '19-install-microsoft-azd') -Message "Renamed azd task was not discovered."
    Assert-True -Condition ($activeNames -contains '20-private-local-task') -Message "Renamed private local-only accessibility task was not discovered."
    Assert-True -Condition ($activeNames -contains '28-copy-user-settings') -Message "Copy user settings task was not discovered."
    Assert-True -Condition ($activeNames -contains '29-health-snapshot') -Message "Renamed health snapshot task was not discovered."
    Assert-True -Condition ($activeNames -contains '30-install-itunes') -Message "iTunes task was not discovered."
    Assert-True -Condition ($activeNames -contains '31-install-be-my-eyes') -Message "Be My Eyes task was not discovered."
    Assert-True -Condition ($activeNames -contains '32-install-nvda') -Message "NVDA task was not discovered."
    Assert-True -Condition ($activeNames -contains '33-install-microsoft-edge') -Message "Microsoft Edge task was not discovered."
    Assert-True -Condition ($activeNames -contains '34-install-vlc') -Message "VLC task was not discovered."
    Assert-True -Condition ($activeNames -contains '35-install-rclone') -Message "rclone task was not discovered."
    Assert-True -Condition ($activeNames -contains '36-install-onedrive') -Message "OneDrive task was not discovered."
    Assert-True -Condition ($activeNames -contains '37-install-google-drive') -Message "Google Drive task was not discovered."
    Assert-True -Condition ($activeNames -contains '38-install-codex-app') -Message "Codex app task was not discovered."
    Assert-True -Condition ($activeNames -contains '39-auto-start-apps') -Message "Auto-start apps task was not discovered."
    Assert-True -Condition (-not ($activeNames -contains '19-health-snapshot')) -Message "Legacy 19-health-snapshot entry must not remain active."
    Assert-True -Condition (-not ($activeNames -contains '20-private-local-task')) -Message "Legacy 20-private-local-task entry must not remain active."
    Assert-True -Condition (-not ($activeNames -contains '28-install-microsoft-azd')) -Message "Legacy 28-install-microsoft-azd entry must not remain active."
    Assert-True -Condition (-not ($activeNames -contains '28-health-snapshot')) -Message "Legacy 28-health-snapshot entry must not remain active."

    foreach ($entry in $expectedTimeouts.GetEnumerator()) {
        $task = $active | Where-Object { [string]$_.Name -eq [string]$entry.Key } | Select-Object -First 1
        Assert-True -Condition ($null -ne $task) -Message ("Expected task '{0}' was not discovered." -f [string]$entry.Key)
        Assert-True -Condition ([int]$task.TimeoutSeconds -eq [int]$entry.Value) -Message ("Task '{0}' timeout must be {1}." -f [string]$entry.Key, [int]$entry.Value)
    }

    Assert-True -Condition (([array]::IndexOf($activeNames, '19-install-microsoft-azd')) -lt ([array]::IndexOf($activeNames, '20-private-local-task'))) -Message "Renamed task order must keep azd before copy-private local-only accessibility-settings."
    Assert-True -Condition (([array]::IndexOf($activeNames, '37-install-google-drive')) -lt ([array]::IndexOf($activeNames, '27-windows-ux-public-desktop-shortcuts'))) -Message "Install tasks must still complete before public desktop shortcut generation."
    Assert-True -Condition (([array]::IndexOf($activeNames, '38-install-codex-app')) -lt ([array]::IndexOf($activeNames, '27-windows-ux-public-desktop-shortcuts'))) -Message "Codex app install must complete before public desktop shortcut generation."
    Assert-True -Condition (([array]::IndexOf($activeNames, '39-auto-start-apps')) -lt ([array]::IndexOf($activeNames, '27-windows-ux-public-desktop-shortcuts'))) -Message "Auto-start mirroring must complete before public desktop shortcut generation."
    Assert-True -Condition (([array]::IndexOf($activeNames, '27-windows-ux-public-desktop-shortcuts')) -lt ([array]::IndexOf($activeNames, '28-copy-user-settings'))) -Message "Task order must keep public desktop shortcuts before copy-user-settings."
    Assert-True -Condition (([array]::IndexOf($activeNames, '28-copy-user-settings')) -lt ([array]::IndexOf($activeNames, '29-health-snapshot'))) -Message "Task order must keep copy-user-settings before health snapshot."
}

Invoke-Test -Name "Windows private local-only accessibility zip asset layout" -Action {
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    $assetsRoot = Join-Path $RepoRoot 'windows\update\local-private-assets'
    $versionZipPath = Join-Path $assetsRoot 'private local-only accessibility-version.zip'
    $roamingZipPath = Join-Path $assetsRoot 'private local-only accessibility-roaming-settings.zip'

    Assert-True -Condition (Test-Path -LiteralPath $versionZipPath) -Message "private local-only accessibility version zip asset was not found."
    Assert-True -Condition (Test-Path -LiteralPath $roamingZipPath) -Message "private local-only accessibility roaming settings zip asset was not found."

    $versionArchive = [System.IO.Compression.ZipFile]::OpenRead($versionZipPath)
    try {
        $versionEntries = @($versionArchive.Entries | ForEach-Object { [string]$_.FullName })
    }
    finally {
        $versionArchive.Dispose()
    }

    $roamingArchive = [System.IO.Compression.ZipFile]::OpenRead($roamingZipPath)
    try {
        $roamingEntries = @($roamingArchive.Entries | ForEach-Object { [string]$_.FullName })
    }
    finally {
        $roamingArchive.Dispose()
    }

    Assert-True -Condition ($versionEntries.Count -eq 1) -Message "private local-only accessibility version zip must contain exactly one root file."
    Assert-True -Condition ([string]$versionEntries[0] -eq 'version.dll') -Message "private local-only accessibility version zip must contain version.dll at archive root."
    Assert-True -Condition ($roamingEntries.Count -gt 0) -Message "private local-only accessibility roaming settings zip must not be empty."
    Assert-True -Condition (-not ($roamingEntries | Where-Object { $_ -like 'Settings/*' -or $_ -eq 'Settings/' })) -Message "private local-only accessibility roaming settings zip must contain Settings contents, not a nested Settings root."
}

Invoke-Test -Name "Windows private local-only accessibility task asset copies" -Action {
    $context = [ordered]@{
        VmUser = "manager"
        VmPass = "secret"
        VmAssistantUser = "assistant"
        VmAssistantPass = "secret2"
        SshPort = "444"
        RdpPort = "3389"
        TcpPorts = @("444","3389","11434")
        ResourceGroup = "rg-examplevm"
        VmName = "examplevm"
        AzLocation = "austriaeast"
        VmSize = "Standard_B2as_v2"
        VmImage = "example:image:urn"
        VmDiskName = "disk-examplevm"
        VmDiskSize = "128"
        VmStorageSku = "StandardSSD_LRS"
    }

    $taskScriptPath = Join-Path $RepoRoot 'windows\update\20-private-local-task.ps1'
    $templates = @(
        [pscustomobject]@{
            Name = "20-private-local-task"
            Script = [string](Get-Content -LiteralPath $taskScriptPath -Raw)
            RelativePath = "20-private-local-task.ps1"
            DirectoryPath = (Join-Path $RepoRoot 'windows\update')
            TimeoutSeconds = 180
        }
    )

    $resolved = Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks $templates -Context $context
    $resolvedTask = @($resolved)[0]
    $assetCopies = @($resolvedTask.AssetCopies)
    $scriptBody = [string]$resolvedTask.Script
    $remotePaths = @($assetCopies | ForEach-Object { [string]$_.RemotePath })
    $localPaths = @($assetCopies | ForEach-Object { [string]$_.LocalPath })

    Assert-True -Condition ($scriptBody -like '*C:\Users\manager\AppData\Roaming\local accessibility vendor\private local-only accessibility\2025\Settings*') -Message "private local-only accessibility task must resolve VM_ADMIN_USER into roaming settings target."
    Assert-True -Condition ($assetCopies.Count -eq 2) -Message "private local-only accessibility task must publish two asset copies."
    Assert-True -Condition ($remotePaths -contains 'C:/Windows/Temp/az-vm-private local-only accessibility-version.zip') -Message "private local-only accessibility version zip remote path mismatch."
    Assert-True -Condition ($remotePaths -contains 'C:/Windows/Temp/az-vm-private local-only accessibility-roaming-settings.zip') -Message "private local-only accessibility roaming zip remote path mismatch."
    Assert-True -Condition (($localPaths | Where-Object { $_ -like '*private local-only accessibility-version.zip' }).Count -eq 1) -Message "private local-only accessibility version zip local asset path mismatch."
    Assert-True -Condition (($localPaths | Where-Object { $_ -like '*private local-only accessibility-roaming-settings.zip' }).Count -eq 1) -Message "private local-only accessibility roaming zip local asset path mismatch."
}

Invoke-Test -Name "Windows Ollama task verifies API readiness" -Action {
    $taskPath = Join-Path $RepoRoot 'windows\update\09-install-ollama.ps1'
    $taskScript = [string](Get-Content -LiteralPath $taskPath -Raw)
    Assert-True -Condition ($taskScript -like '*Ollama.Ollama*') -Message 'Ollama install task must use the Ollama.Ollama winget package id.'
    Assert-True -Condition ($taskScript -like '*127.0.0.1:11434*') -Message 'Ollama install task must check the default Ollama port.'
    Assert-True -Condition ($taskScript -like '*/api/version*') -Message 'Ollama install task must validate the Ollama HTTP API endpoint.'
    Assert-True -Condition ($taskScript -like '*ollama serve*') -Message 'Ollama install task must start ollama serve when the API is not already ready.'
    Assert-True -Condition ($taskScript -like '*Existing Ollama installation is already healthy. Skipping winget install.*') -Message 'Ollama install task must short-circuit when an existing installation is already healthy.'
    Assert-True -Condition ($taskScript -like '*RedirectStandardOutput*') -Message 'Ollama install task must detach ollama serve stdout from the SSH session.'
    Assert-True -Condition ($taskScript -like '*RedirectStandardError*') -Message 'Ollama install task must detach ollama serve stderr from the SSH session.'
    Assert-True -Condition ($taskScript -like '*Stopping stale installer processes before Ollama install*') -Message 'Ollama install task must clear stale installer locks instead of waiting indefinitely.'
    Assert-True -Condition ($taskScript -like '*WaitForExit*') -Message 'Ollama install task must bound the winget install wait time.'
    Assert-True -Condition ($taskScript -like '*timed out after*') -Message 'Ollama install task must fail clearly when winget install exceeds the timeout.'
}

Invoke-Test -Name "Windows VS Code task short-circuits healthy installs" -Action {
    $taskPath = Join-Path $RepoRoot 'windows\update\25-install-microsoft-vscode.ps1'
    $taskScript = [string](Get-Content -LiteralPath $taskPath -Raw)
    Assert-True -Condition ($taskScript -like '*Existing Visual Studio Code installation is already healthy. Skipping winget install.*') -Message 'VS Code install task must skip winget when a healthy installation already exists.'
    Assert-True -Condition ($taskScript -like '*Resolve-CodeExecutable*') -Message 'VS Code install task must resolve the existing Code executable before reinstalling.'
}

Invoke-Test -Name "Windows Docker Desktop task clears stale installer locks" -Action {
    $taskPath = Join-Path $RepoRoot 'windows\update\18-docker-desktop-install-and-configure.ps1'
    $taskScript = [string](Get-Content -LiteralPath $taskPath -Raw)
    Assert-True -Condition ($taskScript -like '*Stopping stale installer processes before Docker Desktop install*') -Message 'Docker Desktop task must clear stale installer locks before winget install.'
    Assert-True -Condition ($taskScript -like '*winget install Docker.DockerDesktop*') -Message 'Docker Desktop task must install Docker Desktop through winget.'
    Assert-True -Condition ($taskScript -like '*Invoke-ProcessWithTimeout*') -Message 'Docker Desktop task must bound the winget install wait time.'
    Assert-True -Condition ($taskScript -like '*Active installer processes*') -Message 'Docker Desktop task must report active installer processes when install timing problems occur.'
}

Invoke-Test -Name "Windows UX helper asset and validation model" -Action {
    $context = [ordered]@{
        VmUser = "manager"
        VmPass = "secret"
        VmAssistantUser = "assistant"
        VmAssistantPass = "secret2"
        SshPort = "444"
        RdpPort = "3389"
        TcpPorts = @("444","3389","11434")
        ResourceGroup = "rg-examplevm"
        VmName = "examplevm"
        AzLocation = "austriaeast"
        VmSize = "Standard_B2as_v2"
        VmImage = "example:image:urn"
        VmDiskName = "disk-examplevm"
        VmDiskSize = "128"
        VmStorageSku = "StandardSSD_LRS"
    }

    $updateDir = Join-Path $RepoRoot 'windows\update'

    $uxTaskPath = Join-Path $updateDir '04-windows-ux-performance-tuning.ps1'
    $uxTemplates = @(
        [pscustomobject]@{
            Name = '04-windows-ux-performance-tuning'
            Script = [string](Get-Content -LiteralPath $uxTaskPath -Raw)
            RelativePath = '04-windows-ux-performance-tuning.ps1'
            DirectoryPath = $updateDir
            TimeoutSeconds = 600
        }
    )

    $resolvedUxTask = @(Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks $uxTemplates -Context $context)[0]
    $uxAssetCopies = @($resolvedUxTask.AssetCopies)
    $uxScriptBody = [string]$resolvedUxTask.Script
    Assert-True -Condition ($uxAssetCopies.Count -eq 1) -Message "UX task must publish exactly one helper asset."
    Assert-True -Condition ([string]$uxAssetCopies[0].RemotePath -eq 'C:/Windows/Temp/az-vm-interactive-session-helper.ps1') -Message "UX task helper remote path mismatch."
    Assert-True -Condition ($uxScriptBody -like '*TaskManager\settings.json*') -Message "UX task must validate Task Manager through settings.json."
    Assert-True -Condition ($uxScriptBody -like '*SearchboxTaskbarMode*') -Message "UX task must hide the taskbar search control."
    Assert-True -Condition ($uxScriptBody -like '*AllowNewsAndInterests*') -Message "UX task must hide Widgets through machine policy."
    Assert-True -Condition ($uxScriptBody -like '*ShowTaskViewButton*') -Message "UX task must hide Task View."
    Assert-True -Condition (-not $resolvedUxTask.PSObject.Properties.Match('InteractiveResultPath').Count) -Message "UX task must not publish reboot-resume metadata."

    $copyUserSettingsTaskPath = Join-Path $updateDir '28-copy-user-settings.ps1'
    $copyUserSettingsTemplates = @(
        [pscustomobject]@{
            Name = '28-copy-user-settings'
            Script = [string](Get-Content -LiteralPath $copyUserSettingsTaskPath -Raw)
            RelativePath = '28-copy-user-settings.ps1'
            DirectoryPath = $updateDir
            TimeoutSeconds = 1800
        }
    )

    $resolvedCopyUserSettingsTask = @(Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks $copyUserSettingsTemplates -Context $context)[0]
    $copyUserSettingsAssetCopies = @($resolvedCopyUserSettingsTask.AssetCopies)
    $copyUserSettingsBody = [string]$resolvedCopyUserSettingsTask.Script
    Assert-True -Condition ($copyUserSettingsAssetCopies.Count -eq 1) -Message "Copy user settings task must publish exactly one helper asset."
    Assert-True -Condition ([string]$copyUserSettingsAssetCopies[0].RemotePath -eq 'C:/Windows/Temp/az-vm-interactive-session-helper.ps1') -Message "Copy user settings helper remote path mismatch."
    Assert-True -Condition ($copyUserSettingsBody -like '*copy-user-settings-profile-materialized*') -Message "Copy user settings task must materialize the assistant profile."
    Assert-True -Condition ($copyUserSettingsBody -like '*SearchboxTaskbarMode*') -Message "Copy user settings task must propagate taskbar search visibility."
    Assert-True -Condition ($copyUserSettingsBody -like '*TaskManager\settings.json*') -Message "Copy user settings task must propagate Task Manager settings."
    Assert-True -Condition ($copyUserSettingsBody -like '*HKEY_USERS\.DEFAULT*') -Message "Copy user settings task must seed the logon-screen hive."
    Assert-True -Condition (-not $resolvedCopyUserSettingsTask.PSObject.Properties.Match('InteractiveResultPath').Count) -Message "Copy user settings task must not publish reboot-resume metadata."

    $advancedTaskPath = Join-Path $updateDir '05-windows-advanced-system-settings.ps1'
    $advancedTemplates = @(
        [pscustomobject]@{
            Name = '05-windows-advanced-system-settings'
            Script = [string](Get-Content -LiteralPath $advancedTaskPath -Raw)
            RelativePath = '05-windows-advanced-system-settings.ps1'
            DirectoryPath = $updateDir
            TimeoutSeconds = 300
        }
    )

    $resolvedAdvancedTask = @(Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks $advancedTemplates -Context $context)[0]
    $advancedAssetCopies = @($resolvedAdvancedTask.AssetCopies)
    $advancedScriptBody = [string]$resolvedAdvancedTask.Script
    Assert-True -Condition ($advancedAssetCopies.Count -eq 0) -Message "Advanced settings task must not publish helper assets."
    Assert-True -Condition ($advancedScriptBody -notlike '*VolumeControl*') -Message "Advanced settings task must not keep legacy audio tuning."
    Assert-True -Condition (-not $resolvedAdvancedTask.PSObject.Properties.Match('InteractiveResultPath').Count) -Message "Advanced settings task must not publish reboot-resume metadata."
}

Invoke-Test -Name "Windows public desktop shortcut contract includes refreshed public shortcuts" -Action {
    $shortcutTaskPath = Join-Path $RepoRoot 'windows\update\27-windows-ux-public-desktop-shortcuts.ps1'
    $shortcutTaskScript = [string](Get-Content -LiteralPath $shortcutTaskPath -Raw)
    $healthTaskPath = Join-Path $RepoRoot 'windows\update\29-health-snapshot.ps1'
    $healthTaskScript = [string](Get-Content -LiteralPath $healthTaskPath -Raw)
    $q1EksisozlukName = ("q1Ek{0}iS{1}zl{2}k" -f [char]0x015F, [char]0x00F6, [char]0x00FC)

    $expectedShortcutNames = @(
        'a1ChatGPT Web',
        'a2Be My Eyes',
        'a3CodexApp',
        'a7Docker Desktop',
        'a10NVDA',
        'a11MS Edge',
        'a14VLC Player',
        'a17Itunes',
        'b1GarantiBank Bireysel',
        'b2GarantiBank Kurumsal',
        'b3QnbBank Bireysel',
        'b4QnbBank Kurumsal',
        'b5AktifBank Bireysel',
        'b6AktifBank Kurumsal',
        'b7ZiraatBank Bireysel',
        'b8ZiraatBank Kurumsal',
        'c0Cmd',
        'd0Rclone CLI',
        'd1One Drive',
        'd2Google Drive',
        'i0Internet',
        'i1WhatsApp Kurumsal',
        'i2WhatsApp Bireysel',
        'i8AnyDesk',
        'i9Windscribe',
        'local-only-shortcut',
        'o0Outlook',
        'o1Teams',
        'o2Word',
        'o3Excel',
        'o4Power Point',
        'o5OneNote',
        's1LinkedIn Kurumsal',
        's2LinkedIn Bireysel',
        's3YouTube Kurumsal',
        's4YouTube Bireysel',
        's5GitHub Kurumsal',
        's6GitHub Bireysel',
        's7TikTok Kurumsal',
        's8TikTok Bireysel',
        's9Instagram Kurumsal',
        's10Instagram Bireysel',
        's11Facebook Kurumsal',
        's12Facebook Bireysel',
        's13X-Twitter Kurumsal',
        's14X-Twitter Bireysel',
        's15Web Sitesi Kurumsal',
        's16Blog Sitesi Kurumsal',
        't0Git Bash',
        't1Python CLI',
        't2Nodejs CLI',
        't3Ollama App',
        't4Pwsh',
        't5PS',
        't6Azure CLI',
        't7WSL',
        't8Docker CLI',
        't9AZD CLI',
        't10GH CLI',
        't11FFmpeg CLI',
        't12SevenZip CLI',
        't13Sysinternals',
        't14Io Unlocker',
        't15Codex CLI',
        't16Gemini CLI',
        'u7Network and Sharing',
        'v5VS Code',
        'z1Google Account Setup',
        'z2Office365 Account Setup'
    )
    $legacyShortcutNames = @(
        'i7whatsapp',
        't0-git bash',
        't1-python cli',
        't2-nodejs cli',
        't3-ollama app',
        't4-pwsh',
        't5-ps',
        't6-azure cli',
        't7-wsl',
        't9-azd cli',
        't10-gh cli',
        't11-ffmpeg cli',
        't12-7zip cli',
        't13-sysinternals',
        't14-io-unlocker',
        't15-codex cli',
        't16-gemini cli',
        'i0internet',
        'z1google account setup',
        'z2Office365 account setup',
        'c0cmd',
        'local-only-shortcut',
        'a7docker desktop',
        'o0outlook',
        'o1teams',
        'o2word',
        'o3excel',
        'o4power point',
        'o5onenote',
        'i8anydesk',
        'i9windscribe',
        'v5vscode',
        'u7network and sharing',
        't3OllamaApp',
        't6azure-cli',
        't12SevenZip-cli',
        't15codex-cli',
        't16gemini-cli'
    )
    $expectedFragments = @(
        'https://chatgpt.com',
        'https://www.google.com',
        'https://web.whatsapp.com',
        'chrome://settings/syncSetup',
        'https://portal.office.com',
        'https://tr.linkedin.com/company/exampleorg',
        'https://linkedin.com/in/<social-handle>',
        'https://www.youtube.com/@exampleorg',
        'https://www.youtube.com/@hasanozdemir8',
        'https://github.com/exampleorg',
        'https://github.com/',
        'https://www.tiktok.com/@exampleorg',
        'https://instagram.com/exampleorg',
        'https://instagram.com/hasanozdemirnet',
        'https://www.facebook.com/people/exampleorg-Teknoloji/61577930401447',
        'https://facebook.com/ozdemirhasan',
        'https://x.com/exampleorg',
        'https://x.com/hasanozdemirnet',
        'https://www.exampleorg.com',
        'https://www.exampleorg.com/blog',
        'https://www.eksisozluk.com',
        'https://sube.garantibbva.com.tr/isube/login/login/passwordentrypersonal-tr',
        'https://sube.garantibbva.com.tr/isube/login/login/passwordentrycorporate-tr',
        'https://internetsubesi.qnb.com.tr/Login/LoginPage.aspx',
        'https://internetsubesi.qnb.com.tr/Login/LoginPage.aspx?FromDK=true',
        'https://online.aktifbank.com.tr/default.aspx?lang=tr-TR',
        'https://kurumsal.aktifbank.com.tr/default.aspx?lang=tr-TR',
        'https://bireysel.ziraatbank.com.tr/Transactions/Login/FirstLogin.aspx',
        'https://kurumsal.ziraatbank.com.tr/Transactions/Login/FirstLogin.aspx?customertype=crp',
        'Resolve-AppPackageExecutablePath',
        'Resolve-StoreAppId',
        'New-StoreDeeplinkShortcut',
        'ms-windows-store://pdp/?ProductId=9MSW46LTDWGF',
        'OpenAI.Codex_26.306.996.0_x64__2p2nqsd0c76g0\app\Codex.exe',
        'WhatsApp.Root.exe',
        '5319275A.WhatsAppDesktop_2.2606.102.0_x64__cv1g1gvanyjgm\WhatsApp.Root.exe',
        'TaskKill -im "ollama app.exe"',
        '/k cd /d c:\users\public & az --version',
        'C:\ProgramData\chocolatey\bin\7z.exe',
        '--enable multi_agent --yolo -s danger-full-access --cd "c:\users\public" --search',
        '--screen-reader --yolo',
        '$publicChromeUserDataDir = "C:\Users\Public\AppData\Local\Google\Chrome\UserData"',
        '--user-data-dir="{0}"',
        '--profile-directory="{1}"',
        'Ctrl+Shift+J'
    )

    foreach ($shortcutName in @($expectedShortcutNames)) {
        Assert-True -Condition (($shortcutTaskScript.IndexOf([string]$shortcutName, [System.StringComparison]::Ordinal)) -ge 0) -Message ("Shortcut task must create '{0}'." -f $shortcutName)
        Assert-True -Condition (($healthTaskScript.IndexOf([string]$shortcutName, [System.StringComparison]::Ordinal)) -ge 0) -Message ("Health snapshot must inventory '{0}'." -f $shortcutName)
    }

    foreach ($legacyShortcutName in @($legacyShortcutNames)) {
        Assert-True -Condition (($shortcutTaskScript.IndexOf([string]$legacyShortcutName, [System.StringComparison]::Ordinal)) -lt 0) -Message ("Shortcut task must not keep legacy shortcut name '{0}'." -f $legacyShortcutName)
        Assert-True -Condition (($healthTaskScript.IndexOf([string]$legacyShortcutName, [System.StringComparison]::Ordinal)) -lt 0) -Message ("Health snapshot must not keep legacy shortcut name '{0}'." -f $legacyShortcutName)
    }

    foreach ($fragment in @($expectedFragments)) {
        Assert-True -Condition ($shortcutTaskScript -like ('*' + $fragment + '*')) -Message ("Shortcut task must include fragment '{0}'." -f $fragment)
    }

    $q1VariableDefinition = '$q1EksisozlukName = ("q1Ek{0}iS{1}zl{2}k" -f [char]0x015F, [char]0x00F6, [char]0x00FC)'
    $q1ShortcutUsage = '@{ Name = $q1EksisozlukName; Url = "https://www.eksisozluk.com" }'
    Assert-True -Condition (($shortcutTaskScript.IndexOf($q1VariableDefinition, [System.StringComparison]::Ordinal)) -ge 0) -Message 'Shortcut task must declare q1EkşiSözlük through the shared Unicode-safe variable.'
    Assert-True -Condition (($shortcutTaskScript.IndexOf($q1ShortcutUsage, [System.StringComparison]::Ordinal)) -ge 0) -Message 'Shortcut task must create q1EkşiSözlük through the shared Unicode-safe variable.'
    Assert-True -Condition (($healthTaskScript.IndexOf('$q1EksisozlukName,', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Health snapshot must inventory q1EkşiSözlük through the shared Unicode-safe variable.'
    Assert-True -Condition ($shortcutTaskScript -like '*New-CmdWrappedShortcut*') -Message 'Shortcut task must use cmd.exe wrappers for command-style shortcuts.'
    Assert-True -Condition ($healthTaskScript -like '*hotkey =>*') -Message 'Health snapshot must read back shortcut hotkeys.'
}

Invoke-Test -Name "Windows app install task contracts cover new shortcut-backed packages" -Action {
    $installTaskMap = [ordered]@{
        '30-install-itunes.ps1' = @('Apple.iTunes', 'iTunes.exe')
        '31-install-be-my-eyes.ps1' = @('9MSW46LTDWGF', '--source msstore', 'Invoke-AzVmInteractiveDesktopAutomation', 'Get-AzVmInteractivePaths')
        '32-install-nvda.ps1' = @('NVAccess.NVDA', 'nvd' )
        '33-install-microsoft-edge.ps1' = @('Microsoft.Edge', 'msedge.exe')
        '34-install-vlc.ps1' = @('VideoLAN.VLC', 'vlc.exe')
        '35-install-rclone.ps1' = @('Rclone.Rclone', 'rclone.exe')
        '36-install-onedrive.ps1' = @('Microsoft.OneDrive', 'OneDrive.exe')
        '37-install-google-drive.ps1' = @('Google.GoogleDrive', 'GoogleDriveFS.exe')
        '38-install-codex-app.ps1' = @('winget install codex -s msstore', 'OpenAI.Codex', 'Codex.exe')
    }

    foreach ($entry in $installTaskMap.GetEnumerator()) {
        $taskPath = Join-Path $RepoRoot ('windows\update\' + [string]$entry.Key)
        Assert-True -Condition (Test-Path -LiteralPath $taskPath) -Message ("Expected install task file was not found: {0}" -f $taskPath)
        $taskText = [string](Get-Content -LiteralPath $taskPath -Raw)
        foreach ($fragment in @($entry.Value)) {
            Assert-True -Condition ($taskText -like ('*' + [string]$fragment + '*')) -Message ("Task '{0}' must include fragment '{1}'." -f [string]$entry.Key, [string]$fragment)
        }
    }
}

Invoke-Test -Name "Windows auto-start task mirrors host startup profile into machine startup" -Action {
    $taskPath = Join-Path $RepoRoot 'windows\update\39-auto-start-apps.ps1'
    Assert-True -Condition (Test-Path -LiteralPath $taskPath) -Message "Expected auto-start task file was not found."
    $taskText = [string](Get-Content -LiteralPath $taskPath -Raw)
    $healthTaskPath = Join-Path $RepoRoot 'windows\update\29-health-snapshot.ps1'
    $healthTaskText = [string](Get-Content -LiteralPath $healthTaskPath -Raw)

    foreach ($fragment in @(
        '__HOST_STARTUP_PROFILE_JSON_B64__',
        'host-startup-profile =>',
        'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp',
        'StartupApproved\StartupFolder',
        'Docker Desktop',
        'Ollama',
        'OneDrive',
        'Teams',
        'private local-only accessibility',
        'iTunesHelper',
        'msteams:system-initiated',
        '%LOCALAPPDATA%\Programs\Ollama\ollama app.exe',
        'auto-start-apps-completed'
    )) {
        Assert-True -Condition ($taskText -like ('*' + $fragment + '*')) -Message ("Auto-start task must include fragment '{0}'." -f $fragment)
    }

    foreach ($fragment in @(
        'AUTO-START APP STATUS:',
        '__HOST_STARTUP_PROFILE_JSON_B64__',
        'startup-shortcut =>',
        'missing-startup-shortcut =>',
        'Docker Desktop',
        'Ollama',
        'OneDrive',
        'Teams',
        'private local-only accessibility',
        'iTunesHelper'
    )) {
        Assert-True -Condition ($healthTaskText -like ('*' + $fragment + '*')) -Message ("Health snapshot must include startup fragment '{0}'." -f $fragment)
    }
}

Invoke-Test -Name "Be My Eyes task publishes interactive helper asset" -Action {
    $updateDir = Join-Path $RepoRoot 'windows\update'
    $context = [ordered]@{
        VM_NAME = 'examplevm'
        VM_ADMIN_USER = 'manager'
        VM_ADMIN_PASS = '<runtime-secret>'
        ASSISTANT_USER = 'assistant'
        ASSISTANT_PASS = '<runtime-secret>'
        SSH_PORT = '22'
        RDP_PORT = '3389'
    }

    $taskPath = Join-Path $updateDir '31-install-be-my-eyes.ps1'
    $templates = @(
        [pscustomobject]@{
            Name = '31-install-be-my-eyes'
            Script = [string](Get-Content -LiteralPath $taskPath -Raw)
            RelativePath = '31-install-be-my-eyes.ps1'
            DirectoryPath = $updateDir
            TimeoutSeconds = 300
        }
    )

    $resolvedTask = @(Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks $templates -Context $context)[0]
    $assetCopies = @($resolvedTask.AssetCopies)
    Assert-True -Condition ($assetCopies.Count -eq 1) -Message "Be My Eyes task must publish exactly one helper asset."
    Assert-True -Condition ([string]$assetCopies[0].RemotePath -eq 'C:/Windows/Temp/az-vm-interactive-session-helper.ps1') -Message "Be My Eyes helper remote path mismatch."
    Assert-True -Condition ([string]$resolvedTask.Script -like '*Invoke-AzVmInteractiveDesktopAutomation*') -Message "Be My Eyes task must call the interactive helper."
}

Write-Host ""
Write-Host ("Compatibility smoke summary -> Passed: {0}, Failed: {1}" -f $passCount, $failCount)
if ($failCount -gt 0) {
    exit 1
}
