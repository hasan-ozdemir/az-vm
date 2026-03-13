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

Invoke-Test -Name "Launcher loads the modern runtime manifest without legacy root loaders" -Action {
    $launcherText = Get-Content -LiteralPath $script:UnifiedScriptPath -Raw
    $manifestPath = Join-Path $RepoRoot 'modules\azvm-runtime-manifest.ps1'
    $manifestText = Get-Content -LiteralPath $manifestPath -Raw

    Assert-True -Condition ($launcherText -match [regex]::Escape('modules/azvm-runtime-manifest.ps1')) -Message "az-vm.ps1 must load the modern runtime manifest."

    foreach ($legacyRelativePath in @(
        'modules\core\azvm-core-foundation.ps1',
        'modules\core\azvm-core-runtime.ps1',
        'modules\config\azvm-config-runtime.ps1',
        'modules\tasks\azvm-run-command-runtime.ps1',
        'modules\tasks\azvm-ssh-runtime.ps1',
        'modules\ui\azvm-ui-runtime.ps1',
        'modules\commands\azvm-orchestration-runtime.ps1',
        'modules\commands\azvm-command-main.ps1'
    )) {
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $legacyRelativePath))) -Message ("Legacy root loader must not exist: {0}" -f $legacyRelativePath)
        Assert-True -Condition (-not ($launcherText -match [regex]::Escape($legacyRelativePath.Replace('\', '/')))) -Message ("az-vm.ps1 must not reference legacy root loader '{0}'." -f $legacyRelativePath)
        Assert-True -Condition (-not ($manifestText -match [regex]::Escape($legacyRelativePath.Replace('\', '/')))) -Message ("Runtime manifest must not reference legacy root loader '{0}'." -f $legacyRelativePath)
    }
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
    Assert-True -Condition (Test-AzVmVmNameFormat -VmName "samplevm") -Message "Expected valid VM name to pass."
    Assert-True -Condition (Test-AzVmVmNameFormat -VmName "samplelinux-1") -Message "Expected valid VM name with hyphen to pass."
    Assert-True -Condition (-not (Test-AzVmVmNameFormat -VmName "1samplevm")) -Message "VM name starting with digit should fail."
    Assert-True -Condition (-not (Test-AzVmVmNameFormat -VmName "ab")) -Message "Too-short VM name should fail."
    Assert-True -Condition (-not (Test-AzVmVmNameFormat -VmName "samplevm_name")) -Message "VM name with underscore should fail."
}

Invoke-Test -Name "Managed resource naming contract" -Action {
    Assert-AzVmManagedResourceNamesValid -NameMap @{
        RESOURCE_GROUP = 'rg-samplevm-ate1-g1'
        VNET_NAME = 'net-samplevm-ate1-n1'
        SUBNET_NAME = 'subnet-samplevm-ate1-n1'
        NSG_NAME = 'nsg-samplevm-ate1-n1'
        NSG_RULE_NAME = 'nsg-rule-samplevm-ate1-n1'
        PUBLIC_IP_NAME = 'ip-samplevm-ate1-n1'
        NIC_NAME = 'nic-samplevm-ate1-n1'
        VM_DISK_NAME = 'disk-samplevm-ate1-n1'
    }

    $invalidCases = @(
        @{ Key = 'RESOURCE_GROUP'; Value = 'rg-samplevm-ate1-g1.' },
        @{ Key = 'VNET_NAME'; Value = 'net samplevm' },
        @{ Key = 'NIC_NAME'; Value = 'nic/samplevm' }
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

    $envExampleKeys = @(Get-Content $envExamplePath | Where-Object { $_ -match '^[A-Za-z0-9_]+=' } | ForEach-Object { ($_ -split '=', 2)[0] })
    $requiredKeys = @(
        'VM_OS_TYPE','VM_NAME','company_name','employee_email_address','employee_full_name','AZ_LOCATION',
        'RESOURCE_GROUP','VNET_NAME','SUBNET_NAME','NSG_NAME','NSG_RULE_NAME','PUBLIC_IP_NAME','NIC_NAME','VM_DISK_NAME',
        'RESOURCE_GROUP_TEMPLATE','VNET_NAME_TEMPLATE','SUBNET_NAME_TEMPLATE','NSG_NAME_TEMPLATE','NSG_RULE_NAME_TEMPLATE','PUBLIC_IP_NAME_TEMPLATE','NIC_NAME_TEMPLATE','VM_DISK_NAME_TEMPLATE',
        'VM_STORAGE_SKU','VM_SECURITY_TYPE','VM_ENABLE_HIBERNATION','VM_ENABLE_NESTED_VIRTUALIZATION','VM_ENABLE_SECURE_BOOT','VM_ENABLE_VTPM','PRICE_HOURS','VM_ADMIN_USER','VM_ADMIN_PASS','VM_ASSISTANT_USER','VM_ASSISTANT_PASS','VM_SSH_PORT','VM_RDP_PORT',
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

    $envExampleText = Get-Content -LiteralPath $envExamplePath -Raw
    Assert-True -Condition ($envExampleText -match [regex]::Escape('VM_ADMIN_PASS=<CHANGE_ME_STRONG_ADMIN_PASSWORD>')) -Message '.env.example must keep the admin password as a placeholder.'
    Assert-True -Condition ($envExampleText -match [regex]::Escape('VM_ASSISTANT_PASS=<CHANGE_ME_STRONG_ASSISTANT_PASSWORD>')) -Message '.env.example must keep the assistant password as a placeholder.'
    Assert-True -Condition ($envExampleText -match [regex]::Escape('VM_ENABLE_HIBERNATION=true')) -Message '.env.example must expose VM_ENABLE_HIBERNATION as a shared feature toggle.'
    Assert-True -Condition ($envExampleText -match [regex]::Escape('VM_ENABLE_NESTED_VIRTUALIZATION=true')) -Message '.env.example must expose VM_ENABLE_NESTED_VIRTUALIZATION as a shared feature toggle.'
    Assert-True -Condition ($envExampleText -match [regex]::Escape('NSG_RULE_NAME_TEMPLATE=nsg-rule-{VM_NAME}-{REGION_CODE}-n{N}')) -Message '.env.example must keep the nsg-rule naming prefix.'
    Assert-True -Condition ($envExampleText -match [regex]::Escape('PYSSH_CLIENT_PATH=tools/pyssh/ssh_client.py')) -Message '.env.example must keep a non-empty repo-relative PYSSH client default.'
    Assert-True -Condition ($envExampleText -match [regex]::Escape('company_name is required for Windows business public desktop shortcuts.')) -Message '.env.example must document company_name as required for the Windows business public desktop shortcut flow.'
    Assert-True -Condition ($envExampleText -match [regex]::Escape('Repo-managed Chrome profile-directory values are normalized to lowercase.')) -Message '.env.example must document lowercase Chrome profile-directory normalization.'
    Assert-True -Condition ($envExampleText -match [regex]::Escape('employee_email_address=<email>')) -Message '.env.example must keep the committed employee_email_address default.'
    Assert-True -Condition ($envExampleText -match [regex]::Escape('employee_full_name=<person-name>')) -Message '.env.example must keep the committed employee_full_name default.'
    Assert-True -Condition (-not ($envExampleText -match [regex]::Escape('<runtime-secret>'))) -Message '.env.example must not keep the old committed assistant password.'
}

Invoke-Test -Name "Shared feature toggles and pyssh path are wired into runtime defaults" -Action {
    $platformDefaultsText = Get-Content -LiteralPath (Join-Path $RepoRoot 'modules\core\platform\azvm-platform-defaults.ps1') -Raw
    $commandContextText = Get-Content -LiteralPath (Join-Path $RepoRoot 'modules\commands\context\azvm-step1-context.ps1') -Raw
    $featureSupportText = Get-Content -LiteralPath (Join-Path $RepoRoot 'modules\commands\features\azvm-feature-support.ps1') -Raw
    $commandRuntimeText = Get-Content -LiteralPath (Join-Path $RepoRoot 'modules\commands\shared\runtime\azvm-command-runtime-context.ps1') -Raw
    $mainText = Get-Content -LiteralPath (Join-Path $RepoRoot 'modules\commands\pipeline\azvm-main-command.ps1') -Raw
    $mainWorkflowText = Get-Content -LiteralPath (Join-Path $RepoRoot 'modules\commands\pipeline\azvm-main-workflow.ps1') -Raw

    Assert-True -Condition ($platformDefaultsText -match [regex]::Escape("return 'tools/pyssh/ssh_client.py'")) -Message 'Platform defaults must publish a non-empty PYSSH client path.'
    Assert-True -Condition ($commandContextText -match [regex]::Escape('VM_ENABLE_HIBERNATION')) -Message 'Command context must read VM_ENABLE_HIBERNATION.'
    Assert-True -Condition ($commandContextText -match [regex]::Escape('VM_ENABLE_NESTED_VIRTUALIZATION')) -Message 'Command context must read VM_ENABLE_NESTED_VIRTUALIZATION.'
    Assert-True -Condition ($featureSupportText -match [regex]::Escape('disabled by VM_ENABLE_HIBERNATION=false')) -Message 'Feature support must honor disabling hibernation by config.'
    Assert-True -Condition ($featureSupportText -match [regex]::Escape('disabled by VM_ENABLE_NESTED_VIRTUALIZATION=false')) -Message 'Feature support must honor disabling nested virtualization by config.'
    Assert-True -Condition ($commandContextText -match [regex]::Escape('nsg-rule-{VM_NAME}-{REGION_CODE}-n{N}')) -Message 'Command context must use the nsg-rule naming prefix.'
    Assert-True -Condition ($commandRuntimeText -match [regex]::Escape('Get-AzVmDefaultPySshClientPathText')) -Message 'Shared command runtime must consume the shared PYSSH client default.'
    Assert-True -Condition ($mainText -match [regex]::Escape('Write-AzVmMainBanner')) -Message 'Command main must render the review-first banner helper.'
    Assert-True -Condition ($mainWorkflowText -match [regex]::Escape('function Write-AzVmMainBanner')) -Message 'Main workflow helper must publish the banner renderer.'
    Assert-True -Condition (($commandContextText.IndexOf('Get-ConfigValue -Config $ConfigMap -Key "company_name" -DefaultValue ''''', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Command context must not fall back company_name to VM_NAME.'
    Assert-True -Condition (($commandContextText.IndexOf('Get-ConfigValue -Config $ConfigMap -Key ''employee_email_address'' -DefaultValue ''''', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Command context must read employee_email_address from config.'
    Assert-True -Condition (($commandContextText.IndexOf('Get-ConfigValue -Config $ConfigMap -Key ''employee_full_name'' -DefaultValue ''''', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Command context must read employee_full_name from config.'
    Assert-True -Condition (($commandRuntimeText.IndexOf('Get-ConfigValue -Config $effectiveConfigMap -Key ''company_name'' -DefaultValue ''''', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Command runtime must not fall back company_name to VM_NAME.'
    Assert-True -Condition (($commandRuntimeText.IndexOf('Get-ConfigValue -Config $effectiveConfigMap -Key ''employee_email_address'' -DefaultValue ''''', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Command runtime must read employee_email_address from config.'
    Assert-True -Condition (($commandRuntimeText.IndexOf('Get-ConfigValue -Config $effectiveConfigMap -Key ''employee_full_name'' -DefaultValue ''''', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Command runtime must read employee_full_name from config.'
}

Invoke-Test -Name "Runtime modules no longer carry personal or secret defaults" -Action {
    $filesToScan = @(
        (Get-ChildItem -Path (Join-Path $RepoRoot 'modules') -Recurse -Filter *.ps1 | ForEach-Object { $_.FullName })
        (Join-Path $RepoRoot 'tools\install-pyssh-tool.ps1')
    )

    foreach ($filePath in @($filesToScan)) {
        $text = Get-Content -LiteralPath $filePath -Raw
        foreach ($forbiddenFragment in @('examplevm','otherexamplevm','<runtime-secret>','<runtime-secret>')) {
            Assert-True -Condition (($text.IndexOf($forbiddenFragment, [System.StringComparison]::OrdinalIgnoreCase)) -lt 0) -Message ("Runtime file '{0}' must not contain '{1}'." -f $filePath, $forbiddenFragment)
        }
    }
}

Invoke-Test -Name "Task outcome mode is not platform-forced" -Action {
    $mainPath = Join-Path $RepoRoot 'modules\commands\pipeline\azvm-main-command.ps1'
    $runtimeContextPath = Join-Path $RepoRoot 'modules\commands\shared\runtime\azvm-command-runtime-context.ps1'

    $mainText = Get-Content -LiteralPath $mainPath -Raw
    $runtimeContextText = Get-Content -LiteralPath $runtimeContextPath -Raw

    Assert-True -Condition ($mainText -notmatch "platform\s*-eq\s*'windows'[\s\S]{0,120}taskOutcomeMode\s*=\s*'strict'") -Message "Main command runtime must not force windows task outcome mode to strict."
    Assert-True -Condition ($runtimeContextText -notmatch "platform\s*-eq\s*'windows'[\s\S]{0,120}taskOutcomeMode\s*=\s*'strict'") -Message "Shared command runtime must not force windows task outcome mode to strict."

    $runCommandDefinition = Get-Command Invoke-VmRunCommandBlocks -CommandType Function
    Assert-True -Condition ($null -ne $runCommandDefinition) -Message "Run-command task runner function was not loaded."
    Assert-True -Condition ($runCommandDefinition.Parameters.ContainsKey('TaskOutcomeMode')) -Message "Run-command task runner must expose TaskOutcomeMode parameter."
}

Invoke-Test -Name "Create and update always execute vm-init stage" -Action {
    $mainPath = Join-Path $RepoRoot 'modules\commands\pipeline\azvm-main-command.ps1'
    $mainText = Get-Content -LiteralPath $mainPath -Raw

    Assert-True -Condition ($mainText -notmatch [regex]::Escape('Default mode with existing VM: init tasks are skipped; proceeding directly to update tasks.')) -Message "Main command runtime must not skip vm-init for existing VMs in full create/update flow."
    Assert-True -Condition ($mainText -notmatch '\$shouldRunInitTasks\s*=') -Message "Main command runtime must not gate vm-init execution behind a should-run flag in full create/update flow."
}

Invoke-Test -Name "Create and update use review-first workflow checkpoints" -Action {
    $mainPath = Join-Path $RepoRoot 'modules\commands\pipeline\azvm-main-command.ps1'
    $mainWorkflowPath = Join-Path $RepoRoot 'modules\commands\pipeline\azvm-main-workflow.ps1'
    $mainText = Get-Content -LiteralPath $mainPath -Raw
    $mainWorkflowText = Get-Content -LiteralPath $mainWorkflowPath -Raw

    $checkpointMatches = [regex]::Matches($mainText, [regex]::Escape('Invoke-AzVmReviewCheckpoint'))
    Assert-True -Condition ($checkpointMatches.Count -eq 4) -Message 'Main command must invoke exactly four review checkpoints.'
    Assert-True -Condition ($mainText -match [regex]::Escape("Show-AzVmStepReview -Title 'Configuration review'")) -Message 'Main command must always show the configuration review screen.'
    Assert-True -Condition ($mainText -match [regex]::Escape("Write-AzVmWorkflowSummary")) -Message 'Main command must always print the workflow summary stage.'
    Assert-True -Condition ($mainText -match [regex]::Escape('$groupDecision = Invoke-AzVmReviewCheckpoint')) -Message 'Group stage must use a review checkpoint.'
    Assert-True -Condition ($mainText -match [regex]::Escape('$deployDecision = Invoke-AzVmReviewCheckpoint')) -Message 'VM deploy stage must use a review checkpoint.'
    Assert-True -Condition ($mainText -match [regex]::Escape('$initDecision = Invoke-AzVmReviewCheckpoint')) -Message 'VM init stage must use a review checkpoint.'
    Assert-True -Condition ($mainText -match [regex]::Escape('$updateDecision = Invoke-AzVmReviewCheckpoint')) -Message 'VM update stage must use a review checkpoint.'
    Assert-True -Condition (-not ($mainText -match [regex]::Escape('$configureDecision = Invoke-AzVmReviewCheckpoint'))) -Message 'Configure stage must not request confirmation.'
    Assert-True -Condition (-not ($mainText -match [regex]::Escape('$summaryDecision = Invoke-AzVmReviewCheckpoint'))) -Message 'VM summary stage must not request confirmation.'
    Assert-True -Condition ($mainWorkflowText -match [regex]::Escape('Confirm-YesNoCancel')) -Message 'Review workflow must use yes/no/cancel prompts.'
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
    Assert-True -Condition ([string]$parsedGlobalHelp.HelpTopic -eq "__overview__") -Message "Global --help should resolve to overview help."

    $parsedGlobalShortHelp = Parse-AzVmCliArguments -CommandToken "-h" -RawArgs @()
    Assert-True -Condition ([string]$parsedGlobalShortHelp.Command -eq "help") -Message "Global -h should resolve to help command."
    Assert-True -Condition ([string]$parsedGlobalShortHelp.HelpTopic -eq "__overview__") -Message "Global -h should resolve to overview help."

    $parsedHelpTopic = Parse-AzVmCliArguments -CommandToken "help" -RawArgs @("create")
    Assert-True -Condition ([string]$parsedHelpTopic.Command -eq "help") -Message "help command parse failed."
    Assert-True -Condition ([string]$parsedHelpTopic.HelpTopic -eq "create") -Message "Help topic positional parse failed."

    $parsedHelpShortFlag = Parse-AzVmCliArguments -CommandToken "help" -RawArgs @("-h")
    Assert-True -Condition ([string]$parsedHelpShortFlag.Command -eq "help") -Message "help -h parse failed."
    Assert-True -Condition ([string]$parsedHelpShortFlag.HelpTopic -eq "") -Message "help -h should keep detailed-catalog behavior."

    $parsedDoTopic = Parse-AzVmCliArguments -CommandToken "help" -RawArgs @("do")
    Assert-True -Condition ([string]$parsedDoTopic.Command -eq "help") -Message "help do parse failed."
    Assert-True -Condition ([string]$parsedDoTopic.HelpTopic -eq "do") -Message "Help topic parse failed for do."

    $parsedCommandHelp = Parse-AzVmCliArguments -CommandToken "create" -RawArgs @("--help")
    Assert-True -Condition ([string]$parsedCommandHelp.Command -eq "create") -Message "Command with --help parse failed."
    Assert-True -Condition ($parsedCommandHelp.Options.ContainsKey("help")) -Message "Command --help option was not captured."

    $parsedCommandShortHelp = Parse-AzVmCliArguments -CommandToken "create" -RawArgs @("-h")
    Assert-True -Condition ([string]$parsedCommandShortHelp.Command -eq "create") -Message "Command with -h parse failed."
    Assert-True -Condition ($parsedCommandShortHelp.Options.ContainsKey("help")) -Message "Command -h option was not captured."

    $parsedConfigureHelp = Parse-AzVmCliArguments -CommandToken "configure" -RawArgs @("--help")
    Assert-True -Condition ([string]$parsedConfigureHelp.Command -eq "configure") -Message "Configure command with --help parse failed."

    $parsedConfigureShortHelp = Parse-AzVmCliArguments -CommandToken "configure" -RawArgs @("-h")
    Assert-True -Condition ([string]$parsedConfigureShortHelp.Command -eq "configure") -Message "Configure command with -h parse failed."

    $parsedSshHelp = Parse-AzVmCliArguments -CommandToken "ssh" -RawArgs @("--help")
    Assert-True -Condition ([string]$parsedSshHelp.Command -eq "ssh") -Message "SSH command with --help parse failed."

    $parsedSshShortHelp = Parse-AzVmCliArguments -CommandToken "ssh" -RawArgs @("-h")
    Assert-True -Condition ([string]$parsedSshShortHelp.Command -eq "ssh") -Message "SSH command with -h parse failed."

    $parsedSshTest = Parse-AzVmCliArguments -CommandToken "ssh" -RawArgs @("--test")
    Assert-True -Condition ([string]$parsedSshTest.Command -eq "ssh") -Message "SSH command with --test parse failed."
    Assert-True -Condition ($parsedSshTest.Options.ContainsKey("test")) -Message "SSH command --test option was not captured."

    $parsedRdpHelp = Parse-AzVmCliArguments -CommandToken "rdp" -RawArgs @("--help")
    Assert-True -Condition ([string]$parsedRdpHelp.Command -eq "rdp") -Message "RDP command with --help parse failed."

    $parsedRdpShortHelp = Parse-AzVmCliArguments -CommandToken "rdp" -RawArgs @("-h")
    Assert-True -Condition ([string]$parsedRdpShortHelp.Command -eq "rdp") -Message "RDP command with -h parse failed."

    $parsedRdpTest = Parse-AzVmCliArguments -CommandToken "rdp" -RawArgs @("--test")
    Assert-True -Condition ([string]$parsedRdpTest.Command -eq "rdp") -Message "RDP command with --test parse failed."
    Assert-True -Condition ($parsedRdpTest.Options.ContainsKey("test")) -Message "RDP command --test option was not captured."

    $parsedDoHelp = Parse-AzVmCliArguments -CommandToken "do" -RawArgs @("--help")
    Assert-True -Condition ([string]$parsedDoHelp.Command -eq "do") -Message "Do command with --help parse failed."
    Assert-True -Condition ($parsedDoHelp.Options.ContainsKey("help")) -Message "Do command --help option was not captured."

    $parsedDoShortHelp = Parse-AzVmCliArguments -CommandToken "do" -RawArgs @("-h")
    Assert-True -Condition ([string]$parsedDoShortHelp.Command -eq "do") -Message "Do command with -h parse failed."
    Assert-True -Condition ($parsedDoShortHelp.Options.ContainsKey("help")) -Message "Do command -h option was not captured."

    $parsedResizeHelp = Parse-AzVmCliArguments -CommandToken "resize" -RawArgs @("--help")
    Assert-True -Condition ([string]$parsedResizeHelp.Command -eq "resize") -Message "Resize command with --help parse failed."
    Assert-True -Condition ($parsedResizeHelp.Options.ContainsKey("help")) -Message "Resize command --help option was not captured."

    $parsedResizeShortHelp = Parse-AzVmCliArguments -CommandToken "resize" -RawArgs @("-h")
    Assert-True -Condition ([string]$parsedResizeShortHelp.Command -eq "resize") -Message "Resize command with -h parse failed."
    Assert-True -Condition ($parsedResizeShortHelp.Options.ContainsKey("help")) -Message "Resize command -h option was not captured."
}

Invoke-Test -Name "Task catalog fallback defaults" -Action {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("az-vm-catalog-test-" + [Guid]::NewGuid().ToString("N"))
    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    try {
        $task01 = Join-Path $tempRoot "01-initial-default.ps1"
        $task101 = Join-Path $tempRoot "101-normal-default.ps1"
        Set-Content -Path $task01 -Value "Write-Host 'task01'" -Encoding UTF8
        Set-Content -Path $task101 -Value "Write-Host 'task101'" -Encoding UTF8

        $catalogPath = Join-Path $tempRoot "vm-update-task-catalog.json"
        $catalogJson = @'
{
  "defaults": {
    "priority": 1000,
    "timeout": 180
  },
  "tasks": [
    {
      "name": "101-normal-default",
      "enabled": true
    }
  ]
}
'@
        Set-Content -Path $catalogPath -Value $catalogJson -Encoding UTF8

        $catalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath $tempRoot -Platform windows -Stage update
        $active = @($catalog.ActiveTasks)
        Assert-True -Condition ($active.Count -eq 2) -Message "Expected 2 active tasks."
        Assert-True -Condition ([string]$active[0].Name -eq "01-initial-default") -Message "Initial tracked task must keep its initial-band order."
        Assert-True -Condition ([string]$active[1].Name -eq "101-normal-default") -Message "Normal tracked task must keep its normal-band order."

        $initialTask = $active | Where-Object { [string]$_.Name -eq "01-initial-default" } | Select-Object -First 1
        $normalTask = $active | Where-Object { [string]$_.Name -eq "101-normal-default" } | Select-Object -First 1
        Assert-True -Condition ([int]$initialTask.Priority -eq 1000) -Message "Missing tracked catalog entry must default to priority 1000."
        Assert-True -Condition ([int]$normalTask.Priority -eq 1000) -Message "Tracked catalog entry without explicit priority must default to priority 1000."
        Assert-True -Condition ([int]$initialTask.TimeoutSeconds -eq 180) -Message "Missing tracked catalog entry timeout must default to 180."
        Assert-True -Condition ([int]$normalTask.TimeoutSeconds -eq 180) -Message "Tracked catalog entry without explicit timeout must default to 180."
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
    Assert-AzVmCommandOptions -CommandName "task" -Options @{ help = $true }
    Assert-AzVmCommandOptions -CommandName "move" -Options @{ help = $true }
    Assert-AzVmCommandOptions -CommandName "resize" -Options @{ help = $true }
    Assert-AzVmCommandOptions -CommandName "set" -Options @{ help = $true }
    Assert-AzVmCommandOptions -CommandName "exec" -Options @{ help = $true }
    Assert-AzVmCommandOptions -CommandName "ssh" -Options @{ help = $true }
    Assert-AzVmCommandOptions -CommandName "rdp" -Options @{ help = $true }
    Assert-AzVmCommandOptions -CommandName "delete" -Options @{ help = $true }
}

Invoke-Test -Name "SSH and RDP commands accept automated test mode" -Action {
    Assert-AzVmCommandOptions -CommandName "ssh" -Options @{ test = $true }
    Assert-AzVmCommandOptions -CommandName "ssh" -Options @{ 'vm-name' = 'samplevm'; user = 'manager'; test = $true }
    Assert-AzVmCommandOptions -CommandName "rdp" -Options @{ test = $true }
    Assert-AzVmCommandOptions -CommandName "rdp" -Options @{ group = 'rg-samplevm-ate1-g1'; 'vm-name' = 'samplevm'; user = 'assistant'; test = $true }
}

Invoke-Test -Name "Create and update accept vm-name override" -Action {
    Assert-AzVmCommandOptions -CommandName 'create' -Options @{ 'vm-name' = 'samplevm'; auto = $true }
    Assert-AzVmCommandOptions -CommandName 'update' -Options @{ 'vm-name' = 'samplevm'; auto = $true }
}

Invoke-Test -Name "Create and update accept renamed step selectors and create destructive rebuild" -Action {
    Assert-AzVmCommandOptions -CommandName 'create' -Options @{ step = 'network'; linux = $true }
    Assert-AzVmCommandOptions -CommandName 'create' -Options @{ 'step-from' = 'vm-deploy'; 'step-to' = 'vm-summary'; auto = $true; windows = $true; 'vm-name' = 'samplevm'; 'vm-region' = 'swedencentral'; 'vm-size' = 'Standard_D4as_v5' }
    Assert-AzVmCommandOptions -CommandName 'create' -Options @{ destructive rebuild = $true; auto = $true; windows = $true; 'vm-name' = 'samplevm'; 'vm-region' = 'swedencentral'; 'vm-size' = 'Standard_D4as_v5' }
    Assert-AzVmCommandOptions -CommandName 'update' -Options @{ step = 'vm-update'; auto = $true; windows = $true; group = 'rg-samplevm-ate1-g1'; 'vm-name' = 'samplevm' }
    Assert-AzVmCommandOptions -CommandName 'update' -Options @{ 'step-from' = 'group'; 'step-to' = 'vm-init'; auto = $true; windows = $true; group = 'rg-samplevm-ate1-g1'; 'vm-name' = 'samplevm' }
}

Invoke-Test -Name "Create and update reject retired step selectors" -Action {
    $retiredOptionCases = @(
        @{ Command = 'create'; Options = @{ 'single-step' = 'network' } },
        @{ Command = 'create'; Options = @{ 'from-step' = 'group'; 'step-to' = 'vm-init' } },
        @{ Command = 'create'; Options = @{ 'step-from' = 'group'; 'to-step' = 'vm-init' } },
        @{ Command = 'update'; Options = @{ 'single-step' = 'vm-update'; auto = $true } },
        @{ Command = 'update'; Options = @{ 'from-step' = 'vm-deploy'; 'to-step' = 'vm-summary'; auto = $true } }
    )

    foreach ($case in @($retiredOptionCases)) {
        $threw = $false
        try {
            Assert-AzVmCommandOptions -CommandName ([string]$case.Command) -Options $case.Options
        }
        catch {
            $threw = $true
        }

        Assert-True -Condition $threw -Message ("Retired step selector must be rejected for command '{0}'." -f [string]$case.Command)
    }
}

Invoke-Test -Name "Action plan resolves renamed step selectors" -Action {
    $singlePlan = Resolve-AzVmActionPlan -CommandName 'create' -Options @{ step = 'network' }
    Assert-True -Condition ([string]$singlePlan.Mode -eq 'single') -Message "Single-step action plan mode mismatch."
    Assert-True -Condition (@($singlePlan.Actions).Count -eq 1 -and [string]$singlePlan.Actions[0] -eq 'network') -Message "Single-step action plan must contain only the requested step."

    $rangePlan = Resolve-AzVmActionPlan -CommandName 'update' -Options @{ 'step-from' = 'vm-deploy'; 'step-to' = 'vm-summary' }
    Assert-True -Condition ([string]$rangePlan.Mode -eq 'range') -Message "Range action plan mode mismatch."
    Assert-True -Condition ((@($rangePlan.Actions) -join ',') -eq 'vm-deploy,vm-init,vm-update,vm-summary') -Message "Range action plan must include the forward step window."

    $threw = $false
    try {
        Resolve-AzVmActionPlan -CommandName 'create' -Options @{ step = 'network'; 'step-to' = 'vm-summary' } | Out-Null
    }
    catch {
        $threw = $true
    }

    Assert-True -Condition $threw -Message "Conflicting renamed step selectors must be rejected."
}

Invoke-Test -Name "Move and set commands accept vm-name" -Action {
    Assert-AzVmCommandOptions -CommandName 'move' -Options @{ 'vm-name' = 'samplevm'; 'vm-region' = 'swedencentral'; group = 'rg-samplevm-ate1-g1' }
    Assert-AzVmCommandOptions -CommandName 'set' -Options @{ 'vm-name' = 'samplevm'; group = 'rg-samplevm-ate1-g1'; hibernation = 'on' }
}

Invoke-Test -Name "Task command accepts list filters" -Action {
    Assert-AzVmCommandOptions -CommandName 'task' -Options @{ list = $true }
    Assert-AzVmCommandOptions -CommandName 'task' -Options @{ list = $true; 'vm-init' = $true; windows = $true }
    Assert-AzVmCommandOptions -CommandName 'task' -Options @{ list = $true; 'vm-update' = $true; disabled = $true; linux = $true }
}

Invoke-Test -Name "Task command lists discovered tasks in runtime order" -Action {
    try {
        function Initialize-AzVmTaskCommandRuntimeContext {
            param([switch]$AutoMode, [switch]$WindowsFlag, [switch]$LinuxFlag)
            return [pscustomobject]@{
                Platform = 'windows'
                VmInitTaskDir = 'windows/init'
                VmUpdateTaskDir = 'windows/update'
            }
        }
        function Get-AzVmTaskBlocksFromDirectory {
            param([string]$DirectoryPath, [string]$Platform, [string]$Stage, [switch]$SuppressSkipMessages)
            if ($Stage -eq 'init') {
                return [ordered]@{
                    InventoryTasks = @(
                        [pscustomobject]@{
                            Name = '01-ensure-users-local'
                            RelativePath = '01-ensure-users-local.ps1'
                            TimeoutSeconds = 180
                            Priority = 1
                            TaskType = 'initial'
                            Source = 'tracked'
                            TaskNumber = 1
                            Enabled = $true
                            DisabledReason = ''
                        },
                        [pscustomobject]@{
                            Name = '1004-disabled-local-task'
                            RelativePath = 'local/disabled/1004-disabled-local-task.ps1'
                            TimeoutSeconds = 180
                            Priority = 1004
                            TaskType = 'local'
                            Source = 'local'
                            TaskNumber = 1004
                            Enabled = $false
                            DisabledReason = 'disabled-by-location'
                        }
                    )
                }
            }

            return [ordered]@{
                InventoryTasks = @(
                    [pscustomobject]@{
                        Name = '10099-capture-snapshot-health'
                        RelativePath = '10099-capture-snapshot-health.ps1'
                        TimeoutSeconds = 30
                        Priority = 10099
                        TaskType = 'final'
                        Source = 'tracked'
                        TaskNumber = 10099
                        Enabled = $true
                        DisabledReason = ''
                    }
                )
            }
        }

        $updateResult = Invoke-AzVmTaskCommand -Options @{ list = $true; 'vm-update' = $true } -AutoMode:$false -WindowsFlag -LinuxFlag:$false
        Assert-True -Condition ($null -ne $updateResult) -Message 'Task command must return a result object.'
        Assert-True -Condition ($updateResult.Rows.Count -eq 1) -Message 'Task command vm-update filter must return only update-stage rows.'
        Assert-True -Condition ([string]$updateResult.Rows[0].Name -eq '10099-capture-snapshot-health') -Message 'Task command must preserve discovered update task names.'
        Assert-True -Condition ([string]$updateResult.Rows[0].Stage -eq 'vm-update') -Message 'Task command must label update-stage rows.'

        $disabledResult = Invoke-AzVmTaskCommand -Options @{ list = $true; disabled = $true } -AutoMode:$false -WindowsFlag -LinuxFlag:$false
        Assert-True -Condition ($disabledResult.Rows.Count -eq 1) -Message 'Task command disabled filter must return only disabled rows.'
        Assert-True -Condition ([string]$disabledResult.Rows[0].Status -eq 'disabled') -Message 'Task command disabled filter must label disabled tasks correctly.'
        Assert-True -Condition ([string]$disabledResult.Rows[0].Source -eq 'local') -Message 'Task command must preserve local/builtin source labels.'
    }
    finally {
        foreach ($functionName in @(
            'Initialize-AzVmTaskCommandRuntimeContext',
            'Get-AzVmTaskBlocksFromDirectory'
        )) {
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue
        }
    }
}

Invoke-Test -Name "Set command applies both toggles and persists them to .env" -Action {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("az-vm-set-test-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tempRoot -Force
    $envFilePath = Join-Path $tempRoot '.env'
    Write-TextFileNormalized -Path $envFilePath -Content @"
RESOURCE_GROUP=rg-old
VM_NAME=oldvm
VM_ENABLE_HIBERNATION=false
VM_ENABLE_NESTED_VIRTUALIZATION=true
"@ -Encoding 'utf8NoBom' -LineEnding 'crlf' -EnsureTrailingNewline

    try {
        $script:SetCommandAzCalls = @()

        function Get-AzVmRepoRoot { return $tempRoot }
        function Initialize-AzVmCommandRuntimeContext { throw 'Set command must not initialize the full command runtime context.' }
        function Resolve-AzVmManagedVmTarget {
            param([hashtable]$Options, [hashtable]$ConfigMap, [string]$OperationName)
            return [pscustomobject]@{
                ResourceGroup = 'rg-target'
                VmName = 'targetvm'
            }
        }
        function Invoke-TrackedAction {
            param([string]$Label, [scriptblock]$Action)
            & $Action
            return [pscustomobject]@{ Label = $Label }
        }
        function az {
            $script:SetCommandAzCalls += ,(@($args) -join ' ')
            $global:LASTEXITCODE = 0
            return ''
        }

        Invoke-AzVmSetCommand -Options @{
            group = 'rg-target'
            'vm-name' = 'targetvm'
            hibernation = 'on'
            'nested-virtualization' = 'off'
        } -AutoMode:$false -WindowsFlag:$false -LinuxFlag:$false

        $envMap = Read-DotEnvFile -Path $envFilePath
        Assert-True -Condition ([string]$envMap['RESOURCE_GROUP'] -eq 'rg-target') -Message 'Set command must persist the resolved resource group.'
        Assert-True -Condition ([string]$envMap['VM_NAME'] -eq 'targetvm') -Message 'Set command must persist the resolved VM name.'
        Assert-True -Condition ([string]$envMap['VM_ENABLE_HIBERNATION'] -eq 'true') -Message 'Set command must persist VM_ENABLE_HIBERNATION=true when hibernation is turned on.'
        Assert-True -Condition ([string]$envMap['VM_ENABLE_NESTED_VIRTUALIZATION'] -eq 'false') -Message 'Set command must persist VM_ENABLE_NESTED_VIRTUALIZATION=false when nested virtualization is turned off.'
        Assert-True -Condition (@($script:SetCommandAzCalls).Count -eq 1) -Message 'Set command must issue the Azure hibernation update without calling a nested virtualization API toggle.'
        Assert-True -Condition ((@($script:SetCommandAzCalls) -join "`n") -match [regex]::Escape('--enable-hibernation true')) -Message 'Set command must call Azure hibernation update.'
        Assert-True -Condition (-not ((@($script:SetCommandAzCalls) -join "`n") -match [regex]::Escape('additionalCapabilities.nestedVirtualization'))) -Message 'Set command must not call the removed Azure nested virtualization property path.'
    }
    finally {
        foreach ($functionName in @(
            'Get-AzVmRepoRoot',
            'Initialize-AzVmCommandRuntimeContext',
            'Resolve-AzVmManagedVmTarget',
            'Invoke-TrackedAction',
            'az'
        )) {
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name SetCommandAzCalls -Scope Script -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "Set command persists successful updates before a later toggle failure" -Action {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("az-vm-set-failover-test-" + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tempRoot -Force
    $envFilePath = Join-Path $tempRoot '.env'
    Write-TextFileNormalized -Path $envFilePath -Content @"
RESOURCE_GROUP=rg-old
VM_NAME=oldvm
VM_ENABLE_HIBERNATION=false
VM_ENABLE_NESTED_VIRTUALIZATION=true
"@ -Encoding 'utf8NoBom' -LineEnding 'crlf' -EnsureTrailingNewline

    try {
        $script:SetCommandFailureAzCalls = @()
        $script:SetCommandNestedValidationCalled = $false

        function Get-AzVmRepoRoot { return $tempRoot }
        function Resolve-AzVmManagedVmTarget {
            param([hashtable]$Options, [hashtable]$ConfigMap, [string]$OperationName)
            return [pscustomobject]@{
                ResourceGroup = 'rg-target'
                VmName = 'targetvm'
            }
        }
        function Invoke-TrackedAction {
            param([string]$Label, [scriptblock]$Action)
            & $Action
            return [pscustomobject]@{ Label = $Label }
        }
        function Get-AzVmVmLifecycleSnapshot {
            param([string]$ResourceGroup, [string]$VmName)
            return [pscustomobject]@{
                NormalizedState = 'started'
                VmName = $VmName
                ResourceGroup = $ResourceGroup
                PowerStateDisplay = 'VM running'
                ProvisioningStateDisplay = 'Provisioning succeeded'
                HibernationStateDisplay = ''
                HibernationStateCode = ''
                HibernationEnabled = $true
            }
        }
        function Get-AzVmNestedVirtualizationGuestValidation {
            param([string]$ResourceGroup, [string]$VmName, [string]$OsType)
            $script:SetCommandNestedValidationCalled = $true
            return [pscustomobject]@{
                Known = $true
                Enabled = $false
                Evidence = @('VirtualizationFirmwareEnabled=False')
                Data = $null
                ErrorMessage = ''
            }
        }
        function az {
            $line = @($args) -join ' '
            $script:SetCommandFailureAzCalls += ,$line
            $global:LASTEXITCODE = 0
            return ''
        }

        $threw = $false
        try {
            Invoke-AzVmSetCommand -Options @{
                group = 'rg-target'
                'vm-name' = 'targetvm'
                hibernation = 'on'
                'nested-virtualization' = 'on'
            } -AutoMode:$false -WindowsFlag:$false -LinuxFlag:$false
        }
        catch {
            $threw = $true
        }

        Assert-True -Condition $threw -Message 'Set command must fail when nested virtualization guest validation fails.'
        Assert-True -Condition ([bool]$script:SetCommandNestedValidationCalled) -Message 'Set command must validate nested virtualization through guest checks when turning it on.'
        $envMap = Read-DotEnvFile -Path $envFilePath
        Assert-True -Condition ([string]$envMap['RESOURCE_GROUP'] -eq 'rg-target') -Message 'Set command must still persist the resolved resource group after a partial update.'
        Assert-True -Condition ([string]$envMap['VM_NAME'] -eq 'targetvm') -Message 'Set command must still persist the resolved VM name after a partial update.'
        Assert-True -Condition ([string]$envMap['VM_ENABLE_HIBERNATION'] -eq 'true') -Message 'Set command must persist the successful hibernation update even if a later toggle fails.'
        Assert-True -Condition ([string]$envMap['VM_ENABLE_NESTED_VIRTUALIZATION'] -eq 'true') -Message 'Set command must not overwrite nested virtualization in .env when the Azure update failed.'
    }
    finally {
        foreach ($functionName in @(
            'Get-AzVmRepoRoot',
            'Resolve-AzVmManagedVmTarget',
            'Invoke-TrackedAction',
            'Get-AzVmVmLifecycleSnapshot',
            'Get-AzVmNestedVirtualizationGuestValidation',
            'az'
        )) {
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name SetCommandFailureAzCalls -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name SetCommandNestedValidationCalled -Scope Script -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "Post-deploy feature enablement verifies desired flags even on existing VMs" -Action {
    $script:FeatureEnablementAzCalls = @()
    $script:FeatureEnablementGuestValidationCalled = $false
    $script:FeatureEnablementState = @{
        HibernationEnabled = $false
    }
    try {
        function Invoke-TrackedAction {
            param([string]$Label, [scriptblock]$Action)
            & $Action
            return [pscustomobject]@{ Label = $Label }
        }
        function Get-AzVmHibernationSupportInfo {
            param([string]$Location, [string]$VmSize)
            return [pscustomobject]@{
                Known = $true
                Supported = $true
                Evidence = @('HibernationSupported=true')
                Message = 'hibernation-supported'
            }
        }
        function Get-AzVmNestedVirtualizationSupportInfo {
            param([string]$Location, [string]$VmSize)
            return [pscustomobject]@{
                Known = $false
                Supported = $false
                Evidence = @()
                Message = 'nested-capability-inconclusive'
            }
        }
        function Get-AzVmNestedVirtualizationGuestValidation {
            param([string]$ResourceGroup, [string]$VmName, [string]$OsType, [int]$MaxAttempts, [int]$RetryDelaySeconds)
            $script:FeatureEnablementGuestValidationCalled = $true
            return [pscustomobject]@{
                Known = $true
                Enabled = $true
                Evidence = @('VMMonitorModeExtensions=True','VirtualizationFirmwareEnabled=True','SecondLevelAddressTranslationExtensions=True')
                Data = $null
                ErrorMessage = ''
            }
        }
        function az {
            $line = @($args) -join ' '
            $script:FeatureEnablementAzCalls += ,$line

            if ($line -match [regex]::Escape('get-instance-view')) {
                $global:LASTEXITCODE = 0
                return '{"provisioningCode":"ProvisioningState/succeeded","provisioningDisplay":"Provisioning succeeded","powerCode":"PowerState/running","powerDisplay":"VM running"}'
            }
            if ($line -match [regex]::Escape('securityProfile.securityType')) {
                $global:LASTEXITCODE = 0
                return '{"securityType":"Standard","secureBoot":true,"vTpm":true}'
            }
            if ($line -match [regex]::Escape('additionalCapabilities.hibernationEnabled')) {
                $global:LASTEXITCODE = 0
                if ([bool]$script:FeatureEnablementState.HibernationEnabled) { return 'true' }
                return ''
            }
            if ($line -match [regex]::Escape('disk update') -or $line -match [regex]::Escape('--set supportsHibernation=true')) {
                $global:LASTEXITCODE = 0
                return ''
            }
            if ($line -match [regex]::Escape('--enable-hibernation true')) {
                $script:FeatureEnablementState.HibernationEnabled = $true
                $global:LASTEXITCODE = 0
                return ''
            }

            $global:LASTEXITCODE = 0
            return ''
        }

        $result = Invoke-AzVmPostDeployFeatureEnablement -Context @{
            ResourceGroup = 'rg-samplevm-ate1-g1'
            VmName = 'samplevm'
            VmDiskName = 'disk-samplevm'
            AzLocation = 'austriaeast'
            VmSize = 'Standard_D4as_v5'
            VmSecurityType = 'Standard'
            VmEnableHibernation = $true
            VmEnableNestedVirtualization = $true
        } -VmCreatedThisRun:$false

        Assert-True -Condition ([bool]$result.HibernationAttempted) -Message 'Feature enablement must still evaluate hibernation on existing VMs.'
        Assert-True -Condition ([bool]$result.HibernationEnabled) -Message 'Feature enablement must verify hibernation.'
        Assert-True -Condition ([bool]$result.NestedAttempted) -Message 'Feature enablement must still evaluate nested virtualization on existing VMs.'
        Assert-True -Condition ([bool]$result.NestedEnabled) -Message 'Feature enablement must verify nested virtualization.'
        Assert-True -Condition ([bool]$script:FeatureEnablementGuestValidationCalled) -Message 'Feature enablement must validate nested virtualization through guest checks.'
        Assert-True -Condition ((@($script:FeatureEnablementAzCalls) -join "`n") -match [regex]::Escape('instanceView.statuses[?starts_with(code,''ProvisioningState/'')]')) -Message 'Feature enablement must read provisioning state from instanceView.statuses in get-instance-view output.'
        Assert-True -Condition ((@($script:FeatureEnablementAzCalls) -join "`n") -match [regex]::Escape('--enable-hibernation true')) -Message 'Feature enablement must call the Azure hibernation update.'
        Assert-True -Condition (-not ((@($script:FeatureEnablementAzCalls) -join "`n") -match [regex]::Escape('additionalCapabilities.nestedVirtualization'))) -Message 'Feature enablement must not call the removed Azure nested virtualization property path.'
        Assert-True -Condition ((@($script:FeatureEnablementAzCalls) | Where-Object { $_ -like '*vm deallocate*' }).Count -eq 1) -Message 'Feature enablement should deallocate the VM once before applying feature updates.'
        Assert-True -Condition ((@($script:FeatureEnablementAzCalls) | Where-Object { $_ -like '*vm start*' }).Count -eq 1) -Message 'Feature enablement should start the VM again after feature updates.'
    }
    finally {
        foreach ($functionName in @(
            'Invoke-TrackedAction',
            'Get-AzVmHibernationSupportInfo',
            'Get-AzVmNestedVirtualizationSupportInfo',
            'Get-AzVmNestedVirtualizationGuestValidation',
            'az'
        )) {
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name FeatureEnablementAzCalls -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name FeatureEnablementGuestValidationCalled -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name FeatureEnablementState -Scope Script -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "Windows nested virtualization guest validation accepts an active nested runtime" -Action {
    try {
        function Invoke-AzVmVmRunCommandJson {
            param(
                [string]$ResourceGroup,
                [string]$VmName,
                [string]$CommandId,
                [string[]]$Scripts,
                [string]$ContextLabel,
                [int]$MaxAttempts,
                [int]$RetryDelaySeconds
            )

            return [pscustomobject]@{
                Success = $true
                ErrorMessage = ''
                OutputObject = [pscustomobject]@{
                    ProcessorName = 'AMD EPYC 7763 64-Core Processor'
                    VMMonitorModeExtensions = $false
                    VirtualizationFirmwareEnabled = $true
                    SecondLevelAddressTranslationExtensions = $false
                    HyperVisorPresent = $true
                    VirtualMachinePlatformState = 'Enabled'
                    HypervisorPlatformState = 'Disabled'
                    MicrosoftHyperVState = 'Disabled'
                    MicrosoftHyperVAllState = 'Disabled'
                    BcdHypervisorLaunchType = ''
                }
            }
        }

        $result = Get-AzVmNestedVirtualizationGuestValidation -ResourceGroup 'rg-samplevm-ate1-g1' -VmName 'samplevm' -OsType 'windows'

        Assert-True -Condition ([bool]$result.Known) -Message 'Nested virtualization guest validation must return a known result when run-command succeeds.'
        Assert-True -Condition ([bool]$result.Enabled) -Message 'Nested virtualization guest validation must accept a running nested runtime on Windows guests.'
        Assert-True -Condition ((@($result.Evidence) -join "`n") -match [regex]::Escape('HyperVisorPresent=True')) -Message 'Nested virtualization guest validation must record active hypervisor evidence.'
        Assert-True -Condition ((@($result.Evidence) -join "`n") -match [regex]::Escape('VirtualMachinePlatformState=Enabled')) -Message 'Nested virtualization guest validation must record virtualization platform feature state.'
    }
    finally {
        Remove-Item Function:\Invoke-AzVmVmRunCommandJson -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "Post-deploy feature enablement fails when nested virtualization cannot be verified" -Action {
    try {
        $script:FeatureEnablementFailureAzCalls = @()
        function Invoke-TrackedAction {
            param([string]$Label, [scriptblock]$Action)
            & $Action
            return [pscustomobject]@{ Label = $Label }
        }
        function Get-AzVmHibernationSupportInfo {
            param([string]$Location, [string]$VmSize)
            return [pscustomobject]@{
                Known = $true
                Supported = $true
                Evidence = @('HibernationSupported=true')
                Message = 'hibernation-supported'
            }
        }
        function Get-AzVmNestedVirtualizationSupportInfo {
            param([string]$Location, [string]$VmSize)
            return [pscustomobject]@{
                Known = $false
                Supported = $false
                Evidence = @()
                Message = 'nested-capability-inconclusive'
            }
        }
        function Get-AzVmNestedVirtualizationGuestValidation {
            param([string]$ResourceGroup, [string]$VmName, [string]$OsType, [int]$MaxAttempts, [int]$RetryDelaySeconds)
            return [pscustomobject]@{
                Known = $true
                Enabled = $false
                Evidence = @('VirtualizationFirmwareEnabled=False')
                Data = $null
                ErrorMessage = ''
            }
        }
        function az {
            $line = @($args) -join ' '
            $script:FeatureEnablementFailureAzCalls += ,$line
            if ($line -match [regex]::Escape('get-instance-view')) {
                $global:LASTEXITCODE = 0
                return '{"provisioningCode":"ProvisioningState/succeeded","provisioningDisplay":"Provisioning succeeded","powerCode":"PowerState/running","powerDisplay":"VM running"}'
            }
            if ($line -match [regex]::Escape('securityProfile.securityType')) {
                $global:LASTEXITCODE = 0
                return '{"securityType":"Standard","secureBoot":true,"vTpm":true}'
            }
            if ($line -match [regex]::Escape('additionalCapabilities.hibernationEnabled')) {
                $global:LASTEXITCODE = 0
                return 'true'
            }
            if ($line -match [regex]::Escape('additionalCapabilities.nestedVirtualization')) {
                $global:LASTEXITCODE = 0
                return ''
            }

            $global:LASTEXITCODE = 0
            return ''
        }

        $threw = $false
        try {
            Invoke-AzVmPostDeployFeatureEnablement -Context @{
                ResourceGroup = 'rg-samplevm-ate1-g1'
                VmName = 'samplevm'
                VmDiskName = 'disk-samplevm'
                AzLocation = 'austriaeast'
                VmSize = 'Standard_D4as_v5'
                VmSecurityType = 'Standard'
                VmEnableHibernation = $true
                VmEnableNestedVirtualization = $true
            } -VmCreatedThisRun:$true | Out-Null
        }
        catch {
            $threw = $true
            Assert-True -Condition ([string]$_.Exception.Message -like '*nested virtualization*') -Message 'Nested verification failure should mention nested virtualization.'
        }

        Assert-True -Condition $threw -Message 'Feature enablement must fail when nested virtualization stays unverified.'
        Assert-True -Condition ((@($script:FeatureEnablementFailureAzCalls) -join "`n") -match [regex]::Escape('instanceView.statuses[?starts_with(code,''ProvisioningState/'')]')) -Message 'Feature enablement failure path must still read provisioning state from instanceView.statuses.'
    }
    finally {
        foreach ($functionName in @(
            'Invoke-TrackedAction',
            'Get-AzVmHibernationSupportInfo',
            'Get-AzVmNestedVirtualizationSupportInfo',
            'Get-AzVmNestedVirtualizationGuestValidation',
            'az'
        )) {
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name FeatureEnablementFailureAzCalls -Scope Script -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "VM create security args are omitted for existing VMs" -Action {
    try {
        function Test-AzVmAzResourceExists {
            param([string[]]$AzArgs)
            return ([string]$AzArgs[-1] -eq 'existingvm')
        }

        $context = @{
            VmSecurityType = 'Standard'
            VmEnableSecureBoot = $false
            VmEnableVtpm = $false
        }

        $existingVmArgs = @(Get-AzVmCreateSecurityArgumentsForCurrentVmState -Context $context -ResourceGroup 'rg-samplevm-ate1-g1' -VmName 'existingvm' -SuppressNotice)
        $newVmArgs = @(Get-AzVmCreateSecurityArgumentsForCurrentVmState -Context $context -ResourceGroup 'rg-samplevm-ate1-g1' -VmName 'newvm' -SuppressNotice)

        Assert-True -Condition ($existingVmArgs.Count -eq 0) -Message 'Existing VMs must omit security-type create arguments.'
        Assert-True -Condition ($newVmArgs.Count -ge 2) -Message 'New VMs must keep security-type create arguments.'
        Assert-True -Condition ($newVmArgs -contains '--security-type') -Message 'New VMs must keep the security-type argument.'
    }
    finally {
        Remove-Item Function:\Test-AzVmAzResourceExists -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "VM create step tolerates a transient non-zero create when the new VM appears after probing" -Action {
    $script:VmCreateProbeCount = 0
    $script:VmCreateDetailedShowCalled = $false
    $script:VmCreateActionCalled = $false

    try {
        function Show-AzVmStepFirstUseValues { param([string]$StepLabel, [hashtable]$Context, [string[]]$Keys, [hashtable]$ExtraValues) }
        function Invoke-TrackedAction {
            param([string]$Label, [scriptblock]$Action)
            & $Action
        }
        function Invoke-AzVmPostDeployFeatureEnablement {
            param([hashtable]$Context, [switch]$VmCreatedThisRun)
            return [pscustomobject]@{
                HibernationAttempted = $false
                HibernationEnabled = $false
                HibernationMessage = ''
                NestedAttempted = $false
                NestedEnabled = $false
                NestedMessage = ''
            }
        }
        function Test-AzVmAzResourceExists {
            param([string[]]$AzArgs)
            $script:VmCreateProbeCount++
            return $true
        }
        function az {
            $line = @($args) -join ' '
            if ($line -match [regex]::Escape('vm list')) {
                $global:LASTEXITCODE = 0
                return ''
            }
            if ($line -match [regex]::Escape('--query id')) {
                $global:LASTEXITCODE = 0
                return '/subscriptions/test/resourceGroups/rg-samplevm-ate1-g1/providers/Microsoft.Compute/virtualMachines/samplevm'
            }
            if ($line -match [regex]::Escape('vm show -g rg-samplevm-ate1-g1 -n samplevm -d')) {
                $script:VmCreateDetailedShowCalled = $true
                $global:LASTEXITCODE = 0
                return '{"id":"/subscriptions/test/resourceGroups/rg-samplevm-ate1-g1/providers/Microsoft.Compute/virtualMachines/samplevm"}'
            }

            $global:LASTEXITCODE = 0
            return ''
        }

        $result = Invoke-AzVmVmCreateStep -Context @{
            ResourceGroup = 'rg-samplevm-ate1-g1'
            VmName = 'samplevm'
        } -ExecutionMode 'default' -CreateVmAction {
            $script:VmCreateActionCalled = $true
            $global:LASTEXITCODE = 1
            return ''
        }

        Assert-True -Condition $script:VmCreateActionCalled -Message 'VM create step must run the create action.'
        Assert-True -Condition ($script:VmCreateProbeCount -ge 1) -Message 'VM create step must probe for a VM that may have landed after a non-zero create result.'
        Assert-True -Condition $script:VmCreateDetailedShowCalled -Message 'VM create step must recover through az vm show -d after the VM appears.'
        Assert-True -Condition ([string]$result.VmId -eq '/subscriptions/test/resourceGroups/rg-samplevm-ate1-g1/providers/Microsoft.Compute/virtualMachines/samplevm') -Message 'VM create step must keep the recovered VM id.'
        Assert-True -Condition ([bool]$result.VmCreateInvoked) -Message 'VM create step must still report the create action as invoked.'
        Assert-True -Condition ([bool]$result.VmCreatedThisRun) -Message 'VM create step must classify the recovered VM as newly created.'
    }
    finally {
        foreach ($functionName in @(
            'Show-AzVmStepFirstUseValues',
            'Invoke-TrackedAction',
            'Invoke-AzVmPostDeployFeatureEnablement',
            'Test-AzVmAzResourceExists',
            'az'
        )) {
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name VmCreateProbeCount -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name VmCreateDetailedShowCalled -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name VmCreateActionCalled -Scope Script -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "Create runtime keeps fresh-target overrides and exposes destructive rebuild mode" -Action {
    $originalFunctionDefinitions = @{}
    foreach ($functionName in @(
        'Get-AzVmRepoRoot',
        'Read-DotEnvFile'
    )) {
        $command = Get-Command $functionName -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            $originalFunctionDefinitions[$functionName] = [string]$command.Definition
        }
    }

    function Get-AzVmRepoRoot { return $RepoRoot }
    function Read-DotEnvFile {
        param([string]$Path)
        return @{
            RESOURCE_GROUP = 'rg-stalevm-ate1-g4'
            VM_NAME = 'seedvm'
        }
    }

    try {
        $runtime = New-AzVmCreateCommandRuntime -Options @{
            auto = $true
            destructive rebuild = $true
            'vm-name' = 'samplevm'
            'vm-region' = 'swedencentral'
            'vm-size' = 'Standard_D4as_v5'
        } -WindowsFlag -LinuxFlag:$false -AutoMode

        Assert-True -Condition ([bool]$runtime.RenewMode) -Message "Create runtime must expose destructive rebuild mode when explicit destructive rebuild flow is present."
        Assert-True -Condition ([string]$runtime.InitialConfigOverrides.VM_NAME -eq 'samplevm') -Message "Create runtime must keep the requested VM name override."
        Assert-True -Condition ([string]$runtime.InitialConfigOverrides.AZ_LOCATION -eq 'swedencentral') -Message "Create runtime must keep the requested Azure region override."
        Assert-True -Condition ([string]$runtime.InitialConfigOverrides.VM_SIZE -eq 'Standard_D4as_v5') -Message "Create runtime must keep the requested VM size override."
        Assert-True -Condition (-not $runtime.InitialConfigOverrides.ContainsKey('RESOURCE_GROUP')) -Message "Create runtime must not reuse an existing managed resource group."
        Assert-True -Condition ([string]$runtime.ActionPlan.Target -eq 'vm-summary') -Message "Create runtime without step selectors must default to the full action plan."
    }
    finally {
        foreach ($functionName in @(
            'Get-AzVmRepoRoot',
            'Read-DotEnvFile'
        )) {
            Remove-Item ("Function:\global:{0}" -f $functionName) -ErrorAction SilentlyContinue
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue

            if ($originalFunctionDefinitions.ContainsKey($functionName)) {
                Set-Item -Path ("Function:\global:{0}" -f $functionName) -Value ([scriptblock]::Create([string]$originalFunctionDefinitions[$functionName]))
            }
        }
    }
}

Invoke-Test -Name "Create auto mode requires vm-name vm-region and vm-size" -Action {
    $threw = $false
    try {
        New-AzVmCreateCommandRuntime -Options @{ auto = $true; 'vm-name' = 'samplevm'; 'vm-region' = 'swedencentral' } -WindowsFlag -LinuxFlag:$false -AutoMode | Out-Null
    }
    catch {
        $threw = $true
        Assert-True -Condition ([string]$_.Exception.Message -like '*requires --vm-size*') -Message "Create auto mode failure must explain the missing vm-size option."
    }

    Assert-True -Condition $threw -Message "Create auto mode must fail when one of the required options is missing."
}

Invoke-Test -Name "Create and update auto mode require explicit platform flags" -Action {
    $createThrew = $false
    try {
        New-AzVmCreateCommandRuntime -Options @{ auto = $true; 'vm-name' = 'samplevm'; 'vm-region' = 'swedencentral'; 'vm-size' = 'Standard_D4as_v5' } -WindowsFlag:$false -LinuxFlag:$false -AutoMode | Out-Null
    }
    catch {
        $createThrew = $true
        Assert-True -Condition ([string]$_.Exception.Message -like '*requires an explicit platform flag*') -Message "Create auto mode failure must explain the missing platform flag."
    }
    Assert-True -Condition $createThrew -Message "Create auto mode must fail when the platform flag is missing."

    $updateThrew = $false
    try {
        New-AzVmUpdateCommandRuntime -Options @{ auto = $true; group = 'rg-samplevm-ate1-g1'; 'vm-name' = 'samplevm' } -WindowsFlag:$false -LinuxFlag:$false -AutoMode | Out-Null
    }
    catch {
        $updateThrew = $true
        Assert-True -Condition ([string]$_.Exception.Message -like '*requires an explicit platform flag*') -Message "Update auto mode failure must explain the missing platform flag."
    }
    Assert-True -Condition $updateThrew -Message "Update auto mode must fail when the platform flag is missing."
}

Invoke-Test -Name "Update runtime requires an existing managed VM before orchestration starts" -Action {
    $originalFunctionDefinitions = @{}
    foreach ($functionName in @(
        'Get-AzVmRepoRoot',
        'Read-DotEnvFile',
        'Resolve-AzVmTargetResourceGroup',
        'Resolve-AzVmTargetVmName',
        'Test-AzVmAzResourceExists'
    )) {
        $command = Get-Command $functionName -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            $originalFunctionDefinitions[$functionName] = [string]$command.Definition
        }
    }

    function Get-AzVmRepoRoot { return $RepoRoot }
    function Read-DotEnvFile {
        param([string]$Path)
        return @{
            RESOURCE_GROUP = 'rg-samplevm-ate1-g1'
            VM_NAME = 'samplevm'
        }
    }
    function Resolve-AzVmTargetResourceGroup {
        param([hashtable]$Options, [switch]$AutoMode, [string]$DefaultResourceGroup, [string]$VmName, [string]$OperationName)
        return 'rg-samplevm-ate1-g1'
    }
    function Resolve-AzVmTargetVmName {
        param([string]$ResourceGroup, [string]$DefaultVmName, [switch]$AutoMode, [string]$OperationName)
        return 'samplevm'
    }
    function Test-AzVmAzResourceExists {
        param([string[]]$AzArgs)
        return $false
    }

    try {
        $threw = $false
        try {
            New-AzVmUpdateCommandRuntime -Options @{ auto = $true; group = 'rg-samplevm-ate1-g1'; 'vm-name' = 'samplevm' } -WindowsFlag -LinuxFlag:$false -AutoMode | Out-Null
        }
        catch {
            $threw = $true
            Assert-True -Condition ([string]$_.Exception.Message -like '*was not found in managed resource group*') -Message "Update runtime failure must explain that the target VM does not exist."
        }

        Assert-True -Condition $threw -Message "Update runtime must fail early when the target VM does not exist."
    }
    finally {
        foreach ($functionName in @(
            'Get-AzVmRepoRoot',
            'Read-DotEnvFile',
            'Resolve-AzVmTargetResourceGroup',
            'Resolve-AzVmTargetVmName',
            'Test-AzVmAzResourceExists'
        )) {
            Remove-Item ("Function:\global:{0}" -f $functionName) -ErrorAction SilentlyContinue
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue

            if ($originalFunctionDefinitions.ContainsKey($functionName)) {
                Set-Item -Path ("Function:\global:{0}" -f $functionName) -Value ([scriptblock]::Create([string]$originalFunctionDefinitions[$functionName]))
            }
        }
    }
}

Invoke-Test -Name "Update auto mode requires group and vm-name" -Action {
    $threw = $false
    try {
        New-AzVmUpdateCommandRuntime -Options @{ auto = $true; group = 'rg-samplevm-ate1-g1' } -WindowsFlag -LinuxFlag:$false -AutoMode | Out-Null
    }
    catch {
        $threw = $true
        Assert-True -Condition ([string]$_.Exception.Message -like '*requires --vm-name*') -Message "Update auto mode failure must explain the missing vm-name option."
    }

    Assert-True -Condition $threw -Message "Update auto mode must fail when vm-name is missing."
}

Invoke-Test -Name "Managed naming uses global gX and sequential global nX allocation" -Action {
    $originalFunctionDefinitions = @{}
    foreach ($functionName in @(
        'Get-AzVmManagedResourceGroupRows',
        'az'
    )) {
        $command = Get-Command $functionName -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            $originalFunctionDefinitions[$functionName] = [string]$command.Definition
        }
    }

    function Get-AzVmManagedResourceGroupRows {
        return @(
            [pscustomobject]@{ name = 'rg-examplevm-ate1-g1' },
            [pscustomobject]@{ name = 'rg-examplevm-sec1-g4' }
        )
    }
    function az {
        $global:LASTEXITCODE = 0
        $argText = (@($args) | ForEach-Object { [string]$_ }) -join ' '
        if ($argText -like 'resource list -g rg-examplevm-ate1-g1*') {
            return @(
                'net-examplevm-ate1-n7'
                'nic-examplevm-ate1-n8'
            )
        }
        if ($argText -like 'resource list -g rg-examplevm-sec1-g4*') {
            return @(
                'ip-examplevm-sec1-n9'
                'disk-examplevm-sec1-n10'
            )
        }
        return @()
    }

    try {
        $nextGroupIndex = Get-AzVmNextManagedResourceGroupIndex -NamePrefix ''
        Assert-True -Condition ($nextGroupIndex -eq 5) -Message "Managed resource group index must be global across all managed resource groups."
        $nextGroupName = Resolve-AzVmResourceGroupNameFromTemplate -Template 'rg-{VM_NAME}-{REGION_CODE}-g{N}' -VmName 'examplevm' -RegionCode 'sec1' -UseNextIndex
        Assert-True -Condition ([string]$nextGroupName -eq 'rg-examplevm-sec1-g5') -Message "Managed resource group name generation must use the next global gX value."

        $allocator = New-AzVmManagedResourceIndexAllocator
        $vnetName = Resolve-AzVmNameFromTemplate -Template 'net-{VM_NAME}-{REGION_CODE}-n{N}' -ResourceType 'net' -VmName 'examplevm' -RegionCode 'sec1' -ResourceGroup 'rg-examplevm-sec1-g5' -UseNextIndex -IndexAllocator $allocator -LogicalName 'VNET_NAME'
        $subnetName = Resolve-AzVmNameFromTemplate -Template 'subnet-{VM_NAME}-{REGION_CODE}-n{N}' -ResourceType 'subnet' -VmName 'examplevm' -RegionCode 'sec1' -ResourceGroup 'rg-examplevm-sec1-g5' -UseNextIndex -IndexAllocator $allocator -LogicalName 'SUBNET_NAME'

        Assert-True -Condition ([string]$vnetName -eq 'net-examplevm-sec1-n11') -Message "First generated managed resource id must continue after the global max nX value."
        Assert-True -Condition ([string]$subnetName -eq 'subnet-examplevm-sec1-n12') -Message "Managed resource ids must stay sequential and unique within the same provisioning plan."
        $reRegisterIndex = Register-AzVmManagedResourceNameIndex -Allocator $allocator -Name 'net-examplevm-sec1-n11' -LogicalName 'VNET_NAME'
        Assert-True -Condition ($reRegisterIndex -eq 11) -Message "Managed resource name registration must be idempotent for the same logical resource."

        $threw = $false
        try {
            Register-AzVmManagedResourceNameIndex -Allocator $allocator -Name 'nic-examplevm-sec1-n12' -LogicalName 'NIC_NAME' | Out-Null
        }
        catch {
            $threw = $true
        }
        Assert-True -Condition $threw -Message "Managed resource name registration must reject duplicate nX ids within the same provisioning plan."
    }
    finally {
        foreach ($functionName in @(
            'Get-AzVmManagedResourceGroupRows',
            'az'
        )) {
            Remove-Item ("Function:\global:{0}" -f $functionName) -ErrorAction SilentlyContinue
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue

            if ($originalFunctionDefinitions.ContainsKey($functionName)) {
                Set-Item -Path ("Function:\global:{0}" -f $functionName) -Value ([scriptblock]::Create([string]$originalFunctionDefinitions[$functionName]))
            }
        }
    }
}

Invoke-Test -Name "Create step1 ignores persisted managed resource names and uses templates" -Action {
    $configMap = @{
        VNET_NAME = 'net-examplevm-sec1-n1'
        VNET_NAME_TEMPLATE = 'net-{VM_NAME}-{REGION_CODE}-n{N}'
        NIC_NAME = 'nic-examplevm-sec1-n1'
        NIC_NAME_TEMPLATE = 'nic-{VM_NAME}-{REGION_CODE}-n{N}'
    }

    $createVnetSeed = Get-AzVmManagedNameSeed -ConfigMap $configMap -ConfigOverrides @{} -OperationName 'create' -NameKey 'VNET_NAME' -TemplateKey 'VNET_NAME_TEMPLATE' -TemplateDefaultValue 'net-{VM_NAME}-{REGION_CODE}-n{N}'
    $createNicSeed = Get-AzVmManagedNameSeed -ConfigMap $configMap -ConfigOverrides @{} -OperationName 'create' -NameKey 'NIC_NAME' -TemplateKey 'NIC_NAME_TEMPLATE' -TemplateDefaultValue 'nic-{VM_NAME}-{REGION_CODE}-n{N}'
    $updateVnetSeed = Get-AzVmManagedNameSeed -ConfigMap $configMap -ConfigOverrides @{} -OperationName 'update' -NameKey 'VNET_NAME' -TemplateKey 'VNET_NAME_TEMPLATE' -TemplateDefaultValue 'net-{VM_NAME}-{REGION_CODE}-n{N}'

    Assert-True -Condition (-not [bool]$createVnetSeed.Explicit) -Message "Create step1 must not treat persisted VNET_NAME as an explicit managed resource target."
    Assert-True -Condition ([string]$createVnetSeed.Value -eq 'net-{VM_NAME}-{REGION_CODE}-n{N}') -Message "Create step1 must fall back to the VNET template when a persisted managed name exists."
    Assert-True -Condition (-not [bool]$createNicSeed.Explicit) -Message "Create step1 must not treat persisted NIC_NAME as an explicit managed resource target."
    Assert-True -Condition ([string]$createNicSeed.Value -eq 'nic-{VM_NAME}-{REGION_CODE}-n{N}') -Message "Create step1 must fall back to the NIC template when a persisted managed name exists."
    Assert-True -Condition ([bool]$updateVnetSeed.Explicit) -Message "Update step1 must continue treating persisted VNET_NAME as the existing managed target."
    Assert-True -Condition ([string]$updateVnetSeed.Value -eq 'net-examplevm-sec1-n1') -Message "Update step1 must preserve the persisted managed resource name for the existing target."
}

Invoke-Test -Name "VM create step redeploys existing VMs in update mode" -Action {
    $script:VmUpdateRedeployInvocation = $null

    try {
        function Show-AzVmStepFirstUseValues { param([string]$StepLabel, [hashtable]$Context, [string[]]$Keys, [hashtable]$ExtraValues) }
        function Invoke-TrackedAction {
            param([string]$Label, [scriptblock]$Action)
            & $Action
        }
        function Invoke-AzVmPostDeployFeatureEnablement {
            param([hashtable]$Context, [switch]$VmCreatedThisRun)
            return [pscustomobject]@{
                HibernationAttempted = $false
                HibernationEnabled = $false
                HibernationMessage = ''
                NestedAttempted = $false
                NestedEnabled = $false
                NestedMessage = ''
            }
        }
        function Invoke-AzVmUpdateVmRedeploy {
            param([string]$ResourceGroup, [string]$VmName, [switch]$AutoMode)
            $script:VmUpdateRedeployInvocation = [pscustomobject]@{
                ResourceGroup = $ResourceGroup
                VmName = $VmName
                AutoMode = [bool]$AutoMode
            }
        }
        function az {
            $line = @($args) -join ' '
            if ($line -match [regex]::Escape('vm list')) {
                $global:LASTEXITCODE = 0
                return 'samplevm'
            }

            $global:LASTEXITCODE = 0
            return ''
        }

        $result = Invoke-AzVmVmCreateStep -Context @{
            ResourceGroup = 'rg-samplevm-ate1-g1'
            VmName = 'samplevm'
        } -AutoMode -ExecutionMode 'update' -CreateVmAction {
            $global:LASTEXITCODE = 0
            return '{"id":"/subscriptions/test/resourceGroups/rg-samplevm-ate1-g1/providers/Microsoft.Compute/virtualMachines/samplevm"}'
        }

        Assert-True -Condition ($null -ne $script:VmUpdateRedeployInvocation) -Message "Update-mode create step must trigger VM redeploy for an existing VM."
        Assert-True -Condition ([string]$script:VmUpdateRedeployInvocation.ResourceGroup -eq 'rg-samplevm-ate1-g1') -Message "Update-mode redeploy must target the existing resource group."
        Assert-True -Condition ([string]$script:VmUpdateRedeployInvocation.VmName -eq 'samplevm') -Message "Update-mode redeploy must target the existing VM."
        Assert-True -Condition (-not [bool]$result.VmCreatedThisRun) -Message "Existing update-mode VM create must not be reported as a fresh VM creation."
    }
    finally {
        foreach ($functionName in @(
            'Show-AzVmStepFirstUseValues',
            'Invoke-TrackedAction',
            'Invoke-AzVmPostDeployFeatureEnablement',
            'Invoke-AzVmUpdateVmRedeploy',
            'az'
        )) {
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name VmUpdateRedeployInvocation -Scope Script -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "Resize command accepts vm-name and platform flags" -Action {
    Assert-AzVmCommandOptions -CommandName 'resize' -Options @{ 'vm-name' = 'samplevm'; 'vm-size' = 'Standard_D4as_v5'; group = 'rg-samplevm-ate1-g1' }
    Assert-AzVmCommandOptions -CommandName 'resize' -Options @{ 'vm-name' = 'samplevm'; 'vm-size' = 'Standard_D2as_v5'; group = 'rg-samplevm-ate1-g1'; windows = $true }
    Assert-AzVmCommandOptions -CommandName 'resize' -Options @{ 'vm-name' = 'samplevm'; 'vm-size' = 'Standard_D2as_v5'; group = 'rg-samplevm-ate1-g1'; linux = $true }
}

Invoke-Test -Name "Resize command accepts disk-size and disk intent flags" -Action {
    Assert-AzVmCommandOptions -CommandName 'resize' -Options @{ 'vm-name' = 'samplevm'; group = 'rg-samplevm-ate1-g1'; 'disk-size' = '196gb'; expand = $true }
    Assert-AzVmCommandOptions -CommandName 'resize' -Options @{ 'vm-name' = 'samplevm'; group = 'rg-samplevm-ate1-g1'; 'disk-size' = '98304mb'; expand = $true; windows = $true }
    Assert-AzVmCommandOptions -CommandName 'resize' -Options @{ 'vm-name' = 'samplevm'; group = 'rg-samplevm-ate1-g1'; 'disk-size' = '64gb'; shrink = $true; linux = $true }
}

Invoke-Test -Name "Exec command accepts vm-name for direct task targeting" -Action {
    Assert-AzVmCommandOptions -CommandName 'exec' -Options @{ 'init-task' = '01'; group = 'rg-samplevm-ate1-g1'; 'vm-name' = 'samplevm'; windows = $true }
    Assert-AzVmCommandOptions -CommandName 'exec' -Options @{ 'update-task' = '28'; group = 'rg-samplevm-ate1-g1'; 'vm-name' = 'samplevm'; windows = $true }
}

Invoke-Test -Name "Do command accepts vm-name and valid vm-action" -Action {
    Assert-AzVmCommandOptions -CommandName 'do' -Options @{ 'vm-name' = 'samplevm'; 'vm-action' = 'status' }
    Assert-AzVmCommandOptions -CommandName 'do' -Options @{ group = 'rg-samplevm-ate1-g1'; 'vm-name' = 'samplevm'; 'vm-action' = 'deallocate' }
    Assert-AzVmCommandOptions -CommandName 'do' -Options @{ group = 'rg-samplevm-ate1-g1'; 'vm-name' = 'samplevm'; 'vm-action' = 'hibernate-deallocate' }
    Assert-AzVmCommandOptions -CommandName 'do' -Options @{ group = 'rg-samplevm-ate1-g1'; 'vm-name' = 'samplevm'; 'vm-action' = 'hibernate-stop' }
    Assert-AzVmCommandOptions -CommandName 'do' -Options @{ group = 'rg-samplevm-ate1-g1'; 'vm-name' = 'samplevm'; 'vm-action' = 'reapply' }
    Assert-AzVmCommandOptions -CommandName 'do' -Options @{ 'vm-action' = '' }
}

Invoke-Test -Name "Move, Set, Resize, Do, SSH, and RDP reject legacy vm option" -Action {
    foreach ($commandName in @('move','set','resize','do','ssh','rdp')) {
        $threw = $false
        try {
            Assert-AzVmCommandOptions -CommandName $commandName -Options @{ vm = 'samplevm' }
        }
        catch {
            $threw = $true
        }
        Assert-True -Condition $threw -Message ("Legacy --vm must be rejected for command '{0}'." -f $commandName)
    }
}

Invoke-Test -Name "Do command rejects retired or unknown power actions" -Action {
    foreach ($actionName in @('release','sleep','hibernate')) {
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

Invoke-Test -Name "Do help and README document reapply" -Action {
    $helpText = [string](Get-Content -LiteralPath (Join-Path $RepoRoot 'modules\core\cli\azvm-help.ps1') -Raw)
    $readmeText = [string](Get-Content -LiteralPath (Join-Path $RepoRoot 'README.md') -Raw)

    Assert-True -Condition ($helpText -match [regex]::Escape('--vm-action=<status|start|restart|stop|deallocate|hibernate-deallocate|hibernate-stop|reapply>')) -Message 'CLI help must list the explicit hibernate actions in the do action contract.'
    Assert-True -Condition ($helpText -match [regex]::Escape('az-vm do --vm-action=reapply --group=<resource-group> --vm-name=<vm-name>')) -Message 'CLI help must show a reapply example.'
    Assert-True -Condition ($helpText -match [regex]::Escape('az-vm do --vm-action=hibernate-stop --group=<resource-group> --vm-name=<vm-name>')) -Message 'CLI help must show a hibernate-stop example.'
    Assert-True -Condition ($helpText -match [regex]::Escape('az-vm do --vm-action=hibernate-deallocate --group=<resource-group> --vm-name=<vm-name>')) -Message 'CLI help must show a hibernate-deallocate example.'
    Assert-True -Condition ($readmeText -match [regex]::Escape('Gives operators lifecycle commands for status, start, restart, reapply, stop, deallocate, hibernate-stop, hibernate-deallocate')) -Message 'README must mention the explicit hibernate actions in the lifecycle command summary.'
    Assert-True -Condition ($readmeText -match [regex]::Escape('.\az-vm.cmd do --vm-action=reapply --group=<resource-group> --vm-name=<vm-name>')) -Message 'README must include a reapply usage example.'
    Assert-True -Condition ($readmeText -match [regex]::Escape('.\az-vm.cmd do --vm-action=hibernate-stop --group=<resource-group> --vm-name=<vm-name>')) -Message 'README must include a hibernate-stop usage example.'
    Assert-True -Condition ($readmeText -match [regex]::Escape('.\az-vm.cmd do --vm-action=hibernate-deallocate --group=<resource-group> --vm-name=<vm-name>')) -Message 'README must include a hibernate-deallocate usage example.'
}

Invoke-Test -Name "Create update and resize docs reflect the current operator contract" -Action {
    $helpText = [string](Get-Content -LiteralPath (Join-Path $RepoRoot 'modules\core\cli\azvm-help.ps1') -Raw)
    $readmeText = [string](Get-Content -LiteralPath (Join-Path $RepoRoot 'README.md') -Raw)

    foreach ($fragment in @(
        'create always targets a fresh managed resource group and fresh managed resources',
        'proposes the next global gX name plus globally unique nX resource ids',
        'Auto mode requires an explicit platform plus --vm-name, --vm-region, and --vm-size',
        'Auto mode requires an explicit platform plus --group and --vm-name',
        'vm-summary always renders, even for partial step windows',
        '--disk-size requires exactly one intent flag: --expand or --shrink'
    )) {
        Assert-True -Condition ($helpText -match [regex]::Escape([string]$fragment)) -Message ("CLI help must include fragment '{0}'." -f [string]$fragment)
    }

    foreach ($fragment in @(
        '`create` now stays dedicated to one fresh managed resource group plus one fresh managed VM; `create explicit destructive rebuild flow` remains the explicit destructive rebuild path for that fresh target.',
        'Auto `create` requires an explicit platform plus `--vm-name`, `--vm-region`, and `--vm-size`.',
        'Auto `update` requires an explicit platform plus `--group` and `--vm-name`.',
        'Interactive `create` and `update` use `yes/no/cancel` review checkpoints only for `group`, `vm-deploy`, `vm-init`, and `vm-update`.',
        '`configure` and `vm-summary` stay visible in both interactive and auto mode, even when partial step selection skips interior stages.',
        'Managed resource group ids use a global `gX` suffix that increments across all managed groups, regardless of region.',
        'Managed resource ids use a global `nX` suffix that increments across all generated managed resources and is never reused by another managed resource of any type.',
        '`create` never reuses an existing managed resource group or existing managed resource names, and `update` never falls through to an implicit fresh-create path.',
        '`--disk-size=... --shrink` is a non-mutating guidance path because Azure does not support shrinking an existing managed OS disk in place; the command prints supported rebuild and migration alternatives instead of risking disk integrity'
    )) {
        Assert-True -Condition ($readmeText -match [regex]::Escape([string]$fragment)) -Message ("README must include fragment '{0}'." -f [string]$fragment)
    }

    foreach ($legacyFragment in @(
        '--single-step',
        '--from-step',
        '--to-step',
        'Create, reuse, destructive rebuild'
    )) {
        Assert-True -Condition (-not ($helpText -match [regex]::Escape([string]$legacyFragment))) -Message ("CLI help must not include retired fragment '{0}'." -f [string]$legacyFragment)
        Assert-True -Condition (-not ($readmeText -match [regex]::Escape([string]$legacyFragment))) -Message ("README must not include retired fragment '{0}'." -f [string]$legacyFragment)
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
    Assert-True -Condition (Test-AzVmResizeDirectRequest -Options @{ group = 'rg-samplevm-ate1-g1'; 'vm-name' = 'samplevm'; 'vm-size' = 'Standard_D4as_v5' }) -Message "Fully specified resize request must be treated as direct."
    Assert-True -Condition (Test-AzVmResizeDirectRequest -Options @{ group = 'rg-samplevm-ate1-g1'; 'vm-name' = 'samplevm'; 'disk-size' = '98304mb'; expand = $true }) -Message "Disk expand request with target group, VM, and disk size must be treated as direct."
    Assert-True -Condition (Test-AzVmResizeDirectRequest -Options @{ group = 'rg-samplevm-ate1-g1'; 'vm-name' = 'samplevm'; 'disk-size' = '64gb'; shrink = $true }) -Message "Disk shrink request with target group, VM, and disk size must be treated as direct."
    Assert-True -Condition (-not (Test-AzVmResizeDirectRequest -Options @{ group = 'rg-samplevm-ate1-g1'; 'vm-name' = 'samplevm' })) -Message "Resize request without vm-size must not be treated as direct."
    Assert-True -Condition (-not (Test-AzVmResizeDirectRequest -Options @{ group = 'rg-samplevm-ate1-g1'; 'vm-name' = 'samplevm'; 'disk-size' = '64gb' })) -Message "Disk resize request without an intent flag must not be treated as direct."
    Assert-True -Condition (-not (Test-AzVmResizeDirectRequest -Options @{ group = 'rg-samplevm-ate1-g1'; vm = 'samplevm'; 'vm-size' = 'Standard_D4as_v5' })) -Message "Legacy vm option must not satisfy direct resize request detection."
}

Invoke-Test -Name "Resize operation request validates disk intent combinations" -Action {
    $expandRequest = Resolve-AzVmResizeOperationRequest -Options @{ 'disk-size' = '98304mb'; expand = $true }
    Assert-True -Condition ([string]$expandRequest.Kind -eq 'disk') -Message "Disk resize request must resolve to the disk kind."
    Assert-True -Condition ([string]$expandRequest.Intent -eq 'expand') -Message "Disk resize request must keep expand intent."
    Assert-True -Condition ([int]$expandRequest.TargetDiskSizeGb -eq 96) -Message "MB disk resize request must round upward to whole GiB."

    $vmSizeRequest = Resolve-AzVmResizeOperationRequest -Options @{ 'vm-size' = 'Standard_D4as_v5' }
    Assert-True -Condition ([string]$vmSizeRequest.Kind -eq 'vm-size') -Message "VM-size resize request must resolve to the vm-size kind."

    foreach ($invalidOptions in @(
        @{ 'disk-size' = '196gb'; expand = $true; shrink = $true },
        @{ 'disk-size' = '196gb' },
        @{ expand = $true },
        @{ 'vm-size' = 'Standard_D4as_v5'; 'disk-size' = '196gb'; expand = $true }
    )) {
        $threw = $false
        try {
            Resolve-AzVmResizeOperationRequest -Options $invalidOptions | Out-Null
        }
        catch {
            $threw = $true
        }

        Assert-True -Condition $threw -Message "Invalid disk resize option combination must be rejected."
    }
}

Invoke-Test -Name "Resize target disk size parser validates units and values" -Action {
    $gbRequest = Resolve-AzVmResizeTargetDiskSize -Options @{ 'disk-size' = '196gb' }
    Assert-True -Condition ([int]$gbRequest.TargetDiskSizeGb -eq 196) -Message "GB disk-size request must keep the same numeric size."

    $mbRequest = Resolve-AzVmResizeTargetDiskSize -Options @{ 'disk-size' = '1537mb' }
    Assert-True -Condition ([int]$mbRequest.TargetDiskSizeGb -eq 2) -Message "MB disk-size request must round upward to the next whole GiB."

    foreach ($invalidDiskSize in @('', '0gb', 'bad', '12tb')) {
        $threw = $false
        try {
            Resolve-AzVmResizeTargetDiskSize -Options @{ 'disk-size' = $invalidDiskSize } | Out-Null
        }
        catch {
            $threw = $true
        }

        Assert-True -Condition $threw -Message ("Invalid disk-size value '{0}' must be rejected." -f $invalidDiskSize)
    }
}

Invoke-Test -Name "Resize shrink path is non-mutating and prints supported alternatives" -Action {
    $script:ResizeShrinkAzCalls = @()
    $script:ResizeShrinkAlternativesShown = $false
    $script:ConfigOverrides = @{}
    $originalFunctionDefinitions = @{}

    foreach ($functionName in @(
        'Get-AzVmRepoRoot',
        'Read-DotEnvFile',
        'Resolve-AzVmManagedVmTarget',
        'Get-AzVmResizeOsDiskContext',
        'Show-AzVmResizeShrinkAlternatives',
        'Set-DotEnvValue',
        'az'
    )) {
        $command = Get-Command $functionName -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            $originalFunctionDefinitions[$functionName] = [string]$command.Definition
        }
    }

    function Get-AzVmRepoRoot { return $RepoRoot }
    function Read-DotEnvFile { param([string]$Path) return @{} }
    function Resolve-AzVmManagedVmTarget {
        param([hashtable]$Options, [hashtable]$ConfigMap, [string]$OperationName)
        return [pscustomobject]@{
            ResourceGroup = 'rg-samplevm-ate1-g1'
            VmName = 'samplevm'
        }
    }
    function Get-AzVmResizeOsDiskContext {
        param([psobject]$VmObject, [string]$ResourceGroup, [string]$VmName)
        return [pscustomobject]@{
            DiskId = '/subscriptions/test/resourceGroups/rg-samplevm-ate1-g1/providers/Microsoft.Compute/disks/disk-samplevm'
            DiskName = 'disk-samplevm'
            DiskSizeGb = 128
            SkuName = 'Premium_LRS'
        }
    }
    function Show-AzVmResizeShrinkAlternatives {
        $script:ResizeShrinkAlternativesShown = $true
    }
    function Set-DotEnvValue {
        throw 'Shrink guidance must not persist .env changes.'
    }
    function az {
        $line = @($args) -join ' '
        $script:ResizeShrinkAzCalls += $line

        if ($line -eq 'vm show -g rg-samplevm-ate1-g1 -n samplevm -o json --only-show-errors') {
            $global:LASTEXITCODE = 0
            return '{"location":"austriaeast","hardwareProfile":{"vmSize":"Standard_D4as_v5"},"storageProfile":{"osDisk":{"osType":"Windows"}}}'
        }

        throw ("Unexpected Azure call during shrink guidance test: {0}" -f $line)
    }

    try {
        $threw = $false
        try {
            Invoke-AzVmResizeCommand -Options @{
                group = 'rg-samplevm-ate1-g1'
                'vm-name' = 'samplevm'
                'disk-size' = '64gb'
                shrink = $true
            } -AutoMode:$false -WindowsFlag -LinuxFlag:$false
        }
        catch {
            $threw = $true
            Assert-True -Condition ([string]$_.Exception.Message -like '*Azure does not support shrinking the existing managed OS disk*') -Message "Shrink guidance failure must explain the Azure OS disk shrink limitation."
        }

        Assert-True -Condition $threw -Message "Shrink guidance path must exit with a friendly error."
        Assert-True -Condition $script:ResizeShrinkAlternativesShown -Message "Shrink guidance path must print supported alternatives."
        Assert-True -Condition (-not ((@($script:ResizeShrinkAzCalls) -join "`n") -match 'vm deallocate|disk update|vm start|vm resize')) -Message "Shrink guidance path must not call mutating Azure resize operations."
        Assert-True -Condition ($script:ConfigOverrides.Count -eq 0) -Message "Shrink guidance path must not update runtime config overrides."
    }
    finally {
        foreach ($functionName in @(
            'Get-AzVmRepoRoot',
            'Read-DotEnvFile',
            'Resolve-AzVmManagedVmTarget',
            'Get-AzVmResizeOsDiskContext',
            'Show-AzVmResizeShrinkAlternatives',
            'Set-DotEnvValue',
            'az'
        )) {
            Remove-Item ("Function:\global:{0}" -f $functionName) -ErrorAction SilentlyContinue
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue

            if ($originalFunctionDefinitions.ContainsKey($functionName)) {
                Set-Item -Path ("Function:\global:{0}" -f $functionName) -Value ([scriptblock]::Create([string]$originalFunctionDefinitions[$functionName]))
            }
        }
        Remove-Variable -Name ResizeShrinkAzCalls -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name ResizeShrinkAlternativesShown -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name ConfigOverrides -Scope Script -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "Resize expand path deallocates, grows disk, restarts, and persists config" -Action {
    $script:ResizeExpandAzCalls = @()
    $script:ResizeExpandWaits = @()
    $script:ResizeExpandPersist = $null
    $script:ConfigOverrides = @{}
    $originalFunctionDefinitions = @{}

    foreach ($functionName in @(
        'Get-AzVmRepoRoot',
        'Read-DotEnvFile',
        'Resolve-AzVmManagedVmTarget',
        'Get-AzVmResizeOsDiskContext',
        'Invoke-TrackedAction',
        'Wait-AzVmVmPowerState',
        'Set-DotEnvValue',
        'az'
    )) {
        $command = Get-Command $functionName -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            $originalFunctionDefinitions[$functionName] = [string]$command.Definition
        }
    }

    function Get-AzVmRepoRoot { return $RepoRoot }
    function Read-DotEnvFile { param([string]$Path) return @{} }
    function Resolve-AzVmManagedVmTarget {
        param([hashtable]$Options, [hashtable]$ConfigMap, [string]$OperationName)
        return [pscustomobject]@{
            ResourceGroup = 'rg-samplevm-ate1-g1'
            VmName = 'samplevm'
        }
    }
    function Get-AzVmResizeOsDiskContext {
        param([psobject]$VmObject, [string]$ResourceGroup, [string]$VmName)
        return [pscustomobject]@{
            DiskId = '/subscriptions/test/resourceGroups/rg-samplevm-ate1-g1/providers/Microsoft.Compute/disks/disk-samplevm'
            DiskName = 'disk-samplevm'
            DiskSizeGb = 128
            SkuName = 'Premium_LRS'
        }
    }
    function Invoke-TrackedAction {
        param([string]$Label, [scriptblock]$Action)
        & $Action
    }
    function Wait-AzVmVmPowerState {
        param([string]$ResourceGroup, [string]$VmName, [string]$DesiredPowerState, [int]$MaxAttempts, [int]$DelaySeconds)
        $script:ResizeExpandWaits += [string]$DesiredPowerState
        return $true
    }
    function Set-DotEnvValue {
        param([string]$Path, [string]$Key, [string]$Value)
        $script:ResizeExpandPersist = [pscustomobject]@{
            Path = $Path
            Key = $Key
            Value = $Value
        }
    }
    function az {
        $line = @($args) -join ' '
        $script:ResizeExpandAzCalls += $line

        switch ($line) {
            'vm show -g rg-samplevm-ate1-g1 -n samplevm -o json --only-show-errors' {
                $global:LASTEXITCODE = 0
                return '{"location":"austriaeast","hardwareProfile":{"vmSize":"Standard_D4as_v5"},"storageProfile":{"osDisk":{"osType":"Windows"}}}'
            }
            'vm deallocate -g rg-samplevm-ate1-g1 -n samplevm -o none --only-show-errors' {
                $global:LASTEXITCODE = 0
                return ''
            }
            'disk update -g rg-samplevm-ate1-g1 -n disk-samplevm --size-gb 196 -o none --only-show-errors' {
                $global:LASTEXITCODE = 0
                return ''
            }
            'vm start -g rg-samplevm-ate1-g1 -n samplevm -o none --only-show-errors' {
                $global:LASTEXITCODE = 0
                return ''
            }
            default {
                throw ("Unexpected Azure call during disk expand test: {0}" -f $line)
            }
        }
    }

    try {
        Invoke-AzVmResizeCommand -Options @{
            group = 'rg-samplevm-ate1-g1'
            'vm-name' = 'samplevm'
            'disk-size' = '196gb'
            expand = $true
        } -AutoMode:$false -WindowsFlag -LinuxFlag:$false

        $expectedAzSequence = @(
            'vm show -g rg-samplevm-ate1-g1 -n samplevm -o json --only-show-errors',
            'vm deallocate -g rg-samplevm-ate1-g1 -n samplevm -o none --only-show-errors',
            'disk update -g rg-samplevm-ate1-g1 -n disk-samplevm --size-gb 196 -o none --only-show-errors',
            'vm start -g rg-samplevm-ate1-g1 -n samplevm -o none --only-show-errors'
        )
        Assert-True -Condition ((@($script:ResizeExpandAzCalls) -join "`n") -eq ($expectedAzSequence -join "`n")) -Message "Disk expand path must call Azure in the expected order."
        Assert-True -Condition ((@($script:ResizeExpandWaits) -join ',') -eq 'VM deallocated,VM running') -Message "Disk expand path must wait for deallocated and running VM states."
        Assert-True -Condition ($null -ne $script:ResizeExpandPersist) -Message "Disk expand path must persist the updated platform disk-size config."
        Assert-True -Condition ([string]$script:ResizeExpandPersist.Key -eq 'WIN_VM_DISK_SIZE_GB') -Message "Disk expand path must persist the Windows disk-size config key for a Windows VM."
        Assert-True -Condition ([string]$script:ResizeExpandPersist.Value -eq '196') -Message "Disk expand path must persist the expanded disk size."
        Assert-True -Condition ([string]$script:ConfigOverrides.WIN_VM_DISK_SIZE_GB -eq '196') -Message "Disk expand path must update in-memory config overrides with the expanded disk size."
    }
    finally {
        foreach ($functionName in @(
            'Get-AzVmRepoRoot',
            'Read-DotEnvFile',
            'Resolve-AzVmManagedVmTarget',
            'Get-AzVmResizeOsDiskContext',
            'Invoke-TrackedAction',
            'Wait-AzVmVmPowerState',
            'Set-DotEnvValue',
            'az'
        )) {
            Remove-Item ("Function:\global:{0}" -f $functionName) -ErrorAction SilentlyContinue
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue

            if ($originalFunctionDefinitions.ContainsKey($functionName)) {
                Set-Item -Path ("Function:\global:{0}" -f $functionName) -Value ([scriptblock]::Create([string]$originalFunctionDefinitions[$functionName]))
            }
        }
        Remove-Variable -Name ResizeExpandAzCalls -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name ResizeExpandWaits -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name ResizeExpandPersist -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name ConfigOverrides -Scope Script -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "Move source group purge-safety helper accepts expected resource set" -Action {
    $resources = @(
        [pscustomobject]@{ name = 'samplevm'; type = 'Microsoft.Compute/virtualMachines' },
        [pscustomobject]@{ name = 'disk-samplevm-ate1-n1'; type = 'Microsoft.Compute/disks' },
        [pscustomobject]@{ name = 'nic-samplevm-ate1-n1'; type = 'Microsoft.Network/networkInterfaces' },
        [pscustomobject]@{ name = 'ip-samplevm-ate1-n1'; type = 'Microsoft.Network/publicIPAddresses' },
        [pscustomobject]@{ name = 'nsg-samplevm-ate1-n1'; type = 'Microsoft.Network/networkSecurityGroups' },
        [pscustomobject]@{ name = 'net-samplevm-ate1-n1'; type = 'Microsoft.Network/virtualNetworks' }
    )

    $result = Test-AzVmMoveResourceSetIsPurgeSafe -Resources $resources -VmName 'samplevm' -OsDiskName 'disk-samplevm-ate1-n1'
    Assert-True -Condition ([bool]$result.IsSafe) -Message "Expected VM-bound resource set must be purge-safe."
}

Invoke-Test -Name "Move source group purge-safety helper rejects unexpected resources" -Action {
    $resources = @(
        [pscustomobject]@{ name = 'samplevm'; type = 'Microsoft.Compute/virtualMachines' },
        [pscustomobject]@{ name = 'disk-samplevm-ate1-n1'; type = 'Microsoft.Compute/disks' },
        [pscustomobject]@{ name = 'nic-samplevm-ate1-n1'; type = 'Microsoft.Network/networkInterfaces' },
        [pscustomobject]@{ name = 'ip-samplevm-ate1-n1'; type = 'Microsoft.Network/publicIPAddresses' },
        [pscustomobject]@{ name = 'nsg-samplevm-ate1-n1'; type = 'Microsoft.Network/networkSecurityGroups' },
        [pscustomobject]@{ name = 'net-samplevm-ate1-n1'; type = 'Microsoft.Network/virtualNetworks' },
        [pscustomobject]@{ name = 'vault-extra'; type = 'Microsoft.KeyVault/vaults' }
    )

    $result = Test-AzVmMoveResourceSetIsPurgeSafe -Resources $resources -VmName 'samplevm' -OsDiskName 'disk-samplevm-ate1-n1'
    Assert-True -Condition (-not [bool]$result.IsSafe) -Message "Unexpected resource types must block automatic source-group purge."
    Assert-True -Condition (@($result.UnexpectedTypes) -contains 'Microsoft.KeyVault/vaults') -Message "Unexpected resource type should be surfaced to the operator."
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
        -ResourceGroup 'rg-samplevm-ate1-g1' `
        -VmName 'samplevm' `
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
        -ResourceGroup 'rg-samplevm-ate1-g1' `
        -VmName 'samplevm' `
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
        -ResourceGroup 'rg-samplevm-ate1-g1' `
        -VmName 'samplevm' `
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
        -ResourceGroup 'rg-samplevm-ate1-g1' `
        -VmName 'samplevm' `
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
        function script:Select-AzLocationInteractive {
            throw "Resize target size selection must not call region picker."
        }

        function script:Select-VmSkuInteractive {
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
        Remove-Item Function:\script:Select-AzLocationInteractive -ErrorAction SilentlyContinue
        Remove-Item Function:\script:Select-VmSkuInteractive -ErrorAction SilentlyContinue
        Remove-Item Function:\global:Select-AzLocationInteractive -ErrorAction SilentlyContinue
        Remove-Item Function:\global:Select-VmSkuInteractive -ErrorAction SilentlyContinue
        Remove-Variable ResizePickerCallCount -Scope Script -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "Resize platform expectation" -Action {
    Assert-AzVmResizePlatformExpectation -ActualPlatform 'windows' -WindowsFlag -VmName 'samplevm' -ResourceGroup 'rg-samplevm-ate1-g1'
    Assert-AzVmResizePlatformExpectation -ActualPlatform 'linux' -LinuxFlag -VmName 'samplevm' -ResourceGroup 'rg-samplevm-ate1-g1'

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
                -VmName 'samplevm' `
                -ResourceGroup 'rg-samplevm-ate1-g1'
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
            ResourceGroup = 'rg-samplevm-ate1-g1'
            VmName = 'samplevm'
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
    Assert-AzVmDoActionAllowed -ActionName 'hibernate-deallocate' -Snapshot (New-TestDoSnapshot -NormalizedState 'started' -PowerStateDisplay 'VM running')
    Assert-AzVmDoActionAllowed -ActionName 'hibernate-stop' -Snapshot (New-TestDoSnapshot -NormalizedState 'started' -PowerStateDisplay 'VM running')
    Assert-AzVmDoActionAllowed -ActionName 'reapply' -Snapshot (New-TestDoSnapshot -NormalizedState 'other' -PowerStateDisplay 'VM starting' -ProvisioningStateCode 'ProvisioningState/updating' -ProvisioningStateDisplay 'Updating')

    $invalidCases = @(
        @{ Action = 'start'; Snapshot = (New-TestDoSnapshot -NormalizedState 'started' -PowerStateDisplay 'VM running') },
        @{ Action = 'hibernate-deallocate'; Snapshot = (New-TestDoSnapshot -NormalizedState 'started' -PowerStateDisplay 'VM running' -HibernationEnabled:$false) },
        @{ Action = 'hibernate-stop'; Snapshot = (New-TestDoSnapshot -NormalizedState 'started' -PowerStateDisplay 'VM running' -HibernationEnabled:$false) },
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
        ResourceGroup = 'rg-samplevm-ate1-g1'
        VmName = 'samplevm'
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
        function Read-Host { param([string]$Prompt) return '' }
        $defaultAction = Read-AzVmDoActionInteractive -Snapshot $snapshot
        Assert-True -Condition ([string]$defaultAction -eq 'status') -Message "Interactive do action default should be status."

        function Read-Host { param([string]$Prompt) return '5' }
        $pickedAction = Read-AzVmDoActionInteractive -Snapshot $snapshot
        Assert-True -Condition ([string]$pickedAction -eq 'deallocate') -Message "Interactive do action selection by number failed."

        function Read-Host { param([string]$Prompt) return '6' }
        $hibernateDeallocateAction = Read-AzVmDoActionInteractive -Snapshot $snapshot
        Assert-True -Condition ([string]$hibernateDeallocateAction -eq 'hibernate-deallocate') -Message "Interactive do action selection must expose hibernate-deallocate."

        function Read-Host { param([string]$Prompt) return '7' }
        $hibernateStopAction = Read-AzVmDoActionInteractive -Snapshot $snapshot
        Assert-True -Condition ([string]$hibernateStopAction -eq 'hibernate-stop') -Message "Interactive do action selection must expose hibernate-stop."

        function Read-Host { param([string]$Prompt) return '8' }
        $reapplyAction = Read-AzVmDoActionInteractive -Snapshot $snapshot
        Assert-True -Condition ([string]$reapplyAction -eq 'reapply') -Message "Interactive do action selection must expose reapply."
    }
    finally {
        Remove-Item Function:\global:Read-Host -ErrorAction SilentlyContinue
        Remove-Item Function:\Read-Host -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "Do reapply action calls Azure reapply and prints refreshed status" -Action {
    $script:DoReapplyInvocation = $null
    $script:DoReapplySnapshotCalls = 0
    $script:DoReapplyWaitCalled = $false
    $script:DoReapplyReportedSnapshot = $null
    $originalFunctionDefinitions = @{}

    foreach ($functionName in @(
        'Resolve-AzVmManagedVmTarget',
        'Get-AzVmVmLifecycleSnapshot',
        'Invoke-AzVmDoAzureAction',
        'Wait-AzVmDoLifecycleState',
        'Write-AzVmDoStatusReport'
    )) {
        $command = Get-Command $functionName -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            $originalFunctionDefinitions[$functionName] = [string]$command.Definition
        }
    }

    function Resolve-AzVmManagedVmTarget {
        param([hashtable]$Options, [hashtable]$ConfigMap, [string]$OperationName)
        return [pscustomobject]@{
            ResourceGroup = 'rg-samplevm-ate1-g1'
            VmName = 'samplevm'
        }
    }
    function Get-AzVmVmLifecycleSnapshot {
        param([string]$ResourceGroup, [string]$VmName)
        $script:DoReapplySnapshotCalls++
        $provisioningDisplay = if ($script:DoReapplySnapshotCalls -eq 1) { 'Updating' } else { 'Provisioning succeeded' }
        $provisioningCode = if ($script:DoReapplySnapshotCalls -eq 1) { 'ProvisioningState/updating' } else { 'ProvisioningState/succeeded' }
        return [pscustomobject]@{
            ResourceGroup = $ResourceGroup
            VmName = $VmName
            OsType = 'Windows'
            Location = 'austriaeast'
            HibernationEnabled = $true
            ProvisioningStateCode = $provisioningCode
            ProvisioningStateDisplay = $provisioningDisplay
            PowerStateCode = 'PowerState/running'
            PowerStateDisplay = 'VM running'
            HibernationStateCode = ''
            HibernationStateDisplay = ''
            NormalizedState = 'started'
        }
    }
    function Invoke-AzVmDoAzureAction {
        param(
            [string]$ActionName,
            [string]$ResourceGroup,
            [string]$VmName,
            [string[]]$AzArguments,
            [string]$AzContext
        )

        $script:DoReapplyInvocation = [pscustomobject]@{
            ActionName = $ActionName
            ResourceGroup = $ResourceGroup
            VmName = $VmName
            AzArguments = @($AzArguments)
            AzContext = $AzContext
        }
    }
    function Wait-AzVmDoLifecycleState {
        param([string]$ResourceGroup, [string]$VmName, [string]$DesiredState, [int]$MaxAttempts, [int]$DelaySeconds)
        $script:DoReapplyWaitCalled = $true
        return $null
    }
    function Write-AzVmDoStatusReport {
        param([psobject]$Snapshot)
        $script:DoReapplyReportedSnapshot = $Snapshot
    }

    try {
        Invoke-AzVmDoCommand -Options @{ group = 'rg-samplevm-ate1-g1'; 'vm-name' = 'samplevm'; 'vm-action' = 'reapply' }

        Assert-True -Condition ($null -ne $script:DoReapplyInvocation) -Message 'Reapply must invoke the Azure action wrapper.'
        Assert-True -Condition ([string]$script:DoReapplyInvocation.ActionName -eq 'reapply') -Message 'Reapply must pass the reapply action name to the Azure wrapper.'
        Assert-True -Condition ([string]$script:DoReapplyInvocation.AzContext -eq 'az vm reapply') -Message 'Reapply must use the az vm reapply context label.'
        Assert-True -Condition ((@($script:DoReapplyInvocation.AzArguments) -join ' ') -eq 'vm reapply -g rg-samplevm-ate1-g1 -n samplevm -o none --only-show-errors') -Message 'Reapply must call az vm reapply with the resolved target.'
        Assert-True -Condition ($script:DoReapplySnapshotCalls -eq 2) -Message 'Reapply must refresh lifecycle status after the Azure action.'
        Assert-True -Condition (-not $script:DoReapplyWaitCalled) -Message 'Reapply must not wait for a synthetic lifecycle-state transition.'
        Assert-True -Condition ($null -ne $script:DoReapplyReportedSnapshot) -Message 'Reapply must print the refreshed VM status.'
        Assert-True -Condition ([string]$script:DoReapplyReportedSnapshot.ProvisioningStateCode -eq 'ProvisioningState/succeeded') -Message 'Reapply must report the post-action lifecycle snapshot.'
    }
    finally {
        foreach ($functionName in @(
            'Resolve-AzVmManagedVmTarget',
            'Get-AzVmVmLifecycleSnapshot',
            'Invoke-AzVmDoAzureAction',
            'Wait-AzVmDoLifecycleState',
            'Write-AzVmDoStatusReport'
        )) {
            Remove-Item ("Function:\global:{0}" -f $functionName) -ErrorAction SilentlyContinue
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue

            if ($originalFunctionDefinitions.ContainsKey($functionName)) {
                Set-Item -Path ("Function:\global:{0}" -f $functionName) -Value ([scriptblock]::Create([string]$originalFunctionDefinitions[$functionName]))
            }
        }
    }
}

Invoke-Test -Name "Do hibernate-stop guest action uses pyssh shutdown" -Action {
    $script:DoHibernateStopProcessInvocation = $null
    $originalFunctionDefinitions = @{}

    foreach ($functionName in @(
        'Initialize-AzVmConnectionCommandContext',
        'Resolve-AzVmConnectionPortNumber',
        'Wait-AzVmTcpPortReachable',
        'Get-AzVmRepoRoot',
        'Get-ConfigValue',
        'Ensure-AzVmPySshTools',
        'Invoke-AzVmProcessWithRetry'
    )) {
        $command = Get-Command $functionName -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            $originalFunctionDefinitions[$functionName] = [string]$command.Definition
        }
    }

    function Initialize-AzVmConnectionCommandContext {
        param([hashtable]$Options, [string]$OperationName)
        return [pscustomobject]@{
            ResourceGroup = 'rg-samplevm-ate1-g1'
            VmName = 'samplevm'
            ConnectionHost = 'samplevm.example'
            VmSshPort = '444'
            SelectedUserName = 'manager'
            SelectedPassword = 'secret'
            ConfigMap = @{ PYSSH_CLIENT_PATH = 'tools/pyssh/ssh_client.py'; SSH_CONNECT_TIMEOUT_SECONDS = '30' }
        }
    }
    function Resolve-AzVmConnectionPortNumber { param([string]$PortText, [string]$PortLabel) return 444 }
    function Wait-AzVmTcpPortReachable { param([string]$HostName, [int]$Port, [int]$MaxAttempts, [int]$DelaySeconds, [int]$TimeoutSeconds, [string]$Label) return $true }
    function Get-AzVmRepoRoot { return $RepoRoot }
    function Get-ConfigValue {
        param([hashtable]$Config, [string]$Key, [string]$DefaultValue)
        if ($Config.ContainsKey($Key)) {
            return [string]$Config[$Key]
        }
        return [string]$DefaultValue
    }
    function Ensure-AzVmPySshTools {
        param([string]$RepoRoot, [string]$ConfiguredPySshClientPath)
        return [pscustomobject]@{
            PythonPath = 'python'
            ClientPath = 'client.py'
        }
    }
    function Invoke-AzVmProcessWithRetry {
        param(
            [string]$FilePath,
            [string[]]$Arguments,
            [string]$Label,
            [int]$MaxAttempts,
            [switch]$AllowFailure
        )

        $script:DoHibernateStopProcessInvocation = [pscustomobject]@{
            FilePath = $FilePath
            Arguments = @($Arguments)
            Label = $Label
            MaxAttempts = $MaxAttempts
            AllowFailure = [bool]$AllowFailure
        }

        return [pscustomobject]@{
            ExitCode = 0
            Output = 'ok'
        }
    }

    try {
        $result = Invoke-AzVmDoGuestHibernateStopCommand -ResourceGroup 'rg-samplevm-ate1-g1' -VmName 'samplevm'
        Assert-True -Condition ($null -ne $result) -Message 'Hibernate-stop helper must return runtime invocation details.'
        Assert-True -Condition ($null -ne $script:DoHibernateStopProcessInvocation) -Message 'Hibernate-stop helper must invoke the pyssh process wrapper.'
        Assert-True -Condition ((@($script:DoHibernateStopProcessInvocation.Arguments) -join ' ') -match [regex]::Escape('--command shutdown /h /f')) -Message 'Hibernate-stop helper must issue shutdown /h /f through pyssh.'
        Assert-True -Condition ($script:DoHibernateStopProcessInvocation.MaxAttempts -eq 1) -Message 'Hibernate-stop helper must not retry the guest shutdown command.'
        Assert-True -Condition ($script:DoHibernateStopProcessInvocation.AllowFailure) -Message 'Hibernate-stop helper must allow a dropped SSH session while the guest powers off.'
    }
    finally {
        foreach ($functionName in @(
            'Initialize-AzVmConnectionCommandContext',
            'Resolve-AzVmConnectionPortNumber',
            'Wait-AzVmTcpPortReachable',
            'Get-AzVmRepoRoot',
            'Get-ConfigValue',
            'Ensure-AzVmPySshTools',
            'Invoke-AzVmProcessWithRetry'
        )) {
            Remove-Item ("Function:\global:{0}" -f $functionName) -ErrorAction SilentlyContinue
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue

            if ($originalFunctionDefinitions.ContainsKey($functionName)) {
                Set-Item -Path ("Function:\global:{0}" -f $functionName) -Value ([scriptblock]::Create([string]$originalFunctionDefinitions[$functionName]))
            }
        }
    }
}

Invoke-Test -Name "Do hibernate-stop action waits for the guest to stop after SSH-triggered hibernation" -Action {
    $script:DoHibernateStopInvocation = $null
    $script:DoHibernateStopWaitInvocation = $null
    $script:DoHibernateStopReportedSnapshot = $null
    $originalFunctionDefinitions = @{}

    foreach ($functionName in @(
        'Resolve-AzVmManagedVmTarget',
        'Get-AzVmVmLifecycleSnapshot',
        'Invoke-AzVmDoGuestHibernateStopCommand',
        'Wait-AzVmDoHibernateStopCompletion',
        'Write-AzVmDoStatusReport'
    )) {
        $command = Get-Command $functionName -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            $originalFunctionDefinitions[$functionName] = [string]$command.Definition
        }
    }

    function Resolve-AzVmManagedVmTarget {
        param([hashtable]$Options, [hashtable]$ConfigMap, [string]$OperationName)
        return [pscustomobject]@{
            ResourceGroup = 'rg-samplevm-ate1-g1'
            VmName = 'samplevm'
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
            PowerStateCode = 'PowerState/running'
            PowerStateDisplay = 'VM running'
            HibernationStateCode = ''
            HibernationStateDisplay = ''
            NormalizedState = 'started'
        }
    }
    function Invoke-AzVmDoGuestHibernateStopCommand {
        param([string]$ResourceGroup, [string]$VmName)
        $script:DoHibernateStopInvocation = [pscustomobject]@{
            ResourceGroup = $ResourceGroup
            VmName = $VmName
        }
        return [pscustomobject]@{
            Runtime = [pscustomobject]@{
                ConnectionHost = 'samplevm.example'
                VmSshPort = '444'
            }
            LaunchResult = [pscustomobject]@{
                ExitCode = 0
                Output = 'issued'
            }
        }
    }
    function Wait-AzVmDoHibernateStopCompletion {
        param([psobject]$Runtime, [string]$ResourceGroup, [string]$VmName, [int]$MaxAttempts, [int]$DelaySeconds)
        $script:DoHibernateStopWaitInvocation = [pscustomobject]@{
            Runtime = $Runtime
            ResourceGroup = $ResourceGroup
            VmName = $VmName
            MaxAttempts = $MaxAttempts
            DelaySeconds = $DelaySeconds
        }
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
    function Write-AzVmDoStatusReport {
        param([psobject]$Snapshot)
        $script:DoHibernateStopReportedSnapshot = $Snapshot
    }

    try {
        Invoke-AzVmDoCommand -Options @{ group = 'rg-samplevm-ate1-g1'; 'vm-name' = 'samplevm'; 'vm-action' = 'hibernate-stop' }

        Assert-True -Condition ($null -ne $script:DoHibernateStopInvocation) -Message 'Hibernate-stop must invoke the guest shutdown helper.'
        Assert-True -Condition ($null -ne $script:DoHibernateStopWaitInvocation) -Message 'Hibernate-stop must wait for the guest to stop after issuing shutdown.'
        Assert-True -Condition ($script:DoHibernateStopWaitInvocation.MaxAttempts -eq 24) -Message 'Hibernate-stop must use the bounded wait contract.'
        Assert-True -Condition ($null -ne $script:DoHibernateStopReportedSnapshot) -Message 'Hibernate-stop must print the final VM status.'
        Assert-True -Condition ([string]$script:DoHibernateStopReportedSnapshot.NormalizedState -eq 'stopped') -Message 'Hibernate-stop must report the post-hibernate stopped state.'
    }
    finally {
        foreach ($functionName in @(
            'Resolve-AzVmManagedVmTarget',
            'Get-AzVmVmLifecycleSnapshot',
            'Invoke-AzVmDoGuestHibernateStopCommand',
            'Wait-AzVmDoHibernateStopCompletion',
            'Write-AzVmDoStatusReport'
        )) {
            Remove-Item ("Function:\global:{0}" -f $functionName) -ErrorAction SilentlyContinue
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue

            if ($originalFunctionDefinitions.ContainsKey($functionName)) {
                Set-Item -Path ("Function:\global:{0}" -f $functionName) -Value ([scriptblock]::Create([string]$originalFunctionDefinitions[$functionName]))
            }
        }
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
            ResourceGroup = 'rg-samplevm-ate1-g1'
            VmName = 'samplevm'
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
                ResourceGroup = 'rg-samplevm-ate1-g1'
                VmName = 'samplevm'
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

Invoke-Test -Name "Show report redacts password-bearing config values and prints nested state" -Action {
    $script:ShowReportCapturedHostLines = @()
    try {
        function Write-Host {
            param(
                [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
                [object[]]$Object,
                [ConsoleColor]$ForegroundColor,
                [ConsoleColor]$BackgroundColor,
                [switch]$NoNewline,
                [object]$Separator
            )

            $script:ShowReportCapturedHostLines += ,((@($Object) | ForEach-Object { [string]$_ }) -join ' ')
        }

        $dump = [ordered]@{
            GeneratedAtUtc = '2026-03-11T00:00:00Z'
            Command = 'show'
            Mode = 'auto'
            RequestedPlatform = 'windows'
            EnvFilePath = 'C:\repo\.env'
            AzureAccount = [ordered]@{
                SubscriptionName = 'sub'
                SubscriptionId = 'sub-id'
                TenantName = 'tenant'
                TenantId = 'tenant-id'
                UserName = '<email>'
            }
            Config = [ordered]@{
                DotEnvValues = [ordered]@{
                    VM_ADMIN_PASS = '<runtime-secret>'
                    VM_ASSISTANT_PASS = '<runtime-secret>'
                    VM_NAME = 'samplevm'
                }
                RuntimeOverrides = [ordered]@{
                    VM_ADMIN_PASS = '<runtime-secret>'
                    RESOURCE_GROUP = 'rg-samplevm-ate1-g1'
                }
            }
            Selection = [ordered]@{
                TargetGroup = 'rg-samplevm-ate1-g1'
                IncludedResourceGroups = @('rg-samplevm-ate1-g1')
            }
            Summary = [ordered]@{
                ResourceGroupCount = 1
                TotalVmCount = 1
                RunningVmCount = 1
            }
            ResourceGroups = @(
                [ordered]@{
                    Name = 'rg-samplevm-ate1-g1'
                    Exists = $true
                    Location = 'austriaeast'
                    ProvisioningState = 'Succeeded'
                    ResourceCount = 6
                    VmCount = 1
                    ResourceTypeCounts = [ordered]@{
                        'Microsoft.Compute/virtualMachines' = 1
                    }
                    Resources = @()
                    Vms = @(
                        [ordered]@{
                            Name = 'samplevm'
                            PowerState = 'VM running'
                            ProvisioningState = 'Succeeded'
                            Location = 'austriaeast'
                            VmSize = 'Standard_D4as_v5'
                            SkuAvailability = 'yes'
                            OsType = 'Windows'
                            PublicIps = '1.2.3.4'
                            PrivateIps = '10.0.0.4'
                            Fqdns = 'samplevm.example'
                            OsDiskName = 'disk-samplevm'
                            DataDiskNames = @()
                            NicIds = @()
                            FeatureFlags = [ordered]@{
                                HibernationEnabled = $true
                                NestedVirtualizationEnabled = $true
                                NestedVirtualizationValidationSource = 'guest'
                                NestedVirtualizationEvidence = @(
                                    'VMMonitorModeExtensions=True',
                                    'VirtualizationFirmwareEnabled=True'
                                )
                            }
                            FocusedCapabilities = @(
                                [pscustomobject]@{ name = 'NestedVirtualization'; value = 'True' }
                            )
                        }
                    )
                }
            )
        }

        Write-AzVmShowReport -Dump $dump

        $outputText = $script:ShowReportCapturedHostLines -join "`n"
        Assert-True -Condition ($outputText -match [regex]::Escape('VM_ADMIN_PASS: [redacted]')) -Message 'Show report must redact the admin password.'
        Assert-True -Condition ($outputText -match [regex]::Escape('VM_ASSISTANT_PASS: [redacted]')) -Message 'Show report must redact the assistant password.'
        Assert-True -Condition (-not ($outputText -match [regex]::Escape('<runtime-secret>'))) -Message 'Show report must not print the raw admin password.'
        Assert-True -Condition (-not ($outputText -match [regex]::Escape('<runtime-secret>'))) -Message 'Show report must not print the raw assistant password.'
        Assert-True -Condition ($outputText -match [regex]::Escape('Nested virtualization enabled: True')) -Message 'Show report must print the nested virtualization enabled state.'
        Assert-True -Condition ($outputText -match [regex]::Escape('Nested virtualization validation source: guest')) -Message 'Show report must print the nested virtualization validation source.'
        Assert-True -Condition ($outputText -match [regex]::Escape('VirtualizationFirmwareEnabled=True')) -Message 'Show report must print nested virtualization guest evidence.'
        Assert-True -Condition ($outputText -match [regex]::Escape('VM_NAME: samplevm')) -Message 'Show report must keep non-secret config values visible.'
    }
    finally {
        Remove-Item Function:\Write-Host -ErrorAction SilentlyContinue
        Remove-Variable -Name ShowReportCapturedHostLines -Scope Script -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "SSH identity output matcher accepts machine-qualified usernames" -Action {
    Assert-True -Condition (Test-AzVmConnectionIdentityOutputMatchesUser -ExpectedUserName 'manager' -OutputText "samplevm\manager") -Message 'Identity matcher must accept machine-qualified usernames.'
    Assert-True -Condition (Test-AzVmConnectionIdentityOutputMatchesUser -ExpectedUserName 'assistant' -OutputText "assistant") -Message 'Identity matcher must accept plain usernames.'
    Assert-True -Condition (-not (Test-AzVmConnectionIdentityOutputMatchesUser -ExpectedUserName 'manager' -OutputText "samplevm\assistant")) -Message 'Identity matcher must reject a different user.'
}

Invoke-Test -Name "SSH test mode performs a non-interactive handshake without launching ssh.exe" -Action {
    $script:SshTestStartedProcess = $false
    $script:SshTestProcessInvocation = $null
    try {
        function Initialize-AzVmConnectionCommandContext {
            param([hashtable]$Options, [string]$OperationName)
            return [pscustomobject]@{
                ConfigMap = @{
                    PYSSH_CLIENT_PATH = 'tools/pyssh/ssh_client.py'
                    SSH_MAX_RETRIES = '2'
                    SSH_CONNECT_TIMEOUT_SECONDS = '30'
                }
                VmName = 'samplevm'
                ResourceGroup = 'rg-samplevm-ate1-g1'
                ConnectionHost = 'samplevm.example'
                SelectedUserName = 'manager'
                SelectedPassword = 'secret'
                VmSshPort = '444'
            }
        }
        function Wait-AzVmTcpPortReachable { param([string]$HostName, [int]$Port, [int]$MaxAttempts, [int]$DelaySeconds, [int]$TimeoutSeconds, [string]$Label) return $true }
        function Get-AzVmRepoRoot { return $RepoRoot }
        function Ensure-AzVmPySshTools { param([string]$RepoRoot, [string]$ConfiguredPySshClientPath) return @{ PythonPath = 'python.exe'; ClientPath = 'ssh_client.py' } }
        function Invoke-AzVmProcessWithRetry {
            param([string]$FilePath, [string[]]$Arguments, [string]$Label, [int]$MaxAttempts, [switch]$AllowFailure)
            $script:SshTestProcessInvocation = [pscustomobject]@{
                FilePath = $FilePath
                Arguments = @($Arguments)
                Label = $Label
                MaxAttempts = $MaxAttempts
                AllowFailure = [bool]$AllowFailure
            }
            return [pscustomobject]@{
                ExitCode = 0
                Output = "samplevm\manager"
            }
        }
        function Start-Process {
            param()
            $script:SshTestStartedProcess = $true
        }
        function Resolve-AzVmLocalExecutablePath { throw 'Local SSH executable should not resolve in --test mode.' }

        Invoke-AzVmSshConnectCommand -Options @{ test = $true; user = 'manager' }

        Assert-True -Condition ($null -ne $script:SshTestProcessInvocation) -Message 'SSH test mode must invoke the pyssh process.'
        Assert-True -Condition (-not $script:SshTestStartedProcess) -Message 'SSH test mode must not launch the external SSH client.'
        Assert-True -Condition ((@($script:SshTestProcessInvocation.Arguments) -join ' ') -match [regex]::Escape('--command whoami')) -Message 'SSH test mode must execute a whoami handshake.'
        Assert-True -Condition ([int]$script:SshTestProcessInvocation.MaxAttempts -eq 2) -Message 'SSH test mode must honor SSH_MAX_RETRIES.'
    }
    finally {
        foreach ($functionName in @(
            'Initialize-AzVmConnectionCommandContext',
            'Wait-AzVmTcpPortReachable',
            'Get-AzVmRepoRoot',
            'Ensure-AzVmPySshTools',
            'Invoke-AzVmProcessWithRetry',
            'Start-Process',
            'Resolve-AzVmLocalExecutablePath'
        )) {
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name SshTestStartedProcess -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name SshTestProcessInvocation -Scope Script -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "RDP test mode checks reachability without launching mstsc" -Action {
    $script:RdpTestStartedProcess = $false
    $script:RdpTestReachabilityCalls = @()
    try {
        function Initialize-AzVmConnectionCommandContext {
            param([hashtable]$Options, [string]$OperationName)
            return [pscustomobject]@{
                VmName = 'samplevm'
                ResourceGroup = 'rg-samplevm-ate1-g1'
                ConnectionHost = 'samplevm.example'
                SelectedUserName = 'manager'
                SelectedPassword = 'secret'
                VmRdpPort = '3389'
                OsType = 'Windows'
            }
        }
        function Wait-AzVmTcpPortReachable {
            param([string]$HostName, [int]$Port, [int]$MaxAttempts, [int]$DelaySeconds, [int]$TimeoutSeconds, [string]$Label)
            $script:RdpTestReachabilityCalls += ,([pscustomobject]@{
                HostName = $HostName
                Port = $Port
                Label = $Label
            })
            return $true
        }
        function Start-Process {
            param()
            $script:RdpTestStartedProcess = $true
        }
        function Resolve-AzVmLocalExecutablePath { throw 'Local RDP executables should not resolve in --test mode.' }

        Invoke-AzVmRdpConnectCommand -Options @{ test = $true; user = 'manager' }

        Assert-True -Condition (@($script:RdpTestReachabilityCalls).Count -eq 1) -Message 'RDP test mode must perform a TCP reachability check.'
        Assert-True -Condition ([int]$script:RdpTestReachabilityCalls[0].Port -eq 3389) -Message 'RDP test mode must probe the resolved RDP port.'
        Assert-True -Condition (-not $script:RdpTestStartedProcess) -Message 'RDP test mode must not launch mstsc.'
    }
    finally {
        foreach ($functionName in @(
            'Initialize-AzVmConnectionCommandContext',
            'Wait-AzVmTcpPortReachable',
            'Start-Process',
            'Resolve-AzVmLocalExecutablePath'
        )) {
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name RdpTestStartedProcess -Scope Script -ErrorAction SilentlyContinue
        Remove-Variable -Name RdpTestReachabilityCalls -Scope Script -ErrorAction SilentlyContinue
    }
}

Invoke-Test -Name "Persistent SSH protocol normalizes spinner-prefixed markers" -Action {
    $normalizedEnd = Normalize-AzVmProtocolLine -Text '   / AZ_VM_TASK_END:118-install-teams-system:4294967295'
    Assert-True -Condition ([string]$normalizedEnd -eq 'AZ_VM_TASK_END:118-install-teams-system:4294967295') -Message 'Spinner-prefixed task end markers must normalize back to the protocol marker.'

    $normalizedError = Normalize-AzVmProtocolLine -Text '  - [stderr] AZ_VM_SESSION_TASK_ERROR:118-install-teams-system:example'
    Assert-True -Condition ([string]$normalizedError -eq '[stderr] AZ_VM_SESSION_TASK_ERROR:118-install-teams-system:example') -Message 'Spinner-prefixed stderr session markers must normalize back to the protocol marker.'

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
                ConfigMap = @{ RESOURCE_GROUP = 'rg-samplevm-ate1-g1'; VM_NAME = 'samplevm' }
                EffectiveConfigMap = @{ RESOURCE_GROUP = 'rg-samplevm-ate1-g1'; VM_NAME = 'samplevm' }
                Platform = 'windows'
                PlatformDefaults = [pscustomobject]@{ RunCommandId = 'RunPowerShellScript' }
                Context = [ordered]@{
                    ResourceGroup = 'rg-samplevm-ate1-g1'
                    VmName = 'samplevm'
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
                    VmDiskName = 'disk-samplevm'
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
                ResourceGroup = 'rg-samplevm-ate1-g1'
                VmName = 'samplevm'
            }
        }
        function Get-AzVmTaskBlocksFromDirectory {
            param([string]$DirectoryPath, [string]$Platform, [string]$Stage)
            return [pscustomobject]@{
                ActiveTasks = @(
                    [pscustomobject]@{
                        Name = '01-ensure-users-local'
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
        Assert-True -Condition ([string]$script:ExecRunCommandInvocation.ResourceGroup -eq 'rg-samplevm-ate1-g1') -Message 'Exec init task must preserve target resource group.'
        Assert-True -Condition ([string]$script:ExecRunCommandInvocation.VmName -eq 'samplevm') -Message 'Exec init task must preserve target VM name.'
        Assert-True -Condition ([string]$script:ExecRunCommandInvocation.CommandId -eq 'RunPowerShellScript') -Message 'Exec init task must preserve platform run-command id.'
        Assert-True -Condition ([string]$script:ExecRunCommandInvocation.TaskName -eq '01-ensure-users-local') -Message 'Exec init task must preserve selected task.'
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

Invoke-Test -Name "Exec command supports strict outcome override" -Action {
    try {
        function Initialize-AzVmExecCommandRuntimeContext {
            param([switch]$AutoMode, [switch]$WindowsFlag, [switch]$LinuxFlag)
            return [pscustomobject]@{
                Context = [ordered]@{
                    ResourceGroup = 'rg-samplevm-ate1-g1'
                    VmName = 'samplevm'
                    VmInitTaskDir = 'windows/init'
                    VmUpdateTaskDir = 'windows/update'
                    VmUser = 'manager'
                    VmPass = 'secret'
                    SshPort = '444'
                    AzLocation = 'austriaeast'
                }
                Platform = 'windows'
                PlatformDefaults = [pscustomobject]@{
                    RunCommandId = 'RunPowerShellScript'
                }
                EffectiveConfigMap = @{}
                TaskOutcomeMode = 'continue'
                ConfiguredPySshClientPath = ''
                SshTaskTimeoutSeconds = 180
                SshConnectTimeoutSeconds = 30
            }
        }
        function Resolve-AzVmManagedVmTarget {
            param([hashtable]$Options, [hashtable]$ConfigMap, [string]$OperationName)
            return [pscustomobject]@{
                ResourceGroup = 'rg-samplevm-ate1-g1'
                VmName = 'samplevm'
            }
        }
        function Get-AzVmTaskBlocksFromDirectory {
            param([string]$DirectoryPath, [string]$Platform, [string]$Stage)
            return [pscustomobject]@{
                ActiveTasks = @(
                    [pscustomobject]@{
                        Name = '10099-capture-snapshot-health'
                        Script = 'Write-Host ok'
                        TimeoutSeconds = 30
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
        function Get-AzVmVmDetails {
            param([hashtable]$Context)
            return [pscustomobject]@{
                VmFqdn = 'samplevm.austriaeast.cloudapp.azure.com'
                PublicIP = '1.2.3.4'
            }
        }
        function Invoke-AzVmSshTaskBlocks {
            param(
                [string]$Platform,
                [string]$RepoRoot,
                [string]$SshHost,
                [string]$SshUser,
                [string]$SshPassword,
                [string]$SshPort,
                [string]$ResourceGroup,
                [string]$VmName,
                [object[]]$TaskBlocks,
                [string]$TaskOutcomeMode,
                [string]$PerfTaskCategory,
                [int]$SshMaxRetries,
                [int]$SshTaskTimeoutSeconds,
                [int]$SshConnectTimeoutSeconds,
                [string]$ConfiguredPySshClientPath
            )

            $script:ExecSshInvocation = [pscustomobject]@{
                ResourceGroup = $ResourceGroup
                VmName = $VmName
                TaskName = [string]@($TaskBlocks)[0].Name
                TaskOutcomeMode = $TaskOutcomeMode
                SshHost = $SshHost
            }

            return [pscustomobject]@{
                SuccessCount = 1
                FailedCount = 0
                WarningCount = 0
                ErrorCount = 0
            }
        }

        $result = Invoke-AzVmExecCommand -Options @{ 'update-task' = '10099' } -AutoMode:$false -WindowsFlag -LinuxFlag:$false -TaskOutcomeModeOverride 'strict'

        Assert-True -Condition ($null -ne $script:ExecSshInvocation) -Message 'Exec update task must invoke SSH task runner.'
        Assert-True -Condition ([string]$script:ExecSshInvocation.TaskName -eq '10099-capture-snapshot-health') -Message 'Exec update task must preserve selected task.'
        Assert-True -Condition ([string]$script:ExecSshInvocation.TaskOutcomeMode -eq 'strict') -Message 'Exec strict override must flow into SSH task outcome mode.'
        Assert-True -Condition ([string]$result.Stage -eq 'update') -Message 'Exec update task must report update stage result.'
        Assert-True -Condition ([string]$result.TaskOutcomeMode -eq 'strict') -Message 'Exec result must expose the strict outcome override.'
    }
    finally {
        foreach ($functionName in @(
            'Initialize-AzVmExecCommandRuntimeContext',
            'Resolve-AzVmManagedVmTarget',
            'Get-AzVmTaskBlocksFromDirectory',
            'Resolve-AzVmRuntimeTaskBlocks',
            'Resolve-AzVmTaskSelection',
            'Get-AzVmVmDetails',
            'Invoke-AzVmSshTaskBlocks'
        )) {
            Remove-Item ("Function:\{0}" -f $functionName) -ErrorAction SilentlyContinue
        }
        Remove-Variable -Name ExecSshInvocation -Scope Script -ErrorAction SilentlyContinue
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
        ResourceGroup = "rg-samplevm"
        VmName = "samplevm"
        CompanyName = "orgprofile"
        EmployeeEmailAddress = "<email>"
        EmployeeFullName = "<person-name>"
        AzLocation = "austriaeast"
        VmSize = "Standard_B2as_v2"
        VmImage = "example:image:urn"
        VmDiskName = "disk-samplevm"
        VmDiskSize = "128"
        VmStorageSku = "StandardSSD_LRS"
        HostStartupProfileJsonBase64 = "W10="
        HostAutostartDiscoveryJsonBase64 = "e30="
    }

    $templates = @(
        [pscustomobject]@{ Name = "01-test"; Script = "echo __VM_ADMIN_USER__ __SSH_PORT__ __RDP_PORT__ __VM_NAME__ __COMPANY_NAME__ __EMPLOYEE_EMAIL_ADDRESS__ __EMPLOYEE_FULL_NAME__ __TCP_PORTS_BASH__ __HOST_STARTUP_PROFILE_JSON_B64__ __HOST_AUTOSTART_DISCOVERY_JSON_B64__" }
    )

    $resolved = Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks $templates -Context $context
    $scriptBody = [string]$resolved[0].Script
    Assert-True -Condition ($scriptBody -like "*manager*") -Message "VM user token was not replaced."
    Assert-True -Condition ($scriptBody -like "*444*") -Message "SSH port token was not replaced."
    Assert-True -Condition ($scriptBody -like "*3389*") -Message "RDP port token was not replaced."
    Assert-True -Condition ($scriptBody -like "*samplevm*") -Message "VM name token was not replaced."
    Assert-True -Condition ($scriptBody -like "*orgprofile*") -Message "Company name token was not replaced."
    Assert-True -Condition ($scriptBody -like "*<email>*") -Message "Employee email token was not replaced."
    Assert-True -Condition ($scriptBody -like "*<person-name>*") -Message "Employee full name token was not replaced."
    Assert-True -Condition ($scriptBody -like "*W10=*") -Message "Host startup profile token was not replaced."
    Assert-True -Condition ($scriptBody -like "*e30=*") -Message "Host autostart discovery token was not replaced."
}

Invoke-Test -Name "Startup mirror profile resolution" -Action {
    $entries = @(
        [pscustomobject]@{ Name = 'Docker Desktop'; Command = 'C:\Program Files\Docker\Docker\Docker Desktop.exe'; EntryType = 'Run'; Scope = 'CurrentUser'; Enabled = $true },
        [pscustomobject]@{ Name = 'Ollama.lnk'; Command = 'C:\Users\operator\AppData\Local\Programs\Ollama\ollama app.exe'; EntryType = 'StartupFolder'; Scope = 'CurrentUser'; Enabled = $true },
        [pscustomobject]@{ Name = 'Teams'; Command = '"C:\Users\operator\AppData\Local\Microsoft\WindowsApps\MSTeams_8wekyb3d8bbwe\ms-teams.exe" msteams:system-initiated'; EntryType = 'Run'; Scope = 'CurrentUser'; Enabled = $true },
        [pscustomobject]@{ Name = 'iTunesHelper'; Command = '"C:\Program Files\iTunes\iTunesHelper.exe"'; EntryType = 'Run'; Scope = 'LocalMachine'; Enabled = $true },
        [pscustomobject]@{ Name = 'OneDrive'; Command = '"C:\Program Files\Microsoft OneDrive\OneDrive.exe" /background'; EntryType = 'Run'; Scope = 'CurrentUser'; Enabled = $true },
        [pscustomobject]@{ Name = 'Microsoft Lists'; Command = '"C:\Program Files\WindowsApps\Microsoft.Lists\Lists.exe"'; EntryType = 'Run'; Scope = 'CurrentUser'; Enabled = $true },
        [pscustomobject]@{ Name = 'Edge'; Command = '"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" --minimized'; EntryType = 'Run'; Scope = 'CurrentUser'; Enabled = $false }
    )

    $profile = @(Resolve-AzVmHostStartupMirrorProfileFromEntries -Entries $entries)
    $keys = @($profile | ForEach-Object { [string]$_.Key })

    foreach ($requiredKey in @('docker-desktop','ollama','teams','itunes-helper','onedrive')) {
        Assert-True -Condition ($keys -contains $requiredKey) -Message ("Startup mirror profile must include '{0}'." -f $requiredKey)
    }

    Assert-True -Condition (-not ($keys -contains 'codex-app')) -Message "Startup mirror profile must not infer unsupported apps from unrelated entries."
    Assert-True -Condition (-not ($keys -contains 'microsoft-edge')) -Message "Disabled startup entries must not be mirrored."
}

Invoke-Test -Name "Required config helper rejects empty and placeholder values" -Action {
    $tokens = @{ VM_NAME = 'samplevm' }

    $missingFailed = $false
    try {
        $null = Get-AzVmRequiredResolvedConfigValue -ConfigMap @{} -Key 'VM_ADMIN_PASS' -Tokens $tokens -Summary 'VM admin password is required.' -Hint 'Set VM_ADMIN_PASS in .env to a non-placeholder password.'
    }
    catch {
        $missingFailed = $true
        Assert-True -Condition ($_.Exception.Data['Hint'] -like '*VM_ADMIN_PASS*') -Message 'Missing required config must point to the missing key.'
    }
    Assert-True -Condition $missingFailed -Message 'Missing required config must fail.'

    $placeholderFailed = $false
    try {
        $null = Get-AzVmRequiredResolvedConfigValue -ConfigMap @{ VM_ADMIN_PASS = '<CHANGE_ME_STRONG_ADMIN_PASSWORD>' } -Key 'VM_ADMIN_PASS' -Tokens $tokens -Summary 'VM admin password is required.' -Hint 'Set VM_ADMIN_PASS in .env to a non-placeholder password.'
    }
    catch {
        $placeholderFailed = $true
        Assert-True -Condition ($_.Exception.Message -like '*placeholder*') -Message 'Placeholder config must fail with a placeholder-specific message.'
    }
    Assert-True -Condition $placeholderFailed -Message 'Placeholder config must fail.'
}

Invoke-Test -Name "Windows vm-update tracked catalog order and timeouts" -Action {
    $updateDir = Join-Path $RepoRoot 'windows\update'
    $catalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath $updateDir -Platform windows -Stage update
    $active = @($catalog.ActiveTasks)
    $activeNames = @($active | ForEach-Object { [string]$_.Name })

    $expectedTrackedTimeouts = [ordered]@{
        '01-bootstrap-winget-system' = 70
        '02-check-install-chrome' = 128
        '101-install-powershell-core' = 180
        '102-install-git-system' = 240
        '103-install-python-system' = 105
        '104-install-node-system' = 240
        '105-install-azure-cli' = 139
        '106-install-gh-cli' = 11
        '107-install-7zip-system' = 13
        '109-install-ffmpeg-system' = 34
        '110-install-vscode-system' = 104
        '111-install-edge-browser' = 120
        '112-install-azd-cli' = 88
        '113-install-wsl2-system' = 137
        '114-install-docker-desktop' = 1649
        '115-install-npm-packages-global' = 420
        '116-install-ollama-system' = 376
        '117-install-codex-app' = 120
        '118-install-teams-system' = 60
        '119-install-onedrive-system' = 5
        '120-install-google-drive' = 103
        '121-install-whatsapp-system' = 10
        '122-install-anydesk-system' = 20
        '123-install-windscribe-system' = 63
        '124-install-vlc-system' = 58
        '125-install-itunes-system' = 57
        '126-install-be-my-eyes' = 240
        '127-install-nvda-system' = 54
        '128-install-rclone-system' = 13
        '129-configure-unlocker-io' = 23
        '131-install-icloud-system' = 120
        '132-install-vs2022community' = 7200
        '10001-configure-apps-startup' = 45
        '10002-create-shortcuts-public-desktop' = 60
        '10003-configure-ux-windows' = 60
        '10004-configure-settings-advanced-system' = 5
        '10005-copy-settings-user' = 300
        '10099-capture-snapshot-health' = 120
    }
    $expectedTrackedOrder = @($expectedTrackedTimeouts.Keys)

    Assert-True -Condition ([string]$activeNames[0] -eq '01-bootstrap-winget-system') -Message 'Winget bootstrap must be the first tracked Windows update task.'
    Assert-True -Condition ([string]$activeNames[1] -eq '02-check-install-chrome') -Message 'Chrome install check must be the second tracked Windows update task.'

    foreach ($entry in $expectedTrackedTimeouts.GetEnumerator()) {
        $task = $active | Where-Object { [string]$_.Name -eq [string]$entry.Key } | Select-Object -First 1
        Assert-True -Condition ($null -ne $task) -Message ("Expected tracked task '{0}' was not discovered." -f [string]$entry.Key)
        Assert-True -Condition ([int]$task.TimeoutSeconds -eq [int]$entry.Value) -Message ("Tracked task '{0}' timeout must stay {1}." -f [string]$entry.Key, [int]$entry.Value)
    }

    $lastSeenIndex = -1
    foreach ($taskName in @($expectedTrackedOrder)) {
        $currentIndex = [array]::IndexOf($activeNames, $taskName)
        Assert-True -Condition ($currentIndex -ge 0) -Message ("Tracked task '{0}' must appear in the active order." -f $taskName)
        Assert-True -Condition ($currentIndex -gt $lastSeenIndex) -Message ("Tracked task order must keep '{0}' after the previous tracked task." -f $taskName)
        $lastSeenIndex = $currentIndex
    }

    Assert-True -Condition ($activeNames -notcontains '108-install-sysinternals-suite') -Message 'Windows update catalog must no longer keep 108-install-sysinternals-suite after the init move.'
    Assert-True -Condition ($activeNames -notcontains '130-autologon-manager-user') -Message 'Windows update catalog must no longer keep 130-autologon-manager-user after the init move.'

    $initCatalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath (Join-Path $RepoRoot 'windows\init') -Platform windows -Stage init
    $initActive = @($initCatalog.ActiveTasks)
    $sysinternalsTask = @($initActive | Where-Object { [string]$_.Name -eq '108-install-sysinternals-suite' } | Select-Object -First 1)
    $autologonTask = @($initActive | Where-Object { [string]$_.Name -eq '130-autologon-manager-user' } | Select-Object -First 1)
    Assert-True -Condition (@($sysinternalsTask).Count -eq 1) -Message 'Windows init catalog must include 108-install-sysinternals-suite.'
    Assert-True -Condition (@($autologonTask).Count -eq 1) -Message 'Windows init catalog must include 130-autologon-manager-user.'
    Assert-True -Condition ([int]$sysinternalsTask[0].TimeoutSeconds -eq 82) -Message 'Windows init catalog must keep 108-install-sysinternals-suite timeout at 82.'
    Assert-True -Condition ([int]$autologonTask[0].TimeoutSeconds -eq 20) -Message 'Windows init catalog must keep 130-autologon-manager-user timeout at 20.'
}

Invoke-Test -Name "Task script metadata controls local-only task discovery" -Action {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("az-vm-task-meta-test-" + [Guid]::NewGuid().ToString("N"))
    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    try {
        $scriptAlpha = Join-Path $tempRoot '101-alpha-task.ps1'
        $localDir = Join-Path $tempRoot 'local'
        $localDisabledDir = Join-Path $localDir 'disabled'
        New-Item -Path $localDisabledDir -ItemType Directory -Force | Out-Null
        $scriptBeta = Join-Path $localDir '1002-beta-task.ps1'
        $scriptDelta = Join-Path $localDir '101-delta-task.ps1'
        $scriptGamma = Join-Path $localDisabledDir '1004-gamma-task.ps1'

        Set-Content -Path $scriptAlpha -Encoding UTF8 -Value @'
# az-vm-task-meta: {"priority":777,"timeout":41,"enabled":true}
Write-Host "alpha"
'@
        Set-Content -Path $scriptBeta -Encoding UTF8 -Value @'
# az-vm-task-meta: {"priority":1002,"timeout":44,"enabled":true}
Write-Host "beta"
'@
        Set-Content -Path $scriptDelta -Encoding UTF8 -Value @'
# az-vm-task-meta: {"enabled":true}
Write-Host "delta"
'@
        Set-Content -Path $scriptGamma -Encoding UTF8 -Value @'
# az-vm-task-meta: {"priority":1004,"timeout":99,"enabled":false}
Write-Host "gamma"
'@

        $catalogJson = @'
{
  "defaults": {
    "priority": 1000,
    "timeout": 180
  },
  "tasks": [
    {
      "name": "101-alpha-task",
      "taskType": "normal",
      "priority": 101,
      "enabled": true,
      "timeout": 90
    }
  ]
}
'@
        Set-Content -Path (Join-Path $tempRoot 'vm-update-task-catalog.json') -Value $catalogJson -Encoding UTF8

        $catalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath $tempRoot -Platform windows -Stage update
        $active = @($catalog.ActiveTasks)
        $activeNames = @($active | ForEach-Object { [string]$_.Name })
        $disabled = @($catalog.DisabledTasks)

        Assert-True -Condition ($active.Count -eq 3) -Message 'Tracked root tasks and local-only tasks must both be discoverable.'
        Assert-True -Condition ($disabled.Count -eq 1) -Message 'Tasks under local/disabled must be discovered as disabled.'
        Assert-True -Condition ([string]$activeNames[0] -eq '101-alpha-task') -Message 'Catalog override must win over tracked script metadata priority.'
        Assert-True -Condition ([string]$activeNames[1] -eq '101-delta-task') -Message 'Local-only tasks without metadata priority or local-band filename must fall back to deterministic auto-detect ordering.'
        Assert-True -Condition ([string]$activeNames[2] -eq '1002-beta-task') -Message 'Script metadata priority must order local-only tasks discovered from local/ once auto-detected priorities are applied.'

        $alphaTask = $active | Where-Object { [string]$_.Name -eq '101-alpha-task' } | Select-Object -First 1
        $betaTask = $active | Where-Object { [string]$_.Name -eq '1002-beta-task' } | Select-Object -First 1
        $deltaTask = $active | Where-Object { [string]$_.Name -eq '101-delta-task' } | Select-Object -First 1

        Assert-True -Condition ([int]$alphaTask.TimeoutSeconds -eq 90) -Message 'Catalog timeout must override script metadata timeout.'
        Assert-True -Condition ([int]$betaTask.TimeoutSeconds -eq 44) -Message 'Script metadata timeout must drive local-only tasks.'
        Assert-True -Condition ([int]$deltaTask.TimeoutSeconds -eq 180) -Message 'Local-only tasks without metadata timeout must default to 180.'
        Assert-True -Condition ([int]$alphaTask.Priority -eq 101) -Message 'Tracked task priority must come from the catalog entry.'
        Assert-True -Condition ([int]$betaTask.Priority -eq 1002) -Message 'Script metadata priority must drive local-only tasks.'
        Assert-True -Condition ([int]$deltaTask.Priority -eq 1001) -Message 'Local-only tasks without metadata priority or numbered filename must auto-detect the next free local priority.'
        Assert-True -Condition ([string]$betaTask.RelativePath -eq 'local/1002-beta-task.ps1') -Message 'Local-only active task must preserve its relative path.'
        Assert-True -Condition ([string]$disabled[0].RelativePath -eq 'local/disabled/1004-gamma-task.ps1') -Message 'Local-only disabled task must preserve its relative path.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-Test -Name "Task discovery keeps initial then normal then local then final order" -Action {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("az-vm-task-order-test-" + [Guid]::NewGuid().ToString("N"))
    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    try {
        $localDir = Join-Path $tempRoot 'local'
        New-Item -Path $localDir -ItemType Directory -Force | Out-Null

        Set-Content -Path (Join-Path $tempRoot '01-alpha-init.ps1') -Encoding UTF8 -Value "Write-Host 'alpha'"
        Set-Content -Path (Join-Path $tempRoot '101-bravo-normal.ps1') -Encoding UTF8 -Value "Write-Host 'bravo'"
        Set-Content -Path (Join-Path $tempRoot '10001-delta-final.ps1') -Encoding UTF8 -Value "Write-Host 'delta'"
        Set-Content -Path (Join-Path $localDir '1002-charlie-local.ps1') -Encoding UTF8 -Value @'
# az-vm-task-meta: {"priority":1002,"timeout":44,"enabled":true}
Write-Host "charlie"
'@

        $catalogJson = @'
{
  "defaults": {
    "priority": 1000,
    "timeout": 180
  },
  "tasks": [
    {
      "name": "01-alpha-init",
      "taskType": "initial",
      "priority": 1,
      "enabled": true,
      "timeout": 30
    },
    {
      "name": "101-bravo-normal",
      "taskType": "normal",
      "priority": 101,
      "enabled": true,
      "timeout": 40
    },
    {
      "name": "10001-delta-final",
      "taskType": "final",
      "priority": 10001,
      "enabled": true,
      "timeout": 50
    }
  ]
}
'@
        Set-Content -Path (Join-Path $tempRoot 'vm-update-task-catalog.json') -Value $catalogJson -Encoding UTF8

        $catalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath $tempRoot -Platform windows -Stage update
        $activeNames = @(@($catalog.ActiveTasks) | ForEach-Object { [string]$_.Name })

        Assert-True -Condition ($activeNames.Count -eq 4) -Message 'Expected tracked initial, tracked normal, local, and tracked final tasks to all be discovered.'
        Assert-True -Condition ([string]$activeNames[0] -eq '01-alpha-init') -Message 'Initial tracked tasks must stay first.'
        Assert-True -Condition ([string]$activeNames[1] -eq '101-bravo-normal') -Message 'Normal tracked tasks must stay after initial tasks.'
        Assert-True -Condition ([string]$activeNames[2] -eq '1002-charlie-local') -Message 'Local untracked tasks must stay after normal tracked tasks.'
        Assert-True -Condition ([string]$activeNames[3] -eq '10001-delta-final') -Message 'Tracked final tasks must stay after local untracked tasks.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-Test -Name "Generic task metadata assets resolve into asset copies" -Action {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("az-vm-task-assets-test-" + [Guid]::NewGuid().ToString("N"))
    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    try {
        $localDir = Join-Path $tempRoot 'local'
        $assetDir = Join-Path $localDir 'example-assets'
        New-Item -Path $assetDir -ItemType Directory -Force | Out-Null
        $assetPath = Join-Path $assetDir 'profile.zip'
        Set-Content -Path $assetPath -Value 'payload' -Encoding UTF8

        $taskPath = Join-Path $localDir '1002-local-config-task.ps1'
        Set-Content -Path $taskPath -Encoding UTF8 -Value @'
# az-vm-task-meta: {"priority":1002,"timeout":7,"enabled":true,"assets":[{"local":"example-assets/profile.zip","remote":"C:/Windows/Temp/__VM_NAME__-profile.zip"}]}
Write-Host "__VM_ADMIN_USER__"
'@

        Set-Content -Path (Join-Path $tempRoot 'vm-update-task-catalog.json') -Encoding UTF8 -Value @'
{
  "defaults": {
    "priority": 1000,
    "timeout": 180
  },
  "tasks": []
}
'@

        $catalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath $tempRoot -Platform windows -Stage update
        $task = @($catalog.ActiveTasks)[0]
        $resolved = @(Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks @($task) -Context ([ordered]@{
            VmUser = 'manager'
            VmPass = 'secret'
            VmAssistantUser = 'assistant'
            VmAssistantPass = 'secret2'
            SshPort = '444'
            RdpPort = '3389'
            TcpPorts = @('444','3389','11434')
            ResourceGroup = 'rg-samplevm'
            VmName = 'samplevm'
            CompanyName = 'orgprofile'
            AzLocation = 'austriaeast'
            VmSize = 'Standard_B2as_v2'
            VmImage = 'example:image:urn'
            VmDiskName = 'disk-samplevm'
            VmDiskSize = '128'
            VmStorageSku = 'StandardSSD_LRS'
        }))[0]

        $assetCopies = @($resolved.AssetCopies)
        Assert-True -Condition ($assetCopies.Count -eq 1) -Message 'Generic metadata asset resolution must publish one asset copy.'
        Assert-True -Condition ([string]$assetCopies[0].RemotePath -eq 'C:/Windows/Temp/samplevm-profile.zip') -Message 'Generic metadata asset remote path mismatch.'
        Assert-True -Condition ([string]$assetCopies[0].LocalPath -eq (Resolve-Path -LiteralPath $assetPath).Path) -Message 'Generic metadata asset local path mismatch.'
        Assert-True -Condition ([string]$resolved.Script -like '*manager*') -Message 'Generic metadata task script must still apply token replacement.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-Test -Name "Duplicate task names across tracked and local-only tasks fail fast" -Action {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("az-vm-task-duplicate-test-" + [Guid]::NewGuid().ToString("N"))
    New-Item -Path $tempRoot -ItemType Directory -Force | Out-Null
    try {
        $localDir = Join-Path $tempRoot 'local'
        New-Item -Path $localDir -ItemType Directory -Force | Out-Null
        Set-Content -Path (Join-Path $tempRoot '101-alpha-task.ps1') -Encoding UTF8 -Value 'Write-Host "tracked"'
        Set-Content -Path (Join-Path $localDir '101-alpha-task.ps1') -Encoding UTF8 -Value @'
# az-vm-task-meta: {"priority":1001,"enabled":true,"timeout":180}
Write-Host "local"
'@
        Set-Content -Path (Join-Path $tempRoot 'vm-update-task-catalog.json') -Encoding UTF8 -Value '{"tasks":[]}'

        $threw = $false
        try {
            Get-AzVmTaskBlocksFromDirectory -DirectoryPath $tempRoot -Platform windows -Stage update | Out-Null
        }
        catch {
            $threw = $true
            Assert-True -Condition ([string]$_.Exception.Message -like '*duplicated between tracked and local-only scripts*') -Message 'Duplicate tracked/local task names must report a precise error.'
        }

        Assert-True -Condition $threw -Message 'Duplicate tracked/local task names must fail fast.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-Test -Name "Unsupported nested local script directories fail fast" -Action {
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("az-vm-task-nesting-test-" + [Guid]::NewGuid().ToString("N"))
    New-Item -Path (Join-Path $tempRoot 'local\subdir') -ItemType Directory -Force | Out-Null
    try {
        Set-Content -Path (Join-Path $tempRoot 'local\subdir\1001-bad-task.ps1') -Encoding UTF8 -Value 'Write-Host "bad"'
        Set-Content -Path (Join-Path $tempRoot 'vm-update-task-catalog.json') -Encoding UTF8 -Value '{"tasks":[]}'

        $threw = $false
        try {
            Get-AzVmTaskBlocksFromDirectory -DirectoryPath $tempRoot -Platform windows -Stage update | Out-Null
        }
        catch {
            $threw = $true
            Assert-True -Condition ([string]$_.Exception.Message -like '*Only root files, disabled/*, local/*, and local/disabled/* are allowed.*') -Message 'Unexpected nested local scripts must mention the supported task locations.'
        }

        Assert-True -Condition $threw -Message 'Unexpected nested local scripts must fail fast.'
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Invoke-Test -Name "Windows Ollama task verifies API readiness" -Action {
    $taskPath = Join-Path $RepoRoot 'windows\update\116-install-ollama-system.ps1'
    $taskScript = [string](Get-Content -LiteralPath $taskPath -Raw)
    Assert-True -Condition ($taskScript -like '*Ollama.Ollama*') -Message 'Ollama install task must use the Ollama.Ollama winget package id.'
    Assert-True -Condition ($taskScript -like '*127.0.0.1:11434*') -Message 'Ollama install task must check the default Ollama port.'
    Assert-True -Condition ($taskScript -like '*/api/version*') -Message 'Ollama install task must validate the Ollama HTTP API endpoint.'
    Assert-True -Condition ($taskScript -like '*ollama serve*') -Message 'Ollama install task must start ollama serve when the API is not already ready.'
    Assert-True -Condition ($taskScript -like '*Existing Ollama installation is already healthy. Skipping winget install.*') -Message 'Ollama install task must short-circuit when an existing installation is already healthy.'
    Assert-True -Condition ($taskScript -like '*RedirectStandardOutput*') -Message 'Ollama install task must detach ollama serve stdout from the SSH session.'
    Assert-True -Condition ($taskScript -like '*RedirectStandardError*') -Message 'Ollama install task must detach ollama serve stderr from the SSH session.'
    Assert-True -Condition ($taskScript -like '*Stopping stale installer processes before Ollama install*') -Message 'Ollama install task must clear stale installer locks instead of waiting indefinitely.'
    Assert-True -Condition ($taskScript -like '*Waiting for installer descendants to settle before Ollama readiness check*') -Message 'Ollama install task must wait briefly for post-winget installer descendants to settle.'
    Assert-True -Condition ($taskScript -like '*WaitForExit*') -Message 'Ollama install task must bound the winget install wait time.'
    Assert-True -Condition ($taskScript -like '*timed out after*') -Message 'Ollama install task must fail clearly when winget install exceeds the timeout.'
    Assert-True -Condition ($taskScript -like '*Retrying after*') -Message 'Ollama install task must retry bounded serve readiness when the first cold-start probe misses.'
    Assert-True -Condition ($taskScript -like '*detail=*') -Message 'Ollama install task must include serve failure detail when readiness still fails.'
}

Invoke-Test -Name "Windows VS Code task short-circuits healthy installs" -Action {
    $taskPath = Join-Path $RepoRoot 'windows\update\110-install-vscode-system.ps1'
    $taskScript = [string](Get-Content -LiteralPath $taskPath -Raw)
    Assert-True -Condition ($taskScript -like '*Existing Visual Studio Code installation is already healthy. Skipping winget install.*') -Message 'VS Code install task must skip winget when a healthy installation already exists.'
    Assert-True -Condition ($taskScript -like '*Resolve-CodeExecutable*') -Message 'VS Code install task must resolve the existing Code executable before reinstalling.'
}

Invoke-Test -Name "Windows Docker Desktop task clears stale installer locks" -Action {
    $taskPath = Join-Path $RepoRoot 'windows\update\114-install-docker-desktop.ps1'
    $taskScript = [string](Get-Content -LiteralPath $taskPath -Raw)
    Assert-True -Condition ($taskScript -like '*Stopping stale installer processes before Docker Desktop install*') -Message 'Docker Desktop task must clear stale installer locks before winget install.'
    Assert-True -Condition ($taskScript -like "*DockerDesktopPackageId = 'Docker.DockerDesktop'*") -Message 'Docker Desktop task must keep the Docker Desktop winget package id in its task-local config block.'
    Assert-True -Condition ($taskScript -match 'winget install \{0\}" -f \[string\]\$taskConfig\.DockerDesktopPackageId') -Message 'Docker Desktop task must label the install step as a winget Docker Desktop install.'
    Assert-True -Condition ($taskScript -match '-Arguments\s+@\(''install'',\s*''-e'',\s*''--id'',\s*\(\[string\]\$taskConfig\.DockerDesktopPackageId\)') -Message 'Docker Desktop task must install Docker Desktop through winget.'
    Assert-True -Condition ($taskScript -like '*Invoke-ProcessWithTimeout*') -Message 'Docker Desktop task must bound the winget install wait time.'
    Assert-True -Condition ($taskScript -like '*Active installer processes*') -Message 'Docker Desktop task must report active installer processes when install timing problems occur.'
    Assert-True -Condition ($taskScript -like '*docker-step-deferred: interactive-sign-in-registered*') -Message 'Docker Desktop task must explicitly defer engine readiness to interactive sign-in instead of retrying long noninteractive daemon probes.'
    Assert-True -Condition (-not ($taskScript -like '*Wait-DockerDaemonReady*')) -Message 'Docker Desktop task must not keep the old daemon probe retry loop.'
    Assert-True -Condition ($taskScript -like '*docker desktop status*') -Message 'Docker Desktop task must include a bounded docker desktop status probe.'
    Assert-True -Condition ($taskScript -like '*docker info*') -Message 'Docker Desktop task must include a bounded docker info probe.'
    Assert-True -Condition ($taskScript -like '*docker-step-warning: docker info is not healthy yet*') -Message 'Docker Desktop task must downgrade non-ready engine checks to a structured warning.'
    Assert-True -Condition ($taskScript -like '*$global:LASTEXITCODE = 0*') -Message 'Docker Desktop task must clear non-fatal native exit codes before completing.'
}

Invoke-Test -Name "Windows AnyDesk task verifies the executable after non-fatal winget exits" -Action {
    $taskPath = Join-Path $RepoRoot 'windows\update\122-install-anydesk-system.ps1'
    $taskScript = [string](Get-Content -LiteralPath $taskPath -Raw)
    Assert-True -Condition ($taskScript -like '*post-install verification will determine whether the package is usable*') -Message 'AnyDesk task must treat transient winget failures as verification-required, not immediate hard failure.'
    Assert-True -Condition ($taskScript -like '*install-anydesk-system-verified: executable*') -Message 'AnyDesk task must log executable-based verification after install.'
    Assert-True -Condition ($taskScript -like '*winget list anydesk.anydesk*') -Message 'AnyDesk task must keep a package-list fallback verification path.'
    Assert-True -Condition ($taskScript -like '*$global:LASTEXITCODE = 0*') -Message 'AnyDesk task must clear non-fatal native exit codes before completing.'
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
        ResourceGroup = "rg-samplevm"
        VmName = "samplevm"
        AzLocation = "austriaeast"
        VmSize = "Standard_B2as_v2"
        VmImage = "example:image:urn"
        VmDiskName = "disk-samplevm"
        VmDiskSize = "128"
        VmStorageSku = "StandardSSD_LRS"
    }

    $updateDir = Join-Path $RepoRoot 'windows\update'

    $uxTaskPath = Join-Path $updateDir '10003-configure-ux-windows.ps1'
    $uxTemplates = @(
        [pscustomobject]@{
            Name = '10003-configure-ux-windows'
            Script = [string](Get-Content -LiteralPath $uxTaskPath -Raw)
            RelativePath = '10003-configure-ux-windows.ps1'
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
    Assert-True -Condition ($uxScriptBody -like '*Disable-ComputerRestore*') -Message "UX task must disable System Restore."
    Assert-True -Condition ($uxScriptBody -like '*vssadmin.exe delete shadows*') -Message "UX task must delete existing shadow copies."
    Assert-True -Condition ($uxScriptBody -like '*DisableThumbsDBOnNetworkFolders*') -Message "UX task must suppress Thumbs.db creation on known Windows Explorer policy paths."
    Assert-True -Condition ($uxScriptBody -like '*DisableThumbnailCache*') -Message "UX task must suppress thumbnail cache generation."
    Assert-True -Condition ($uxScriptBody -like '*UserAuthentication*') -Message "UX task must disable RDP NLA."
    Assert-True -Condition ($uxScriptBody -like '*shell-icons-hidden*') -Message "UX task must hide shell-managed desktop icons."
    Assert-True -Condition ($uxScriptBody -like '*System Volume Information*') -Message "UX task must attempt best-effort System Volume Information cleanup."
    Assert-True -Condition ($uxScriptBody -like '*Convert-AzVmShellSortBytesToPropertyExpression*') -Message "UX task must normalize Windows shell sort binary values during validation."
    Assert-True -Condition ($uxScriptBody -like '*b725f130-47ef-101a-a5f1-02608c9eebac:10*') -Message "UX task must recognize the shell property key for System.ItemNameDisplay."
    Assert-True -Condition ($uxScriptBody -like '*Invoke-RegQuiet*') -Message "UX task must keep registry hive load and unload operations quiet under strict PowerShell native error handling."
    Assert-True -Condition (-not $resolvedUxTask.PSObject.Properties.Match('InteractiveResultPath').Count) -Message "UX task must not publish reboot-resume metadata."

    $copyUserSettingsTaskPath = Join-Path $updateDir '10005-copy-settings-user.ps1'
    $copyUserSettingsTemplates = @(
        [pscustomobject]@{
            Name = '10005-copy-settings-user'
            Script = [string](Get-Content -LiteralPath $copyUserSettingsTaskPath -Raw)
            RelativePath = '10005-copy-settings-user.ps1'
            DirectoryPath = $updateDir
            TimeoutSeconds = 1800
        }
    )

    $resolvedCopyUserSettingsTask = @(Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks $copyUserSettingsTemplates -Context $context)[0]
    $copyUserSettingsAssetCopies = @($resolvedCopyUserSettingsTask.AssetCopies)
    $copyUserSettingsBody = [string]$resolvedCopyUserSettingsTask.Script
    Assert-True -Condition ($copyUserSettingsAssetCopies.Count -eq 1) -Message "Copy user settings task must publish exactly one helper asset."
    Assert-True -Condition ([string]$copyUserSettingsAssetCopies[0].RemotePath -eq 'C:/Windows/Temp/az-vm-interactive-session-helper.ps1') -Message "Copy user settings helper remote path mismatch."
    Assert-True -Condition ($copyUserSettingsBody -like '*copy-settings-user-profile-materialized*') -Message "Copy user settings task must materialize the assistant profile."
    Assert-True -Condition ($copyUserSettingsBody -like '*SearchboxTaskbarMode*') -Message "Copy user settings task must propagate taskbar search visibility."
    Assert-True -Condition ($copyUserSettingsBody -like '*TaskManager\settings.json*') -Message "Copy user settings task must propagate Task Manager settings."
    Assert-True -Condition ($copyUserSettingsBody -like '*HKEY_USERS\.DEFAULT*') -Message "Copy user settings task must seed the logon-screen hive."
    Assert-True -Condition ($copyUserSettingsBody -like '*Desktop*') -Message "Copy user settings task must explicitly copy required profile roots such as Desktop."
    Assert-True -Condition ($copyUserSettingsBody -like '*Documents*') -Message "Copy user settings task must explicitly copy required profile roots such as Documents."
    Assert-True -Condition ($copyUserSettingsBody -like '*Downloads*') -Message "Copy user settings task must explicitly copy required profile roots such as Downloads."
    Assert-True -Condition ($copyUserSettingsBody -like '*Links*') -Message "Copy user settings task must explicitly copy required profile roots such as Links."
    Assert-True -Condition ($copyUserSettingsBody -like '*desktop.ini*') -Message "Copy user settings task must exclude desktop.ini from file copies."
    Assert-True -Condition ($copyUserSettingsBody -like '*Thumbs.db*') -Message "Copy user settings task must exclude Thumbs.db from file copies."
    Assert-True -Condition ($copyUserSettingsBody -like '*Microsoft\Windows\WebCacheLock.dat*') -Message "Copy user settings task must exclude the locked WebCacheLock.dat path from local profile copies."
    Assert-True -Condition ($copyUserSettingsBody -like '*Assert-RequiredRelativePathCopied*') -Message "Copy user settings task must validate that required profile roots were copied."
    Assert-True -Condition (($copyUserSettingsBody.IndexOf('AppData\LocalLow', [System.StringComparison]::Ordinal)) -lt 0) -Message "Copy user settings task must not spend time copying LocalLow."
    Assert-True -Condition (($copyUserSettingsBody.IndexOf('Application Data', [System.StringComparison]::Ordinal)) -lt 0) -Message "Copy user settings task must not keep the old root blocker scan."
    Assert-True -Condition (($copyUserSettingsBody.IndexOf('root reparse-point', [System.StringComparison]::Ordinal)) -lt 0) -Message "Copy user settings task must not keep the old broad root reparse scan."
    Assert-True -Condition ($copyUserSettingsBody -like '*HideDesktopIcons*') -Message "Copy user settings task must propagate hidden shell desktop icon state."
    Assert-True -Condition ($copyUserSettingsBody -like '*ollama app.exe\EBWebView\Default\Network*') -Message "Copy user settings task must exclude Ollama WebView network state from roaming copies."
    Assert-True -Condition ($copyUserSettingsBody -like '*ollama app.exe\EBWebView\Default\Safe Browsing Network*') -Message "Copy user settings task must exclude Ollama WebView safe-browsing cookie state from roaming copies."
    Assert-True -Condition ($copyUserSettingsBody -like '*ollama app.exe\EBWebView\Default\Cache*') -Message "Copy user settings task must exclude Ollama WebView cache directories from roaming copies."
    Assert-True -Condition ($copyUserSettingsBody -like '*Remove-StaleExcludedTargetPaths*') -Message "Copy user settings task must prune stale excluded target content on reruns."
    Assert-True -Condition ($copyUserSettingsBody -like '*copy-settings-user-target-prune:*') -Message "Copy user settings task must log stale excluded target pruning on reruns."
    Assert-True -Condition ($copyUserSettingsBody -like '*Invoke-RegQuiet*') -Message "Copy user settings task must run registry hive load and unload operations through the quiet helper."
    Assert-True -Condition ($copyUserSettingsBody -like '*with exit code*') -Message "Copy user settings task must include the unload exit code in terminal hive cleanup failures."
    Assert-True -Condition ($copyUserSettingsBody -like '*Wait-UserSessionsAndProcessesToSettle*') -Message "Copy user settings task must use a bounded settle helper instead of a fixed post-logoff sleep."
    Assert-True -Condition (($copyUserSettingsBody.IndexOf('Start-Sleep -Seconds 5', [System.StringComparison]::Ordinal)) -lt 0) -Message "Copy user settings task must not keep the old fixed five-second post-logoff sleep."
    Assert-True -Condition (-not $resolvedCopyUserSettingsTask.PSObject.Properties.Match('InteractiveResultPath').Count) -Message "Copy user settings task must not publish reboot-resume metadata."

    $advancedTaskPath = Join-Path $updateDir '10004-configure-settings-advanced-system.ps1'
    $advancedTemplates = @(
        [pscustomobject]@{
            Name = '10004-configure-settings-advanced-system'
            Script = [string](Get-Content -LiteralPath $advancedTaskPath -Raw)
            RelativePath = '10004-configure-settings-advanced-system.ps1'
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
    $shortcutTaskPath = Join-Path $RepoRoot 'windows\update\10002-create-shortcuts-public-desktop.ps1'
    $shortcutTaskScript = [string](Get-Content -LiteralPath $shortcutTaskPath -Raw)
    $healthTaskPath = Join-Path $RepoRoot 'windows\update\10099-capture-snapshot-health.ps1'
    $healthTaskScript = [string](Get-Content -LiteralPath $healthTaskPath -Raw)

    $expectedShortcutNames = @(
        'a1ChatGPT Web',
        'a2CodexApp',
        'a3Be My Eyes',
        'a4WhatsApp Business',
        'a5WhatsApp Personal',
        'a6AnyDesk',
        'a7Docker Desktop',
        'a8WindScribe',
        'a9VLC Player',
        'a10NVDA',
        'a11MS Edge',
        'a12Itunes',
        'b1GarantiBank Business',
        'b2GarantiBank Personal',
        'b3QnbBank Business',
        'b4QnbBank Personal',
        'b5AktifBank Business',
        'b6AktifBank Personal',
        'b7ZiraatBank Business',
        'b8ZiraatBank Personal',
        'c1Cmd',
        'd1RClone CLI',
        'd2One Drive',
        'd3Google Drive',
        'd4ICloud',
        'e1Mail {0}',
        'g1Apple Developer',
        'g2Google Developer',
        'g3Microsoft Developer',
        'g4Azure Portal',
        'i1Internet Business',
        'i2Internet Personal',
        'k1Codex CLI',
        'k2Gemini CLI',
        'k3Github Copilot CLI',
        'm1Digital Tax Office',
        'n1Notepad',
        'o1Outlook',
        'o2Teams',
        'o3Word',
        'o4Excel',
        'o5Power Point',
        'o6OneNote',
        'q1SourTimes',
        'q2Spotify',
        'q3Netflix',
        'q4eGovernment',
        'q5Apple Account',
        'q6AJet Flights',
        'q7TCDD Train',
        'q8OBilet Bus',
        'r1Sahibinden Business',
        'r2Sahibinden Personal',
        'r3Letgo Business',
        'r4Letgo Personal',
        'r5Trendyol Business',
        'r6Trendyol Personal',
        'r7Amazon TR Business',
        'r8Amazon TR Personal',
        'r9HepsiBurada Business',
        'r10HepsiBurada Personal',
        'r11N11 Business',
        'r12N11 Personal',
        'r13ÇiçekSepeti Business',
        'r14ÇiçekSepeti Personal',
        'r15Pazarama Business',
        'r16Pazarama Personal',
        'r17PTTAVM Business',
        'r18PTTAVM Personal',
        'r19Ozon Business',
        'r20Ozon Personal',
        'r21Getir Business',
        'r22Getir Personal',
        's1LinkedIn Business',
        's2LinkedIn Personal',
        's3YouTube Business',
        's4YouTube Personal',
        's5GitHub Business',
        's6GitHub Personal',
        's7TikTok Business',
        's8TikTok Personal',
        's9Instagram Business',
        's10Instagram Personal',
        's11Facebook Business',
        's12Facebook Personal',
        's13X-Twitter Business',
        's14X-Twitter Personal',
        's15{0} Web',
        's16{0} Blog',
        's17SnapChat Business',
        's18NextSosyal Business',
        't1Git Bash',
        't2Python CLI',
        't3NodeJS CLI',
        't4Ollama App',
        't5Pwsh',
        't6PS',
        't7Azure CLI',
        't8WSL',
        't9Docker CLI',
        't10Azd CLI',
        't11GH CLI',
        't12FFmpeg CLI',
        't13Seven Zip CLI',
        't14Process Explorer',
        't15Io Unlocker',
        'u1User Files',
        'u2This PC',
        'u3Control Panel',
        'u7Network and Sharing',
        'v1VS2022Com',
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
        't3OllamaApp',
        't6azure-cli',
        't12SevenZip-cli',
        't15codex-cli',
        't16gemini-cli',
        'a4WhatsApp Kurumsal',
        'a5WhatsApp Bireysel',
        'b1GarantiBank Kurumsal',
        'b2GarantiBank Bireysel',
        'b3QnbBank Kurumsal',
        'b4QnbBank Bireysel',
        'b5AktifBank Kurumsal',
        'b6AktifBank Bireysel',
        'b7ZiraatBank Kurumsal',
        'b8ZiraatBank Bireysel',
        'i1Internet Kurumsal',
        'i2Internet Bireysel',
        'm1Dijital Vergi Dairesi',
        'q4EDevlet',
        'q6AJet Uçak',
        'q7TCDD Tren',
        'q8OBilet Otobüs',
        'r13Çiçek Sepeti Kurumsal',
        'r14Çiçek Sepeti Bireysel',
        'r17PTT AVM Kurumsal',
        'r18PTT AVM Bireysel',
        's18Next Sosyal'
    )
    $expectedFragments = @(
        'company_name is required for the Windows business public desktop shortcut flow',
        'employee_email_address is required for the Windows public desktop shortcut flow',
        'employee_full_name is required for the Windows public desktop shortcut flow',
        'Get-EmployeeEmailBaseName',
        'ConvertTo-LowerInvariantText',
        'ConvertTo-TitleCaseShortcutText',
        '$companyChromeProfileDirectory = ConvertTo-LowerInvariantText -Value $companyName',
        '$employeeEmailBaseName = ConvertTo-LowerInvariantText -Value $employeeEmailBaseName',
        'Get-ChromeArgsPrefix',
        'Get-ChromeProfileDirectoryForShortcut -ProfileKind $ProfileKind',
        'New-ChromeShortcutSpec',
        'Get-NormalizedShortcutNameKey',
        'Get-ShortcutUrlFromArguments',
        'Test-ShortcutDetailsMatchManagedSpec',
        'https://chatgpt.com',
        'https://www.google.com',
        'https://www.exampleorg.com',
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
        'https://www.exampleorg.com/blog',
        'https://sube.garantibbva.com.tr/isube/login/login/passwordentrycorporate-tr',
        'https://sube.garantibbva.com.tr/isube/login/login/passwordentrypersonal-tr',
        'https://internetsubesi.qnb.com.tr/Login/LoginPage.aspx?FromDK=true',
        'https://internetsubesi.qnb.com.tr/Login/LoginPage.aspx',
        'https://kurumsal.aktifbank.com.tr/default.aspx?lang=tr-TR',
        'https://online.aktifbank.com.tr/default.aspx?lang=tr-TR',
        'https://kurumsal.ziraatbank.com.tr/Transactions/Login/FirstLogin.aspx?customertype=crp',
        'https://bireysel.ziraatbank.com.tr/Transactions/Login/FirstLogin.aspx',
        'https://www.snapchat.com/@exampleorg',
        'https://sosyal.teknofest.app/@exampleorg',
        'https://dijital.gib.gov.tr/portal/login',
        'https://www.eksisozluk.com',
        'https://secure.sahibinden.com/giris',
        'https://www.sahibinden.com',
        'https://www.letgo.com',
        'https://partner.trendyol.com',
        'https://www.trendyol.com/uyelik',
        'https://sellercentral.amazon.com.tr',
        'https://www.amazon.com.tr/ap/signin',
        'https://merchant.hepsiburada.com',
        'https://giris.hepsiburada.com',
        'https://so.n11.com',
        'https://www.n11.com/giris-yap',
        'https://seller.ciceksepeti.com/giris',
        'https://www.ciceksepeti.com/uye-girisi',
        'https://isortagim.pazarama.com',
        'https://account.pazarama.com/giris',
        'https://merchant.pttavm.com/magaza-giris',
        'https://www.pttavm.com',
        'https://seller.ozon.ru/app/registration/signin?locale=en',
        'https://www-ozon-ru.translate.goog/?_x_tr_sl=ru&_x_tr_tl=en&_x_tr_hl=en&_x_tr_hist=true',
        'https://panel.getircarsi.com/login',
        'https://getir.com',
        'Resolve-AppPackageExecutablePath',
        'Resolve-StoreAppId',
        'ms-windows-store://pdp/?ProductId=9MSW46LTDWGF',
        'Resolve-EmbeddedShortcutCommandPath',
        'public-shortcut-skip:',
        'shell:AppsFolder\',
        'OpenAI.Codex',
        'WhatsApp.Root.exe',
        'Resolve-AppPackageExecutablePath -NameFragment "whatsapp"',
        '5319275A.WhatsAppDesktop',
        'iCloudHome.exe',
        '/c start outlook.exe /select "outlook:\\{0}\\Inbox"',
        'https://developer.apple.com/account',
        'https://play.google.com/console/signin',
        'https://aka.ms/submitwindowsapp',
        'https://portal.azure.com',
        'C:\Windows\System32\notepad.exe',
        'https://accounts.spotify.com/en/login?continue=https%3A%2F%2Fopen.spotify.com',
        'https://www.netflix.com/tr-en/login',
        'https://www.turkiye.gov.tr',
        'https://account.apple.com/sign-in',
        'https://ajet.com',
        'https://ebilet.tcddtasimacilik.gov.tr',
        'https://www.obilet.com/?giris',
        'TaskKill -im "ollama app.exe"',
        '/k cd /d %UserProfile% & docker',
        '%UserProfile%\AppData\Roaming\npm\copilot.cmd --screen-reader --yolo --no-ask-user --model claude-haiku-4.5',
        'C:\ProgramData\chocolatey\bin\7z.exe',
        '--enable multi_agent --yolo -s danger-full-access --cd "%UserProfile%" --search',
        '--screen-reader --yolo',
        'C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\devenv.exe',
        'Set-ShortcutRunAsAdministratorFlag',
        'Get-ShortcutRunAsAdministratorFlag',
        'WindowStyle',
        'RunAsAdmin = [bool]$RunAsAdmin',
        'ShowCmd = [int]$ShowCmd',
        'Name "z1Google Account Setup" -TargetPath $cmdExe',
        '/c start "" "{0}" --new-window --start-maximized --user-data-dir="{1}" --profile-directory={2} "chrome://settings/syncSetup"',
        'Resolve-CommandPath -CommandName "control.exe"',
        'Microsoft.NetworkAndSharingCenter',
        'function Clear-DesktopEntries',
        'user-desktop-entry-removed:',
        '("C:\Users\{0}\Desktop" -f $managerUser)',
        '("C:\Users\{0}\Desktop" -f $assistantUser)',
        '"C:\Users\Default\Desktop"',
        '%UserProfile%',
        '$publicChromeUserDataDir = "C:\Users\Public\AppData\Local\Google\Chrome\UserData"',
        '--user-data-dir="{0}"',
        '--profile-directory="{1}"',
        'return [string]$employeeEmailBaseName',
        'return [string]$companyChromeProfileDirectory',
        'public-desktop-inspect-skip:',
        'public-desktop-removed: {0} => managed-by {1}',
        'CleanupAliases = @(',
        'CleanupMatchTargetOnly = [bool]$CleanupMatchTargetOnly',
        'CleanupAliasMatchByNameOnly = [bool]$CleanupAliasMatchByNameOnly'
    )

    foreach ($shortcutName in @($expectedShortcutNames)) {
        Assert-True -Condition (($shortcutTaskScript.IndexOf([string]$shortcutName, [System.StringComparison]::Ordinal)) -ge 0) -Message ("Shortcut task must create '{0}'." -f $shortcutName)
        Assert-True -Condition (($healthTaskScript.IndexOf([string]$shortcutName, [System.StringComparison]::Ordinal)) -ge 0) -Message ("Health snapshot must inventory '{0}'." -f $shortcutName)
    }

    foreach ($legacyShortcutName in @($legacyShortcutNames)) {
        Assert-True -Condition (($shortcutTaskScript.IndexOf([string]$legacyShortcutName, [System.StringComparison]::Ordinal)) -lt 0) -Message ("Shortcut task must not keep legacy shortcut name '{0}'." -f $legacyShortcutName)
        Assert-True -Condition (($healthTaskScript.IndexOf([string]$legacyShortcutName, [System.StringComparison]::Ordinal)) -lt 0) -Message ("Health snapshot must not keep legacy shortcut name '{0}'." -f $legacyShortcutName)
    }

    Assert-True -Condition (($shortcutTaskScript.IndexOf('-Name "i1Internet"', [System.StringComparison]::Ordinal)) -lt 0) -Message 'Shortcut task must not keep the old i1Internet shortcut label.'
    Assert-True -Condition (($shortcutTaskScript.IndexOf('t10AZD CLI', [System.StringComparison]::Ordinal)) -lt 0) -Message 'Shortcut task must not keep the old t10AZD CLI shortcut label.'
    Assert-True -Condition (($healthTaskScript.IndexOf('t10AZD CLI', [System.StringComparison]::Ordinal)) -lt 0) -Message 'Health snapshot must not keep the old t10AZD CLI shortcut label.'
    Assert-True -Condition (($shortcutTaskScript.IndexOf('Test-PersonalChromeShortcutName', [System.StringComparison]::Ordinal)) -lt 0) -Message 'Shortcut task must not route personal Chrome profiles by the old label-text helper.'

    foreach ($fragment in @($expectedFragments)) {
        Assert-True -Condition (($shortcutTaskScript.IndexOf([string]$fragment, [System.StringComparison]::Ordinal)) -ge 0) -Message ("Shortcut task must include fragment '{0}'." -f $fragment)
    }
    Assert-True -Condition ($shortcutTaskScript -like '*RunAsAdmin*') -Message 'Shortcut task must model RunAsAdmin in the manifest.'
    Assert-True -Condition ($shortcutTaskScript -like '*ShowCmd*') -Message 'Shortcut task must model ShowCmd in the manifest.'
    Assert-True -Condition ($healthTaskScript -like '*hotkey =>*') -Message 'Health snapshot must read back shortcut hotkeys.'
    Assert-True -Condition ($healthTaskScript -like '*start-in =>*') -Message 'Health snapshot must read back shortcut working directories.'
    Assert-True -Condition ($healthTaskScript -like '*show =>*') -Message 'Health snapshot must read back shortcut show commands.'
    Assert-True -Condition ($healthTaskScript -like '*run-as-admin =>*') -Message 'Health snapshot must read back shortcut admin flags.'
    Assert-True -Condition ($healthTaskScript -like '*unmanaged-public-shortcut-count=*') -Message 'Health snapshot must inventory unmanaged Public Desktop shortcuts.'
    Assert-True -Condition (($healthTaskScript.IndexOf("Write-ShortcutReadback -Label 'unmanaged-public-shortcut'", [System.StringComparison]::Ordinal)) -ge 0) -Message 'Health snapshot must read back unmanaged Public Desktop shortcut details.'
    Assert-True -Condition (($shortcutTaskScript.IndexOf('Where-Object { $managedShortcutNames -contains [System.IO.Path]::GetFileNameWithoutExtension([string]$_.Name) }', [System.StringComparison]::Ordinal)) -lt 0) -Message 'Shortcut task must not keep the old exact-name-only Public Desktop cleanup logic.'
    Assert-True -Condition (($shortcutTaskScript.IndexOf('function Find-ManagedShortcutSpecByName', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Shortcut task must provide a direct-name shortcut spec matcher for Public Desktop cleanup.'
    Assert-True -Condition (($shortcutTaskScript.IndexOf('function Find-ManagedShortcutSpecByDetails', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Shortcut task must provide a semantic shortcut spec matcher for Public Desktop cleanup.'
    Assert-True -Condition (($shortcutTaskScript.IndexOf('function Test-PublicDesktopAlreadyNormalized', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Shortcut task must provide a no-op fast path when the Public Desktop is already normalized.'
    Assert-True -Condition (($shortcutTaskScript.IndexOf('public-desktop-normalized: no changes required', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Shortcut task must log the no-op normalized path explicitly.'
    Assert-True -Condition (($shortcutTaskScript.IndexOf('Find-ManagedShortcutSpecByDetails -Specs $shortcutSpecs -Details $existingDetails -ShortcutBaseName $shortcutBaseName', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Shortcut task must use semantic duplicate matching for Public Desktop cleanup.'
    Assert-True -Condition (-not ($shortcutTaskScript -match 'public-desktop-inspect-skip:[\s\S]{0,120}\breturn\b')) -Message 'Shortcut task must not exit early after an unmanaged shortcut inspection warning.'
    Assert-True -Condition (-not ($shortcutTaskScript -match 'if\s*\(\$null\s*-eq\s*\$matchedSpec\)\s*\{\s*return\b')) -Message 'Shortcut task must continue past unrelated Public Desktop shortcuts instead of returning from the script.'
    Assert-True -Condition (($shortcutTaskScript.IndexOf('@("Google Chrome", "Chrome")', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Shortcut task must carry explicit Chrome duplicate aliases.'
    Assert-True -Condition (($shortcutTaskScript.IndexOf('@("Microsoft Edge")', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Shortcut task must carry explicit Edge duplicate aliases.'
    Assert-True -Condition (($shortcutTaskScript.IndexOf('@("Visual Studio 2022")', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Shortcut task must carry explicit Visual Studio duplicate aliases.'
    Assert-True -Condition (($shortcutTaskScript.IndexOf('@("AnyDesk")', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Shortcut task must carry explicit AnyDesk duplicate aliases.'
    Assert-True -Condition (($shortcutTaskScript.IndexOf('@("IObit Unlocker")', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Shortcut task must carry an explicit IObit Unlocker duplicate alias.'
    Assert-True -Condition (($shortcutTaskScript.IndexOf('@("NVDA")', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Shortcut task must carry an explicit NVDA duplicate alias.'
    Assert-True -Condition (($shortcutTaskScript.IndexOf('CleanupAliasMatchByNameOnly $true', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Shortcut task must support explicit alias-only cleanup for installer shortcuts that wrap the managed app target.'
    Assert-True -Condition (($shortcutTaskScript.IndexOf('unexpected-public-shortcut', [System.StringComparison]::Ordinal)) -lt 0) -Message 'Shortcut task must not keep unexpected Public Desktop cleanup logic.'
    Assert-True -Condition (($healthTaskScript.IndexOf("Write-DesktopState -Label 'assistant'", [System.StringComparison]::Ordinal)) -ge 0) -Message 'Health snapshot must report assistant desktop state.'
    Assert-True -Condition (($healthTaskScript.IndexOf('Write-DesktopArtifactScan', [System.StringComparison]::Ordinal)) -ge 0) -Message 'Health snapshot must scan desktop.ini and Thumbs.db artifacts.'
}

Invoke-Test -Name "Windows app install task contracts cover new shortcut-backed packages" -Action {
    $installTaskMap = [ordered]@{
        '115-install-npm-packages-global.ps1' = @('@github/copilot@latest', '@openai/codex@latest', '@google/gemini-cli@latest')
        '125-install-itunes-system.ps1' = @('Apple.iTunes', 'iTunes.exe')
        '126-install-be-my-eyes.ps1' = @('9MSW46LTDWGF', '--source msstore', 'Invoke-AzVmInteractiveDesktopAutomation', 'Get-AzVmInteractivePaths', 'RunAsMode ''interactiveToken''', 'install-be-my-eyes-deferred', 'AzVmInstallBeMyEyes')
        '127-install-nvda-system.ps1' = @('NVAccess.NVDA', 'nvd' )
        '111-install-edge-browser.ps1' = @('Microsoft.Edge', 'msedge.exe')
        '124-install-vlc-system.ps1' = @('VideoLAN.VLC', 'vlc.exe')
        '128-install-rclone-system.ps1' = @('Rclone.Rclone', 'rclone.exe')
        '131-install-icloud-system.ps1' = @('9PKTQ5699M62', "PackageSource = 'msstore'", 'iCloudHome.exe', 'Get-StartApps', 'Invoke-AzVmInteractiveDesktopAutomation', 'RunAsMode ''interactiveToken''', 'install-icloud-system-deferred', 'AzVmInstallICloud')
        '132-install-vs2022community.ps1' = @('visualstudio2022community', 'choco install', 'devenv.exe', 'install-vs2022community-completed')
        '119-install-onedrive-system.ps1' = @('Microsoft.OneDrive', 'OneDrive.exe')
        '120-install-google-drive.ps1' = @('Google.GoogleDrive', 'GoogleDriveFS.exe')
        '117-install-codex-app.ps1' = @('winget install codex -s msstore', 'OpenAI.Codex', 'Codex.exe')
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

Invoke-Test -Name "Windows autologon manager task and health contract" -Action {
    $taskPath = Join-Path $RepoRoot 'windows\init\130-autologon-manager-user.ps1'
    $healthTaskPath = Join-Path $RepoRoot 'windows\update\10099-capture-snapshot-health.ps1'

    Assert-True -Condition (Test-Path -LiteralPath $taskPath) -Message 'Autologon manager task file was not found.'
    $taskText = [string](Get-Content -LiteralPath $taskPath -Raw)
    $healthTaskText = [string](Get-Content -LiteralPath $healthTaskPath -Raw)

    foreach ($fragment in @(
        '__VM_ADMIN_USER__',
        '__VM_ADMIN_PASS__',
        '/accepteula',
        'LogonUser',
        'AutoAdminLogon',
        'DefaultUserName',
        'DefaultDomainName',
        'DefaultPasswordPresent',
        'autologon-state =>',
        'Autologon note: DefaultPassword is not present in Winlogon.',
        'autologon-manager-user-completed',
        'autologon.exe was not found',
        'Ensure 108-install-sysinternals-suite completed successfully.'
    )) {
        Assert-True -Condition ($taskText -like ('*' + [string]$fragment + '*')) -Message ("Autologon manager task must include fragment '{0}'." -f [string]$fragment)
    }

    foreach ($fragment in @(
        'AUTOLOGON STATUS:',
        'manager_autologon_configured',
        'DefaultDomainName',
        'CredentialStorageMode',
        'sysinternals-autologon-or-external-store'
    )) {
        Assert-True -Condition ($healthTaskText -like ('*' + [string]$fragment + '*')) -Message ("Health snapshot must include autologon fragment '{0}'." -f [string]$fragment)
    }
}

Invoke-Test -Name "Windows auto-start task mirrors the host startup profile by method" -Action {
    $taskPath = Join-Path $RepoRoot 'windows\update\10001-configure-apps-startup.ps1'
    Assert-True -Condition (Test-Path -LiteralPath $taskPath) -Message "Expected auto-start task file was not found."
    $taskText = [string](Get-Content -LiteralPath $taskPath -Raw)
    $healthTaskPath = Join-Path $RepoRoot 'windows\update\10099-capture-snapshot-health.ps1'
    $healthTaskText = [string](Get-Content -LiteralPath $healthTaskPath -Raw)

    foreach ($fragment in @(
        '__HOST_STARTUP_PROFILE_JSON_B64__',
        'host-startup-profile =>',
        'Get-ManagerContext',
        'Get-StartupLocationDefinitions',
        'Resolve-RequestedStartupLocation',
        'Clear-OwnedStartupArtifacts',
        'autostart-cleared:',
        'autostart-method =>',
        'Register-ScheduledTask',
        'ScheduledTask/AtLogOn',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run32',
        'C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp',
        'docker-desktop',
        'ollama',
        'onedrive',
        'teams',
        'itunes-helper',
        'google-drive',
        'windscribe',
        'anydesk',
        'codex-app',
        'Docker Desktop',
        'Ollama',
        'OneDrive',
        'Teams',
        'iTunesHelper',
        'Google Drive',
        'Windscribe',
        'AnyDesk',
        'Codex App',
        'msteams:system-initiated',
        '%LOCALAPPDATA%\Programs\Ollama\ollama app.exe',
        'configure-apps-startup-completed'
    )) {
        Assert-True -Condition ($taskText -like ('*' + $fragment + '*')) -Message ("Auto-start task must include fragment '{0}'." -f $fragment)
    }
    Assert-True -Condition (($taskText.IndexOf('static-startup-snapshot =>', [System.StringComparison]::Ordinal)) -lt 0) -Message "Auto-start task must not keep the static startup snapshot contract."

    foreach ($fragment in @(
        'AUTO-START APP STATUS:',
        '__HOST_STARTUP_PROFILE_JSON_B64__',
        'host-startup-profile =>',
        'startup-entry =>',
        'missing-startup-entry =>',
        'unsupported-startup-key =>',
        'Docker Desktop',
        'Ollama',
        'OneDrive',
        'Teams',
        'iTunesHelper'
    )) {
        Assert-True -Condition ($healthTaskText -like ('*' + $fragment + '*')) -Message ("Health snapshot must include startup fragment '{0}'." -f $fragment)
    }
    Assert-True -Condition (($healthTaskText.IndexOf('Get-ManagerContext', [System.StringComparison]::Ordinal)) -ge 0) -Message "Health snapshot must read manager-scope startup locations through the manager hive."
}

Invoke-Test -Name "Windows install tasks short-circuit healthy installs and avoid forceful package reinstalls" -Action {
    $expectedHealthySkipFragments = [ordered]@{
        '01-bootstrap-winget-system.ps1' = @('Existing winget installation is already healthy. Skipping choco install.', 'Skipping forceful source reset and attempting one bounded source update.')
        '02-check-install-chrome.ps1' = @('Google Chrome executable already exists:', 'choco install googlechrome')
        '101-install-powershell-core.ps1' = @('Existing PowerShell 7 installation is already healthy. Skipping choco install.')
        '102-install-git-system.ps1' = @('Existing Git installation is already healthy. Skipping choco install.', 'choco install git')
        '103-install-python-system.ps1' = @('Existing Python installation is already healthy. Skipping choco install.', 'choco install python312')
        '104-install-node-system.ps1' = @('Existing Node.js installation is already healthy. Skipping choco install.', 'choco install nodejs-lts')
        '105-install-azure-cli.ps1' = @('Existing Azure CLI installation is already healthy:', 'choco install azure-cli')
        '106-install-gh-cli.ps1' = @('Existing GitHub CLI installation is already healthy. Skipping choco install.')
        '107-install-7zip-system.ps1' = @('Existing 7-Zip installation is already healthy. Skipping choco install.')
        '108-install-sysinternals-suite.ps1' = @('Existing Sysinternals installation is already healthy:', 'choco install sysinternals')
        '109-install-ffmpeg-system.ps1' = @('Existing FFmpeg installation is already healthy. Skipping choco install.')
        '112-install-azd-cli.ps1' = @('Existing azd installation is already healthy. Skipping winget install.')
        '118-install-teams-system.ps1' = @('Existing Microsoft Teams installation is already healthy. Skipping winget install.')
        '122-install-anydesk-system.ps1' = @('Existing AnyDesk installation is already healthy', 'function Test-AnyDeskInstalled')
        '123-install-windscribe-system.ps1' = @('Existing Windscribe installation is already healthy. Skipping winget install.', 'function Test-WindscribeInstalled')
        '129-configure-unlocker-io.ps1' = @('Existing Io Unlocker installation is already healthy. Skipping choco install.')
    }

    foreach ($entry in $expectedHealthySkipFragments.GetEnumerator()) {
        $taskRelativePath = if ([string]$entry.Key -eq '108-install-sysinternals-suite.ps1') {
            ('windows\init\' + [string]$entry.Key)
        }
        else {
            ('windows\update\' + [string]$entry.Key)
        }
        $taskPath = Join-Path $RepoRoot $taskRelativePath
        $taskText = [string](Get-Content -LiteralPath $taskPath -Raw)
        foreach ($fragment in @($entry.Value)) {
            Assert-True -Condition ($taskText -like ('*' + [string]$fragment + '*')) -Message ("Task '{0}' must include fragment '{1}'." -f [string]$entry.Key, [string]$fragment)
        }
    }

    foreach ($taskPath in @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'windows\update') -Filter '*.ps1' -File -ErrorAction Stop)) {
        $taskText = [string](Get-Content -LiteralPath $taskPath.FullName -Raw)
        Assert-True -Condition (-not ($taskText -match 'winget\s+install[^\r\n]{0,240}--force')) -Message ("Task '{0}' must not pass --force to winget install." -f $taskPath.Name)
        Assert-True -Condition (-not ($taskText -match 'choco\s+upgrade\s+\S+')) -Message ("Task '{0}' must not use choco upgrade for package install semantics." -f $taskPath.Name)
        Assert-True -Condition (($taskText.IndexOf('--force', [System.StringComparison]::Ordinal)) -lt 0) -Message ("Task '{0}' must not pass any --force flag in vm-update." -f $taskPath.Name)
    }
}

Invoke-Test -Name "Tracked tree omits local-only accessibility vendor residue" -Action {
    $trackedRelativePaths = @()
    $gitCommand = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCommand) {
        $trackedRelativePaths = @(
            & $gitCommand.Source -C $RepoRoot ls-files --cached --others --exclude-standard
        )
    }

    $repoFiles = @()
    foreach ($relativePath in @($trackedRelativePaths)) {
        $relativeText = [string]$relativePath
        if ([string]::IsNullOrWhiteSpace([string]$relativeText)) {
            continue
        }
        if ($relativeText.StartsWith('.git/', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ($relativeText.StartsWith('windows/update/local/', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ($relativeText.StartsWith('windows/init/local/', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $absolutePath = Join-Path $RepoRoot $relativeText
        if (Test-Path -LiteralPath $absolutePath -PathType Leaf) {
            $repoFiles += [string]$absolutePath
        }
    }

    $legacyNeedles = @(
        ('ja' + 'ws'),
        ('j0' + 'ja' + 'ws'),
        ('jfw' + '.exe'),
        ('Freedom' + ' Scientific'),
        ('ja' + 'ws2025files')
    )

    foreach ($needle in @($legacyNeedles)) {
        $matchingFiles = New-Object 'System.Collections.Generic.List[string]'
        foreach ($file in @($repoFiles)) {
            $fileText = ''
            try {
                $fileText = [string](Get-Content -LiteralPath $file -Raw -ErrorAction Stop)
            }
            catch {
                $fileText = ''
            }

            if (-not [string]::IsNullOrEmpty([string]$fileText) -and $fileText.IndexOf([string]$needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                [void]$matchingFiles.Add([string]$file)
            }
        }

        Assert-True -Condition ($matchingFiles.Count -eq 0) -Message ("Tracked tree must not keep local-only accessibility vendor residue for needle '{0}'. Matches: {1}" -f [string]$needle, ($matchingFiles -join ', '))
    }
}

Invoke-Test -Name "Be My Eyes task publishes interactive helper asset" -Action {
    $updateDir = Join-Path $RepoRoot 'windows\update'
    $context = [ordered]@{
        VM_NAME = 'samplevm'
        VM_ADMIN_USER = 'manager'
        VM_ADMIN_PASS = '<runtime-secret>'
        ASSISTANT_USER = 'assistant'
        ASSISTANT_PASS = '<runtime-secret>'
        SSH_PORT = '22'
        RDP_PORT = '3389'
    }

    $taskPath = Join-Path $updateDir '126-install-be-my-eyes.ps1'
    $templates = @(
        [pscustomobject]@{
            Name = '126-install-be-my-eyes'
            Script = [string](Get-Content -LiteralPath $taskPath -Raw)
            RelativePath = '126-install-be-my-eyes.ps1'
            DirectoryPath = $updateDir
            TimeoutSeconds = 300
        }
    )

    $resolvedTask = @(Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks $templates -Context $context)[0]
    $assetCopies = @($resolvedTask.AssetCopies)
    Assert-True -Condition ($assetCopies.Count -eq 1) -Message "Be My Eyes task must publish exactly one helper asset."
    Assert-True -Condition ([string]$assetCopies[0].RemotePath -eq 'C:/Windows/Temp/az-vm-interactive-session-helper.ps1') -Message "Be My Eyes helper remote path mismatch."
    Assert-True -Condition ([string]$resolvedTask.Script -like '*Invoke-AzVmInteractiveDesktopAutomation*') -Message "Be My Eyes task must call the interactive helper."
    Assert-True -Condition ([string]$resolvedTask.Script -like '*Test-AzVmUserInteractiveDesktopReady*') -Message "Be My Eyes task must check for an interactive desktop before running the Store install."
    Assert-True -Condition ([string]$resolvedTask.Script -like '*install-be-my-eyes-deferred*') -Message "Be My Eyes task must fall back to a deferred install when no interactive desktop is available."
}

Invoke-Test -Name "iCloud task publishes interactive helper asset" -Action {
    $updateDir = Join-Path $RepoRoot 'windows\update'
    $context = [ordered]@{
        VM_NAME = 'samplevm'
        VM_ADMIN_USER = 'manager'
        VM_ADMIN_PASS = '<runtime-secret>'
        ASSISTANT_USER = 'assistant'
        ASSISTANT_PASS = '<runtime-secret>'
        SSH_PORT = '22'
        RDP_PORT = '3389'
    }

    $taskPath = Join-Path $updateDir '131-install-icloud-system.ps1'
    $templates = @(
        [pscustomobject]@{
            Name = '131-install-icloud-system'
            Script = [string](Get-Content -LiteralPath $taskPath -Raw)
            RelativePath = '131-install-icloud-system.ps1'
            DirectoryPath = $updateDir
            TimeoutSeconds = 300
        }
    )

    $resolvedTask = @(Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks $templates -Context $context)[0]
    $assetCopies = @($resolvedTask.AssetCopies)
    Assert-True -Condition ($assetCopies.Count -eq 1) -Message "iCloud task must publish exactly one helper asset."
    Assert-True -Condition ([string]$assetCopies[0].RemotePath -eq 'C:/Windows/Temp/az-vm-interactive-session-helper.ps1') -Message "iCloud helper remote path mismatch."
    Assert-True -Condition ([string]$resolvedTask.Script -like '*Invoke-AzVmInteractiveDesktopAutomation*') -Message "iCloud task must call the interactive helper."
    Assert-True -Condition ([string]$resolvedTask.Script -like '*Test-AzVmUserInteractiveDesktopReady*') -Message "iCloud task must check for an interactive desktop before running the Store install."
    Assert-True -Condition ([string]$resolvedTask.Script -like '*install-icloud-system-deferred*') -Message "iCloud task must fall back to a deferred install when no interactive desktop is available."
}

Write-Host ""
Write-Host ("Compatibility smoke summary -> Passed: {0}, Failed: {1}" -f $passCount, $failCount)
if ($failCount -gt 0) {
    exit 1
}


