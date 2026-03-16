# Create command runtime helpers.

function Assert-AzVmCreateAutoOptions {
    param(
        [hashtable]$Options,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag,
        [hashtable]$ConfigMap
    )

    if (-not (Get-AzVmCliOptionBool -Options $Options -Name 'auto' -DefaultValue $false)) {
        return
    }

    $validationConfig = if ($ConfigMap) { Resolve-AzVmSupportedDotEnvConfig -ConfigMap $ConfigMap } else { @{} }
    $platform = if ($WindowsFlag) {
        'windows'
    }
    elseif ($LinuxFlag) {
        'linux'
    }
    else {
        [string](Get-ConfigValue -Config $validationConfig -Key 'SELECTED_VM_OS' -DefaultValue '')
    }

    if ([string]::IsNullOrWhiteSpace([string]$platform)) {
        Throw-FriendlyError `
            -Detail "Create auto mode could not resolve a platform from CLI flags or .env." `
            -Code 2 `
            -Summary "Create auto mode requires platform selection." `
            -Hint "Set SELECTED_VM_OS=windows|linux in .env, or pass --windows/--linux."
    }

    $normalizedPlatform = $platform.Trim().ToLowerInvariant()
    if ($normalizedPlatform -notin @('windows','linux')) {
        Throw-FriendlyError `
            -Detail ("Unsupported platform value '{0}' was resolved for create auto mode." -f [string]$platform) `
            -Code 2 `
            -Summary "Create auto mode requires a supported platform." `
            -Hint "Set SELECTED_VM_OS=windows|linux in .env, or pass --windows/--linux."
    }

    $effectiveVmName = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-name')
    if ([string]::IsNullOrWhiteSpace([string]$effectiveVmName)) {
        $effectiveVmName = [string](Get-ConfigValue -Config $validationConfig -Key 'SELECTED_VM_NAME' -DefaultValue '')
    }

    $effectiveRegion = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-region')
    if ([string]::IsNullOrWhiteSpace([string]$effectiveRegion)) {
        $effectiveRegion = [string](Get-ConfigValue -Config $validationConfig -Key 'SELECTED_AZURE_REGION' -DefaultValue '')
    }

    $vmSizeKey = Get-AzVmPlatformVmConfigKey -Platform $normalizedPlatform -BaseKey 'VM_SIZE'
    $effectiveVmSize = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-size')
    if ([string]::IsNullOrWhiteSpace([string]$effectiveVmSize)) {
        $effectiveVmSize = [string](Get-ConfigValue -Config $validationConfig -Key $vmSizeKey -DefaultValue '')
    }

    $missing = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace([string]$effectiveVmName)) { [void]$missing.Add('SELECTED_VM_NAME or --vm-name') }
    if ([string]::IsNullOrWhiteSpace([string]$effectiveRegion)) { [void]$missing.Add('SELECTED_AZURE_REGION or --vm-region') }
    if ([string]::IsNullOrWhiteSpace([string]$effectiveVmSize)) { [void]$missing.Add(("'{0}' or --vm-size" -f $vmSizeKey)) }

    if ($missing.Count -gt 0) {
        Throw-FriendlyError `
            -Detail ("Create auto mode is missing resolvable values: {0}." -f (@($missing) -join ', ')) `
            -Code 2 `
            -Summary "Create auto mode is missing required selection values." `
            -Hint "Populate the SELECTED_* values in .env together with the platform VM size defaults, or pass the missing CLI options explicitly."
    }
}

function New-AzVmCreateCommandRuntime {
    param(
        [hashtable]$Options,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag,
        [switch]$AutoMode
    )

    $actionPlan = Resolve-AzVmActionPlan -CommandName 'create' -Options $Options
    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    Assert-AzVmCreateAutoOptions -Options $Options -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -ConfigMap $configMap
    $createOverrides = @{}
    $cliSubscriptionId = [string](Get-AzVmCliOptionText -Options $Options -Name 'subscription-id')

    if (-not $AutoMode -and [string]::IsNullOrWhiteSpace([string]$cliSubscriptionId)) {
        $currentSubscription = Get-AzVmResolvedSubscriptionContext
        $selectedSubscription = Select-AzVmSubscriptionInteractive -DefaultSubscriptionId ([string]$currentSubscription.SubscriptionId)
        Set-AzVmResolvedSubscriptionContext `
            -SubscriptionId ([string]$selectedSubscription.id) `
            -SubscriptionName ([string]$selectedSubscription.name) `
            -TenantId ([string]$selectedSubscription.tenantId) `
            -ResolutionSource 'interactive'
        $createOverrides['SELECTED_AZURE_SUBSCRIPTION_ID'] = [string]$selectedSubscription.id
        Set-AzVmConfigValueSource -Key 'SELECTED_AZURE_SUBSCRIPTION_ID' -Source 'interactive value'
    }

    $createVmName = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-name')
    if (-not [string]::IsNullOrWhiteSpace([string]$createVmName)) {
        $createOverrides['SELECTED_VM_NAME'] = $createVmName.Trim()
        Set-AzVmConfigValueSource -Key 'SELECTED_VM_NAME' -Source 'cli value'
    }
    else {
        $configuredVmName = [string](Get-ConfigValue -Config $configMap -Key 'SELECTED_VM_NAME' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace([string]$configuredVmName)) {
            $createOverrides['SELECTED_VM_NAME'] = $configuredVmName.Trim()
            Set-AzVmConfigValueSource -Key 'SELECTED_VM_NAME' -Source '.env value'
        }
    }

    $createVmRegion = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-region')
    if (-not [string]::IsNullOrWhiteSpace([string]$createVmRegion)) {
        $createOverrides['SELECTED_AZURE_REGION'] = $createVmRegion.Trim().ToLowerInvariant()
        Set-AzVmConfigValueSource -Key 'SELECTED_AZURE_REGION' -Source 'cli value'
    }
    else {
        $configuredVmRegion = [string](Get-ConfigValue -Config $configMap -Key 'SELECTED_AZURE_REGION' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace([string]$configuredVmRegion)) {
            $createOverrides['SELECTED_AZURE_REGION'] = $configuredVmRegion.Trim().ToLowerInvariant()
            Set-AzVmConfigValueSource -Key 'SELECTED_AZURE_REGION' -Source '.env value'
        }
    }

    $createVmSize = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-size')
    if (-not [string]::IsNullOrWhiteSpace([string]$createVmSize)) {
        $createOverrides['VM_SIZE'] = $createVmSize.Trim()
        Set-AzVmConfigValueSource -Key 'VM_SIZE' -Source 'cli value'
    }

    return [pscustomobject]@{
        ActionPlan = $actionPlan
        InitialConfigOverrides = $createOverrides
        WindowsFlag = [bool]$WindowsFlag
        LinuxFlag = [bool]$LinuxFlag
        AutoMode = [bool]$AutoMode
    }
}
