# Imported runtime region: test-sku.

# Handles Get-PriceHoursFromConfig.
function Get-PriceHoursFromConfig {
    param(
        [hashtable]$Config,
        [int]$DefaultHours = 730
    )

    $hoursText = Get-ConfigValue -Config $Config -Key "PRICE_HOURS" -DefaultValue "$DefaultHours"
    if ($hoursText -match '^\d+$') {
        $hours = [int]$hoursText
        if ($hours -gt 0) {
            return $hours
        }
    }

    return $DefaultHours
}

# Handles Get-AzLocationCatalog.
function Get-AzLocationCatalog {
    $locationsJson = az account list-locations `
        --only-show-errors `
        --query "[?metadata.regionType=='Physical'].{Name:name,DisplayName:displayName,RegionType:metadata.regionType}" `
        -o json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($locationsJson)) {
        Throw-FriendlyError `
            -Detail "az account list-locations failed with exit code $LASTEXITCODE." `
            -Code 26 `
            -Summary "Azure region list could not be loaded." `
            -Hint "Run az login and verify subscription access."
    }

    $locations = ConvertFrom-JsonArrayCompat -InputObject $locationsJson
    if (-not $locations -or $locations.Count -eq 0) {
        $alternateLocationsJson = az account list-locations `
            --only-show-errors `
            --query "[].{Name:name,DisplayName:displayName,RegionType:metadata.regionType}" `
            -o json
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($alternateLocationsJson)) {
            $alternateLocations = ConvertFrom-JsonArrayCompat -InputObject $alternateLocationsJson
            $locations = @($alternateLocations | Where-Object { $_.RegionType -eq "Physical" })
        }
    }
    if (-not $locations -or $locations.Count -eq 0) {
        Throw-FriendlyError `
            -Detail "Azure returned an empty physical deployment region list." `
            -Code 26 `
            -Summary "Azure region list could not be loaded." `
            -Hint "Check Azure account/subscription context and location metadata availability."
    }

    return (ConvertTo-ObjectArrayCompat -InputObject @($locations | Sort-Object DisplayName, Name))
    return
}

# Handles Write-RegionSelectionGrid.
function Write-RegionSelectionGrid {
    param(
        [object[]]$Locations,
        [int]$DefaultIndex,
        [int]$Columns = 9
    )

    if (-not $Locations -or $Locations.Count -eq 0) {
        return
    }

    if ($Columns -lt 1) {
        $Columns = 1
    }

    $labels = @()
    for ($i = 0; $i -lt $Locations.Count; $i++) {
        $regionName = [string]$Locations[$i].Name
        $isDefault = (($i + 1) -eq $DefaultIndex)
        if ($isDefault) {
            $labels += ("*{0}-{1}." -f ($i + 1), $regionName)
        }
        else {
            $labels += ("{0}-{1}." -f ($i + 1), $regionName)
        }
    }

    $maxLength = ($labels | Measure-Object -Property Length -Maximum).Maximum
    $cellWidth = [int]$maxLength + 3

    for ($start = 0; $start -lt $labels.Count; $start += $Columns) {
        $end = [math]::Min($start + $Columns - 1, $labels.Count - 1)
        $lineBuilder = New-Object System.Text.StringBuilder
        for ($idx = $start; $idx -le $end; $idx++) {
            [void]$lineBuilder.Append(($labels[$idx]).PadRight($cellWidth))
        }
        Write-Host $lineBuilder.ToString().TrimEnd()
    }

}

# Handles Resolve-AzVmLocationNameFromEntry.
function Resolve-AzVmLocationNameFromEntry {
    param(
        [object]$Entry,
        [object[]]$Catalog,
        [string]$DefaultLocation = ''
    )

    $nameCandidates = @()
    if ($null -ne $Entry) {
        $nameCandidates += @(
            [string]$Entry.Name,
            [string]$Entry.name,
            [string]$Entry.Location,
            [string]$Entry.location
        )
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$DefaultLocation)) {
        $nameCandidates += @([string]$DefaultLocation)
    }

    foreach ($candidateRaw in @($nameCandidates)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidateRaw)) {
            continue
        }

        $candidate = ([string]$candidateRaw).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) {
            continue
        }

        if ($Catalog -and @($Catalog).Count -gt 0) {
            $matched = @($Catalog | Where-Object {
                [string]::Equals(([string]$_.Name), $candidate, [System.StringComparison]::OrdinalIgnoreCase) -or
                [string]::Equals(([string]$_.name), $candidate, [System.StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1)
            if ($matched.Count -gt 0) {
                $matchedName = [string]$matched[0].Name
                if ([string]::IsNullOrWhiteSpace([string]$matchedName)) {
                    $matchedName = [string]$matched[0].name
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$matchedName)) {
                    return $matchedName.Trim().ToLowerInvariant()
                }
            }
        }
        else {
            return $candidate
        }
    }

    if ($null -ne $Entry) {
        $displayName = [string]$Entry.DisplayName
        if ([string]::IsNullOrWhiteSpace([string]$displayName)) {
            $displayName = [string]$Entry.displayName
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$displayName) -and $Catalog) {
            $matchByDisplay = @($Catalog | Where-Object {
                [string]::Equals(([string]$_.DisplayName), $displayName, [System.StringComparison]::OrdinalIgnoreCase) -or
                [string]::Equals(([string]$_.displayName), $displayName, [System.StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1)
            if ($matchByDisplay.Count -gt 0) {
                $matchName = [string]$matchByDisplay[0].Name
                if ([string]::IsNullOrWhiteSpace([string]$matchName)) {
                    $matchName = [string]$matchByDisplay[0].name
                }
                if (-not [string]::IsNullOrWhiteSpace([string]$matchName)) {
                    return $matchName.Trim().ToLowerInvariant()
                }
            }
        }
    }

    return ''
}

# Handles Select-AzLocationInteractive.
function Select-AzLocationInteractive {
    param(
        [string]$DefaultLocation
    )

    $locations = Get-AzLocationCatalog
    $defaultIndex = 1
    for ($i = 0; $i -lt $locations.Count; $i++) {
        if ([string]::Equals($locations[$i].Name, $DefaultLocation, [System.StringComparison]::OrdinalIgnoreCase)) {
            $defaultIndex = $i + 1
            break
        }
    }

    Write-Host ""
    Write-Host "Available Azure regions (select by number):" -ForegroundColor Cyan
    Write-RegionSelectionGrid -Locations $locations -DefaultIndex $defaultIndex -Columns 9

    while ($true) {
        $inputValue = Read-Host "Enter region number (default=$defaultIndex)"
        if ([string]::IsNullOrWhiteSpace($inputValue)) {
            $selectedLocation = Resolve-AzVmLocationNameFromEntry -Entry $locations[$defaultIndex - 1] -Catalog $locations -DefaultLocation $DefaultLocation
            if (-not [string]::IsNullOrWhiteSpace([string]$selectedLocation)) {
                return $selectedLocation
            }
            Write-Host "Default region resolution returned empty value. Please select a region number explicitly." -ForegroundColor Yellow
            continue
        }

        if ($inputValue -match '^\d+$') {
            $selectedNo = [int]$inputValue
            if ($selectedNo -ge 1 -and $selectedNo -le $locations.Count) {
                $selectedLocation = Resolve-AzVmLocationNameFromEntry -Entry $locations[$selectedNo - 1] -Catalog $locations -DefaultLocation $DefaultLocation
                if (-not [string]::IsNullOrWhiteSpace([string]$selectedLocation)) {
                    return $selectedLocation
                }
                Write-Host "Selected region could not be resolved. Please choose another region number." -ForegroundColor Yellow
                continue
            }
        }

        Write-Host "Invalid region selection. Please enter a valid number." -ForegroundColor Yellow
    }
}

# Handles Convert-ToSkuSearchPattern.
function Convert-ToSkuSearchPattern {
    param(
        [string]$FilterText
    )

    if ([string]::IsNullOrWhiteSpace($FilterText)) {
        return ""
    }

    $trimmed = $FilterText.Trim()
    return "*" + $trimmed + "*"
}

# Handles Test-SkuWildcardMatchOrdinalIgnoreCase.
function Test-SkuWildcardMatchOrdinalIgnoreCase {
    param(
        [string]$Text,
        [string]$Pattern
    )

    if ($null -eq $Text) {
        $Text = ""
    }
    if ($null -eq $Pattern) {
        $Pattern = ""
    }

    $textIndex = 0
    $patternIndex = 0
    $lastStarIndex = -1
    $starMatchTextIndex = 0

    while ($textIndex -lt $Text.Length) {
        if ($patternIndex -lt $Pattern.Length) {
            $patternChar = $Pattern[$patternIndex]
            $textChar = $Text[$textIndex]

            if ($patternChar -eq '?') {
                $textIndex++
                $patternIndex++
                continue
            }

            if ([string]::Equals([string]$textChar, [string]$patternChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                $textIndex++
                $patternIndex++
                continue
            }

            if ($patternChar -eq '*') {
                $lastStarIndex = $patternIndex
                $starMatchTextIndex = $textIndex
                $patternIndex++
                continue
            }
        }

        if ($lastStarIndex -ne -1) {
            $patternIndex = $lastStarIndex + 1
            $starMatchTextIndex++
            $textIndex = $starMatchTextIndex
            continue
        }

        return $false
    }

    while ($patternIndex -lt $Pattern.Length -and $Pattern[$patternIndex] -eq '*') {
        $patternIndex++
    }

    return ($patternIndex -eq $Pattern.Length)
}

# Handles Get-LocationSkusForSelection.
function Get-LocationSkusForSelection {
    param(
        [string]$Location,
        [string]$SkuLike
    )

    $filterText = ""
    if (-not [string]::IsNullOrWhiteSpace($SkuLike)) {
        $filterText = $SkuLike.Trim()
    }

    $raw = az vm list-sizes -l $Location --only-show-errors -o json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        Throw-FriendlyError `
            -Detail "az vm list-sizes failed for location '$Location' with exit code $LASTEXITCODE." `
            -Code 27 `
            -Summary "VM size list could not be loaded for the selected region." `
            -Hint "Verify the selected region and Azure subscription permissions."
    }

    $allSkus = ConvertFrom-JsonArrayCompat -InputObject $raw
    $namedSkus = @(
        $allSkus | Where-Object {
            $_.name
        }
    )

    if ($filterText -eq "") {
        return (ConvertTo-ObjectArrayCompat -InputObject @($namedSkus | Sort-Object name -Unique))
        return
    }

    $effectivePattern = Convert-ToSkuSearchPattern -FilterText $filterText
    $filtered = foreach ($sku in $namedSkus) {
        $name = [string]$sku.name
        if (Test-SkuWildcardMatchOrdinalIgnoreCase -Text $name -Pattern $effectivePattern) {
            $sku
        }
    }

    return (ConvertTo-ObjectArrayCompat -InputObject @($filtered | Sort-Object name -Unique))
    return
}

# Handles Get-SkuAvailabilityMap.
function Get-SkuAvailabilityMap {
    param(
        [string]$Location,
        [string[]]$SkuNames
    )

    $result = @{}
    if (-not $SkuNames -or $SkuNames.Count -eq 0) {
        return $result
    }

    $targetSkuSet = @{}
    foreach ($skuName in $SkuNames) {
        if (-not [string]::IsNullOrWhiteSpace($skuName)) {
            $targetSkuSet[$skuName.ToLowerInvariant()] = $true
        }
    }

    $subscriptionId = az account show --only-show-errors --query id -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subscriptionId)) {
        Throw-FriendlyError `
            -Detail "az account show failed while resolving subscription for SKU availability." `
            -Code 24 `
            -Summary "SKU availability pre-check could not be completed." `
            -Hint "Run az login and verify active subscription."
    }

    $tokenJson = az account get-access-token --only-show-errors --resource https://management.azure.com/ -o json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($tokenJson)) {
        Throw-FriendlyError `
            -Detail "az account get-access-token failed while resolving SKU availability." `
            -Code 24 `
            -Summary "SKU availability pre-check could not be completed." `
            -Hint "Verify Azure CLI authentication and token permissions."
    }

    $accessToken = (ConvertFrom-JsonCompat -InputObject $tokenJson).accessToken
    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        Throw-FriendlyError `
            -Detail "Azure access token is empty for SKU availability request." `
            -Code 24 `
            -Summary "SKU availability pre-check could not be completed." `
            -Hint "Refresh Azure login session and retry."
    }

    $filter = [uri]::EscapeDataString("location eq '$Location'")
    $url = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Compute/skus?api-version=2023-07-01&`$filter=$filter"

    try {
        $response = Invoke-AzVmHttpRestMethod `
            -Method Get `
            -Uri $url `
            -Headers @{ Authorization = "Bearer $accessToken" } `
            -PerfLabel ("http compute skus list (location={0})" -f [string]$Location)
    }
    catch {
        Throw-FriendlyError `
            -Detail "Resource SKU API call failed for availability check in '$Location'." `
            -Code 24 `
            -Summary "SKU availability pre-check could not be completed." `
            -Hint "Check Azure REST access and subscription permissions."
    }

    $items = @(
        (ConvertTo-ObjectArrayCompat -InputObject $response.value) |
            Where-Object { $_.resourceType -eq "virtualMachines" }
    )
    foreach ($item in $items) {
        if (-not $item.name) { continue }
        $itemName = [string]$item.name
        $skuKey = $itemName.ToLowerInvariant()
        if (-not $targetSkuSet.ContainsKey($skuKey)) { continue }

        $isUnavailable = $false
        foreach ($restriction in (ConvertTo-ObjectArrayCompat -InputObject $item.restrictions)) {
            if ($restriction.reasonCode -eq "NotAvailableForSubscription") {
                $isUnavailable = $true
                break
            }
            if ($restriction.type -eq "Location" -and (($restriction.values -and ($restriction.values -contains $Location)) -or -not $restriction.values)) {
                $isUnavailable = $true
                break
            }
        }

        $locationInfo = @(
            (ConvertTo-ObjectArrayCompat -InputObject $item.locationInfo) |
                Where-Object { $_.location -ieq $Location }
        )
        if ($isUnavailable -or -not $locationInfo) {
            $result[$itemName] = "no"
        }
        else {
            $result[$itemName] = "yes"
        }
    }

    return $result
}

# Handles Get-SkuPriceMap.
function Get-SkuPriceMap {
    param(
        [string]$Location,
        [string[]]$SkuNames
    )

    $result = @{}
    if (-not $SkuNames -or $SkuNames.Count -eq 0) {
        return $result
    }

    $catalog = Get-AzVmRetailPricingCatalogForLocation -Location $Location
    foreach ($skuName in $SkuNames) {
        if ([string]::IsNullOrWhiteSpace([string]$skuName)) {
            continue
        }

        $skuKey = ([string]$skuName).ToLowerInvariant()
        if ($catalog.ContainsKey($skuKey)) {
            $result[[string]$skuName] = $catalog[$skuKey]
        }
    }

    return $result
}

# Handles Get-AzVmHttpStatusCode.
function Get-AzVmHttpStatusCode {
    param(
        [object]$ExceptionObject
    )

    if ($null -eq $ExceptionObject) {
        return $null
    }

    $statusCodeValue = $null
    $response = $null
    if ($ExceptionObject.PSObject.Properties.Match('Response').Count -gt 0) {
        $response = $ExceptionObject.Response
    }

    if ($null -ne $response -and $response.PSObject.Properties.Match('StatusCode').Count -gt 0 -and $null -ne $response.StatusCode) {
        try {
            $statusCodeValue = [int]$response.StatusCode
        }
        catch {
            try {
                $statusCodeValue = [int]$response.StatusCode.value__
            }
            catch {
                $statusCodeValue = $null
            }
        }
    }

    if ($null -eq $statusCodeValue -and $ExceptionObject.PSObject.Properties.Match('StatusCode').Count -gt 0 -and $null -ne $ExceptionObject.StatusCode) {
        try {
            $statusCodeValue = [int]$ExceptionObject.StatusCode
        }
        catch {
            try {
                $statusCodeValue = [int]$ExceptionObject.StatusCode.value__
            }
            catch {
                $statusCodeValue = $null
            }
        }
    }

    return $statusCodeValue
}

# Handles Get-AzVmHttpRetryAfterSeconds.
function Get-AzVmHttpRetryAfterSeconds {
    param(
        [object]$ExceptionObject
    )

    if ($null -eq $ExceptionObject) {
        return $null
    }

    $response = $null
    if ($ExceptionObject.PSObject.Properties.Match('Response').Count -gt 0) {
        $response = $ExceptionObject.Response
    }

    if ($null -eq $response) {
        return $null
    }

    $headers = $null
    if ($response.PSObject.Properties.Match('Headers').Count -gt 0) {
        $headers = $response.Headers
    }
    if ($null -eq $headers) {
        return $null
    }

    $retryAfterRaw = $null
    try {
        $retryAfterRaw = $headers['Retry-After']
    }
    catch {
        $retryAfterRaw = $null
    }
    if ([string]::IsNullOrWhiteSpace([string]$retryAfterRaw)) {
        try {
            $retryAfterValues = $headers.GetValues('Retry-After')
            if ($retryAfterValues -and $retryAfterValues.Count -gt 0) {
                $retryAfterRaw = [string]$retryAfterValues[0]
            }
        }
        catch {
            $retryAfterRaw = $null
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$retryAfterRaw) -and $headers.PSObject.Properties.Match('RetryAfter').Count -gt 0 -and $null -ne $headers.RetryAfter) {
        $retryAfterObject = $headers.RetryAfter
        if ($retryAfterObject.PSObject.Properties.Match('Delta').Count -gt 0 -and $null -ne $retryAfterObject.Delta) {
            try {
                return [int][math]::Ceiling([double]$retryAfterObject.Delta.TotalSeconds)
            }
            catch {}
        }
        if ($retryAfterObject.PSObject.Properties.Match('Date').Count -gt 0 -and $null -ne $retryAfterObject.Date) {
            try {
                $seconds = [int][math]::Ceiling(([datetimeoffset]$retryAfterObject.Date - [datetimeoffset]::UtcNow).TotalSeconds)
                if ($seconds -gt 0) {
                    return $seconds
                }
            }
            catch {}
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$retryAfterRaw)) {
        return $null
    }

    $numeric = 0
    if ([int]::TryParse(([string]$retryAfterRaw).Trim(), [ref]$numeric)) {
        if ($numeric -gt 0) {
            return $numeric
        }
        return $null
    }

    $retryAfterDate = [datetime]::MinValue
    if ([datetime]::TryParse([string]$retryAfterRaw, [ref]$retryAfterDate)) {
        $deltaSeconds = [int][math]::Ceiling(($retryAfterDate.ToUniversalTime() - [datetime]::UtcNow).TotalSeconds)
        if ($deltaSeconds -gt 0) {
            return $deltaSeconds
        }
    }

    return $null
}

# Handles Invoke-AzVmRetailPricingRequest.
function Invoke-AzVmRetailPricingRequest {
    param(
        [string]$Uri
    )

    $maxRetries = [math]::Max([int]$script:RetailPricingMaxRetries, 0)
    for ($retry = 0; $true; $retry++) {
        try {
            return Invoke-AzVmHttpRestMethod -Method Get -Uri $Uri -PerfLabel "http retail pricing api"
        }
        catch {
            $statusCode = Get-AzVmHttpStatusCode -ExceptionObject $_.Exception
            $isRetryable = $false
            if ($null -ne $statusCode) {
                $retryableCodes = @(429, 500, 502, 503, 504)
                if ($retryableCodes -contains ([int]$statusCode)) {
                    $isRetryable = $true
                }
            }

            if (-not $isRetryable -or $retry -ge $maxRetries) {
                throw
            }

            $retryAfterSeconds = Get-AzVmHttpRetryAfterSeconds -ExceptionObject $_.Exception
            if ($null -eq $retryAfterSeconds -or $retryAfterSeconds -le 0) {
                $retryAfterSeconds = [int][math]::Min([math]::Pow(2, ($retry + 1)), 30)
            }
            if ($retryAfterSeconds -lt 1) {
                $retryAfterSeconds = 1
            }

            Write-Host ("Retail Pricing API returned HTTP {0}. Retrying in {1}s ({2}/{3})..." -f $statusCode, $retryAfterSeconds, ($retry + 1), $maxRetries) -ForegroundColor Yellow
            Start-Sleep -Seconds $retryAfterSeconds
        }
    }
}

# Handles Normalize-AzVmRetailPricingNextPageLink.
function Normalize-AzVmRetailPricingNextPageLink {
    param(
        [string]$Uri
    )

    if ([string]::IsNullOrWhiteSpace([string]$Uri)) {
        return $null
    }

    $normalized = ([string]$Uri).Trim()
    $normalized = $normalized -replace '(?i)([?&])\$top=-?\d+', '$1'
    $normalized = $normalized -replace '\?&', '?'
    $normalized = $normalized -replace '&&', '&'
    $normalized = $normalized -replace '[?&]$', ''

    if ([string]::IsNullOrWhiteSpace([string]$normalized)) {
        return $null
    }

    return $normalized
}

# Handles Get-AzVmRetailPricingCatalogForLocation.
function Get-AzVmRetailPricingCatalogForLocation {
    param(
        [string]$Location
    )

    if ([string]::IsNullOrWhiteSpace([string]$Location)) {
        return @{}
    }

    $locationKey = ([string]$Location).Trim().ToLowerInvariant()
    if ($script:RetailPricingCacheByLocation.ContainsKey($locationKey)) {
        return $script:RetailPricingCacheByLocation[$locationKey]
    }

    $catalog = @{}
    $baseFilter = "serviceName eq 'Virtual Machines' and armRegionName eq '$Location' and type eq 'Consumption' and unitOfMeasure eq '1 Hour'"
    $nextUri = "https://prices.azure.com/api/retail/prices?`$filter=" + [uri]::EscapeDataString($baseFilter) + "&`$top=1000"

    while ($nextUri) {
        $response = Invoke-AzVmRetailPricingRequest -Uri $nextUri
        foreach ($item in (ConvertTo-ObjectArrayCompat -InputObject $response.Items)) {
            if (-not $item.armSkuName -or $item.unitPrice -eq $null) {
                continue
            }

            if ($item.productName -like "*Cloud Services*") {
                continue
            }
            $priceText = "$($item.productName) $($item.skuName) $($item.meterName) $($item.meterSubCategory)"
            if ($priceText -match '(?i)\bspot\b' -or $priceText -match '(?i)\blow\s+priority\b') {
                continue
            }

            $catalogKey = ([string]$item.armSkuName).ToLowerInvariant()
            if (-not $catalog.ContainsKey($catalogKey)) {
                $catalog[$catalogKey] = [ordered]@{
                    LinuxPerHour   = $null
                    WindowsPerHour = $null
                    Currency       = $item.currencyCode
                }
            }

            $entry = $catalog[$catalogKey]
            $unitPrice = [double]$item.unitPrice
            if ($item.productName -like "*Windows*") {
                if ($null -eq $entry.WindowsPerHour -or $unitPrice -lt $entry.WindowsPerHour) {
                    $entry.WindowsPerHour = $unitPrice
                }
            }
            else {
                if ($null -eq $entry.LinuxPerHour -or $unitPrice -lt $entry.LinuxPerHour) {
                    $entry.LinuxPerHour = $unitPrice
                }
            }
        }

        $nextUri = Normalize-AzVmRetailPricingNextPageLink -Uri ([string]$response.NextPageLink)
        if ([string]::IsNullOrWhiteSpace($nextUri)) {
            $nextUri = $null
        }
        elseif ([int]$script:RetailPricingPageDelayMs -gt 0) {
            Start-Sleep -Milliseconds ([int]$script:RetailPricingPageDelayMs)
        }
    }

    $script:RetailPricingCacheByLocation[$locationKey] = $catalog
    return $catalog
}

# Handles Convert-HourlyPriceToMonthlyText.
function Convert-HourlyPriceToMonthlyText {
    param(
        [double]$PricePerHour,
        [int]$Hours
    )

    if ($PricePerHour -le 0) {
        return "N/A"
    }

    return [math]::Round(($PricePerHour * $Hours), 2)
}

# Handles Build-VmSkuSelectionRows.
function Build-VmSkuSelectionRows {
    param(
        [object[]]$Skus,
        [hashtable]$AvailabilityMap,
        [hashtable]$PriceMap,
        [int]$PriceHours
    )

    $linuxPriceColumn = "Linux_{0}h" -f $PriceHours
    $windowsPriceColumn = "Windows_{0}h" -f $PriceHours

    $rows = @()
    for ($i = 0; $i -lt $Skus.Count; $i++) {
        $sku = $Skus[$i]
        $skuName = [string]$sku.name
        $price = $null
        if ($PriceMap.ContainsKey($skuName)) {
            $price = $PriceMap[$skuName]
        }

        $availability = "unknown"
        if ($AvailabilityMap.ContainsKey($skuName)) {
            $availability = [string]$AvailabilityMap[$skuName]
        }

        $row = [ordered]@{
            No          = $i + 1
            Sku         = $skuName
            vCPU        = [int]$sku.numberOfCores
            RAM_GB      = [math]::Round(([double]$sku.memoryInMB / 1024), 2)
        }

        $linuxPrice = if ($price -and $price.LinuxPerHour -ne $null) { Convert-HourlyPriceToMonthlyText -PricePerHour $price.LinuxPerHour -Hours $PriceHours } else { "N/A" }
        $windowsPrice = if ($price -and $price.WindowsPerHour -ne $null) { Convert-HourlyPriceToMonthlyText -PricePerHour $price.WindowsPerHour -Hours $PriceHours } else { "N/A" }
        $row[$linuxPriceColumn] = $linuxPrice
        $row[$windowsPriceColumn] = $windowsPrice
        $row["CreateReady"] = $availability

        $rows += [PSCustomObject]$row
    }

    return (ConvertTo-ObjectArrayCompat -InputObject $rows)
    return
}

# Handles Read-StrictYesNo.
function Read-StrictYesNo {
    param(
        [string]$PromptText
    )

    while ($true) {
        $raw = Read-Host ("{0} (y/n)" -f $PromptText)
        if ($null -eq $raw) {
            $raw = ""
        }

        $value = $raw.Trim().ToLowerInvariant()
        if ($value -eq "y") {
            return $true
        }
        if ($value -eq "n") {
            return $false
        }

        Write-Host "Invalid choice. Please enter 'y' or 'n'." -ForegroundColor Yellow
    }
}

# Handles Get-AzVmSkuPickerRegionBackToken.
function Get-AzVmSkuPickerRegionBackToken {
    return "__AZ_VM_PICK_REGION_AGAIN__"
}

# Handles Select-VmSkuInteractive.
function Select-VmSkuInteractive {
    param(
        [string]$Location,
        [string]$DefaultVmSize,
        [int]$PriceHours
    )

    $currentVmSku = ""
    if (-not [string]::IsNullOrWhiteSpace($DefaultVmSize)) {
        $currentVmSku = $DefaultVmSize.Trim()
    }

    if (-not [string]::IsNullOrWhiteSpace($currentVmSku)) {
        Write-Host ""
        Write-Host ("Current VM SKU for region '{0}': {1}" -f $Location, $currentVmSku) -ForegroundColor Cyan
        $useCurrentSku = Read-StrictYesNo -PromptText ("Continue with VM SKU '{0}'?" -f $currentVmSku)
        if ($useCurrentSku) {
            return $currentVmSku
        }
    }

    while ($true) {
        $skuLikeRaw = Read-Host "Enter partial VM type (supports * and ?, examples: b2a, standard_a*, standard_b?a*v2). Leave empty to list all"
        if ($null -eq $skuLikeRaw) {
            $skuLikeRaw = ""
        }
        $skuLike = $skuLikeRaw.Trim()

        $skus = Get-LocationSkusForSelection -Location $Location -SkuLike $skuLike
        $effectiveFilter = if ([string]::IsNullOrWhiteSpace($skuLike)) { "<all>" } else { $skuLike }
        Write-Host ("Partial VM type filter received: {0}" -f $effectiveFilter) -ForegroundColor DarkGray
        Write-Host ("Matching SKU count: {0}" -f @($skus).Count) -ForegroundColor DarkGray
        if (-not $skus -or $skus.Count -eq 0) {
            Write-Host "No matching VM SKU found for '$skuLike' in '$Location'. Try another filter." -ForegroundColor Yellow
            continue
        }

        $skuNames = @($skus | ForEach-Object { [string]$_.name })
        $availabilityMap = Get-SkuAvailabilityMap -Location $Location -SkuNames $skuNames
        $priceMap = @{}
        try {
            $priceMap = Get-SkuPriceMap -Location $Location -SkuNames $skuNames
        }
        catch {
            Write-Warning "Price API lookup failed. Pricing columns will be shown as N/A. Detail: $($_.Exception.Message)"
        }

        Write-Host ""
        Write-Host ("Available VM SKUs in region '{0}' (prices use {1} hours/month):" -f $Location, $PriceHours) -ForegroundColor Cyan
        $rows = Build-VmSkuSelectionRows -Skus $skus -AvailabilityMap $availabilityMap -PriceMap $priceMap -PriceHours $PriceHours
        $rows | Format-Table -AutoSize | Out-Host

        $defaultIndex = 1
        for ($i = 0; $i -lt $rows.Count; $i++) {
            if ([string]::Equals($rows[$i].Sku, $DefaultVmSize, [System.StringComparison]::OrdinalIgnoreCase)) {
                $defaultIndex = $i + 1
                break
            }
        }

        while ($true) {
            $selection = Read-Host "Enter VM SKU number (default=$defaultIndex, f=change filter, r=change region)"
            if ([string]::IsNullOrWhiteSpace($selection)) {
                $selectedSku = [string]$rows[$defaultIndex - 1].Sku
                $confirmSelected = Read-StrictYesNo -PromptText ("Selected VM SKU: '{0}'. Continue?" -f $selectedSku)
                if ($confirmSelected) {
                    return $selectedSku
                }

                Write-Host "Returning to VM SKU filter search..." -ForegroundColor DarkGray
                break
            }
            if ($selection -match '^[fF]$') {
                break
            }
            if ($selection -match '^[rR]$') {
                Write-Host "Returning to region selection..." -ForegroundColor DarkGray
                return (Get-AzVmSkuPickerRegionBackToken)
            }

            if ($selection -match '^\d+$') {
                $selectedNo = [int]$selection
                if ($selectedNo -ge 1 -and $selectedNo -le $rows.Count) {
                    $selectedSku = [string]$rows[$selectedNo - 1].Sku
                    $confirmSelected = Read-StrictYesNo -PromptText ("Selected VM SKU: '{0}'. Continue?" -f $selectedSku)
                    if ($confirmSelected) {
                        return $selectedSku
                    }

                    Write-Host "Returning to VM SKU filter search..." -ForegroundColor DarkGray
                    break
                }
            }

            Write-Host "Invalid VM SKU selection. Please enter a valid number, or use 'f'/'r'." -ForegroundColor Yellow
        }
    }
}

# Handles Get-AzVmResourceGroupsForSelection.
function Get-AzVmResourceGroupsForSelection {
    param(
        [string]$ServerName
    )

    $rows = @()
    try {
        $rows = @(Get-AzVmManagedResourceGroupRows)
    }
    catch {
        Throw-FriendlyError `
            -Detail "az group list failed while loading managed resource groups." `
            -Code 64 `
            -Summary "Resource group list could not be loaded." `
            -Hint "Run az login and verify subscription access."
    }

    $names = @(
        ConvertTo-ObjectArrayCompat -InputObject $rows |
            ForEach-Object { [string]$_.name } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Sort-Object -Unique
    )
    if ($names.Count -eq 0) {
        Throw-FriendlyError `
            -Detail ("No managed resource groups were found with tag {0}={1}." -f [string]$script:ManagedByTagKey, [string]$script:ManagedByTagValue) `
            -Code 64 `
            -Summary "Resource group list is empty." `
            -Hint "Run create to provision a managed resource group, then retry."
    }

    $filtered = @($names)

    if (-not [string]::IsNullOrWhiteSpace([string]$ServerName)) {
        $needle = [string]$ServerName.Trim().ToLowerInvariant()
        $serverMatches = @(
            $filtered | Where-Object {
                $candidate = ([string]$_).ToLowerInvariant()
                $candidate.Contains($needle)
            }
        )
        if ($serverMatches.Count -gt 0) {
            $filtered = @($serverMatches)
        }
    }

    return @($filtered | Sort-Object -Unique)
}

# Handles Select-AzVmResourceGroupInteractive.
function Select-AzVmResourceGroupInteractive {
    param(
        [string]$DefaultResourceGroup,
        [string]$ServerName
    )

    $groups = @(Get-AzVmResourceGroupsForSelection -ServerName $ServerName)
    if ($groups.Count -eq 0) {
        Throw-FriendlyError `
            -Detail "No selectable resource group was found." `
            -Code 64 `
            -Summary "Resource group selection cannot continue." `
            -Hint "Create a resource group first, then retry."
    }

    $defaultIndex = 1
    for ($i = 0; $i -lt $groups.Count; $i++) {
        if ([string]::Equals([string]$groups[$i], [string]$DefaultResourceGroup, [System.StringComparison]::OrdinalIgnoreCase)) {
            $defaultIndex = $i + 1
            break
        }
    }

    Write-Host ""
    Write-Host "Available resource groups (select by number):" -ForegroundColor Cyan
    for ($i = 0; $i -lt $groups.Count; $i++) {
        $label = if (($i + 1) -eq $defaultIndex) { "*{0}-{1}." -f ($i + 1), [string]$groups[$i] } else { "{0}-{1}." -f ($i + 1), [string]$groups[$i] }
        Write-Host $label
    }

    while ($true) {
        $raw = Read-Host ("Enter resource group number (default={0})" -f $defaultIndex)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [string]$groups[$defaultIndex - 1]
        }
        if ($raw -match '^\d+$') {
            $index = [int]$raw
            if ($index -ge 1 -and $index -le $groups.Count) {
                return [string]$groups[$index - 1]
            }
        }
        Write-Host "Invalid resource group selection. Please enter a valid number." -ForegroundColor Yellow
    }
}

# Handles Resolve-AzVmTargetResourceGroup.
function Resolve-AzVmTargetResourceGroup {
    param(
        [hashtable]$Options,
        [switch]$AutoMode,
        [string]$DefaultResourceGroup,
        [string]$ServerName,
        [string]$OperationName = 'operation'
    )

    $groupOption = [string](Get-AzVmCliOptionText -Options $Options -Name 'group')
    $resourceGroup = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$groupOption)) {
        $resourceGroup = $groupOption.Trim()
    }
    elseif ($AutoMode) {
        $resourceGroup = [string]$DefaultResourceGroup
        if ([string]::IsNullOrWhiteSpace([string]$resourceGroup)) {
            Throw-FriendlyError `
                -Detail ("No active resource group is configured for auto mode in {0} command." -f $OperationName) `
                -Code 66 `
                -Summary ("{0} command cannot resolve target resource group." -f $OperationName) `
                -Hint "Set RESOURCE_GROUP in .env or provide --group=<name>."
        }
    }
    else {
        $resourceGroup = Select-AzVmResourceGroupInteractive -DefaultResourceGroup $DefaultResourceGroup -ServerName $ServerName
    }

    $groupExists = az group exists -n $resourceGroup --only-show-errors
    Assert-LastExitCode ("az group exists ({0})" -f $OperationName)
    if (-not [string]::Equals([string]$groupExists, "true", [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-FriendlyError `
            -Detail ("Resource group '{0}' was not found." -f $resourceGroup) `
            -Code 66 `
            -Summary ("{0} command cannot continue because resource group was not found." -f $OperationName) `
            -Hint "Provide a valid --group value or select an existing managed resource group."
    }

    Assert-AzVmManagedResourceGroup -ResourceGroup $resourceGroup -OperationName $OperationName
    return $resourceGroup
}

# Handles Get-AzVmVmNamesForResourceGroup.
function Get-AzVmVmNamesForResourceGroup {
    param(
        [string]$ResourceGroup
    )

    $raw = az vm list -g $ResourceGroup --query "[].name" -o json --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$raw)) {
        Throw-FriendlyError `
            -Detail ("az vm list failed for resource group '{0}'." -f $ResourceGroup) `
            -Code 65 `
            -Summary "VM list could not be loaded." `
            -Hint "Verify the resource group name and Azure access."
    }

    $vmNames = @(
        ConvertFrom-JsonArrayCompat -InputObject $raw |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Sort-Object -Unique
    )
    return @($vmNames)
}

# Handles Select-AzVmVmInteractive.
function Select-AzVmVmInteractive {
    param(
        [string]$ResourceGroup,
        [string]$DefaultVmName
    )

    $vmNames = @(Get-AzVmVmNamesForResourceGroup -ResourceGroup $ResourceGroup)
    if ($vmNames.Count -eq 0) {
        Throw-FriendlyError `
            -Detail ("Resource group '{0}' does not contain any VM." -f $ResourceGroup) `
            -Code 65 `
            -Summary "VM selection cannot continue because the VM list is empty." `
            -Hint "Create a VM first or choose another resource group."
    }

    $defaultIndex = 1
    for ($i = 0; $i -lt $vmNames.Count; $i++) {
        if ([string]::Equals([string]$vmNames[$i], [string]$DefaultVmName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $defaultIndex = $i + 1
            break
        }
    }

    Write-Host ""
    Write-Host ("Available VM names in '{0}' (select by number):" -f $ResourceGroup) -ForegroundColor Cyan
    for ($i = 0; $i -lt $vmNames.Count; $i++) {
        $label = if (($i + 1) -eq $defaultIndex) { "*{0}-{1}." -f ($i + 1), [string]$vmNames[$i] } else { "{0}-{1}." -f ($i + 1), [string]$vmNames[$i] }
        Write-Host $label
    }

    while ($true) {
        $raw = Read-Host ("Enter VM number (default={0})" -f $defaultIndex)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return [string]$vmNames[$defaultIndex - 1]
        }
        if ($raw -match '^\d+$') {
            $index = [int]$raw
            if ($index -ge 1 -and $index -le $vmNames.Count) {
                return [string]$vmNames[$index - 1]
            }
        }
        Write-Host "Invalid VM selection. Please enter a valid number." -ForegroundColor Yellow
    }
}

# Handles Resolve-AzVmTargetVmName.
function Resolve-AzVmTargetVmName {
    param(
        [string]$ResourceGroup,
        [string]$DefaultVmName,
        [switch]$AutoMode,
        [string]$OperationName = 'operation'
    )

    $vmNames = @(Get-AzVmVmNamesForResourceGroup -ResourceGroup $ResourceGroup)
    if ($vmNames.Count -eq 0) {
        Throw-FriendlyError `
            -Detail ("No VM found in resource group '{0}'." -f $ResourceGroup) `
            -Code 65 `
            -Summary ("{0} command cannot continue because VM list is empty." -f $OperationName) `
            -Hint "Create a VM first or choose another resource group."
    }

    if ($AutoMode) {
        if (-not [string]::IsNullOrWhiteSpace([string]$DefaultVmName)) {
            foreach ($candidate in @($vmNames)) {
                if ([string]::Equals([string]$candidate, [string]$DefaultVmName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return [string]$candidate
                }
            }
        }

        if ($vmNames.Count -eq 1) {
            return [string]$vmNames[0]
        }

        Throw-FriendlyError `
            -Detail ("Auto mode could not resolve one VM in resource group '{0}'." -f $ResourceGroup) `
            -Code 65 `
            -Summary ("{0} command cannot resolve target VM in auto mode." -f $OperationName) `
            -Hint "Set VM_NAME in .env, provide command-specific VM parameter, or use interactive mode."
    }

    return (Select-AzVmVmInteractive -ResourceGroup $ResourceGroup -DefaultVmName $DefaultVmName)
}

# Handles Get-AzVmVmNetworkDescriptor.
function Get-AzVmVmNetworkDescriptor {
    param(
        [string]$ResourceGroup,
        [string]$VmName
    )

    $vmJson = az vm show -g $ResourceGroup -n $VmName -o json --only-show-errors
    Assert-LastExitCode "az vm show (network descriptor)"
    $vmObject = ConvertFrom-JsonCompat -InputObject $vmJson
    if (-not $vmObject) {
        throw "VM metadata could not be parsed while collecting network resources."
    }

    $osDiskName = [string]$vmObject.storageProfile.osDisk.name
    $nicName = ""
    $nicEntries = @($vmObject.networkProfile.networkInterfaces)
    if ($nicEntries.Count -gt 0) {
        $primaryNic = @($nicEntries | Where-Object { $_.primary -eq $true } | Select-Object -First 1)
        if ($null -eq $primaryNic -or @($primaryNic).Count -eq 0) {
            $primaryNic = @($nicEntries | Select-Object -First 1)
        }
        if ($primaryNic -is [System.Array]) { $primaryNic = [object]$primaryNic[0] }
        $nicId = [string]$primaryNic.id
        if (-not [string]::IsNullOrWhiteSpace([string]$nicId)) {
            $nicParts = @($nicId -split '/')
            $nicName = [string]$nicParts[$nicParts.Count - 1]
        }
    }

    $publicIpName = ""
    $nsgName = ""
    $vnetName = ""
    if (-not [string]::IsNullOrWhiteSpace($nicName)) {
        $nicJson = az network nic show -g $ResourceGroup -n $nicName -o json --only-show-errors
        Assert-LastExitCode "az network nic show (network descriptor)"
        $nicObject = ConvertFrom-JsonCompat -InputObject $nicJson
        if ($nicObject) {
            $publicIpId = [string]$nicObject.ipConfigurations[0].publicIPAddress.id
            if (-not [string]::IsNullOrWhiteSpace([string]$publicIpId)) {
                $publicIpParts = @($publicIpId -split '/')
                $publicIpName = [string]$publicIpParts[$publicIpParts.Count - 1]
            }

            $nsgId = [string]$nicObject.networkSecurityGroup.id
            if (-not [string]::IsNullOrWhiteSpace([string]$nsgId)) {
                $nsgParts = @($nsgId -split '/')
                $nsgName = [string]$nsgParts[$nsgParts.Count - 1]
            }

            $subnetId = [string]$nicObject.ipConfigurations[0].subnet.id
            if (-not [string]::IsNullOrWhiteSpace([string]$subnetId)) {
                $subnetParts = @($subnetId -split '/')
                for ($i = 0; $i -lt $subnetParts.Count - 1; $i++) {
                    if ([string]::Equals([string]$subnetParts[$i], 'virtualNetworks', [System.StringComparison]::OrdinalIgnoreCase)) {
                        $vnetName = [string]$subnetParts[$i + 1]
                        break
                    }
                }
            }
        }
    }

    return [pscustomobject]@{
        OsDiskName = $osDiskName
        NicName = $nicName
        PublicIpName = $publicIpName
        NsgName = $nsgName
        VnetName = $vnetName
    }
}

# Handles Assert-AzVmCommandOptions.
function Assert-AzVmCommandOptions {
    param(
        [string]$CommandName,
        [hashtable]$Options
    )

    $allowed = @()

    switch ($CommandName) {
        'create' { $allowed = @('auto','perf','windows','linux','help','to-step','from-step','single-step') }
        'update' { $allowed = @('auto','perf','windows','linux','help','to-step','from-step','single-step','group') }
        'config' { $allowed = @('perf','windows','linux','help','group') }
        'group'  { $allowed = @('help','list','select') }
        'move'   { $allowed = @('perf','help','group','vm','vm-region') }
        'resize' { $allowed = @('perf','help','group','vm','vm-size') }
        'set'    { $allowed = @('perf','help','group','vm','hibernation','nested-virtualization') }
        'exec'   { $allowed = @('perf','windows','linux','help','group','init-task','update-task') }
        'show'   { $allowed = @('perf','help','group') }
        'delete' { $allowed = @('auto','perf','help','target','group','yes') }
        'help'   { $allowed = @('help') }
        default {
            Throw-FriendlyError `
                -Detail ("Unsupported command '{0}'." -f $CommandName) `
                -Code 2 `
                -Summary "Unknown command." `
                -Hint "Use one command: create | update | config | group | move | resize | set | exec | show | delete."
        }
    }

    foreach ($key in @($Options.Keys)) {
        $optionName = [string]$key
        if ($allowed -notcontains $optionName) {
            Throw-FriendlyError `
                -Detail ("Option '--{0}' is not supported for command '{1}'." -f $optionName, $CommandName) `
                -Code 2 `
                -Summary "Unsupported command option." `
                -Hint ("Use valid options for '{0}' only." -f $CommandName)
        }
    }

    $helpRequested = Get-AzVmCliOptionBool -Options $Options -Name 'help' -DefaultValue $false
    if ($helpRequested -and $CommandName -ne 'help') {
        return
    }

    if ($CommandName -eq 'delete') {
        $targetText = [string](Get-AzVmCliOptionText -Options $Options -Name 'target')
        $target = $targetText.Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($target)) {
            Throw-FriendlyError `
                -Detail "Option '--target' is required for delete command." `
                -Code 2 `
                -Summary "Delete target is missing." `
                -Hint "Use --target=group|network|vm|disk."
        }

        if ($target -notin @('group','network','vm','disk')) {
            Throw-FriendlyError `
                -Detail ("Invalid delete target '{0}'." -f $targetText) `
                -Code 2 `
                -Summary "Delete target is invalid." `
                -Hint "Valid targets: group, network, vm, disk."
        }
    }
}

# Handles Initialize-AzVmCommandRuntimeContext.
function Initialize-AzVmCommandRuntimeContext {
    param(
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag,
        [hashtable]$ConfigMapOverrides = @{},
        [switch]$UseInteractiveStep1,
        [switch]$PersistGeneratedResourceGroup
    )

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $platform = Resolve-AzVmPlatformSelection -ConfigMap $configMap -EnvFilePath $envFilePath -AutoMode:$AutoMode -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -ConfigOverrides $script:ConfigOverrides
    $platformDefaults = Get-AzVmPlatformDefaults -Platform $platform
    $effectiveConfigMap = Resolve-AzVmPlatformConfigMap -ConfigMap $configMap -Platform $platform
    foreach ($key in @($ConfigMapOverrides.Keys)) {
        $overrideKey = [string]$key
        if ([string]::IsNullOrWhiteSpace($overrideKey)) {
            continue
        }
        $effectiveConfigMap[$overrideKey] = [string]$ConfigMapOverrides[$key]
        $script:ConfigOverrides[$overrideKey] = [string]$ConfigMapOverrides[$key]
    }

    $step1AutoMode = $true
    if ($UseInteractiveStep1) {
        $step1AutoMode = [bool]$AutoMode
    }

    $step1Context = Invoke-AzVmStep1Common `
        -ConfigMap $effectiveConfigMap `
        -EnvFilePath $envFilePath `
        -Platform $platform `
        -AutoMode:$step1AutoMode `
        -PersistGeneratedResourceGroup:$PersistGeneratedResourceGroup `
        -ScriptRoot $repoRoot `
        -ServerNameDefault ([string]$platformDefaults.ServerNameDefault) `
        -VmImageDefault ([string]$platformDefaults.VmImageDefault) `
        -VmDiskSizeDefault ([string]$platformDefaults.VmDiskSizeDefault) `
        -ConfigOverrides $script:ConfigOverrides

    $step1Context['VmOsType'] = $platform

    $taskOutcomeModeRaw = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'TASK_OUTCOME_MODE' -DefaultValue 'continue')
    if ([string]::IsNullOrWhiteSpace($taskOutcomeModeRaw)) { $taskOutcomeModeRaw = 'continue' }
    $taskOutcomeMode = $taskOutcomeModeRaw.Trim().ToLowerInvariant()
    if ($taskOutcomeMode -ne 'continue' -and $taskOutcomeMode -ne 'strict') {
        $taskOutcomeMode = 'continue'
    }
    if ($platform -eq 'windows') {
        $taskOutcomeMode = 'strict'
    }

    $configuredPySshClientPath = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'PYSSH_CLIENT_PATH' -DefaultValue '')
    $sshTaskTimeoutText = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'SSH_TASK_TIMEOUT_SECONDS' -DefaultValue ([string]$script:SshTaskTimeoutSeconds))
    $sshTaskTimeoutSeconds = $script:SshTaskTimeoutSeconds
    if ($sshTaskTimeoutText -match '^\d+$') { $sshTaskTimeoutSeconds = [int]$sshTaskTimeoutText }
    if ($sshTaskTimeoutSeconds -lt 30) { $sshTaskTimeoutSeconds = 30 }
    if ($sshTaskTimeoutSeconds -gt 7200) { $sshTaskTimeoutSeconds = 7200 }

    $sshConnectTimeoutText = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'SSH_CONNECT_TIMEOUT_SECONDS' -DefaultValue ([string]$script:SshConnectTimeoutSeconds))
    $sshConnectTimeoutSeconds = $script:SshConnectTimeoutSeconds
    if ($sshConnectTimeoutText -match '^\d+$') { $sshConnectTimeoutSeconds = [int]$sshConnectTimeoutText }
    if ($sshConnectTimeoutSeconds -lt 5) { $sshConnectTimeoutSeconds = 5 }
    if ($sshConnectTimeoutSeconds -gt 300) { $sshConnectTimeoutSeconds = 300 }

    $azCommandTimeoutText = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'AZ_COMMAND_TIMEOUT_SECONDS' -DefaultValue ([string]$script:AzCommandTimeoutSeconds))
    $azCommandTimeoutSeconds = $script:AzCommandTimeoutSeconds
    if ($azCommandTimeoutText -match '^\d+$') { $azCommandTimeoutSeconds = [int]$azCommandTimeoutText }
    if ($azCommandTimeoutSeconds -lt 30) { $azCommandTimeoutSeconds = 30 }
    if ($azCommandTimeoutSeconds -gt 7200) { $azCommandTimeoutSeconds = 7200 }

    $script:AzCommandTimeoutSeconds = $azCommandTimeoutSeconds
    $script:SshTaskTimeoutSeconds = $sshTaskTimeoutSeconds
    $script:SshConnectTimeoutSeconds = $sshConnectTimeoutSeconds
    $step1Context['AzCommandTimeoutSeconds'] = $azCommandTimeoutSeconds
    $step1Context['SshTaskTimeoutSeconds'] = $sshTaskTimeoutSeconds
    $step1Context['SshConnectTimeoutSeconds'] = $sshConnectTimeoutSeconds

    return [pscustomobject]@{
        EnvFilePath = $envFilePath
        ConfigMap = $configMap
        EffectiveConfigMap = $effectiveConfigMap
        Platform = $platform
        PlatformDefaults = $platformDefaults
        Context = $step1Context
        TaskOutcomeMode = $taskOutcomeMode
        ConfiguredPySshClientPath = $configuredPySshClientPath
        SshTaskTimeoutSeconds = $sshTaskTimeoutSeconds
        SshConnectTimeoutSeconds = $sshConnectTimeoutSeconds
    }
}

# Handles Get-AzVmConfigPersistenceMap.
function Get-AzVmConfigPersistenceMap {
    param(
        [string]$Platform,
        [hashtable]$Context
    )

    $tcpPortsCsv = (@($Context.TcpPorts) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ','
    $vmImageConfigKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey "VM_IMAGE"
    $vmSizeConfigKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey "VM_SIZE"
    $vmDiskSizeConfigKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey "VM_DISK_SIZE_GB"

    $persist = [ordered]@{
        VM_OS_TYPE = [string]$Platform
        SERVER_NAME = [string]$Context.ServerName
        AZ_LOCATION = [string]$Context.AzLocation
        RESOURCE_GROUP = [string]$Context.ResourceGroup
        VNET_NAME = [string]$Context.VNET
        SUBNET_NAME = [string]$Context.SUBNET
        NSG_NAME = [string]$Context.NSG
        NSG_RULE_NAME = [string]$Context.NsgRule
        PUBLIC_IP_NAME = [string]$Context.IP
        NIC_NAME = [string]$Context.NIC
        VM_NAME = [string]$Context.VmName
        VM_DISK_NAME = [string]$Context.VmDiskName
        VM_STORAGE_SKU = [string]$Context.VmStorageSku
        SSH_PORT = [string]$Context.SshPort
        TCP_PORTS = [string]$tcpPortsCsv
    }

    $persist[$vmImageConfigKey] = [string]$Context.VmImage
    $persist[$vmSizeConfigKey] = [string]$Context.VmSize
    $persist[$vmDiskSizeConfigKey] = [string]$Context.VmDiskSize

    return $persist
}

# Handles Save-AzVmConfigToDotEnv.
function Save-AzVmConfigToDotEnv {
    param(
        [string]$EnvFilePath,
        [hashtable]$ConfigBefore,
        [hashtable]$PersistMap
    )

    $before = @{}
    if ($ConfigBefore) {
        foreach ($key in @($ConfigBefore.Keys)) {
            $before[[string]$key] = [string]$ConfigBefore[$key]
        }
    }

    $changes = @()
    foreach ($key in @($PersistMap.Keys)) {
        $name = [string]$key
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }

        $newValue = [string]$PersistMap[$name]
        $oldValue = ''
        if ($before.ContainsKey($name)) {
            $oldValue = [string]$before[$name]
        }

        if ([string]::Equals($oldValue, $newValue, [System.StringComparison]::Ordinal)) {
            continue
        }

        Set-DotEnvValue -Path $EnvFilePath -Key $name -Value $newValue
        $changes += [pscustomobject]@{
            Key = $name
            OldValue = $oldValue
            NewValue = $newValue
        }
    }

    return @($changes)
}

# Handles Show-AzVmKeyValueList.
function Show-AzVmKeyValueList {
    param(
        [string]$Title,
        [System.Collections.IDictionary]$Values
    )

    Write-Host $Title -ForegroundColor Cyan
    if (-not $Values -or $Values.Count -eq 0) {
        Write-Host "- (empty)"
        return
    }

    foreach ($key in @($Values.Keys | Sort-Object)) {
        $valueText = ConvertTo-AzVmDisplayValue -Value $Values[$key]
        Write-Host ("- {0} = {1}" -f [string]$key, [string]$valueText)
    }
}

# Handles Invoke-AzVmResourceGroupPreviewStep.
function Invoke-AzVmResourceGroupPreviewStep {
    param(
        [hashtable]$Context
    )

    Show-AzVmStepFirstUseValues `
        -StepLabel "Step 3/3 - resource group preview" `
        -Context $Context `
        -Keys @("ResourceGroup", "AzLocation")

    $resourceGroup = [string]$Context.ResourceGroup
    $resourceExists = az group exists -n $resourceGroup --only-show-errors
    Assert-LastExitCode "az group exists (config preview)"
    $resourceExistsBool = [string]::Equals([string]$resourceExists, "true", [System.StringComparison]::OrdinalIgnoreCase)

    if ($resourceExistsBool) {
        Write-Host ("Preview: resource group '{0}' exists. Config command will not modify it." -f $resourceGroup) -ForegroundColor Yellow
    }
    else {
        Write-Host ("Preview: resource group '{0}' does not exist. It will be created by create/update commands." -f $resourceGroup) -ForegroundColor Yellow
    }

    return [pscustomobject]@{
        ResourceGroup = $resourceGroup
        Exists = $resourceExistsBool
    }
}

# Handles Invoke-AzVmGroupCommand.
function Invoke-AzVmGroupCommand {
    param(
        [hashtable]$Options
    )

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $activeGroup = [string](Get-ConfigValue -Config $configMap -Key 'RESOURCE_GROUP' -DefaultValue '')
    $serverName = [string](Get-ConfigValue -Config $configMap -Key 'SERVER_NAME' -DefaultValue '')

    $hasList = Test-AzVmCliOptionPresent -Options $Options -Name 'list'
    $hasSelect = Test-AzVmCliOptionPresent -Options $Options -Name 'select'
    if ($hasList -and $hasSelect) {
        Throw-FriendlyError `
            -Detail "Options '--list' and '--select' cannot be used together." `
            -Code 2 `
            -Summary "Group command options are conflicting." `
            -Hint "Run list and select as separate commands."
    }

    if ($hasSelect) {
        $selectionRaw = [string](Get-AzVmCliOptionText -Options $Options -Name 'select')
        $selectedGroup = ''
        if ([string]::IsNullOrWhiteSpace([string]$selectionRaw)) {
            $selectedGroup = Select-AzVmResourceGroupInteractive -DefaultResourceGroup $activeGroup -ServerName $serverName
        }
        else {
            $selectedGroup = $selectionRaw.Trim()
            $exists = az group exists -n $selectedGroup --only-show-errors
            Assert-LastExitCode "az group exists (group select)"
            if (-not [string]::Equals([string]$exists, "true", [System.StringComparison]::OrdinalIgnoreCase)) {
                Throw-FriendlyError `
                    -Detail ("Resource group '{0}' was not found." -f $selectedGroup) `
                    -Code 64 `
                    -Summary "Group select failed because target resource group was not found." `
                    -Hint "Select an existing managed resource group."
            }
            Assert-AzVmManagedResourceGroup -ResourceGroup $selectedGroup -OperationName 'group select'
        }

        Set-DotEnvValue -Path $envFilePath -Key 'RESOURCE_GROUP' -Value $selectedGroup
        $script:ConfigOverrides['RESOURCE_GROUP'] = $selectedGroup
        Write-Host ("Active resource group set to '{0}'." -f $selectedGroup) -ForegroundColor Green
        return
    }

    $filterRaw = if ($hasList) { [string](Get-AzVmCliOptionText -Options $Options -Name 'list') } else { '' }
    $filter = if ([string]::IsNullOrWhiteSpace([string]$filterRaw)) { '' } else { $filterRaw.Trim().ToLowerInvariant() }

    $rows = @()
    try {
        $rows = @(Get-AzVmManagedResourceGroupRows)
    }
    catch {
        Throw-FriendlyError `
            -Detail "Managed resource groups could not be listed." `
            -Code 64 `
            -Summary "Group list failed." `
            -Hint "Run az login and verify Azure access."
    }

    $names = @(
        ConvertTo-ObjectArrayCompat -InputObject $rows |
            ForEach-Object { [string]$_.name } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Sort-Object -Unique
    )
    if (-not [string]::IsNullOrWhiteSpace([string]$filter)) {
        $names = @(
            $names | Where-Object {
                ([string]$_).ToLowerInvariant().Contains($filter)
            }
        )
    }

    Write-Host "Managed resource groups (az-vm):" -ForegroundColor Cyan
    if (@($names).Count -eq 0) {
        Write-Host "- (none)"
        return
    }

    for ($i = 0; $i -lt $names.Count; $i++) {
        $name = [string]$names[$i]
        $label = if ([string]::Equals($name, $activeGroup, [System.StringComparison]::OrdinalIgnoreCase)) {
            "*{0}-{1}." -f ($i + 1), $name
        }
        else {
            "{0}-{1}." -f ($i + 1), $name
        }
        Write-Host $label
    }
}

# Handles Invoke-AzVmConfigCommand.
function Invoke-AzVmConfigCommand {
    param(
        [hashtable]$Options,
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configBefore = Read-DotEnvFile -Path $envFilePath
    $defaultResourceGroup = [string](Get-ConfigValue -Config $configBefore -Key 'RESOURCE_GROUP' -DefaultValue '')
    $serverName = [string](Get-ConfigValue -Config $configBefore -Key 'SERVER_NAME' -DefaultValue '')
    $selectedResourceGroup = Resolve-AzVmTargetResourceGroup `
        -Options $Options `
        -AutoMode:$AutoMode `
        -DefaultResourceGroup $defaultResourceGroup `
        -ServerName $serverName `
        -OperationName 'config'

    $runtime = $null
    $context = $null
    $platform = ''
    $step1Result = $null

    $step1Result = Invoke-Step 'Step 1/3 - configuration values will be resolved...' {
        $runtimeLocal = Initialize-AzVmCommandRuntimeContext `
            -AutoMode:$AutoMode `
            -WindowsFlag:$WindowsFlag `
            -LinuxFlag:$LinuxFlag `
            -ConfigMapOverrides @{ RESOURCE_GROUP = $selectedResourceGroup } `
            -PersistGeneratedResourceGroup
        [pscustomobject]@{
            Runtime = $runtimeLocal
            Context = $runtimeLocal.Context
            Platform = [string]$runtimeLocal.Platform
        }
    }
    if ($null -eq $step1Result -or @($step1Result).Count -eq 0) {
        Throw-FriendlyError `
            -Detail "Interactive configuration step did not produce runtime context." `
            -Code 64 `
            -Summary "Config command could not continue after step 1." `
            -Hint "Rerun 'az-vm config' and verify group selection."
    }
    if ($step1Result -is [System.Array]) {
        $step1Result = $step1Result[-1]
    }
    $runtime = $step1Result.Runtime
    $context = $step1Result.Context
    $platform = [string]$step1Result.Platform
    if ($null -eq $context) {
        Throw-FriendlyError `
            -Detail "Step 1 returned an empty context object." `
            -Code 64 `
            -Summary "Config command could not continue after step 1." `
            -Hint "Rerun 'az-vm config' and verify interactive selections."
    }
    if ([string]::IsNullOrWhiteSpace([string]$context.AzLocation)) {
        Throw-FriendlyError `
            -Detail "Step 1 returned empty AZ_LOCATION in context." `
            -Code 64 `
            -Summary "Config command could not continue because region was not captured." `
            -Hint "Select a valid region in step 1 and retry."
    }

    Invoke-Step 'Step 2/3 - region, image, and VM size availability will be checked...' {
        Invoke-AzVmPrecheckStep -Context $context
    }

    Invoke-Step 'Step 3/3 - resource group preview will be displayed...' {
        $null = Invoke-AzVmResourceGroupPreviewStep -Context $context
    }

    $persistMap = Get-AzVmConfigPersistenceMap -Platform $platform -Context $context
    $changes = Save-AzVmConfigToDotEnv -EnvFilePath ([string]$runtime.EnvFilePath) -ConfigBefore $configBefore -PersistMap $persistMap
    $configAfter = Read-DotEnvFile -Path ([string]$runtime.EnvFilePath)

    Write-Host ""
    Show-AzVmKeyValueList -Title "Existing .env values (before config):" -Values $configBefore
    Write-Host ""
    Show-AzVmKeyValueList -Title "Resolved configuration values:" -Values $context
    Write-Host ""
    Show-AzVmKeyValueList -Title ".env values after config:" -Values $configAfter
    Write-Host ""
    if (@($changes).Count -gt 0) {
        Write-Host "Saved .env changes:" -ForegroundColor Green
        foreach ($change in @($changes)) {
            $oldValue = if ([string]::IsNullOrWhiteSpace([string]$change.OldValue)) { "(empty)" } else { [string]$change.OldValue }
            $newValue = if ([string]::IsNullOrWhiteSpace([string]$change.NewValue)) { "(empty)" } else { [string]$change.NewValue }
            Write-Host ("- {0}: {1} -> {2}" -f [string]$change.Key, $oldValue, $newValue)
        }
    }
    else {
        Write-Host "No .env value changes were needed; current values are already aligned." -ForegroundColor Yellow
    }

    Write-Host ""
    Write-Host "Config completed successfully. No Azure resources were created, updated, or deleted." -ForegroundColor Green
    Write-Host "Next actions:" -ForegroundColor Cyan
    Write-Host "- az-vm create --auto"
    Write-Host "- az-vm create --to-step=vm-deploy"
}

# Handles Resolve-AzVmTaskSelection.
function Resolve-AzVmTaskSelection {
    param(
        [object[]]$TaskBlocks,
        [string]$TaskNumberOrName,
        [string]$Stage,
        [switch]$AutoMode
    )

    $allTasks = @($TaskBlocks)
    if ($allTasks.Count -eq 0) {
        Throw-FriendlyError `
            -Detail ("No active {0} tasks were found." -f $Stage) `
            -Code 60 `
            -Summary "Task list is empty." `
            -Hint ("Add files under the '{0}' task directory." -f $Stage)
    }

    $selectedToken = if ($null -eq $TaskNumberOrName) { '' } else { [string]$TaskNumberOrName }
    $selectedToken = $selectedToken.Trim()
    if ([string]::IsNullOrWhiteSpace($selectedToken)) {
        if ($AutoMode) {
            Throw-FriendlyError `
                -Detail ("Option '--{0}-task' is required in auto mode." -f $Stage) `
                -Code 60 `
                -Summary "Task selection is required in auto mode." `
                -Hint ("Provide --{0}-task=<NN>." -f $Stage)
        }

        Write-Host ("Available {0} tasks:" -f $Stage) -ForegroundColor Cyan
        for ($i = 0; $i -lt $allTasks.Count; $i++) {
            Write-Host ("{0}. {1}" -f ($i + 1), [string]$allTasks[$i].Name)
        }
        while ($true) {
            $pickRaw = Read-Host ("Enter {0} task number" -f $Stage)
            if ($pickRaw -match '^\d+$') {
                $pickNumber = [int]$pickRaw
                if ($pickNumber -ge 1 -and $pickNumber -le $allTasks.Count) {
                    return $allTasks[$pickNumber - 1]
                }
            }
            Write-Host "Invalid task selection. Please enter a valid number." -ForegroundColor Yellow
        }
    }

    $selectedTask = $null
    if ($selectedToken -match '^\d+$') {
        $prefix = ([int]$selectedToken).ToString('00')
        $selectedTask = @($allTasks | Where-Object { ([string]$_.Name).StartsWith($prefix + '-', [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
    }
    else {
        $selectedTask = @($allTasks | Where-Object { [string]::Equals([string]$_.Name, $selectedToken, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
    }

    if ($null -eq $selectedTask -or @($selectedTask).Count -eq 0) {
        Throw-FriendlyError `
            -Detail ("Task '{0}' was not found in {1} catalog." -f $selectedToken, $Stage) `
            -Code 60 `
            -Summary "Task selection is invalid." `
            -Hint ("List valid {0} task numbers with 'az-vm exec' in interactive mode." -f $Stage)
    }

    return $selectedTask[0]
}

# Handles Invoke-AzVmExecCommand.
function Invoke-AzVmExecCommand {
    param(
        [hashtable]$Options,
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    $runtimeConfigOverrides = @{}
    $runtime = Initialize-AzVmCommandRuntimeContext -AutoMode:$true -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -ConfigMapOverrides $runtimeConfigOverrides
    $context = $runtime.Context
    $platform = [string]$runtime.Platform
    $platformDefaults = $runtime.PlatformDefaults
    $selectedResourceGroup = Resolve-AzVmTargetResourceGroup `
        -Options $Options `
        -AutoMode:$AutoMode `
        -DefaultResourceGroup ([string]$context.ResourceGroup) `
        -ServerName ([string]$context.ServerName) `
        -OperationName 'exec'
    $context.ResourceGroup = $selectedResourceGroup

    $hasInitTask = Test-AzVmCliOptionPresent -Options $Options -Name 'init-task'
    $hasUpdateTask = Test-AzVmCliOptionPresent -Options $Options -Name 'update-task'
    if ($hasInitTask -and $hasUpdateTask) {
        Throw-FriendlyError `
            -Detail "Both --init-task and --update-task were provided." `
            -Code 61 `
            -Summary "Only one task selector can be used at a time." `
            -Hint "Use either --init-task=<NN> or --update-task=<NN>."
    }

    $hasTaskSelector = ($hasInitTask -or $hasUpdateTask)
    if ($hasTaskSelector) {
        $stage = if ($hasInitTask) { 'init' } else { 'update' }
        $context.VmName = Resolve-AzVmTargetVmName -ResourceGroup ([string]$context.ResourceGroup) -DefaultVmName ([string]$context.VmName) -AutoMode:$AutoMode -OperationName 'exec'

        if ($stage -eq 'init') {
            $catalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath ([string]$context.VmInitTaskDir) -Platform $platform -Stage 'init'
            $tasks = Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks @($catalog.ActiveTasks) -Context $context
            $requested = Get-AzVmCliOptionText -Options $Options -Name 'init-task'
            $selectedTask = Resolve-AzVmTaskSelection -TaskBlocks $tasks -TaskNumberOrName $requested -Stage 'init' -AutoMode:$AutoMode
            $combinedShell = if ($platform -eq 'linux') { 'bash' } else { 'powershell' }
            Invoke-VmRunCommandBlocks -ResourceGroup ([string]$context.ResourceGroup) -VmName ([string]$context.VmName) -CommandId ([string]$platformDefaults.RunCommandId) -TaskBlocks @($selectedTask) -CombinedShell $combinedShell -PerfTaskCategory "exec-task" | Out-Null
            Write-Host ("Exec completed: init task '{0}'." -f [string]$selectedTask.Name) -ForegroundColor Green
            return
        }

        $catalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath ([string]$context.VmUpdateTaskDir) -Platform $platform -Stage 'update'
        $tasks = Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks @($catalog.ActiveTasks) -Context $context
        $requested = Get-AzVmCliOptionText -Options $Options -Name 'update-task'
        $selectedTask = Resolve-AzVmTaskSelection -TaskBlocks $tasks -TaskNumberOrName $requested -Stage 'update' -AutoMode:$AutoMode

        $vmRuntimeDetails = Get-AzVmVmDetails -Context $context
        $sshHost = [string]$vmRuntimeDetails.VmFqdn
        if ([string]::IsNullOrWhiteSpace($sshHost)) {
            $sshHost = [string]$vmRuntimeDetails.PublicIP
        }
        if ([string]::IsNullOrWhiteSpace($sshHost)) {
            throw "Exec could not resolve VM SSH host (FQDN/Public IP)."
        }

        Invoke-AzVmSshTaskBlocks `
            -Platform $platform `
            -RepoRoot (Get-AzVmRepoRoot) `
            -SshHost $sshHost `
            -SshUser ([string]$context.VmUser) `
            -SshPassword ([string]$context.VmPass) `
            -SshPort ([string]$context.SshPort) `
            -ResourceGroup ([string]$context.ResourceGroup) `
            -VmName ([string]$context.VmName) `
            -TaskBlocks @($selectedTask) `
            -TaskOutcomeMode ([string]$runtime.TaskOutcomeMode) `
            -PerfTaskCategory 'exec-task' `
            -SshMaxRetries 1 `
            -SshTaskTimeoutSeconds ([int]$runtime.SshTaskTimeoutSeconds) `
            -SshConnectTimeoutSeconds ([int]$runtime.SshConnectTimeoutSeconds) `
            -ConfiguredPySshClientPath ([string]$runtime.ConfiguredPySshClientPath) | Out-Null

        Write-Host ("Exec completed: update task '{0}'." -f [string]$selectedTask.Name) -ForegroundColor Green
        return
    }

    $selectedVmName = Resolve-AzVmTargetVmName -ResourceGroup $selectedResourceGroup -DefaultVmName ([string]$context.VmName) -AutoMode:$AutoMode -OperationName 'exec'
    $vmDetailContext = [ordered]@{
        ResourceGroup = $selectedResourceGroup
        VmName = $selectedVmName
        AzLocation = [string]$context.AzLocation
        SshPort = [string]$context.SshPort
    }

    $vmRuntimeDetails = Get-AzVmVmDetails -Context $vmDetailContext
    $sshHost = [string]$vmRuntimeDetails.VmFqdn
    if ([string]::IsNullOrWhiteSpace($sshHost)) {
        $sshHost = [string]$vmRuntimeDetails.PublicIP
    }
    if ([string]::IsNullOrWhiteSpace($sshHost)) {
        throw "Exec REPL could not resolve VM SSH host (FQDN/Public IP)."
    }

    $vmJson = az vm show -g $selectedResourceGroup -n $selectedVmName -o json --only-show-errors
    Assert-LastExitCode "az vm show (exec repl)"
    $vmObject = ConvertFrom-JsonCompat -InputObject $vmJson
    $osType = [string]$vmObject.storageProfile.osDisk.osType
    $replPlatform = if ([string]::Equals($osType, 'Linux', [System.StringComparison]::OrdinalIgnoreCase)) { 'linux' } else { 'windows' }
    $shell = if ($replPlatform -eq 'linux') { 'bash' } else { 'powershell' }

    $pySsh = Ensure-AzVmPySshTools -RepoRoot (Get-AzVmRepoRoot) -ConfiguredPySshClientPath ([string]$runtime.ConfiguredPySshClientPath)
    $bootstrap = Initialize-AzVmSshHostKey `
        -PySshPythonPath ([string]$pySsh.PythonPath) `
        -PySshClientPath ([string]$pySsh.ClientPath) `
        -HostName $sshHost `
        -UserName ([string]$context.VmUser) `
        -Password ([string]$context.VmPass) `
        -Port ([string]$context.SshPort) `
        -ConnectTimeoutSeconds ([int]$runtime.SshConnectTimeoutSeconds)
    if (-not [string]::IsNullOrWhiteSpace([string]$bootstrap.Output)) {
        Write-Host ([string]$bootstrap.Output)
    }

    Write-Host ("Interactive exec shell connected: {0}@{1}:{2} ({3})" -f [string]$context.VmUser, $sshHost, [string]$context.SshPort, $shell) -ForegroundColor Green
    Write-Host "Type 'exit' in the remote shell to close the session." -ForegroundColor Cyan

    $shellWatch = $null
    if ($script:PerfMode) {
        $shellWatch = [System.Diagnostics.Stopwatch]::StartNew()
    }

    $shellArgs = @(
        [string]$pySsh.ClientPath,
        "shell",
        "--host", [string]$sshHost,
        "--port", [string]$context.SshPort,
        "--user", [string]$context.VmUser,
        "--password", [string]$context.VmPass,
        "--timeout", [string]$runtime.SshConnectTimeoutSeconds,
        "--reconnect-retries", "3",
        "--keepalive-seconds", "15",
        "--shell", [string]$shell
    )

    & ([string]$pySsh.PythonPath) @shellArgs
    $shellExitCode = [int]$LASTEXITCODE

    if ($null -ne $shellWatch -and $shellWatch.IsRunning) {
        $shellWatch.Stop()
        Write-AzVmPerfTiming -Category "exec-task" -Label "interactive shell session" -Seconds $shellWatch.Elapsed.TotalSeconds
    }

    if ($shellExitCode -ne 0) {
        Throw-FriendlyError `
            -Detail ("Interactive exec shell ended with exit code {0}." -f $shellExitCode) `
            -Code 61 `
            -Summary "Interactive exec shell failed." `
            -Hint "Review remote shell output and retry. Ensure SSH service remains available on the VM."
    }

    Write-Host "Exec REPL session closed." -ForegroundColor Green
}

# Handles Resolve-AzVmToggleValue.
function Resolve-AzVmToggleValue {
    param(
        [string]$Name,
        [string]$RawValue
    )

    $value = if ($null -eq $RawValue) { '' } else { [string]$RawValue }
    $normalized = $value.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace([string]$normalized)) {
        return ''
    }

    if ($normalized -in @('on','true','1','yes','y')) {
        return 'on'
    }
    if ($normalized -in @('off','false','0','no','n')) {
        return 'off'
    }

    Throw-FriendlyError `
        -Detail ("Invalid value '{0}' for --{1}." -f $RawValue, $Name) `
        -Code 62 `
        -Summary "Invalid toggle value." `
        -Hint ("Use --{0}=on|off." -f $Name)
}

# Handles Read-AzVmToggleInteractive.
function Read-AzVmToggleInteractive {
    param(
        [string]$PromptText,
        [string]$DefaultValue = 'off'
    )

    $defaultNormalized = Resolve-AzVmToggleValue -Name 'toggle' -RawValue $DefaultValue
    if ([string]::IsNullOrWhiteSpace([string]$defaultNormalized)) {
        $defaultNormalized = 'off'
    }

    while ($true) {
        $raw = Read-Host ("{0} (on/off, default={1})" -f $PromptText, $defaultNormalized)
        if ([string]::IsNullOrWhiteSpace([string]$raw)) {
            return $defaultNormalized
        }
        $candidate = Resolve-AzVmToggleValue -Name 'toggle' -RawValue $raw
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
            return $candidate
        }
    }
}

# Handles Copy-AzVmOptionsMap.
function Copy-AzVmOptionsMap {
    param(
        [hashtable]$Source
    )

    $copy = @{}
    if ($null -eq $Source) {
        return $copy
    }
    foreach ($key in @($Source.Keys)) {
        $copy[[string]$key] = $Source[$key]
    }
    return $copy
}

# Handles Invoke-AzVmMoveCommand.
function Invoke-AzVmMoveCommand {
    param(
        [hashtable]$Options,
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    if (Test-AzVmCliOptionPresent -Options $Options -Name 'vm-size') {
        Throw-FriendlyError `
            -Detail "Option '--vm-size' is not supported with move command." `
            -Code 62 `
            -Summary "Unsupported option for move command." `
            -Hint "Use resize command for VM size updates."
    }

    $forwardOptions = Copy-AzVmOptionsMap -Source $Options
    if (-not (Test-AzVmCliOptionPresent -Options $forwardOptions -Name 'vm-region')) {
        $forwardOptions['vm-region'] = ''
    }

    $regionValue = [string](Get-AzVmCliOptionText -Options $forwardOptions -Name 'vm-region')
    $effectiveAutoMode = $AutoMode -or (-not [string]::IsNullOrWhiteSpace([string]$regionValue))
    Invoke-AzVmChangeCommand -Options $forwardOptions -AutoMode:$effectiveAutoMode -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -OperationLabel 'move'
}

# Handles Invoke-AzVmResizeCommand.
function Invoke-AzVmResizeCommand {
    param(
        [hashtable]$Options,
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    if (Test-AzVmCliOptionPresent -Options $Options -Name 'vm-region') {
        Throw-FriendlyError `
            -Detail "Option '--vm-region' is not supported with resize command." `
            -Code 62 `
            -Summary "Unsupported option for resize command." `
            -Hint "Use move command for region changes."
    }

    $forwardOptions = Copy-AzVmOptionsMap -Source $Options
    if (-not (Test-AzVmCliOptionPresent -Options $forwardOptions -Name 'vm-size')) {
        $forwardOptions['vm-size'] = ''
    }

    $sizeValue = [string](Get-AzVmCliOptionText -Options $forwardOptions -Name 'vm-size')
    $effectiveAutoMode = $AutoMode -or (-not [string]::IsNullOrWhiteSpace([string]$sizeValue))
    Invoke-AzVmChangeCommand -Options $forwardOptions -AutoMode:$effectiveAutoMode -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -OperationLabel 'resize'
}

# Handles Invoke-AzVmSetCommand.
function Invoke-AzVmSetCommand {
    param(
        [hashtable]$Options,
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    $runtimeConfigOverrides = @{}
    $groupOption = [string](Get-AzVmCliOptionText -Options $Options -Name 'group')
    if (-not [string]::IsNullOrWhiteSpace([string]$groupOption)) {
        $runtimeConfigOverrides['RESOURCE_GROUP'] = $groupOption.Trim()
    }
    $vmOption = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm')
    if (-not [string]::IsNullOrWhiteSpace([string]$vmOption)) {
        $runtimeConfigOverrides['VM_NAME'] = $vmOption.Trim()
    }

    $runtime = Initialize-AzVmCommandRuntimeContext -AutoMode:$true -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -ConfigMapOverrides $runtimeConfigOverrides
    $context = $runtime.Context

    $resourceGroup = Resolve-AzVmTargetResourceGroup `
        -Options $Options `
        -AutoMode:$AutoMode `
        -DefaultResourceGroup ([string]$context.ResourceGroup) `
        -ServerName ([string]$context.ServerName) `
        -OperationName 'set'

    $vmName = [string]$vmOption
    if ([string]::IsNullOrWhiteSpace([string]$vmName)) {
        $vmName = Resolve-AzVmTargetVmName -ResourceGroup $resourceGroup -DefaultVmName ([string]$context.VmName) -AutoMode:$AutoMode -OperationName 'set'
    }

    $vmExists = Test-AzVmAzResourceExists -AzArgs @("vm", "show", "-g", $resourceGroup, "-n", $vmName)
    if (-not $vmExists) {
        Throw-FriendlyError `
            -Detail ("VM '{0}' was not found in resource group '{1}'." -f $vmName, $resourceGroup) `
            -Code 62 `
            -Summary "Set command cannot continue because VM was not found." `
            -Hint "Select an existing VM or run create first."
    }

    $hasHibernation = Test-AzVmCliOptionPresent -Options $Options -Name 'hibernation'
    $hasNested = Test-AzVmCliOptionPresent -Options $Options -Name 'nested-virtualization'
    $hibernationTarget = ''
    $nestedTarget = ''

    if ($hasHibernation) {
        $hibernationTarget = Resolve-AzVmToggleValue -Name 'hibernation' -RawValue ([string](Get-AzVmCliOptionText -Options $Options -Name 'hibernation'))
    }
    if ($hasNested) {
        $nestedTarget = Resolve-AzVmToggleValue -Name 'nested-virtualization' -RawValue ([string](Get-AzVmCliOptionText -Options $Options -Name 'nested-virtualization'))
    }

    if ($AutoMode -and -not $hasHibernation -and -not $hasNested) {
        Throw-FriendlyError `
            -Detail "Auto mode requires at least one set target (--hibernation or --nested-virtualization)." `
            -Code 62 `
            -Summary "Set command has no update target in auto mode." `
            -Hint "Provide --hibernation=on|off and/or --nested-virtualization=on|off."
    }

    if (-not $hasHibernation -and -not $hasNested) {
        Write-Host "Set command interactive mode: select feature values." -ForegroundColor Cyan
        $hibernationTarget = Read-AzVmToggleInteractive -PromptText "Set hibernation"
        $nestedTarget = Read-AzVmToggleInteractive -PromptText "Set nested virtualization"
        $hasHibernation = $true
        $hasNested = $true
    }
    elseif ($hasHibernation -and [string]::IsNullOrWhiteSpace([string]$hibernationTarget)) {
        if ($AutoMode) {
            Throw-FriendlyError `
                -Detail "Option '--hibernation' was provided without a value in auto mode." `
                -Code 62 `
                -Summary "Set command cannot continue in auto mode." `
                -Hint "Use --hibernation=on|off."
        }
        $hibernationTarget = Read-AzVmToggleInteractive -PromptText "Set hibernation"
    }
    elseif ($hasNested -and [string]::IsNullOrWhiteSpace([string]$nestedTarget)) {
        if ($AutoMode) {
            Throw-FriendlyError `
                -Detail "Option '--nested-virtualization' was provided without a value in auto mode." `
                -Code 62 `
                -Summary "Set command cannot continue in auto mode." `
                -Hint "Use --nested-virtualization=on|off."
        }
        $nestedTarget = Read-AzVmToggleInteractive -PromptText "Set nested virtualization"
    }

    if (-not $hasHibernation -and -not $hasNested) {
        Write-Host "No set operation was requested." -ForegroundColor Yellow
        return
    }

    if ($hasHibernation) {
        $hibernationBool = if ([string]::Equals($hibernationTarget, 'on', [System.StringComparison]::OrdinalIgnoreCase)) { 'true' } else { 'false' }
        Invoke-TrackedAction -Label ("az vm update -g {0} -n {1} --enable-hibernation {2}" -f $resourceGroup, $vmName, $hibernationBool) -Action {
            az vm update -g $resourceGroup -n $vmName --enable-hibernation $hibernationBool -o none --only-show-errors
            Assert-LastExitCode "az vm update --enable-hibernation"
        } | Out-Null
    }

    if ($hasNested) {
        $nestedBool = if ([string]::Equals($nestedTarget, 'on', [System.StringComparison]::OrdinalIgnoreCase)) { 'true' } else { 'false' }
        try {
            Invoke-TrackedAction -Label ("az vm update -g {0} -n {1} --set additionalCapabilities.nestedVirtualization={2}" -f $resourceGroup, $vmName, $nestedBool) -Action {
                az vm update -g $resourceGroup -n $vmName --set ("additionalCapabilities.nestedVirtualization={0}" -f $nestedBool) -o none --only-show-errors
                Assert-LastExitCode "az vm update --set additionalCapabilities.nestedVirtualization"
            } | Out-Null
        }
        catch {
            Throw-FriendlyError `
                -Detail ("Nested virtualization update failed via Azure API: {0}" -f $_.Exception.Message) `
                -Code 62 `
                -Summary "Nested virtualization setting could not be applied." `
                -Hint "Check VM SKU/API support for nested virtualization, then retry."
        }
    }

    Write-Host ("Set command completed for VM '{0}' in resource group '{1}'." -f $vmName, $resourceGroup) -ForegroundColor Green
}

# Handles Invoke-AzVmChangeCommand.
function Invoke-AzVmChangeCommand {
    param(
        [hashtable]$Options,
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag,
        [string]$OperationLabel = 'move/resize'
    )

    $runtimeConfigOverrides = @{}
    $groupOptionValue = [string](Get-AzVmCliOptionText -Options $Options -Name 'group')
    if (-not [string]::IsNullOrWhiteSpace([string]$groupOptionValue)) {
        $runtimeConfigOverrides['RESOURCE_GROUP'] = $groupOptionValue.Trim()
    }
    $vmOptionValue = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm')
    if (-not [string]::IsNullOrWhiteSpace([string]$vmOptionValue)) {
        $runtimeConfigOverrides['VM_NAME'] = $vmOptionValue.Trim()
    }

    $runtime = Initialize-AzVmCommandRuntimeContext -AutoMode:$AutoMode -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -ConfigMapOverrides $runtimeConfigOverrides
    $context = $runtime.Context
    $platform = [string]$runtime.Platform
    $envFilePath = [string]$runtime.EnvFilePath
    $effectiveConfigMap = $runtime.EffectiveConfigMap
    $vmSizeConfigKey = Get-AzVmPlatformVmConfigKey -Platform $platform -BaseKey "VM_SIZE"
    $resourceGroup = [string]$context.ResourceGroup
    $vmName = [string]$context.VmName
    $groupWasProvided = -not [string]::IsNullOrWhiteSpace([string]$groupOptionValue)
    $vmWasProvided = -not [string]::IsNullOrWhiteSpace([string]$vmOptionValue)

    $resourceGroup = Resolve-AzVmTargetResourceGroup `
        -Options $Options `
        -AutoMode:$AutoMode `
        -DefaultResourceGroup $resourceGroup `
        -ServerName ([string]$context.ServerName) `
        -OperationName $OperationLabel
    $context.ResourceGroup = $resourceGroup

    if ($vmWasProvided) {
        $vmName = [string]$vmOptionValue
    }
    else {
        $vmName = Resolve-AzVmTargetVmName -ResourceGroup $resourceGroup -DefaultVmName $vmName -AutoMode:$AutoMode -OperationName $OperationLabel
    }
    $context.VmName = $vmName

    $hasRegionOption = Test-AzVmCliOptionPresent -Options $Options -Name 'vm-region'
    $hasSizeOption = Test-AzVmCliOptionPresent -Options $Options -Name 'vm-size'
    $targetRegion = ''
    $targetSize = ''

    if (-not $hasRegionOption -and -not $hasSizeOption) {
        if ($AutoMode) {
            Throw-FriendlyError `
                -Detail ("{0} command requires at least one target value in non-interactive mode." -f $OperationLabel) `
                -Code 62 `
                -Summary "No target value was provided." `
                -Hint "Use --vm-region=<region> and/or --vm-size=<sku>."
        }

        $selectedResourceGroup = Select-AzVmResourceGroupInteractive -DefaultResourceGroup $resourceGroup -ServerName ([string]$context.ServerName)
        $selectedVmName = Select-AzVmVmInteractive -ResourceGroup $selectedResourceGroup -DefaultVmName $vmName

        if (-not [string]::Equals($selectedResourceGroup, $resourceGroup, [System.StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals($selectedVmName, $vmName, [System.StringComparison]::OrdinalIgnoreCase)) {
            $runtime = Initialize-AzVmCommandRuntimeContext `
                -AutoMode:$AutoMode `
                -WindowsFlag:$WindowsFlag `
                -LinuxFlag:$LinuxFlag `
                -ConfigMapOverrides @{
                    RESOURCE_GROUP = $selectedResourceGroup
                    VM_NAME = $selectedVmName
                }
            $context = $runtime.Context
            $envFilePath = [string]$runtime.EnvFilePath
            $effectiveConfigMap = $runtime.EffectiveConfigMap
            $resourceGroup = [string]$context.ResourceGroup
            $vmName = [string]$context.VmName
        }
    }

    $vmJson = az vm show -g $resourceGroup -n $vmName -o json --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$vmJson)) {
        Throw-FriendlyError `
            -Detail ("VM '{0}' was not found in resource group '{1}'." -f $vmName, $resourceGroup) `
            -Code 62 `
            -Summary ("{0} command cannot continue because VM does not exist." -f $OperationLabel) `
            -Hint "Run 'az-vm create' first, or check active naming values in .env."
    }

    $vmObject = ConvertFrom-JsonCompat -InputObject $vmJson
    $currentRegion = [string]$vmObject.location
    $currentSize = [string]$vmObject.hardwareProfile.vmSize
    if ([string]::IsNullOrWhiteSpace($currentRegion)) { $currentRegion = [string]$context.AzLocation }
    if ([string]::IsNullOrWhiteSpace($currentSize)) { $currentSize = [string]$context.VmSize }

    if ($hasRegionOption) {
        $targetRegion = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-region')
        if ([string]::IsNullOrWhiteSpace($targetRegion)) {
            if ($AutoMode) {
                Throw-FriendlyError `
                    -Detail "Option '--vm-region' was provided without a value in auto mode." `
                    -Code 62 `
                    -Summary "Region value is required in auto mode." `
                    -Hint "Provide --vm-region=<azure-region>."
            }
            $targetRegion = Select-AzLocationInteractive -DefaultLocation $currentRegion
        }
    }

    if ($hasSizeOption) {
        $targetSize = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-size')
        if ([string]::IsNullOrWhiteSpace($targetSize)) {
            if ($AutoMode) {
                Throw-FriendlyError `
                    -Detail "Option '--vm-size' was provided without a value in auto mode." `
                    -Code 62 `
                    -Summary "VM size value is required in auto mode." `
                    -Hint "Provide --vm-size=<vm-sku>."
            }

            $pickerLocation = $currentRegion
            if (-not [string]::IsNullOrWhiteSpace($targetRegion)) {
                $pickerLocation = $targetRegion
            }
            $priceHours = Get-PriceHoursFromConfig -Config $effectiveConfigMap -DefaultHours 730
            while ($true) {
                $sizePick = Select-VmSkuInteractive -Location $pickerLocation -DefaultVmSize $currentSize -PriceHours $priceHours
                if ([string]::Equals([string]$sizePick, (Get-AzVmSkuPickerRegionBackToken), [System.StringComparison]::Ordinal)) {
                    $pickerLocation = Select-AzLocationInteractive -DefaultLocation $pickerLocation
                    if (-not $hasRegionOption) {
                        $targetRegion = $pickerLocation
                    }
                    continue
                }
                $targetSize = [string]$sizePick
                break
            }
        }
    }

    if (-not $hasRegionOption -and -not $hasSizeOption) {
        $targetRegion = Select-AzLocationInteractive -DefaultLocation $currentRegion
        $hasRegionOption = $true
        $priceHours = Get-PriceHoursFromConfig -Config $effectiveConfigMap -DefaultHours 730
        while ($true) {
            $sizePick = Select-VmSkuInteractive -Location $targetRegion -DefaultVmSize $currentSize -PriceHours $priceHours
            if ([string]::Equals([string]$sizePick, (Get-AzVmSkuPickerRegionBackToken), [System.StringComparison]::Ordinal)) {
                $targetRegion = Select-AzLocationInteractive -DefaultLocation $targetRegion
                continue
            }
            $targetSize = [string]$sizePick
            $hasSizeOption = $true
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($targetRegion)) { $targetRegion = $currentRegion }
    if ([string]::IsNullOrWhiteSpace($targetSize)) { $targetSize = $currentSize }
    $targetRegion = $targetRegion.Trim().ToLowerInvariant()
    $targetSize = $targetSize.Trim()

    Assert-LocationExists -Location $targetRegion
    Assert-VmSkuAvailableViaRest -Location $targetRegion -VmSize $targetSize

    $regionChanged = -not [string]::Equals($targetRegion, $currentRegion, [System.StringComparison]::OrdinalIgnoreCase)
    $sizeChanged = -not [string]::Equals($targetSize, $currentSize, [System.StringComparison]::OrdinalIgnoreCase)
    if (-not $regionChanged -and -not $sizeChanged) {
        Write-Host ("No effective {0} operation is required. Region and VM size are already at target values." -f $OperationLabel) -ForegroundColor Yellow
        return
    }

    $regionMoveApplied = $false
    $activeResourceGroup = $resourceGroup
    $activeVmName = $vmName

    if ($regionChanged) {
        Write-Host "Applying snapshot-based region migration."
        Write-Host ("Current: region={0}, size={1}, rg={2}" -f $currentRegion, $currentSize, $resourceGroup)
        Write-Host ("Target : region={0}, size={1}" -f $targetRegion, $targetSize)

        if (-not $AutoMode) {
            $approveRegionMove = Confirm-YesNo -PromptText "Continue with snapshot-based region migration?" -DefaultYes $false
            if (-not $approveRegionMove) {
                Write-Host ("{0} command canceled by user." -f $OperationLabel) -ForegroundColor Yellow
                return
            }
        }

        $sourceOsDiskId = [string]$vmObject.storageProfile.osDisk.managedDisk.id
        if ([string]::IsNullOrWhiteSpace([string]$sourceOsDiskId)) {
            Throw-FriendlyError `
                -Detail "Source VM OS disk id could not be resolved." `
                -Code 62 `
                -Summary "Region move cannot continue." `
                -Hint "Check VM storage profile and retry."
        }

        $dataDisks = @($vmObject.storageProfile.dataDisks)
        if ($dataDisks.Count -gt 0) {
            Throw-FriendlyError `
                -Detail ("Attached data disk count: {0}." -f $dataDisks.Count) `
                -Code 62 `
                -Summary "Snapshot region move currently supports OS disk only." `
                -Hint "Detach/migrate data disks separately, then retry."
        }

        $sourceDiskJson = az disk show --ids $sourceOsDiskId -o json --only-show-errors
        Assert-LastExitCode "az disk show (source os disk)"
        $sourceDisk = ConvertFrom-JsonCompat -InputObject $sourceDiskJson
        $sourceDiskSku = [string]$sourceDisk.sku.name
        $sourceOsType = [string]$sourceDisk.osType
        if ([string]::IsNullOrWhiteSpace([string]$sourceDiskSku)) { $sourceDiskSku = "StandardSSD_LRS" }
        if ([string]::IsNullOrWhiteSpace([string]$sourceOsType)) { $sourceOsType = "Windows" }

        $targetRegionCode = Get-AzVmRegionCode -Location $targetRegion
        $nameTokens = @{
            SERVER_NAME = [string]$context.ServerName
            REGION_CODE = [string]$targetRegionCode
        }

        $targetResourceGroupTemplate = [string](Get-ConfigValue -Config $effectiveConfigMap -Key "RESOURCE_GROUP_TEMPLATE" -DefaultValue "rg-{SERVER_NAME}-{REGION_CODE}-g{N}")
        $targetResourceGroup = Resolve-AzVmResourceGroupNameFromTemplate `
            -Template (Resolve-ServerTemplate -Value $targetResourceGroupTemplate -ServerName ([string]$context.ServerName)) `
            -ServerName ([string]$context.ServerName) `
            -RegionCode $targetRegionCode `
            -UseNextIndex

        $targetVmTemplate = [string](Get-ConfigValue -Config $effectiveConfigMap -Key "VM_NAME_TEMPLATE" -DefaultValue "vm-{SERVER_NAME}-{REGION_CODE}-n{N}")
        $targetDiskTemplate = [string](Get-ConfigValue -Config $effectiveConfigMap -Key "VM_DISK_NAME_TEMPLATE" -DefaultValue "disk-{SERVER_NAME}-{REGION_CODE}-n{N}")
        $targetVnetTemplate = [string](Get-ConfigValue -Config $effectiveConfigMap -Key "VNET_NAME_TEMPLATE" -DefaultValue "net-{SERVER_NAME}-{REGION_CODE}-n{N}")
        $targetSubnetTemplate = [string](Get-ConfigValue -Config $effectiveConfigMap -Key "SUBNET_NAME_TEMPLATE" -DefaultValue "subnet-{SERVER_NAME}-{REGION_CODE}-n{N}")
        $targetNsgTemplate = [string](Get-ConfigValue -Config $effectiveConfigMap -Key "NSG_NAME_TEMPLATE" -DefaultValue "nsg-{SERVER_NAME}-{REGION_CODE}-n{N}")
        $targetNsgRuleTemplate = [string](Get-ConfigValue -Config $effectiveConfigMap -Key "NSG_RULE_NAME_TEMPLATE" -DefaultValue "nsgrule-{SERVER_NAME}-{REGION_CODE}-n{N}")
        $targetIpTemplate = [string](Get-ConfigValue -Config $effectiveConfigMap -Key "PUBLIC_IP_NAME_TEMPLATE" -DefaultValue "ip-{SERVER_NAME}-{REGION_CODE}-n{N}")
        $targetNicTemplate = [string](Get-ConfigValue -Config $effectiveConfigMap -Key "NIC_NAME_TEMPLATE" -DefaultValue "nic-{SERVER_NAME}-{REGION_CODE}-n{N}")

        $targetVmName = Resolve-AzVmNameFromTemplate -Template $targetVmTemplate -ResourceType 'vm' -ServerName ([string]$context.ServerName) -RegionCode $targetRegionCode -ResourceGroup $targetResourceGroup -UseNextIndex
        $targetDiskName = Resolve-AzVmNameFromTemplate -Template $targetDiskTemplate -ResourceType 'disk' -ServerName ([string]$context.ServerName) -RegionCode $targetRegionCode -ResourceGroup $targetResourceGroup -UseNextIndex
        $targetVnetName = Resolve-AzVmNameFromTemplate -Template $targetVnetTemplate -ResourceType 'net' -ServerName ([string]$context.ServerName) -RegionCode $targetRegionCode -ResourceGroup $targetResourceGroup -UseNextIndex
        $targetSubnetName = Resolve-AzVmNameFromTemplate -Template $targetSubnetTemplate -ResourceType 'subnet' -ServerName ([string]$context.ServerName) -RegionCode $targetRegionCode -ResourceGroup $targetResourceGroup -UseNextIndex
        $targetNsgName = Resolve-AzVmNameFromTemplate -Template $targetNsgTemplate -ResourceType 'nsg' -ServerName ([string]$context.ServerName) -RegionCode $targetRegionCode -ResourceGroup $targetResourceGroup -UseNextIndex
        $targetNsgRuleName = Resolve-AzVmNameFromTemplate -Template $targetNsgRuleTemplate -ResourceType 'nsgrule' -ServerName ([string]$context.ServerName) -RegionCode $targetRegionCode -ResourceGroup $targetResourceGroup -UseNextIndex
        $targetIpName = Resolve-AzVmNameFromTemplate -Template $targetIpTemplate -ResourceType 'ip' -ServerName ([string]$context.ServerName) -RegionCode $targetRegionCode -ResourceGroup $targetResourceGroup -UseNextIndex
        $targetNicName = Resolve-AzVmNameFromTemplate -Template $targetNicTemplate -ResourceType 'nic' -ServerName ([string]$context.ServerName) -RegionCode $targetRegionCode -ResourceGroup $targetResourceGroup -UseNextIndex

        Write-Host ("Target naming resolved: rg={0}, vm={1}, disk={2}" -f $targetResourceGroup, $targetVmName, $targetDiskName)

        $targetGroupCreatedInRun = $false
        $sourceSnapshotName = ''
        $targetSnapshotName = ''
        $sourceSnapshotCreated = $false
        $targetSnapshotCreated = $false
        $targetVmCreated = $false
        $targetDiskCreated = $false
        $targetNetworkAttempted = $false

        $cleanupTarget = {
            param([string]$Reason)
            Write-Host ("Region move cleanup started. Reason: {0}" -f $Reason) -ForegroundColor Yellow

            if ($targetVmCreated) {
                az vm delete -g $targetResourceGroup -n $targetVmName --yes -o none --only-show-errors 2>$null
            }
            if ($targetDiskCreated) {
                az disk delete -g $targetResourceGroup -n $targetDiskName --yes -o none --only-show-errors 2>$null
            }

            if ($targetNetworkAttempted) {
                az network nic delete -g $targetResourceGroup -n $targetNicName --only-show-errors 2>$null
                az network public-ip delete -g $targetResourceGroup -n $targetIpName --only-show-errors 2>$null
                az network nsg delete -g $targetResourceGroup -n $targetNsgName --only-show-errors 2>$null
                az network vnet delete -g $targetResourceGroup -n $targetVnetName --only-show-errors 2>$null
            }

            if ($targetSnapshotCreated -and -not [string]::IsNullOrWhiteSpace([string]$targetSnapshotName)) {
                az snapshot delete -g $targetResourceGroup -n $targetSnapshotName --only-show-errors 2>$null
            }
            if ($sourceSnapshotCreated -and -not [string]::IsNullOrWhiteSpace([string]$sourceSnapshotName)) {
                az snapshot delete -g $resourceGroup -n $sourceSnapshotName --only-show-errors 2>$null
            }
        }

        try {
            $targetGroupExists = az group exists -n $targetResourceGroup --only-show-errors
            Assert-LastExitCode "az group exists (target)"
            if (-not [string]::Equals([string]$targetGroupExists, "true", [System.StringComparison]::OrdinalIgnoreCase)) {
                Invoke-TrackedAction -Label ("az group create -n {0} -l {1}" -f $targetResourceGroup, $targetRegion) -Action {
                    az group create -n $targetResourceGroup -l $targetRegion --tags ("{0}={1}" -f [string]$script:ManagedByTagKey, [string]$script:ManagedByTagValue) -o none --only-show-errors
                    Assert-LastExitCode "az group create (target)"
                } | Out-Null
                $targetGroupCreatedInRun = $true
            }
            Set-AzVmManagedTagOnResourceGroup -ResourceGroup $targetResourceGroup

            $stamp = Get-Date -Format "yyMMddHHmmss"
            $sourceSnapshotName = ("snap-src-{0}-{1}" -f [string]$context.ServerName, $stamp)
            $targetSnapshotName = ("snap-dst-{0}-{1}" -f [string]$context.ServerName, $stamp)

            Invoke-TrackedAction -Label ("az snapshot create source incremental {0}" -f $sourceSnapshotName) -Action {
                az snapshot create -g $resourceGroup -n $sourceSnapshotName --source $sourceOsDiskId --location $currentRegion --incremental true --sku Standard_LRS -o none --only-show-errors
                Assert-LastExitCode "az snapshot create (source)"
            } | Out-Null
            $sourceSnapshotCreated = $true

            $sourceSnapshotId = az snapshot show -g $resourceGroup -n $sourceSnapshotName --query "id" -o tsv --only-show-errors
            Assert-LastExitCode "az snapshot show (source id)"
            if ([string]::IsNullOrWhiteSpace([string]$sourceSnapshotId)) { throw "Source snapshot id could not be resolved." }

            Invoke-TrackedAction -Label ("az snapshot create target copy-start {0}" -f $targetSnapshotName) -Action {
                az snapshot create -g $targetResourceGroup -n $targetSnapshotName --source $sourceSnapshotId --location $targetRegion --incremental true --sku Standard_LRS --copy-start true -o none --only-show-errors
                Assert-LastExitCode "az snapshot create (target)"
            } | Out-Null
            $targetSnapshotCreated = $true

            $copyMaxAttempts = 540
            $copyDelaySeconds = 20
            for ($copyAttempt = 1; $copyAttempt -le $copyMaxAttempts; $copyAttempt++) {
                $copyStateJson = az snapshot show -g $targetResourceGroup -n $targetSnapshotName --query "{provisioningState:provisioningState,snapshotAccessState:snapshotAccessState,completionPercent:completionPercent}" -o json --only-show-errors
                Assert-LastExitCode "az snapshot show (target copy state)"
                $copyState = ConvertFrom-JsonCompat -InputObject $copyStateJson
                $prov = [string]$copyState.provisioningState
                $acc = [string]$copyState.snapshotAccessState
                $pct = 0.0
                if ($null -ne $copyState.completionPercent) { $pct = [double]$copyState.completionPercent }
                Write-Host ("Target snapshot copy {0}/{1}: provisioningState={2}, accessState={3}, completionPercent={4:N1}" -f $copyAttempt, $copyMaxAttempts, $prov, $acc, $pct)
                if ([string]::Equals($prov, "Succeeded", [System.StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($acc, "Available", [System.StringComparison]::OrdinalIgnoreCase) -and $pct -ge 100.0) { break }
                if ($copyAttempt -ge $copyMaxAttempts) { throw "Target snapshot copy did not complete in expected time." }
                Start-Sleep -Seconds $copyDelaySeconds
            }

            $targetSnapshotId = az snapshot show -g $targetResourceGroup -n $targetSnapshotName --query "id" -o tsv --only-show-errors
            Assert-LastExitCode "az snapshot show (target id)"
            if ([string]::IsNullOrWhiteSpace([string]$targetSnapshotId)) { throw "Target snapshot id could not be resolved." }

            $targetContext = [ordered]@{
                ResourceGroup = $targetResourceGroup
                AzLocation = $targetRegion
                VNET = $targetVnetName
                SUBNET = $targetSubnetName
                NSG = $targetNsgName
                NsgRule = $targetNsgRuleName
                IP = $targetIpName
                NIC = $targetNicName
                TcpPorts = @($context.TcpPorts)
                VmName = $targetVmName
            }
            Invoke-AzVmNetworkStep -Context $targetContext -ExecutionMode "update"
            $targetNetworkAttempted = $true

            Invoke-TrackedAction -Label ("az disk create -g {0} -n {1}" -f $targetResourceGroup, $targetDiskName) -Action {
                $diskArgs = @("disk", "create", "-g", $targetResourceGroup, "-n", $targetDiskName, "--source", $targetSnapshotId, "--location", $targetRegion, "--sku", $sourceDiskSku, "--os-type", $sourceOsType, "-o", "none", "--only-show-errors")
                az @diskArgs
                Assert-LastExitCode "az disk create (target)"
            } | Out-Null
            $targetDiskCreated = $true

            $targetCreateJson = Invoke-TrackedAction -Label ("az vm create -g {0} -n {1} --attach-os-disk" -f $targetResourceGroup, $targetVmName) -Action {
                $vmCreateArgs = @("vm", "create", "--resource-group", $targetResourceGroup, "--name", $targetVmName, "--attach-os-disk", $targetDiskName, "--os-type", $sourceOsType, "--size", $currentSize, "--admin-username", [string]$context.VmUser, "--admin-password", [string]$context.VmPass, "--authentication-type", "password", "--nics", $targetNicName, "-o", "json", "--only-show-errors")
                az @vmCreateArgs
            }
            Assert-LastExitCode "az vm create (target attach-os-disk)"
            $targetCreateObj = ConvertFrom-JsonCompat -InputObject $targetCreateJson
            if (-not $targetCreateObj.id) { throw "Target VM creation returned no VM id." }
            $targetVmCreated = $true

            if (-not [string]::Equals([string]$targetSize, [string]$currentSize, [System.StringComparison]::OrdinalIgnoreCase)) {
                Invoke-TrackedAction -Label ("az vm deallocate -g {0} -n {1}" -f $targetResourceGroup, $targetVmName) -Action {
                    az vm deallocate -g $targetResourceGroup -n $targetVmName -o none --only-show-errors
                    Assert-LastExitCode "az vm deallocate (target)"
                } | Out-Null
                $targetDeallocated = Wait-AzVmVmPowerState -ResourceGroup $targetResourceGroup -VmName $targetVmName -DesiredPowerState "VM deallocated" -MaxAttempts 18 -DelaySeconds 10
                if (-not $targetDeallocated) { throw "Target VM did not reach deallocated state before resize." }

                Invoke-TrackedAction -Label ("az vm resize -g {0} -n {1} --size {2}" -f $targetResourceGroup, $targetVmName, $targetSize) -Action {
                    az vm resize -g $targetResourceGroup -n $targetVmName --size $targetSize -o none --only-show-errors
                    Assert-LastExitCode "az vm resize (target)"
                } | Out-Null
                $currentSize = $targetSize
            }

            Invoke-TrackedAction -Label ("az vm start -g {0} -n {1}" -f $targetResourceGroup, $targetVmName) -Action {
                az vm start -g $targetResourceGroup -n $targetVmName -o none --only-show-errors
                Assert-LastExitCode "az vm start (target)"
            } | Out-Null
            $targetRunning = Wait-AzVmVmRunningState -ResourceGroup $targetResourceGroup -VmName $targetVmName -MaxAttempts 6 -DelaySeconds 10
            if (-not $targetRunning) { throw "Target VM did not reach running state after migration." }

            if ($targetSnapshotCreated -and -not [string]::IsNullOrWhiteSpace([string]$targetSnapshotName)) { az snapshot delete -g $targetResourceGroup -n $targetSnapshotName --only-show-errors 2>$null }
            if ($sourceSnapshotCreated -and -not [string]::IsNullOrWhiteSpace([string]$sourceSnapshotName)) { az snapshot delete -g $resourceGroup -n $sourceSnapshotName --only-show-errors 2>$null }

            $activeResourceGroup = $targetResourceGroup
            $activeVmName = $targetVmName
            $resourceGroup = $targetResourceGroup
            $vmName = $targetVmName
            $currentRegion = $targetRegion
            $regionMoveApplied = $true

            $context.ResourceGroup = $targetResourceGroup
            $context.AzLocation = $targetRegion
            $context.RegionCode = $targetRegionCode
            $context.VmName = $targetVmName
            $context.VmDiskName = $targetDiskName
            $context.VNET = $targetVnetName
            $context.SUBNET = $targetSubnetName
            $context.NSG = $targetNsgName
            $context.NsgRule = $targetNsgRuleName
            $context.IP = $targetIpName
            $context.NIC = $targetNicName

            Write-Host ("Region migration completed. Active target -> rg={0}, vm={1}" -f $activeResourceGroup, $activeVmName) -ForegroundColor Green
        }
        catch {
            $innerError = $_
            & $cleanupTarget -Reason ([string]$innerError.Exception.Message)
            Throw-FriendlyError `
                -Detail ("Snapshot-based region migration failed. Cleanup completed. Error: {0}" -f $innerError.Exception.Message) `
                -Code 62 `
                -Summary "Region move failed and target-side artifacts were rolled back." `
                -Hint ("Review failure detail, then retry {0} command." -f $OperationLabel)
        }
    }

    $sizeChangedAfterRegion = -not [string]::Equals([string]$currentSize, [string]$targetSize, [System.StringComparison]::OrdinalIgnoreCase)
    if ($sizeChangedAfterRegion) {
        Write-Host ("Applying VM size update: {0} -> {1}" -f $currentSize, $targetSize)
        if (-not $AutoMode -and -not $regionMoveApplied) {
            $approveResize = Confirm-YesNo -PromptText "Continue with VM size change?" -DefaultYes $false
            if (-not $approveResize) {
                Write-Host ("{0} command canceled by user." -f $OperationLabel) -ForegroundColor Yellow
                return
            }
        }

        Invoke-TrackedAction -Label ("az vm deallocate -g {0} -n {1}" -f $activeResourceGroup, $activeVmName) -Action {
            az vm deallocate -g $activeResourceGroup -n $activeVmName -o none --only-show-errors
            Assert-LastExitCode "az vm deallocate"
        } | Out-Null
        $deallocated = Wait-AzVmVmPowerState -ResourceGroup $activeResourceGroup -VmName $activeVmName -DesiredPowerState "VM deallocated" -MaxAttempts 18 -DelaySeconds 10
        if (-not $deallocated) {
            Throw-FriendlyError `
                -Detail ("VM '{0}' did not reach deallocated state in expected time." -f $activeVmName) `
                -Code 62 `
                -Summary "VM size change stopped because VM deallocation was not confirmed." `
                -Hint ("Check VM power state in Azure and retry {0} command." -f $OperationLabel)
        }

        Invoke-TrackedAction -Label ("az vm resize -g {0} -n {1} --size {2}" -f $activeResourceGroup, $activeVmName, $targetSize) -Action {
            az vm resize -g $activeResourceGroup -n $activeVmName --size $targetSize -o none --only-show-errors
            Assert-LastExitCode "az vm resize"
        } | Out-Null
        $currentSize = $targetSize
    }
    else {
        Write-Host ("VM size is already '{0}'; resize step is skipped." -f $targetSize) -ForegroundColor Yellow
    }

    Invoke-TrackedAction -Label ("az vm start -g {0} -n {1}" -f $activeResourceGroup, $activeVmName) -Action {
        az vm start -g $activeResourceGroup -n $activeVmName -o none --only-show-errors
        Assert-LastExitCode "az vm start"
    } | Out-Null

    $running = Wait-AzVmVmRunningState -ResourceGroup $activeResourceGroup -VmName $activeVmName -MaxAttempts 3 -DelaySeconds 10
    if (-not $running) {
        Throw-FriendlyError `
            -Detail ("VM did not return to running state after {0} operation." -f $OperationLabel) `
            -Code 62 `
            -Summary ("{0} command completed with unhealthy VM power state." -f $OperationLabel) `
            -Hint "Check VM power state in Azure Portal and start VM manually if needed."
    }

    if ($regionMoveApplied) {
        Set-DotEnvValue -Path $envFilePath -Key 'AZ_LOCATION' -Value $targetRegion
        Set-DotEnvValue -Path $envFilePath -Key 'RESOURCE_GROUP' -Value $activeResourceGroup
        Set-DotEnvValue -Path $envFilePath -Key 'VM_NAME' -Value ([string]$context.VmName)
        Set-DotEnvValue -Path $envFilePath -Key 'VM_DISK_NAME' -Value ([string]$context.VmDiskName)
        Set-DotEnvValue -Path $envFilePath -Key 'VNET_NAME' -Value ([string]$context.VNET)
        Set-DotEnvValue -Path $envFilePath -Key 'SUBNET_NAME' -Value ([string]$context.SUBNET)
        Set-DotEnvValue -Path $envFilePath -Key 'NSG_NAME' -Value ([string]$context.NSG)
        Set-DotEnvValue -Path $envFilePath -Key 'NSG_RULE_NAME' -Value ([string]$context.NsgRule)
        Set-DotEnvValue -Path $envFilePath -Key 'PUBLIC_IP_NAME' -Value ([string]$context.IP)
        Set-DotEnvValue -Path $envFilePath -Key 'NIC_NAME' -Value ([string]$context.NIC)

        $script:ConfigOverrides['AZ_LOCATION'] = $targetRegion
        $script:ConfigOverrides['RESOURCE_GROUP'] = $activeResourceGroup
        $script:ConfigOverrides['VM_NAME'] = [string]$context.VmName
        $script:ConfigOverrides['VM_DISK_NAME'] = [string]$context.VmDiskName
        $script:ConfigOverrides['VNET_NAME'] = [string]$context.VNET
        $script:ConfigOverrides['SUBNET_NAME'] = [string]$context.SUBNET
        $script:ConfigOverrides['NSG_NAME'] = [string]$context.NSG
        $script:ConfigOverrides['NSG_RULE_NAME'] = [string]$context.NsgRule
        $script:ConfigOverrides['PUBLIC_IP_NAME'] = [string]$context.IP
        $script:ConfigOverrides['NIC_NAME'] = [string]$context.NIC
    }

    if ($sizeChangedAfterRegion) {
        Set-DotEnvValue -Path $envFilePath -Key $vmSizeConfigKey -Value $targetSize
        $script:ConfigOverrides[$vmSizeConfigKey] = $targetSize
    }

    if ($regionMoveApplied) {
        Write-Host ("Change completed successfully. Region='{0}', VM size='{1}', active resource group='{2}'." -f $targetRegion, $currentSize, $activeResourceGroup) -ForegroundColor Green
    }
    else {
        Write-Host ("Change completed successfully. VM size is now '{0}'." -f $targetSize) -ForegroundColor Green
    }
}

# Handles Invoke-AzVmAzJsonOrNull.
function Invoke-AzVmAzJsonOrNull {
    param(
        [string[]]$AzArgs,
        [string]$Context,
        [switch]$SuppressError
    )

    $output = az @AzArgs
    if ($LASTEXITCODE -ne 0) {
        if ($SuppressError) {
            return $null
        }

        if ([string]::IsNullOrWhiteSpace([string]$Context)) {
            throw ("Azure command failed with exit code {0}." -f $LASTEXITCODE)
        }
        throw ("{0} failed with exit code {1}." -f $Context, $LASTEXITCODE)
    }

    if ($null -eq $output -or [string]::IsNullOrWhiteSpace([string]$output)) {
        return $null
    }

    try {
        return ConvertFrom-JsonCompat -InputObject $output
    }
    catch {
        if ($SuppressError) {
            return $null
        }

        if ([string]::IsNullOrWhiteSpace([string]$Context)) {
            throw "Azure command returned an unparseable JSON payload."
        }
        throw ("{0} returned an unparseable JSON payload." -f $Context)
    }
}

# Handles Get-AzVmResourceTypeCountMap.
function Get-AzVmResourceTypeCountMap {
    param(
        [object[]]$Resources
    )

    $counter = @{}
    foreach ($resource in @($Resources)) {
        if ($null -eq $resource) {
            continue
        }

        $typeName = [string]$resource.type
        if ([string]::IsNullOrWhiteSpace([string]$typeName)) {
            $typeName = "(unknown)"
        }

        if (-not $counter.ContainsKey($typeName)) {
            $counter[$typeName] = 0
        }
        $counter[$typeName] = [int]$counter[$typeName] + 1
    }

    $ordered = [ordered]@{}
    foreach ($key in @($counter.Keys | Sort-Object)) {
        $ordered[[string]$key] = [int]$counter[$key]
    }

    return $ordered
}

# Handles Get-AzVmVmInventoryDump.
function Get-AzVmVmInventoryDump {
    param(
        [string]$ResourceGroup,
        [string]$VmName
    )

    $vmFull = Invoke-AzVmAzJsonOrNull -AzArgs @("vm", "show", "-g", $ResourceGroup, "-n", $VmName, "-o", "json", "--only-show-errors") -Context "az vm show" -SuppressError
    if ($null -eq $vmFull) {
        return [ordered]@{
            Name = [string]$VmName
            ResourceGroup = [string]$ResourceGroup
            Error = "VM metadata could not be loaded."
        }
    }

    $vmDetailed = Invoke-AzVmAzJsonOrNull -AzArgs @("vm", "show", "-d", "-g", $ResourceGroup, "-n", $VmName, "-o", "json", "--only-show-errors") -Context "az vm show -d" -SuppressError
    $vmInstanceView = Invoke-AzVmAzJsonOrNull -AzArgs @("vm", "get-instance-view", "-g", $ResourceGroup, "-n", $VmName, "-o", "json", "--only-show-errors") -Context "az vm get-instance-view" -SuppressError

    $location = [string]$vmFull.location
    $vmSize = [string]$vmFull.hardwareProfile.vmSize
    $osType = [string]$vmFull.storageProfile.osDisk.osType
    $powerState = [string]$vmDetailed.powerState
    if ([string]::IsNullOrWhiteSpace([string]$powerState) -and $vmInstanceView) {
        foreach ($status in @(ConvertTo-ObjectArrayCompat -InputObject $vmInstanceView.statuses)) {
            $statusCode = [string]$status.code
            if ($statusCode.StartsWith("PowerState/", [System.StringComparison]::OrdinalIgnoreCase)) {
                $powerState = [string]$status.displayStatus
                if ([string]::IsNullOrWhiteSpace([string]$powerState)) {
                    $powerState = $statusCode
                }
                break
            }
        }
    }

    $osDiskName = [string]$vmFull.storageProfile.osDisk.name
    $dataDiskNames = @(
        ConvertTo-ObjectArrayCompat -InputObject $vmFull.storageProfile.dataDisks |
            ForEach-Object { [string]$_.name } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )

    $diskDetails = @()
    foreach ($diskName in @(@($osDiskName) + @($dataDiskNames) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)) {
        $diskObj = Invoke-AzVmAzJsonOrNull -AzArgs @("disk", "show", "-g", $ResourceGroup, "-n", [string]$diskName, "-o", "json", "--only-show-errors") -Context "az disk show" -SuppressError
        if ($null -ne $diskObj) {
            $diskDetails += $diskObj
        }
    }

    $nicIds = @(
        ConvertTo-ObjectArrayCompat -InputObject $vmFull.networkProfile.networkInterfaces |
            ForEach-Object { [string]$_.id } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Select-Object -Unique
    )

    $nicDetails = @()
    $publicIpIdSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($nicId in @($nicIds)) {
        $nicObj = Invoke-AzVmAzJsonOrNull -AzArgs @("network", "nic", "show", "--ids", [string]$nicId, "-o", "json", "--only-show-errors") -Context "az network nic show" -SuppressError
        if ($null -eq $nicObj) {
            continue
        }

        $nicDetails += $nicObj
        foreach ($ipCfg in @(ConvertTo-ObjectArrayCompat -InputObject $nicObj.ipConfigurations)) {
            $publicIpId = [string]$ipCfg.publicIpAddress.id
            if (-not [string]::IsNullOrWhiteSpace([string]$publicIpId)) {
                [void]$publicIpIdSet.Add($publicIpId)
            }
        }
    }

    $publicIpDetails = @()
    foreach ($publicIpId in @($publicIpIdSet | Sort-Object)) {
        $publicIpObj = Invoke-AzVmAzJsonOrNull -AzArgs @("network", "public-ip", "show", "--ids", [string]$publicIpId, "-o", "json", "--only-show-errors") -Context "az network public-ip show" -SuppressError
        if ($null -ne $publicIpObj) {
            $publicIpDetails += $publicIpObj
        }
    }

    $featureFlags = [ordered]@{
        HibernationEnabled = $vmFull.additionalCapabilities.hibernationEnabled
        NestedVirtualizationCapabilities = @()
    }

    return [ordered]@{
        Name = [string]$VmName
        ResourceGroup = [string]$ResourceGroup
        Location = [string]$location
        VmSize = [string]$vmSize
        OsType = [string]$osType
        PowerState = [string]$powerState
        ProvisioningState = [string]$vmDetailed.provisioningState
        PublicIps = [string]$vmDetailed.publicIps
        PrivateIps = [string]$vmDetailed.privateIps
        Fqdns = [string]$vmDetailed.fqdns
        Identity = $vmFull.identity
        AdditionalCapabilities = $vmFull.additionalCapabilities
        FeatureFlags = $featureFlags
        SkuName = [string]$vmSize
        SkuTier = ""
        SkuFamily = ""
        SkuAvailability = "unknown"
        SkuCapabilities = @()
        FocusedCapabilities = @()
        OsDiskName = [string]$osDiskName
        DataDiskNames = @($dataDiskNames)
        Disks = @($diskDetails)
        NicIds = @($nicIds)
        Nics = @($nicDetails)
        PublicIpResources = @($publicIpDetails)
        VmShowDetails = $vmDetailed
        InstanceView = $vmInstanceView
        VmProperties = $vmFull
    }
}

# Handles Get-AzVmSkuMetadataMap.
function Get-AzVmSkuMetadataMap {
    param(
        [string]$Location,
        [string[]]$SkuNames
    )

    $result = @{}
    if ([string]::IsNullOrWhiteSpace([string]$Location) -or -not $SkuNames -or $SkuNames.Count -eq 0) {
        return $result
    }

    $targetSkuSet = @{}
    foreach ($skuName in @($SkuNames)) {
        $nameText = [string]$skuName
        if ([string]::IsNullOrWhiteSpace([string]$nameText)) {
            continue
        }
        $targetSkuSet[$nameText.ToLowerInvariant()] = $true
    }
    if ($targetSkuSet.Count -eq 0) {
        return $result
    }

    $subscriptionId = az account show --only-show-errors --query id -o tsv
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$subscriptionId)) {
        return $result
    }

    $tokenJson = az account get-access-token --only-show-errors --resource https://management.azure.com/ -o json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$tokenJson)) {
        return $result
    }

    $accessToken = (ConvertFrom-JsonCompat -InputObject $tokenJson).accessToken
    if ([string]::IsNullOrWhiteSpace([string]$accessToken)) {
        return $result
    }

    $filter = [uri]::EscapeDataString("location eq '$Location'")
    $url = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Compute/skus?api-version=2023-07-01&`$filter=$filter"
    try {
        $response = Invoke-AzVmHttpRestMethod `
            -Method Get `
            -Uri $url `
            -Headers @{ Authorization = "Bearer $accessToken" } `
            -PerfLabel ("http compute skus metadata (location={0})" -f [string]$Location)
    }
    catch {
        return $result
    }

    foreach ($item in @((ConvertTo-ObjectArrayCompat -InputObject $response.value) | Where-Object { $_.resourceType -eq "virtualMachines" })) {
        if (-not $item.name) {
            continue
        }

        $itemName = [string]$item.name
        $itemKey = $itemName.ToLowerInvariant()
        if (-not $targetSkuSet.ContainsKey($itemKey)) {
            continue
        }

        $isUnavailable = $false
        foreach ($restriction in (ConvertTo-ObjectArrayCompat -InputObject $item.restrictions)) {
            if ($restriction.reasonCode -eq "NotAvailableForSubscription") {
                $isUnavailable = $true
                break
            }
            if ($restriction.type -eq "Location" -and (($restriction.values -and ($restriction.values -contains $Location)) -or -not $restriction.values)) {
                $isUnavailable = $true
                break
            }
        }

        $locationInfo = @(
            (ConvertTo-ObjectArrayCompat -InputObject $item.locationInfo) |
                Where-Object { $_.location -ieq $Location }
        )
        $availability = if ($isUnavailable -or -not $locationInfo) { "no" } else { "yes" }

        $skuCapabilities = @(ConvertTo-ObjectArrayCompat -InputObject $item.capabilities)
        $focusedCapabilities = @(
            $skuCapabilities | Where-Object {
                $capName = [string]$_.name
                if ([string]::IsNullOrWhiteSpace([string]$capName)) {
                    return $false
                }

                $capLower = $capName.ToLowerInvariant()
                return (
                    $capLower.Contains("nested") -or
                    $capLower.Contains("hibern") -or
                    $capLower.Contains("hyperv") -or
                    $capLower.Contains("trusted") -or
                    $capLower.Contains("encryption")
                )
            }
        )

        $nestedCapabilities = @(
            $focusedCapabilities |
                Where-Object {
                    $capName = [string]$_.name
                    -not [string]::IsNullOrWhiteSpace([string]$capName) -and $capName.ToLowerInvariant().Contains("nested")
                }
        )

        $result[$itemName] = [ordered]@{
            Name = $itemName
            Tier = [string]$item.tier
            Family = [string]$item.family
            Availability = [string]$availability
            SkuCapabilities = @($skuCapabilities)
            FocusedCapabilities = @($focusedCapabilities)
            NestedCapabilities = @($nestedCapabilities)
        }
    }

    return $result
}

# Handles Get-AzVmResourceGroupInventoryDump.
function Get-AzVmResourceGroupInventoryDump {
    param(
        [string]$ResourceGroup
    )

    Write-Host ("show: scanning resource group '{0}'..." -f [string]$ResourceGroup) -ForegroundColor DarkGray
    $groupObj = Invoke-AzVmAzJsonOrNull -AzArgs @("group", "show", "-n", $ResourceGroup, "-o", "json", "--only-show-errors") -Context "az group show" -SuppressError
    if ($null -eq $groupObj) {
        return [ordered]@{
            Name = [string]$ResourceGroup
            Exists = $false
            ResourceCount = 0
            ResourceTypeCounts = [ordered]@{}
            VmCount = 0
            Vms = @()
            Resources = @()
        }
    }

    $resourcesRaw = Invoke-AzVmAzJsonOrNull -AzArgs @("resource", "list", "-g", $ResourceGroup, "-o", "json", "--only-show-errors") -Context "az resource list" -SuppressError
    $resources = @(ConvertTo-ObjectArrayCompat -InputObject $resourcesRaw)
    $resourceTypeCounts = Get-AzVmResourceTypeCountMap -Resources $resources

    $vmNameRows = Invoke-AzVmAzJsonOrNull -AzArgs @("vm", "list", "-g", $ResourceGroup, "--query", "[].name", "-o", "json", "--only-show-errors") -Context "az vm list" -SuppressError
    $vmNames = @(
        ConvertTo-ObjectArrayCompat -InputObject $vmNameRows |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Sort-Object -Unique
    )

    $vmDumps = @()
    foreach ($vmName in @($vmNames)) {
        Write-Host ("show: collecting VM '{0}' in group '{1}'..." -f [string]$vmName, [string]$ResourceGroup) -ForegroundColor DarkGray
        $vmDumps += (Get-AzVmVmInventoryDump -ResourceGroup $ResourceGroup -VmName ([string]$vmName))
    }

    $skuNamesByLocation = @{}
    foreach ($vmDump in @($vmDumps)) {
        $vmLocation = [string]$vmDump.Location
        $vmSkuName = [string]$vmDump.VmSize
        if ([string]::IsNullOrWhiteSpace([string]$vmLocation) -or [string]::IsNullOrWhiteSpace([string]$vmSkuName)) {
            continue
        }

        if (-not $skuNamesByLocation.ContainsKey($vmLocation)) {
            $skuNamesByLocation[$vmLocation] = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
        }
        [void]$skuNamesByLocation[$vmLocation].Add($vmSkuName)
    }

    $skuMetadataByLocation = @{}
    foreach ($locationKey in @($skuNamesByLocation.Keys)) {
        $skuNameList = @($skuNamesByLocation[$locationKey] | Sort-Object)
        if ($skuNameList.Count -eq 0) {
            continue
        }
        Write-Host ("show: loading optimized SKU metadata for location '{0}'..." -f [string]$locationKey) -ForegroundColor DarkGray
        $skuMetadataByLocation[$locationKey] = Get-AzVmSkuMetadataMap -Location ([string]$locationKey) -SkuNames $skuNameList
    }

    foreach ($vmDump in @($vmDumps)) {
        $vmLocation = [string]$vmDump.Location
        $vmSkuName = [string]$vmDump.VmSize
        if ([string]::IsNullOrWhiteSpace([string]$vmLocation) -or [string]::IsNullOrWhiteSpace([string]$vmSkuName)) {
            continue
        }
        if (-not $skuMetadataByLocation.ContainsKey($vmLocation)) {
            continue
        }

        $locationMeta = $skuMetadataByLocation[$vmLocation]
        if (-not $locationMeta.ContainsKey($vmSkuName)) {
            continue
        }

        $meta = $locationMeta[$vmSkuName]
        $vmDump['SkuName'] = [string]$meta.Name
        $vmDump['SkuTier'] = [string]$meta.Tier
        $vmDump['SkuFamily'] = [string]$meta.Family
        $vmDump['SkuAvailability'] = [string]$meta.Availability
        $vmDump['SkuCapabilities'] = @($meta.SkuCapabilities)
        $vmDump['FocusedCapabilities'] = @($meta.FocusedCapabilities)

        if ($vmDump.Contains('FeatureFlags') -and $vmDump.FeatureFlags) {
            $vmDump.FeatureFlags['NestedVirtualizationCapabilities'] = @($meta.NestedCapabilities)
        }
    }

    return [ordered]@{
        Name = [string]$groupObj.name
        Exists = $true
        Id = [string]$groupObj.id
        Location = [string]$groupObj.location
        ManagedBy = [string]$groupObj.managedBy
        ProvisioningState = [string]$groupObj.properties.provisioningState
        Tags = $groupObj.tags
        ResourceCount = @($resources).Count
        ResourceTypeCounts = $resourceTypeCounts
        VmCount = @($vmDumps).Count
        Vms = @($vmDumps)
        Resources = @($resources)
    }
}

# Handles Write-AzVmShowSectionHeader.
function Write-AzVmShowSectionHeader {
    param(
        [string]$Text
    )

    Write-Host ""
    Write-Host $Text -ForegroundColor Cyan
}

# Handles Write-AzVmShowKeyValueRow.
function Write-AzVmShowKeyValueRow {
    param(
        [string]$Label,
        [object]$Value,
        [int]$Indent = 0
    )

    $indentSize = [Math]::Max(0, [int]$Indent)
    $indentText = (' ' * $indentSize)
    $valueText = ConvertTo-AzVmDisplayValue -Value $Value
    if ([string]::IsNullOrWhiteSpace([string]$valueText)) {
        $valueText = "(empty)"
    }

    Write-Host ("{0}{1}: {2}" -f $indentText, $Label, $valueText)
}

# Handles Write-AzVmShowReport.
function Write-AzVmShowReport {
    param(
        [hashtable]$Dump
    )

    Write-AzVmShowSectionHeader -Text "Azure VM Show Report"
    Write-AzVmShowKeyValueRow -Label "Generated at (UTC)" -Value ([string]$Dump.GeneratedAtUtc) -Indent 2
    Write-AzVmShowKeyValueRow -Label "Command" -Value ([string]$Dump.Command) -Indent 2
    Write-AzVmShowKeyValueRow -Label "Mode" -Value ([string]$Dump.Mode) -Indent 2
    Write-AzVmShowKeyValueRow -Label "Requested platform" -Value ([string]$Dump.RequestedPlatform) -Indent 2
    Write-AzVmShowKeyValueRow -Label "Env file path" -Value ([string]$Dump.EnvFilePath) -Indent 2

    Write-AzVmShowSectionHeader -Text "Azure Account"
    Write-AzVmShowKeyValueRow -Label "Subscription name" -Value ([string]$Dump.AzureAccount.SubscriptionName) -Indent 2
    Write-AzVmShowKeyValueRow -Label "Subscription id" -Value ([string]$Dump.AzureAccount.SubscriptionId) -Indent 2
    Write-AzVmShowKeyValueRow -Label "Tenant name" -Value ([string]$Dump.AzureAccount.TenantName) -Indent 2
    Write-AzVmShowKeyValueRow -Label "Tenant id" -Value ([string]$Dump.AzureAccount.TenantId) -Indent 2
    Write-AzVmShowKeyValueRow -Label "Account user" -Value ([string]$Dump.AzureAccount.UserName) -Indent 2

    Write-AzVmShowSectionHeader -Text "Selection And Summary"
    Write-AzVmShowKeyValueRow -Label "Target group filter" -Value ([string]$Dump.Selection.TargetGroup) -Indent 2
    Write-AzVmShowKeyValueRow -Label "Included resource groups" -Value (@($Dump.Selection.IncludedResourceGroups)) -Indent 2
    Write-AzVmShowKeyValueRow -Label "Resource group count" -Value ([int]$Dump.Summary.ResourceGroupCount) -Indent 2
    Write-AzVmShowKeyValueRow -Label "Total VM count" -Value ([int]$Dump.Summary.TotalVmCount) -Indent 2
    Write-AzVmShowKeyValueRow -Label "Running VM count" -Value ([int]$Dump.Summary.RunningVmCount) -Indent 2

    Write-AzVmShowSectionHeader -Text ".env Configuration Values"
    $envValues = $Dump.Config.DotEnvValues
    if ($envValues -and $envValues.Count -gt 0) {
        foreach ($key in @($envValues.Keys | Sort-Object)) {
            Write-AzVmShowKeyValueRow -Label ([string]$key) -Value ($envValues[$key]) -Indent 2
        }
    }
    else {
        Write-AzVmShowKeyValueRow -Label "values" -Value "(empty)" -Indent 2
    }

    Write-AzVmShowSectionHeader -Text "Runtime Overrides"
    $overrideValues = $Dump.Config.RuntimeOverrides
    if ($overrideValues -and $overrideValues.Count -gt 0) {
        foreach ($key in @($overrideValues.Keys | Sort-Object)) {
            Write-AzVmShowKeyValueRow -Label ([string]$key) -Value ($overrideValues[$key]) -Indent 2
        }
    }
    else {
        Write-AzVmShowKeyValueRow -Label "values" -Value "(empty)" -Indent 2
    }

    Write-AzVmShowSectionHeader -Text "Resource Groups"
    $groupIndex = 0
    foreach ($group in @(ConvertTo-ObjectArrayCompat -InputObject $Dump.ResourceGroups)) {
        $groupIndex++
        Write-Host ""
        Write-Host ("[{0}] Resource Group: {1}" -f $groupIndex, [string]$group.Name) -ForegroundColor Yellow
        Write-AzVmShowKeyValueRow -Label "Exists" -Value ([bool]$group.Exists) -Indent 2
        Write-AzVmShowKeyValueRow -Label "Location" -Value ([string]$group.Location) -Indent 2
        Write-AzVmShowKeyValueRow -Label "Provisioning state" -Value ([string]$group.ProvisioningState) -Indent 2
        Write-AzVmShowKeyValueRow -Label "Resource count" -Value ([int]$group.ResourceCount) -Indent 2
        Write-AzVmShowKeyValueRow -Label "VM count" -Value ([int]$group.VmCount) -Indent 2

        $typeCountMap = $group.ResourceTypeCounts
        if ($typeCountMap -and $typeCountMap.Count -gt 0) {
            Write-Host "  Resource types:"
            foreach ($typeKey in @($typeCountMap.Keys | Sort-Object)) {
                Write-AzVmShowKeyValueRow -Label ([string]$typeKey) -Value ([int]$typeCountMap[$typeKey]) -Indent 4
            }
        }
        else {
            Write-AzVmShowKeyValueRow -Label "Resource types" -Value "(none)" -Indent 2
        }

        $resourceRows = @(
            ConvertTo-ObjectArrayCompat -InputObject $group.Resources |
                ForEach-Object {
                    $resourceName = [string]$_.name
                    $resourceType = [string]$_.type
                    $resourceLocation = [string]$_.location
                    if ([string]::IsNullOrWhiteSpace([string]$resourceLocation)) {
                        return ("{0} ({1})" -f $resourceName, $resourceType)
                    }
                    return ("{0} ({1}, {2})" -f $resourceName, $resourceType, $resourceLocation)
                } |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
        )
        if ($resourceRows.Count -gt 0) {
            Write-Host "  Resources:"
            foreach ($resourceRow in @($resourceRows)) {
                Write-Host ("    - {0}" -f [string]$resourceRow)
            }
        }
        else {
            Write-AzVmShowKeyValueRow -Label "Resources" -Value "(none)" -Indent 2
        }

        $vmRows = @(ConvertTo-ObjectArrayCompat -InputObject $group.Vms)
        if ($vmRows.Count -eq 0) {
            Write-AzVmShowKeyValueRow -Label "VM details" -Value "(none)" -Indent 2
            continue
        }

        Write-Host "  VM details:"
        $vmIndex = 0
        foreach ($vm in @($vmRows)) {
            $vmIndex++
            Write-Host ("    [{0}] VM: {1}" -f $vmIndex, [string]$vm.Name) -ForegroundColor Green
            Write-AzVmShowKeyValueRow -Label "Power state" -Value ([string]$vm.PowerState) -Indent 6
            Write-AzVmShowKeyValueRow -Label "Provisioning state" -Value ([string]$vm.ProvisioningState) -Indent 6
            Write-AzVmShowKeyValueRow -Label "Location" -Value ([string]$vm.Location) -Indent 6
            Write-AzVmShowKeyValueRow -Label "Size (SKU)" -Value ([string]$vm.VmSize) -Indent 6
            Write-AzVmShowKeyValueRow -Label "SKU availability (subscription)" -Value ([string]$vm.SkuAvailability) -Indent 6
            Write-AzVmShowKeyValueRow -Label "OS type" -Value ([string]$vm.OsType) -Indent 6
            Write-AzVmShowKeyValueRow -Label "Public IPs" -Value ([string]$vm.PublicIps) -Indent 6
            Write-AzVmShowKeyValueRow -Label "Private IPs" -Value ([string]$vm.PrivateIps) -Indent 6
            Write-AzVmShowKeyValueRow -Label "FQDNs" -Value ([string]$vm.Fqdns) -Indent 6
            Write-AzVmShowKeyValueRow -Label "OS disk" -Value ([string]$vm.OsDiskName) -Indent 6
            Write-AzVmShowKeyValueRow -Label "Data disks" -Value (@($vm.DataDiskNames)) -Indent 6
            Write-AzVmShowKeyValueRow -Label "NIC ids" -Value (@($vm.NicIds)) -Indent 6

            $hibernationEnabled = $null
            if ($vm.FeatureFlags -and $vm.FeatureFlags.Contains('HibernationEnabled')) {
                $hibernationEnabled = $vm.FeatureFlags.HibernationEnabled
            }
            Write-AzVmShowKeyValueRow -Label "Hibernation enabled" -Value $hibernationEnabled -Indent 6

            $nestedCapabilityRows = @(
                ConvertTo-ObjectArrayCompat -InputObject $vm.FocusedCapabilities |
                    Where-Object {
                        $capName = [string]$_.name
                        -not [string]::IsNullOrWhiteSpace([string]$capName) -and $capName.ToLowerInvariant().Contains("nested")
                    } |
                    ForEach-Object { "{0}={1}" -f ([string]$_.name), ([string]$_.value) }
            )
            Write-AzVmShowKeyValueRow -Label "Nested virtualization capabilities" -Value $nestedCapabilityRows -Indent 6

            $focusedCaps = @(
                ConvertTo-ObjectArrayCompat -InputObject $vm.FocusedCapabilities |
                    ForEach-Object { "{0}={1}" -f ([string]$_.name), ([string]$_.value) }
            )
            Write-AzVmShowKeyValueRow -Label "Focused capabilities" -Value $focusedCaps -Indent 6
        }
    }
}

# Handles Invoke-AzVmShowCommand.
function Invoke-AzVmShowCommand {
    param(
        [hashtable]$Options,
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $accountSnapshot = Get-AzVmAzAccountSnapshot

    $targetGroupValue = [string](Get-AzVmCliOptionText -Options $Options -Name 'group')
    $targetGroup = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$targetGroupValue)) {
        $targetGroup = $targetGroupValue.Trim()
    }

    $allGroupRows = @()
    try {
        $allGroupRows = @(Get-AzVmManagedResourceGroupRows)
    }
    catch {
        Throw-FriendlyError `
            -Detail "Managed resource groups could not be loaded for show command." `
            -Code 64 `
            -Summary "Show command cannot continue." `
            -Hint "Run az login and verify subscription access."
    }
    $allGroups = @(
        ConvertTo-ObjectArrayCompat -InputObject $allGroupRows |
            ForEach-Object { [string]$_.name } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            Sort-Object -Unique
    )

    $selectedGroups = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$targetGroup)) {
        Assert-AzVmManagedResourceGroup -ResourceGroup $targetGroup -OperationName 'show'
        $selectedGroups = @($targetGroup)
    }
    else {
        $selectedGroups = @($allGroups)
    }

    if (@($selectedGroups).Count -eq 0) {
        Throw-FriendlyError `
            -Detail "No resource groups were found for show command." `
            -Code 64 `
            -Summary "Show command cannot continue because no resource groups were found." `
            -Hint "Run az login, verify subscription, and create resources first."
    }

    $platformRequest = ''
    if ($WindowsFlag) {
        $platformRequest = 'windows'
    }
    elseif ($LinuxFlag) {
        $platformRequest = 'linux'
    }

    $groupDumps = @()
    foreach ($resourceGroup in @($selectedGroups)) {
        $groupDumps += (Get-AzVmResourceGroupInventoryDump -ResourceGroup ([string]$resourceGroup))
    }

    $totalVmCount = 0
    $runningVmCount = 0
    foreach ($groupDump in @($groupDumps)) {
        $groupVmCount = @($groupDump.Vms).Count
        $totalVmCount += [int]$groupVmCount
        foreach ($vmDump in @($groupDump.Vms)) {
            $powerStateText = [string]$vmDump.PowerState
            if (-not [string]::IsNullOrWhiteSpace([string]$powerStateText) -and $powerStateText.ToLowerInvariant().Contains("running")) {
                $runningVmCount += 1
            }
        }
    }

    $configOrdered = [ordered]@{}
    foreach ($key in @($configMap.Keys | Sort-Object)) {
        $configOrdered[[string]$key] = [string]$configMap[$key]
    }

    $overridesOrdered = [ordered]@{}
    foreach ($key in @($script:ConfigOverrides.Keys | Sort-Object)) {
        $overridesOrdered[[string]$key] = [string]$script:ConfigOverrides[$key]
    }

    $dump = [ordered]@{
        GeneratedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
        Command = "show"
        Mode = "auto"
        RequestedPlatform = [string]$platformRequest
        EnvFilePath = [string]$envFilePath
        AzureAccount = $accountSnapshot
        Config = [ordered]@{
            DotEnvValues = $configOrdered
            RuntimeOverrides = $overridesOrdered
        }
        Selection = [ordered]@{
            TargetGroup = [string]$targetGroup
            IncludedResourceGroups = @($selectedGroups)
        }
        Summary = [ordered]@{
            ResourceGroupCount = @($groupDumps).Count
            TotalVmCount = [int]$totalVmCount
            RunningVmCount = [int]$runningVmCount
        }
        ResourceGroups = @($groupDumps)
    }

    Write-AzVmShowReport -Dump $dump
}

# Handles Invoke-AzVmDeleteCommand.
function Invoke-AzVmDeleteCommand {
    param(
        [hashtable]$Options,
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $serverName = [string](Get-ConfigValue -Config $configMap -Key 'SERVER_NAME' -DefaultValue '')
    $defaultResourceGroup = [string](Get-ConfigValue -Config $configMap -Key 'RESOURCE_GROUP' -DefaultValue '')
    $defaultVmName = [string](Get-ConfigValue -Config $configMap -Key 'VM_NAME' -DefaultValue '')
    $defaultVmDiskName = [string](Get-ConfigValue -Config $configMap -Key 'VM_DISK_NAME' -DefaultValue '')

    $targetRaw = [string](Get-AzVmCliOptionText -Options $Options -Name 'target')
    $target = $targetRaw.Trim().ToLowerInvariant()
    if ($target -notin @('group','network','vm','disk')) {
        Throw-FriendlyError `
            -Detail ("Invalid delete target '{0}'." -f $targetRaw) `
            -Code 66 `
            -Summary "Delete target is invalid." `
            -Hint "Use --target=group|network|vm|disk."
    }

    $groupOption = [string](Get-AzVmCliOptionText -Options $Options -Name 'group')
    $resourceGroup = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$groupOption)) {
        $resourceGroup = $groupOption.Trim()
    }
    elseif ($AutoMode) {
        if ([string]::IsNullOrWhiteSpace([string]$defaultResourceGroup)) {
            Throw-FriendlyError `
                -Detail "Resource group is required in auto mode when --group is not provided." `
                -Code 66 `
                -Summary "Delete command cannot resolve target resource group." `
                -Hint "Provide --group=<name> or set RESOURCE_GROUP in .env."
        }
        $resourceGroup = $defaultResourceGroup.Trim()
    }
    else {
        $resourceGroup = Select-AzVmResourceGroupInteractive -DefaultResourceGroup $defaultResourceGroup -ServerName $serverName
    }

    $groupExists = az group exists -n $resourceGroup --only-show-errors
    Assert-LastExitCode "az group exists (delete)"
    if (-not [string]::Equals([string]$groupExists, "true", [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-FriendlyError `
            -Detail ("Resource group '{0}' was not found." -f $resourceGroup) `
            -Code 66 `
            -Summary "Delete command cannot continue because resource group was not found." `
            -Hint "Select an existing resource group."
    }
    Assert-AzVmManagedResourceGroup -ResourceGroup $resourceGroup -OperationName 'delete'

    $forceYes = Get-AzVmCliOptionBool -Options $Options -Name 'yes' -DefaultValue $false

    if ($target -eq 'group') {
        $approved = ($forceYes -or $AutoMode)
        if (-not $approved) {
            $approved = Confirm-YesNo -PromptText ("Delete resource group '{0}' and all resources?" -f $resourceGroup) -DefaultYes $false
        }
        if (-not $approved) {
            Write-Host "Delete command canceled by user." -ForegroundColor Yellow
            return
        }

        Invoke-TrackedAction -Label ("az group delete -n {0} --yes --no-wait" -f $resourceGroup) -Action {
            az group delete -n $resourceGroup --yes --no-wait --only-show-errors
            Assert-LastExitCode "az group delete"
        } | Out-Null
        Invoke-TrackedAction -Label ("az group wait -n {0} --deleted" -f $resourceGroup) -Action {
            az group wait -n $resourceGroup --deleted --only-show-errors
            Assert-LastExitCode "az group wait --deleted"
        } | Out-Null

        Write-Host ("Delete completed: resource group '{0}' was purged." -f $resourceGroup) -ForegroundColor Green
        return
    }

    $vmNames = @(Get-AzVmVmNamesForResourceGroup -ResourceGroup $resourceGroup)
    if ($vmNames.Count -eq 0) {
        Throw-FriendlyError `
            -Detail ("No VM found in resource group '{0}' for target '{1}'." -f $resourceGroup, $target) `
            -Code 66 `
            -Summary "Delete target requires a VM context but none was found." `
            -Hint "Create a VM first or choose another resource group."
    }

    $selectedVmName = ''
    if ($AutoMode) {
        if (-not [string]::IsNullOrWhiteSpace([string]$defaultVmName)) {
            $candidate = $defaultVmName.Trim()
            if (@($vmNames | Where-Object { [string]::Equals([string]$_, $candidate, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
                $selectedVmName = $candidate
            }
        }

        if ([string]::IsNullOrWhiteSpace([string]$selectedVmName)) {
            if ($vmNames.Count -eq 1) {
                $selectedVmName = [string]$vmNames[0]
            }
            else {
                Throw-FriendlyError `
                    -Detail ("Auto mode could not resolve a unique VM in resource group '{0}'." -f $resourceGroup) `
                    -Code 66 `
                    -Summary "Delete command needs an explicit VM in auto mode." `
                    -Hint "Set VM_NAME in .env to one VM in the selected group."
            }
        }
    }
    else {
        $selectedVmName = Select-AzVmVmInteractive -ResourceGroup $resourceGroup -DefaultVmName $defaultVmName
    }

    $descriptor = Get-AzVmVmNetworkDescriptor -ResourceGroup $resourceGroup -VmName $selectedVmName
    $vmExists = Test-AzVmAzResourceExists -AzArgs @("vm", "show", "-g", $resourceGroup, "-n", $selectedVmName)

    $confirmPrompt = switch ($target) {
        'vm' { "Delete VM '$selectedVmName' from resource group '$resourceGroup'?" }
        'disk' { "Delete OS disk for VM '$selectedVmName' in resource group '$resourceGroup'?" }
        default { "Delete VM-bound network resources for '$selectedVmName' in resource group '$resourceGroup'?" }
    }
    $approved = ($forceYes -or $AutoMode)
    if (-not $approved) {
        $approved = Confirm-YesNo -PromptText $confirmPrompt -DefaultYes $false
    }
    if (-not $approved) {
        Write-Host "Delete command canceled by user." -ForegroundColor Yellow
        return
    }

    if ($target -eq 'vm') {
        if (-not $vmExists) {
            Write-Host ("VM '{0}' is already absent in resource group '{1}'." -f $selectedVmName, $resourceGroup) -ForegroundColor Yellow
            return
        }
        Invoke-TrackedAction -Label ("az vm delete -g {0} -n {1} --yes" -f $resourceGroup, $selectedVmName) -Action {
            az vm delete -g $resourceGroup -n $selectedVmName --yes -o none --only-show-errors
            Assert-LastExitCode "az vm delete"
        } | Out-Null
        Write-Host ("Delete completed: VM '{0}' was purged." -f $selectedVmName) -ForegroundColor Green
        return
    }

    if ($vmExists) {
        Invoke-TrackedAction -Label ("az vm delete -g {0} -n {1} --yes" -f $resourceGroup, $selectedVmName) -Action {
            az vm delete -g $resourceGroup -n $selectedVmName --yes -o none --only-show-errors
            Assert-LastExitCode "az vm delete"
        } | Out-Null
    }

    if ($target -eq 'disk') {
        $diskName = [string]$descriptor.OsDiskName
        if ([string]::IsNullOrWhiteSpace([string]$diskName)) {
            $diskName = $defaultVmDiskName
        }
        if ([string]::IsNullOrWhiteSpace([string]$diskName)) {
            Throw-FriendlyError `
                -Detail "OS disk name could not be resolved." `
                -Code 66 `
                -Summary "Delete disk target failed before execution." `
                -Hint "Set VM_DISK_NAME in .env or ensure VM metadata is available."
        }

        $diskExists = Test-AzVmAzResourceExists -AzArgs @("disk", "show", "-g", $resourceGroup, "-n", $diskName)
        if ($diskExists) {
            Invoke-TrackedAction -Label ("az disk delete -g {0} -n {1} --yes" -f $resourceGroup, $diskName) -Action {
                az disk delete -g $resourceGroup -n $diskName --yes -o none --only-show-errors
                Assert-LastExitCode "az disk delete"
            } | Out-Null
            Write-Host ("Delete completed: disk '{0}' was purged." -f $diskName) -ForegroundColor Green
        }
        else {
            Write-Host ("Disk '{0}' is already absent in resource group '{1}'." -f $diskName, $resourceGroup) -ForegroundColor Yellow
        }
        return
    }

    $nicName = [string]$descriptor.NicName
    if (-not [string]::IsNullOrWhiteSpace([string]$nicName)) {
        $nicExists = Test-AzVmAzResourceExists -AzArgs @("network", "nic", "show", "-g", $resourceGroup, "-n", $nicName)
        if ($nicExists) {
            Invoke-TrackedAction -Label ("az network nic delete -g {0} -n {1}" -f $resourceGroup, $nicName) -Action {
                az network nic delete -g $resourceGroup -n $nicName --only-show-errors
                Assert-LastExitCode "az network nic delete"
            } | Out-Null
        }
    }

    $publicIpName = [string]$descriptor.PublicIpName
    if (-not [string]::IsNullOrWhiteSpace([string]$publicIpName)) {
        $ipExists = Test-AzVmAzResourceExists -AzArgs @("network", "public-ip", "show", "-g", $resourceGroup, "-n", $publicIpName)
        if ($ipExists) {
            Invoke-TrackedAction -Label ("az network public-ip delete -g {0} -n {1}" -f $resourceGroup, $publicIpName) -Action {
                az network public-ip delete -g $resourceGroup -n $publicIpName --only-show-errors
                Assert-LastExitCode "az network public-ip delete"
            } | Out-Null
        }
    }

    $nsgName = [string]$descriptor.NsgName
    if (-not [string]::IsNullOrWhiteSpace([string]$nsgName)) {
        $nsgExists = Test-AzVmAzResourceExists -AzArgs @("network", "nsg", "show", "-g", $resourceGroup, "-n", $nsgName)
        if ($nsgExists) {
            Invoke-TrackedAction -Label ("az network nsg delete -g {0} -n {1}" -f $resourceGroup, $nsgName) -Action {
                az network nsg delete -g $resourceGroup -n $nsgName --only-show-errors
                Assert-LastExitCode "az network nsg delete"
            } | Out-Null
        }
    }

    $vnetName = [string]$descriptor.VnetName
    if (-not [string]::IsNullOrWhiteSpace([string]$vnetName)) {
        $vnetExists = Test-AzVmAzResourceExists -AzArgs @("network", "vnet", "show", "-g", $resourceGroup, "-n", $vnetName)
        if ($vnetExists) {
            Invoke-TrackedAction -Label ("az network vnet delete -g {0} -n {1}" -f $resourceGroup, $vnetName) -Action {
                az network vnet delete -g $resourceGroup -n $vnetName --only-show-errors
                Assert-LastExitCode "az network vnet delete"
            } | Out-Null
        }
    }

    Write-Host ("Delete completed: VM-bound network resources for '{0}' were purged." -f $selectedVmName) -ForegroundColor Green
}

# Handles Invoke-AzVmCommandDispatcher.
function Invoke-AzVmCommandDispatcher {
    param(
        [string]$CommandName,
        [hashtable]$Options,
        [string]$HelpTopic = ''
    )

    Assert-AzVmCommandOptions -CommandName $CommandName -Options $Options

    $autoRequested = Get-AzVmCliOptionBool -Options $Options -Name 'auto' -DefaultValue $false
    $script:AutoMode = ($CommandName -in @('create','update','delete')) -and $autoRequested
    $script:PerfMode = Get-AzVmCliOptionBool -Options $Options -Name 'perf' -DefaultValue $false
    $windowsFlag = Get-AzVmCliOptionBool -Options $Options -Name 'windows' -DefaultValue $false
    $linuxFlag = Get-AzVmCliOptionBool -Options $Options -Name 'linux' -DefaultValue $false
    if ($windowsFlag -and $linuxFlag) {
        Throw-FriendlyError `
            -Detail "Both --windows and --linux were provided." `
            -Code 2 `
            -Summary "Conflicting OS selection flags were provided." `
            -Hint "Use only one of --windows or --linux."
    }

    $script:ConfigOverrides = @{}
    $script:ActiveCommand = [string]$CommandName
    $helpRequested = Get-AzVmCliOptionBool -Options $Options -Name 'help' -DefaultValue $false

    $commandPerfWatch = $null
    if ($script:PerfMode) {
        $commandPerfWatch = [System.Diagnostics.Stopwatch]::StartNew()
    }
    try {
        if ($helpRequested -and $CommandName -ne 'help') {
            Show-AzVmCommandHelp -Topic $CommandName
            return
        }

        switch ($CommandName) {
            'help' {
                if ($helpRequested) {
                    Show-AzVmCommandHelp -Overview
                }
                else {
                    Show-AzVmCommandHelp -Topic $HelpTopic
                }
                return
            }
            'config' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmConfigCommand -Options $Options -AutoMode:$false -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag
                return
            }
            'group' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmGroupCommand -Options $Options
                return
            }
            'create' {
                $actionPlan = Resolve-AzVmActionPlan -CommandName 'create' -Options $Options
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'

                # create always targets a new managed resource group name from template/index.
                Invoke-AzVmMain `
                    -WindowsFlag:$windowsFlag `
                    -LinuxFlag:$linuxFlag `
                    -CommandName 'create' `
                    -InitialConfigOverrides @{ RESOURCE_GROUP = '' } `
                    -ActionPlan $actionPlan
                return
            }
            'update' {
                $actionPlan = Resolve-AzVmActionPlan -CommandName 'update' -Options $Options
                $script:UpdateMode = $true
                $script:RenewMode = $false
                $script:ExecutionMode = 'update'

                $envFilePath = Join-Path (Get-AzVmRepoRoot) '.env'
                $configMap = Read-DotEnvFile -Path $envFilePath
                $defaultResourceGroup = [string](Get-ConfigValue -Config $configMap -Key 'RESOURCE_GROUP' -DefaultValue '')
                $serverName = [string](Get-ConfigValue -Config $configMap -Key 'SERVER_NAME' -DefaultValue '')
                $targetResourceGroup = Resolve-AzVmTargetResourceGroup `
                    -Options $Options `
                    -AutoMode:$script:AutoMode `
                    -DefaultResourceGroup $defaultResourceGroup `
                    -ServerName $serverName `
                    -OperationName 'update'

                Invoke-AzVmMain `
                    -WindowsFlag:$windowsFlag `
                    -LinuxFlag:$linuxFlag `
                    -CommandName 'update' `
                    -InitialConfigOverrides @{ RESOURCE_GROUP = $targetResourceGroup } `
                    -ActionPlan $actionPlan
                return
            }
            'move' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmMoveCommand -Options $Options -AutoMode:$script:AutoMode -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag
                return
            }
            'resize' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmResizeCommand -Options $Options -AutoMode:$script:AutoMode -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag
                return
            }
            'set' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmSetCommand -Options $Options -AutoMode:$script:AutoMode -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag
                return
            }
            'exec' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmExecCommand -Options $Options -AutoMode:$script:AutoMode -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag
                return
            }
            'show' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmShowCommand -Options $Options -AutoMode:$false -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag
                return
            }
            'delete' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmDeleteCommand -Options $Options -AutoMode:$script:AutoMode -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag
                return
            }
            default {
                Throw-FriendlyError `
                    -Detail ("Unknown command '{0}'." -f $CommandName) `
                    -Code 2 `
                    -Summary "Unknown command." `
                    -Hint "Use one command: create | update | config | group | move | resize | set | exec | show | delete."
            }
        }
    }
    finally {
        if ($script:PerfMode -and $null -ne $commandPerfWatch) {
            if ($commandPerfWatch.IsRunning) {
                $commandPerfWatch.Stop()
            }

            Write-AzVmPerfTiming -Category "command" -Label ([string]$CommandName) -Seconds $commandPerfWatch.Elapsed.TotalSeconds
        }
    }
}
