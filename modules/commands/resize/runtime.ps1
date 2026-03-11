# Resize command runtime helpers.

# Handles Invoke-AzVmResizeCommand.
function Get-AzVmPlatformNameFromOsType {
    param(
        [string]$OsType
    )

    $osTypeText = [string]$OsType
    if ([string]::IsNullOrWhiteSpace([string]$osTypeText)) {
        return ''
    }

    $normalized = $osTypeText.Trim().ToLowerInvariant()
    switch ($normalized) {
        'windows' { return 'windows' }
        'linux' { return 'linux' }
        default { return '' }
    }
}

# Handles Test-AzVmResizeDirectRequest.
function Test-AzVmResizeDirectRequest {
    param(
        [hashtable]$Options
    )

    foreach ($requiredName in @('group','vm-name','vm-size')) {
        if (-not (Test-AzVmCliOptionPresent -Options $Options -Name $requiredName)) {
            return $false
        }

        $rawValue = [string](Get-AzVmCliOptionText -Options $Options -Name $requiredName)
        if ([string]::IsNullOrWhiteSpace([string]$rawValue)) {
            return $false
        }
    }

    return $true
}

# Handles Resolve-AzVmResizeTargetSize.
function Resolve-AzVmResizeTargetSize {
    param(
        [hashtable]$Options,
        [string]$CurrentRegion,
        [string]$CurrentSize,
        [hashtable]$ConfigMap
    )

    $targetSize = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-size')
    if (-not [string]::IsNullOrWhiteSpace([string]$targetSize)) {
        return $targetSize.Trim()
    }

    $priceHours = Get-PriceHoursFromConfig -Config $ConfigMap -DefaultHours 730
    while ($true) {
        $sizePick = Select-VmSkuInteractive -Location $CurrentRegion -DefaultVmSize $CurrentSize -PriceHours $priceHours
        if ([string]::Equals([string]$sizePick, (Get-AzVmSkuPickerRegionBackToken), [System.StringComparison]::Ordinal)) {
            Write-Host "Resize command keeps the current region fixed. Select another VM size in the same region." -ForegroundColor Yellow
            continue
        }

        $resolvedSize = [string]$sizePick
        if (-not [string]::IsNullOrWhiteSpace([string]$resolvedSize)) {
            return $resolvedSize.Trim()
        }
    }
}

# Handles Assert-AzVmResizePlatformExpectation.
function Assert-AzVmResizePlatformExpectation {
    param(
        [string]$ActualPlatform,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag,
        [string]$VmName,
        [string]$ResourceGroup
    )

    $expectedPlatform = ''
    if ($WindowsFlag) {
        $expectedPlatform = 'windows'
    }
    elseif ($LinuxFlag) {
        $expectedPlatform = 'linux'
    }

    if ([string]::IsNullOrWhiteSpace([string]$expectedPlatform)) {
        return
    }

    if ([string]::IsNullOrWhiteSpace([string]$ActualPlatform)) {
        Throw-FriendlyError `
            -Detail ("Resize command could not resolve the actual platform for VM '{0}' in resource group '{1}'." -f $VmName, $ResourceGroup) `
            -Code 62 `
            -Summary "Resize command cannot verify the target VM operating system." `
            -Hint "Check the VM metadata in Azure and retry without conflicting platform flags."
    }

    if (-not [string]::Equals([string]$expectedPlatform, [string]$ActualPlatform, [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-FriendlyError `
            -Detail ("Resize command expected a {0} VM, but '{1}' in resource group '{2}' is {3}." -f $expectedPlatform, $VmName, $ResourceGroup, $ActualPlatform) `
            -Code 62 `
            -Summary "Resize command platform flag does not match the target VM." `
            -Hint "Use the correct --windows or --linux flag for the existing VM, or omit the platform flag."
    }
}
