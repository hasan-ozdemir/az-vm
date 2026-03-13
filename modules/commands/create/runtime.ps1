# Create command runtime helpers.

function Assert-AzVmCreateAutoOptions {
    param(
        [hashtable]$Options,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    if (-not (Get-AzVmCliOptionBool -Options $Options -Name 'auto' -DefaultValue $false)) {
        return
    }

    if (-not $WindowsFlag -and -not $LinuxFlag) {
        Throw-FriendlyError `
            -Detail "Create auto mode requires an explicit platform flag." `
            -Code 2 `
            -Summary "Create auto mode requires platform selection." `
            -Hint "Use --windows or --linux together with create --auto."
    }

    $requiredOptions = @('vm-name', 'vm-region', 'vm-size')
    foreach ($optionName in @($requiredOptions)) {
        if (Test-AzVmCliOptionPresent -Options $Options -Name $optionName) {
            continue
        }

        Throw-FriendlyError `
            -Detail ("Create auto mode requires --{0}." -f [string]$optionName) `
            -Code 2 `
            -Summary "Create auto mode is missing a required option." `
            -Hint "Provide --vm-name, --vm-region, and --vm-size together with create --auto."
    }
}

function New-AzVmCreateCommandRuntime {
    param(
        [hashtable]$Options,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag,
        [switch]$AutoMode
    )

    Assert-AzVmCreateAutoOptions -Options $Options -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag

    $actionPlan = Resolve-AzVmActionPlan -CommandName 'create' -Options $Options
    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $createOverrides = @{}

    $createVmName = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-name')
    if (-not [string]::IsNullOrWhiteSpace([string]$createVmName)) {
        $createOverrides['VM_NAME'] = $createVmName.Trim()
    }
    else {
        $configuredVmName = [string](Get-ConfigValue -Config $configMap -Key 'VM_NAME' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace([string]$configuredVmName)) {
            $createOverrides['VM_NAME'] = $configuredVmName.Trim()
        }
    }

    $createVmRegion = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-region')
    if (-not [string]::IsNullOrWhiteSpace([string]$createVmRegion)) {
        $createOverrides['AZ_LOCATION'] = $createVmRegion.Trim().ToLowerInvariant()
    }

    $createVmSize = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-size')
    if (-not [string]::IsNullOrWhiteSpace([string]$createVmSize)) {
        $createOverrides['VM_SIZE'] = $createVmSize.Trim()
    }

    return [pscustomobject]@{
        ActionPlan = $actionPlan
        InitialConfigOverrides = $createOverrides
        RenewMode = (Get-AzVmCliOptionBool -Options $Options -Name 'destructive rebuild' -DefaultValue $false)
        WindowsFlag = [bool]$WindowsFlag
        LinuxFlag = [bool]$LinuxFlag
        AutoMode = [bool]$AutoMode
    }
}
