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
        [string]$VmName
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

    if (-not [string]::IsNullOrWhiteSpace([string]$VmName)) {
        $needle = [string]$VmName.Trim().ToLowerInvariant()
        $vmMatches = @(
            $filtered | Where-Object {
                $candidate = ([string]$_).ToLowerInvariant()
                $candidate.Contains($needle)
            }
        )
        if ($vmMatches.Count -gt 0) {
            $filtered = @($vmMatches)
        }
    }

    return @($filtered | Sort-Object -Unique)
}

# Handles Select-AzVmResourceGroupInteractive.
function Select-AzVmResourceGroupInteractive {
    param(
        [string]$DefaultResourceGroup,
        [string]$VmName
    )

    $groups = @(Get-AzVmResourceGroupsForSelection -VmName $VmName)
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
        [string]$VmName,
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
        $resourceGroup = Select-AzVmResourceGroupInteractive -DefaultResourceGroup $DefaultResourceGroup -VmName $VmName
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
            -Hint "Set VM_NAME in .env to the exact Azure VM name, provide a command-specific VM parameter, or use interactive mode."
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
        'create' { $allowed = @('auto','perf','windows','linux','help','to-step','from-step','single-step','vm-name') }
        'update' { $allowed = @('auto','perf','windows','linux','help','to-step','from-step','single-step','group','vm-name') }
        'configure' { $allowed = @('perf','windows','linux','help','group') }
        'group'  { $allowed = @('help','list','select') }
        'show'   { $allowed = @('perf','help','group') }
        'do'     { $allowed = @('perf','help','group','vm-name','vm-action') }
        'move'   { $allowed = @('perf','help','group','vm-name','vm-region') }
        'resize' { $allowed = @('perf','help','group','vm-name','vm-size','windows','linux') }
        'set'    { $allowed = @('perf','help','group','vm-name','hibernation','nested-virtualization') }
        'exec'   { $allowed = @('perf','windows','linux','help','group','vm-name','init-task','update-task') }
        'ssh'    { $allowed = @('perf','help','group','vm-name','user') }
        'rdp'    { $allowed = @('perf','help','group','vm-name','user') }
        'delete' { $allowed = @('auto','perf','help','target','group','yes') }
        'help'   { $allowed = @('help') }
        default {
            Throw-FriendlyError `
                -Detail ("Unsupported command '{0}'." -f $CommandName) `
                -Code 2 `
                -Summary "Unknown command." `
                -Hint "Use one command: create | update | configure | group | show | do | move | resize | set | exec | ssh | rdp | delete."
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

    if ($CommandName -eq 'do' -and (Test-AzVmCliOptionPresent -Options $Options -Name 'vm-action')) {
        [void](Resolve-AzVmDoActionName -RawValue ([string](Get-AzVmCliOptionText -Options $Options -Name 'vm-action')) -AllowEmpty)
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
        -VmNameDefault ([string]$platformDefaults.VmNameDefault) `
        -VmImageDefault ([string]$platformDefaults.VmImageDefault) `
        -VmSizeDefault ([string]$platformDefaults.VmSizeDefault) `
        -VmDiskSizeDefault ([string]$platformDefaults.VmDiskSizeDefault) `
        -ConfigOverrides $script:ConfigOverrides

    $step1Context['VmOsType'] = $platform

    $taskOutcomeModeRaw = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'VM_TASK_OUTCOME_MODE' -DefaultValue 'continue')
    if ([string]::IsNullOrWhiteSpace($taskOutcomeModeRaw)) { $taskOutcomeModeRaw = 'continue' }
    $taskOutcomeMode = $taskOutcomeModeRaw.Trim().ToLowerInvariant()
    if ($taskOutcomeMode -ne 'continue' -and $taskOutcomeMode -ne 'strict') {
        Throw-FriendlyError `
            -Detail ("Invalid VM_TASK_OUTCOME_MODE '{0}'." -f $taskOutcomeModeRaw) `
            -Code 14 `
            -Summary "Task outcome mode is invalid." `
            -Hint "Set VM_TASK_OUTCOME_MODE=continue or VM_TASK_OUTCOME_MODE=strict."
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

# Handles Initialize-AzVmExecCommandRuntimeContext.
function Initialize-AzVmExecCommandRuntimeContext {
    param(
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $platform = Resolve-AzVmPlatformSelection -ConfigMap $configMap -EnvFilePath $envFilePath -AutoMode:$AutoMode -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -ConfigOverrides $script:ConfigOverrides
    $platformDefaults = Get-AzVmPlatformDefaults -Platform $platform
    $effectiveConfigMap = Resolve-AzVmPlatformConfigMap -ConfigMap $configMap -Platform $platform

    $vmName = [string](Get-AzVmRequiredResolvedConfigValue -ConfigMap $effectiveConfigMap -Key 'VM_NAME' -Summary 'VM name is required.' -Hint 'Set VM_NAME in .env, or pass --vm-name where the command supports it.')

    $azLocation = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'AZ_LOCATION' -DefaultValue '')
    $regionCode = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$azLocation)) {
        $regionCode = Get-AzVmRegionCode -Location ([string]$azLocation)
    }

    $nameTokens = @{
        VM_NAME = [string]$vmName
        REGION_CODE = [string]$regionCode
        N = '1'
    }

    $resourceGroup = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'RESOURCE_GROUP' -DefaultValue '')
    if (-not [string]::IsNullOrWhiteSpace([string]$resourceGroup)) {
        $resourceGroup = Resolve-AzVmTemplate -Template $resourceGroup -Tokens $nameTokens
    }

    $vmStorageSku = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key 'VM_STORAGE_SKU' -DefaultValue 'StandardSSD_LRS')) -Tokens $nameTokens
    $vmSizeConfigKey = Get-AzVmPlatformVmConfigKey -Platform $platform -BaseKey 'VM_SIZE'
    $vmImageConfigKey = Get-AzVmPlatformVmConfigKey -Platform $platform -BaseKey 'VM_IMAGE'
    $vmDiskSizeConfigKey = Get-AzVmPlatformVmConfigKey -Platform $platform -BaseKey 'VM_DISK_SIZE_GB'
    $vmSize = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key $vmSizeConfigKey -DefaultValue ([string]$platformDefaults.VmSizeDefault))) -Tokens $nameTokens
    $vmImage = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key $vmImageConfigKey -DefaultValue ([string]$platformDefaults.VmImageDefault))) -Tokens $nameTokens
    $vmDiskSize = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key $vmDiskSizeConfigKey -DefaultValue ([string]$platformDefaults.VmDiskSizeDefault))) -Tokens $nameTokens
    $vmDiskName = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key 'VM_DISK_NAME' -DefaultValue '')) -Tokens $nameTokens
    $companyName = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key 'company_name' -DefaultValue ([string]$vmName))) -Tokens $nameTokens
    if ([string]::IsNullOrWhiteSpace([string]$companyName)) {
        $companyName = [string]$vmName
    }
    $vmUser = Get-AzVmRequiredResolvedConfigValue -ConfigMap $effectiveConfigMap -Key 'VM_ADMIN_USER' -Tokens $nameTokens -Summary 'VM admin user is required.' -Hint 'Set VM_ADMIN_USER in .env to the primary VM username.'
    $vmPass = Get-AzVmRequiredResolvedConfigValue -ConfigMap $effectiveConfigMap -Key 'VM_ADMIN_PASS' -Tokens $nameTokens -Summary 'VM admin password is required.' -Hint 'Set VM_ADMIN_PASS in .env to a non-placeholder password.'
    $vmAssistantUser = Get-AzVmRequiredResolvedConfigValue -ConfigMap $effectiveConfigMap -Key 'VM_ASSISTANT_USER' -Tokens $nameTokens -Summary 'VM assistant user is required.' -Hint 'Set VM_ASSISTANT_USER in .env to the secondary VM username.'
    $vmAssistantPass = Get-AzVmRequiredResolvedConfigValue -ConfigMap $effectiveConfigMap -Key 'VM_ASSISTANT_PASS' -Tokens $nameTokens -Summary 'VM assistant password is required.' -Hint 'Set VM_ASSISTANT_PASS in .env to a non-placeholder password.'
    $sshPort = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key 'VM_SSH_PORT' -DefaultValue (Get-AzVmDefaultSshPortText))) -Tokens $nameTokens
    $rdpPort = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key 'VM_RDP_PORT' -DefaultValue (Get-AzVmDefaultRdpPortText))) -Tokens $nameTokens

    $vmInitTaskDirName = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key (Get-AzVmPlatformTaskCatalogConfigKey -Platform $platform -Stage 'init') -DefaultValue ([string]$platformDefaults.VmInitTaskDirDefault))) -Tokens $nameTokens
    $vmUpdateTaskDirName = Resolve-AzVmTemplate -Template ([string](Get-ConfigValue -Config $effectiveConfigMap -Key (Get-AzVmPlatformTaskCatalogConfigKey -Platform $platform -Stage 'update') -DefaultValue ([string]$platformDefaults.VmUpdateTaskDirDefault))) -Tokens $nameTokens
    $vmInitTaskDir = Resolve-ConfigPath -PathValue $vmInitTaskDirName -RootPath $repoRoot
    $vmUpdateTaskDir = Resolve-ConfigPath -PathValue $vmUpdateTaskDirName -RootPath $repoRoot

    $defaultPortsCsv = Get-AzVmDefaultTcpPortsCsv
    $tcpPortsConfiguredCsv = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'TCP_PORTS' -DefaultValue $defaultPortsCsv)
    $tcpPorts = @($tcpPortsConfiguredCsv -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^\d+$' })
    if (-not [string]::IsNullOrWhiteSpace([string]$sshPort) -and ($sshPort -match '^\d+$') -and $tcpPorts -notcontains $sshPort) {
        $tcpPorts += $sshPort
    }
    if ([bool]$platformDefaults.IncludeRdp -and -not [string]::IsNullOrWhiteSpace([string]$rdpPort) -and ($rdpPort -match '^\d+$') -and $tcpPorts -notcontains $rdpPort) {
        $tcpPorts += $rdpPort
    }

    $taskOutcomeModeRaw = [string](Get-ConfigValue -Config $effectiveConfigMap -Key 'VM_TASK_OUTCOME_MODE' -DefaultValue 'continue')
    if ([string]::IsNullOrWhiteSpace($taskOutcomeModeRaw)) { $taskOutcomeModeRaw = 'continue' }
    $taskOutcomeMode = $taskOutcomeModeRaw.Trim().ToLowerInvariant()
    if ($taskOutcomeMode -ne 'continue' -and $taskOutcomeMode -ne 'strict') {
        Throw-FriendlyError `
            -Detail ("Invalid VM_TASK_OUTCOME_MODE '{0}'." -f $taskOutcomeModeRaw) `
            -Code 14 `
            -Summary "Task outcome mode is invalid." `
            -Hint "Set VM_TASK_OUTCOME_MODE=continue or VM_TASK_OUTCOME_MODE=strict."
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

    $context = [ordered]@{
        ResourceGroup = [string]$resourceGroup
        AzLocation = [string]$azLocation
        VmName = [string]$vmName
        VmImage = [string]$vmImage
        VmStorageSku = [string]$vmStorageSku
        VmSize = [string]$vmSize
        VmDiskName = [string]$vmDiskName
        VmDiskSize = [string]$vmDiskSize
        CompanyName = [string]$companyName
        VmUser = [string]$vmUser
        VmPass = [string]$vmPass
        VmAssistantUser = [string]$vmAssistantUser
        VmAssistantPass = [string]$vmAssistantPass
        SshPort = [string]$sshPort
        RdpPort = [string]$rdpPort
        TcpPorts = @($tcpPorts)
        TcpPortsConfiguredCsv = [string]$tcpPortsConfiguredCsv
        VmInitTaskDir = [string]$vmInitTaskDir
        VmUpdateTaskDir = [string]$vmUpdateTaskDir
        VmOsType = [string]$platform
        AzCommandTimeoutSeconds = [int]$azCommandTimeoutSeconds
        SshTaskTimeoutSeconds = [int]$sshTaskTimeoutSeconds
        SshConnectTimeoutSeconds = [int]$sshConnectTimeoutSeconds
    }

    return [pscustomobject]@{
        EnvFilePath = $envFilePath
        ConfigMap = $configMap
        EffectiveConfigMap = $effectiveConfigMap
        Platform = $platform
        PlatformDefaults = $platformDefaults
        Context = $context
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

    $tcpPortsCsv = [string]$Context.TcpPortsConfiguredCsv
    if ([string]::IsNullOrWhiteSpace([string]$tcpPortsCsv)) {
        $tcpPortsCsv = (@($Context.TcpPorts) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ','
    }
    $vmImageConfigKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey "VM_IMAGE"
    $vmSizeConfigKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey "VM_SIZE"
    $vmDiskSizeConfigKey = Get-AzVmPlatformVmConfigKey -Platform $Platform -BaseKey "VM_DISK_SIZE_GB"

    $persist = [ordered]@{
        VM_OS_TYPE = [string]$Platform
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
        VM_SSH_PORT = [string]$Context.SshPort
        VM_RDP_PORT = [string]$Context.RdpPort
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
    $vmName = [string](Get-ConfigValue -Config $configMap -Key 'VM_NAME' -DefaultValue '')

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
            $selectedGroup = Select-AzVmResourceGroupInteractive -DefaultResourceGroup $activeGroup -VmName $vmName
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

# Handles Invoke-AzVmConfigureCommand.
function Invoke-AzVmConfigureCommand {
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
    $vmName = [string](Get-ConfigValue -Config $configBefore -Key 'VM_NAME' -DefaultValue '')
    $selectedResourceGroup = Resolve-AzVmTargetResourceGroup `
        -Options $Options `
        -AutoMode:$AutoMode `
        -DefaultResourceGroup $defaultResourceGroup `
        -VmName $vmName `
        -OperationName 'configure'

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
            -Summary "Configure command could not continue after step 1." `
            -Hint "Rerun 'az-vm configure' and verify group selection."
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
            -Summary "Configure command could not continue after step 1." `
            -Hint "Rerun 'az-vm configure' and verify interactive selections."
    }
    if ([string]::IsNullOrWhiteSpace([string]$context.AzLocation)) {
        Throw-FriendlyError `
            -Detail "Step 1 returned empty AZ_LOCATION in context." `
            -Code 64 `
            -Summary "Configure command could not continue because region was not captured." `
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
    Show-AzVmKeyValueList -Title "Existing .env values (before configure):" -Values $configBefore
    Write-Host ""
    Show-AzVmKeyValueList -Title "Resolved configuration values:" -Values $context
    Write-Host ""
    Show-AzVmKeyValueList -Title ".env values after configure:" -Values $configAfter
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
    Write-Host "Configure completed successfully. No Azure resources were created, updated, or deleted." -ForegroundColor Green
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
        [switch]$LinuxFlag,
        [ValidateSet('continue','strict')]
        [string]$TaskOutcomeModeOverride = ''
    )

    $runtime = Initialize-AzVmExecCommandRuntimeContext -AutoMode:$AutoMode -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag
    $context = $runtime.Context
    $platform = [string]$runtime.Platform
    $platformDefaults = $runtime.PlatformDefaults
    $effectiveTaskOutcomeMode = [string]$runtime.TaskOutcomeMode
    if (-not [string]::IsNullOrWhiteSpace([string]$TaskOutcomeModeOverride)) {
        $effectiveTaskOutcomeMode = [string]$TaskOutcomeModeOverride
    }

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
        $target = Resolve-AzVmManagedVmTarget -Options $Options -ConfigMap $runtime.EffectiveConfigMap -OperationName 'exec'
        $context.ResourceGroup = [string]$target.ResourceGroup
        $context.VmName = [string]$target.VmName

        if ($stage -eq 'init') {
            $catalog = Get-AzVmTaskBlocksFromDirectory -DirectoryPath ([string]$context.VmInitTaskDir) -Platform $platform -Stage 'init'
            $tasks = Resolve-AzVmRuntimeTaskBlocks -TemplateTaskBlocks @($catalog.ActiveTasks) -Context $context
            $requested = Get-AzVmCliOptionText -Options $Options -Name 'init-task'
            $selectedTask = Resolve-AzVmTaskSelection -TaskBlocks $tasks -TaskNumberOrName $requested -Stage 'init' -AutoMode:$AutoMode
            $combinedShell = if ($platform -eq 'linux') { 'bash' } else { 'powershell' }
            $runCommandResult = Invoke-VmRunCommandBlocks -ResourceGroup ([string]$context.ResourceGroup) -VmName ([string]$context.VmName) -CommandId ([string]$platformDefaults.RunCommandId) -TaskBlocks @($selectedTask) -CombinedShell $combinedShell -TaskOutcomeMode $effectiveTaskOutcomeMode -PerfTaskCategory "exec-task"
            Write-Host ("Exec completed: init task '{0}'." -f [string]$selectedTask.Name) -ForegroundColor Green
            return [pscustomobject]@{
                Stage = 'init'
                Task = $selectedTask
                TaskOutcomeMode = $effectiveTaskOutcomeMode
                Result = $runCommandResult
            }
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

        $sshTaskResult = Invoke-AzVmSshTaskBlocks `
            -Platform $platform `
            -RepoRoot (Get-AzVmRepoRoot) `
            -SshHost $sshHost `
            -SshUser ([string]$context.VmUser) `
            -SshPassword ([string]$context.VmPass) `
            -SshPort ([string]$context.SshPort) `
            -ResourceGroup ([string]$context.ResourceGroup) `
            -VmName ([string]$context.VmName) `
            -TaskBlocks @($selectedTask) `
            -TaskOutcomeMode $effectiveTaskOutcomeMode `
            -PerfTaskCategory 'exec-task' `
            -SshMaxRetries 1 `
            -SshTaskTimeoutSeconds ([int]$runtime.SshTaskTimeoutSeconds) `
            -SshConnectTimeoutSeconds ([int]$runtime.SshConnectTimeoutSeconds) `
            -ConfiguredPySshClientPath ([string]$runtime.ConfiguredPySshClientPath)

        Write-Host ("Exec completed: update task '{0}'." -f [string]$selectedTask.Name) -ForegroundColor Green
        return [pscustomobject]@{
            Stage = 'update'
            Task = $selectedTask
            TaskOutcomeMode = $effectiveTaskOutcomeMode
            Result = $sshTaskResult
        }
    }

    $target = Resolve-AzVmManagedVmTarget -Options $Options -ConfigMap $runtime.EffectiveConfigMap -OperationName 'exec'
    $selectedResourceGroup = [string]$target.ResourceGroup
    $selectedVmName = [string]$target.VmName
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

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $target = Resolve-AzVmManagedVmTarget -Options $Options -ConfigMap $configMap -OperationName 'resize'
    $resourceGroup = [string]$target.ResourceGroup
    $vmName = [string]$target.VmName
    $isDirectRequest = Test-AzVmResizeDirectRequest -Options $Options

    $vmJson = az vm show -g $resourceGroup -n $vmName -o json --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$vmJson)) {
        Throw-FriendlyError `
            -Detail ("VM '{0}' was not found in resource group '{1}'." -f $vmName, $resourceGroup) `
            -Code 62 `
            -Summary "Resize command cannot continue because VM does not exist." `
            -Hint "Select an existing VM or run create first."
    }

    $vmObject = ConvertFrom-JsonCompat -InputObject $vmJson
    $currentRegion = [string]$vmObject.location
    $currentSize = [string]$vmObject.hardwareProfile.vmSize
    $actualPlatform = Get-AzVmPlatformNameFromOsType -OsType ([string]$vmObject.storageProfile.osDisk.osType)
    $vmSizeConfigKey = if ([string]::IsNullOrWhiteSpace([string]$actualPlatform)) { 'VM_SIZE' } else { Get-AzVmPlatformVmConfigKey -Platform $actualPlatform -BaseKey 'VM_SIZE' }

    Assert-AzVmResizePlatformExpectation `
        -ActualPlatform $actualPlatform `
        -WindowsFlag:$WindowsFlag `
        -LinuxFlag:$LinuxFlag `
        -VmName $vmName `
        -ResourceGroup $resourceGroup

    if ([string]::IsNullOrWhiteSpace([string]$currentRegion)) {
        Throw-FriendlyError `
            -Detail ("Resize command could not resolve the Azure region for VM '{0}'." -f $vmName) `
            -Code 62 `
            -Summary "Resize command cannot continue because VM region is unknown." `
            -Hint "Check the VM metadata in Azure, then retry."
    }
    if ([string]::IsNullOrWhiteSpace([string]$currentSize)) {
        Throw-FriendlyError `
            -Detail ("Resize command could not resolve the current VM size for '{0}'." -f $vmName) `
            -Code 62 `
            -Summary "Resize command cannot continue because current VM size is unknown." `
            -Hint "Check the VM metadata in Azure, then retry."
    }

    $targetSize = Resolve-AzVmResizeTargetSize -Options $Options -CurrentRegion $currentRegion -CurrentSize $currentSize -ConfigMap $configMap
    Assert-LocationExists -Location $currentRegion
    Assert-VmSkuAvailableViaRest -Location $currentRegion -VmSize $targetSize

    if ([string]::Equals([string]$targetSize, [string]$currentSize, [System.StringComparison]::OrdinalIgnoreCase)) {
        Write-Host ("No effective resize operation is required. VM size is already '{0}'." -f $targetSize) -ForegroundColor Yellow
        return
    }

    if (-not $isDirectRequest) {
        $approveResize = Confirm-YesNo -PromptText "Continue with VM size change?" -DefaultYes $false
        if (-not $approveResize) {
            Write-Host "Resize command canceled by user." -ForegroundColor Yellow
            return
        }
    }

    Write-Host ("Applying VM size update for '{0}' in '{1}': {2} -> {3}" -f $vmName, $resourceGroup, $currentSize, $targetSize)

    Invoke-TrackedAction -Label ("az vm deallocate -g {0} -n {1}" -f $resourceGroup, $vmName) -Action {
        az vm deallocate -g $resourceGroup -n $vmName -o none --only-show-errors
        Assert-LastExitCode "az vm deallocate"
    } | Out-Null
    $deallocated = Wait-AzVmVmPowerState -ResourceGroup $resourceGroup -VmName $vmName -DesiredPowerState "VM deallocated" -MaxAttempts 18 -DelaySeconds 10
    if (-not $deallocated) {
        Throw-FriendlyError `
            -Detail ("VM '{0}' did not reach deallocated state in expected time." -f $vmName) `
            -Code 62 `
            -Summary "Resize command stopped because VM deallocation was not confirmed." `
            -Hint "Check VM power state in Azure and retry resize."
    }

    Invoke-TrackedAction -Label ("az vm resize -g {0} -n {1} --size {2}" -f $resourceGroup, $vmName, $targetSize) -Action {
        az vm resize -g $resourceGroup -n $vmName --size $targetSize -o none --only-show-errors
        Assert-LastExitCode "az vm resize"
    } | Out-Null

    Invoke-TrackedAction -Label ("az vm start -g {0} -n {1}" -f $resourceGroup, $vmName) -Action {
        az vm start -g $resourceGroup -n $vmName -o none --only-show-errors
        Assert-LastExitCode "az vm start"
    } | Out-Null

    $running = Wait-AzVmVmRunningState -ResourceGroup $resourceGroup -VmName $vmName -MaxAttempts 3 -DelaySeconds 10
    if (-not $running) {
        Throw-FriendlyError `
            -Detail "VM did not return to running state after resize operation." `
            -Code 62 `
            -Summary "Resize command completed with unhealthy VM power state." `
            -Hint "Check VM power state in Azure Portal and start VM manually if needed."
    }

    Set-DotEnvValue -Path $envFilePath -Key $vmSizeConfigKey -Value $targetSize
    $script:ConfigOverrides[$vmSizeConfigKey] = $targetSize

    Write-Host ("Resize completed successfully. VM size is now '{0}'." -f $targetSize) -ForegroundColor Green
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
    $vmOption = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-name')
    if (-not [string]::IsNullOrWhiteSpace([string]$vmOption)) {
        $runtimeConfigOverrides['VM_NAME'] = $vmOption.Trim()
    }

    $runtime = Initialize-AzVmCommandRuntimeContext -AutoMode:$true -WindowsFlag:$WindowsFlag -LinuxFlag:$LinuxFlag -ConfigMapOverrides $runtimeConfigOverrides
    $context = $runtime.Context

    $resourceGroup = Resolve-AzVmTargetResourceGroup `
        -Options $Options `
        -AutoMode:$AutoMode `
        -DefaultResourceGroup ([string]$context.ResourceGroup) `
        -VmName ([string]$context.VmName) `
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

# Handles Get-AzVmMoveExpectedSourceResourceTypeCounts.
function Get-AzVmMoveExpectedSourceResourceTypeCounts {
    return [ordered]@{
        'Microsoft.Compute/disks' = 1
        'Microsoft.Compute/virtualMachines' = 1
        'Microsoft.Network/networkInterfaces' = 1
        'Microsoft.Network/networkSecurityGroups' = 1
        'Microsoft.Network/publicIPAddresses' = 1
        'Microsoft.Network/virtualNetworks' = 1
    }
}

# Handles Test-AzVmMoveResourceSetIsPurgeSafe.
function Test-AzVmMoveResourceSetIsPurgeSafe {
    param(
        [object[]]$Resources,
        [string]$VmName,
        [string]$OsDiskName
    )

    $expectedCounts = Get-AzVmMoveExpectedSourceResourceTypeCounts
    $resourceRows = @($Resources | Where-Object { $null -ne $_ })
    $actualCounts = Get-AzVmResourceTypeCountMap -Resources $resourceRows
    $unexpectedTypes = @($actualCounts.Keys | Where-Object { $expectedCounts.Keys -notcontains [string]$_ } | Sort-Object)
    $countMismatches = @()

    foreach ($typeName in @($expectedCounts.Keys)) {
        $expectedCount = [int]$expectedCounts[$typeName]
        $actualCount = 0
        if ($actualCounts.Contains([string]$typeName)) {
            $actualCount = [int]$actualCounts[[string]$typeName]
        }

        if ($actualCount -ne $expectedCount) {
            $countMismatches += ("{0} expected={1} actual={2}" -f [string]$typeName, $expectedCount, $actualCount)
        }
    }

    $vmMatch = @($resourceRows | Where-Object {
        [string]::Equals([string]$_.type, 'Microsoft.Compute/virtualMachines', [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$_.name, [string]$VmName, [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)

    $diskMatch = @($resourceRows | Where-Object {
        [string]::Equals([string]$_.type, 'Microsoft.Compute/disks', [System.StringComparison]::OrdinalIgnoreCase) -and
        [string]::Equals([string]$_.name, [string]$OsDiskName, [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)

    return [pscustomobject]@{
        IsSafe = ($unexpectedTypes.Count -eq 0 -and $countMismatches.Count -eq 0 -and @($vmMatch).Count -gt 0 -and @($diskMatch).Count -gt 0)
        ResourceCount = [int]$resourceRows.Count
        CountMap = $actualCounts
        UnexpectedTypes = @($unexpectedTypes)
        CountMismatches = @($countMismatches)
        VmMatched = (@($vmMatch).Count -gt 0)
        DiskMatched = (@($diskMatch).Count -gt 0)
    }
}

# Handles Get-AzVmMoveSourceGroupResources.
function Get-AzVmMoveSourceGroupResources {
    param(
        [string]$ResourceGroup
    )

    $resourcesJson = az resource list -g $ResourceGroup -o json --only-show-errors
    Assert-LastExitCode "az resource list (move source group)"
    return @(ConvertFrom-JsonArrayCompat -InputObject $resourcesJson)
}

# Handles Assert-AzVmMoveSourceGroupPurgeSafe.
function Assert-AzVmMoveSourceGroupPurgeSafe {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$OsDiskName
    )

    Assert-AzVmManagedResourceGroup -ResourceGroup $ResourceGroup -OperationName 'move'
    $resources = @(Get-AzVmMoveSourceGroupResources -ResourceGroup $ResourceGroup)
    $result = Test-AzVmMoveResourceSetIsPurgeSafe -Resources $resources -VmName $VmName -OsDiskName $OsDiskName
    if ([bool]$result.IsSafe) {
        return $result
    }

    $details = @()
    if (@($result.UnexpectedTypes).Count -gt 0) {
        $details += ("unexpected resource types: {0}" -f (@($result.UnexpectedTypes) -join ', '))
    }
    if (@($result.CountMismatches).Count -gt 0) {
        $details += ("count mismatches: {0}" -f (@($result.CountMismatches) -join '; '))
    }
    if (-not [bool]$result.VmMatched) {
        $details += ("vm '{0}' was not found in the source group inventory" -f $VmName)
    }
    if (-not [bool]$result.DiskMatched) {
        $details += ("os disk '{0}' was not found in the source group inventory" -f $OsDiskName)
    }

    Throw-FriendlyError `
        -Detail ("Source resource group '{0}' is not safe for automatic purge after move: {1}." -f $ResourceGroup, ($details -join '; ')) `
        -Code 62 `
        -Summary "Move command stopped before source-group deletion safety check." `
        -Hint "Inspect the extra resources in the source group and clean them up manually, or remove only the old group yourself after the move."
}

# Handles Wait-AzVmSnapshotCopyReady.
function Wait-AzVmSnapshotCopyReady {
    param(
        [string]$ResourceGroup,
        [string]$SnapshotName,
        [int]$MaxAttempts = 540,
        [int]$DelaySeconds = 20,
        [int]$NoProgressAttemptLimit = 45
    )

    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
    if ($DelaySeconds -lt 1) { $DelaySeconds = 1 }
    if ($NoProgressAttemptLimit -lt 1) { $NoProgressAttemptLimit = 1 }

    $previousProgressKey = ''
    $stagnantAttempts = 0

    for ($copyAttempt = 1; $copyAttempt -le $MaxAttempts; $copyAttempt++) {
        $copyStateJson = az snapshot show -g $ResourceGroup -n $SnapshotName --query "{provisioningState:provisioningState,snapshotAccessState:snapshotAccessState,completionPercent:completionPercent}" -o json --only-show-errors
        Assert-LastExitCode "az snapshot show (target copy state)"
        $copyState = ConvertFrom-JsonCompat -InputObject $copyStateJson
        $prov = [string]$copyState.provisioningState
        $acc = [string]$copyState.snapshotAccessState
        $pct = 0.0
        if ($null -ne $copyState.completionPercent) {
            $pct = [double]$copyState.completionPercent
        }

        $progressKey = ("{0}|{1}|{2:N1}" -f $prov, $acc, $pct)
        if ([string]::Equals([string]$progressKey, [string]$previousProgressKey, [System.StringComparison]::OrdinalIgnoreCase)) {
            $stagnantAttempts++
        }
        else {
            $stagnantAttempts = 0
            $previousProgressKey = $progressKey
        }

        Write-Host ("Target snapshot copy {0}/{1}: provisioningState={2}, accessState={3}, completionPercent={4:N1}" -f $copyAttempt, $MaxAttempts, $prov, $acc, $pct)

        if ([string]::Equals($prov, "Succeeded", [System.StringComparison]::OrdinalIgnoreCase) -and [string]::Equals($acc, "Available", [System.StringComparison]::OrdinalIgnoreCase) -and $pct -ge 100.0) {
            return $copyState
        }

        if ($stagnantAttempts -ge $NoProgressAttemptLimit) {
            throw ("Target snapshot copy made no observable progress for {0} attempt(s)." -f $NoProgressAttemptLimit)
        }

        if ($copyAttempt -ge $MaxAttempts) {
            throw "Target snapshot copy did not complete in expected time."
        }

        Start-Sleep -Seconds $DelaySeconds
    }

    throw "Target snapshot copy did not complete in expected time."
}

# Handles Test-AzVmTcpPortReachable.
function Test-AzVmTcpPortReachable {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$TimeoutSeconds = 5
    )

    if ([string]::IsNullOrWhiteSpace([string]$HostName) -or $Port -lt 1 -or $Port -gt 65535) {
        return $false
    }

    if ($TimeoutSeconds -lt 1) { $TimeoutSeconds = 1 }

    $client = New-Object System.Net.Sockets.TcpClient
    $waitHandle = $null
    try {
        $async = $client.BeginConnect([string]$HostName, [int]$Port, $null, $null)
        $waitHandle = $async.AsyncWaitHandle
        if (-not $waitHandle.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds), $false)) {
            return $false
        }

        $client.EndConnect($async)
        return $client.Connected
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $waitHandle) {
            try { $waitHandle.Close() } catch { }
        }
        try { $client.Dispose() } catch { }
    }
}

# Handles Wait-AzVmTcpPortReachable.
function Wait-AzVmTcpPortReachable {
    param(
        [string]$HostName,
        [int]$Port,
        [int]$MaxAttempts = 18,
        [int]$DelaySeconds = 10,
        [int]$TimeoutSeconds = 5,
        [string]$Label = 'tcp port'
    )

    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
    if ($DelaySeconds -lt 1) { $DelaySeconds = 1 }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Host ("Connectivity check ({0}) {1}:{2} attempt {3}/{4}" -f $Label, $HostName, $Port, $attempt, $MaxAttempts)
        if (Test-AzVmTcpPortReachable -HostName $HostName -Port $Port -TimeoutSeconds $TimeoutSeconds) {
            return $true
        }
        Start-Sleep -Seconds $DelaySeconds
    }

    return $false
}

# Handles Assert-AzVmMoveTargetParity.
function Assert-AzVmMoveTargetParity {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$ExpectedRegion,
        [string]$ExpectedVmSize,
        [string]$ExpectedDiskSku,
        [int]$ExpectedDiskSizeGb,
        [bool]$ExpectedDiskSupportsHibernation,
        [bool]$ExpectedVmHibernationEnabled
    )

    $vmJson = az vm show -g $ResourceGroup -n $VmName -o json --only-show-errors
    Assert-LastExitCode "az vm show (move target parity)"
    $vmObject = ConvertFrom-JsonCompat -InputObject $vmJson
    if ($null -eq $vmObject) {
        throw "Target VM metadata could not be parsed."
    }

    $actualRegion = [string]$vmObject.location
    $actualVmSize = [string]$vmObject.hardwareProfile.vmSize
    $actualVmHibernation = $false
    if ($vmObject.PSObject.Properties.Match('additionalCapabilities').Count -gt 0 -and $null -ne $vmObject.additionalCapabilities) {
        if ($vmObject.additionalCapabilities.PSObject.Properties.Match('hibernationEnabled').Count -gt 0 -and $null -ne $vmObject.additionalCapabilities.hibernationEnabled) {
            $actualVmHibernation = [bool]$vmObject.additionalCapabilities.hibernationEnabled
        }
    }

    $diskId = [string]$vmObject.storageProfile.osDisk.managedDisk.id
    if ([string]::IsNullOrWhiteSpace([string]$diskId)) {
        throw "Target VM OS disk id could not be resolved."
    }

    $diskJson = az disk show --ids $diskId -o json --only-show-errors
    Assert-LastExitCode "az disk show (move target parity)"
    $diskObject = ConvertFrom-JsonCompat -InputObject $diskJson
    if ($null -eq $diskObject) {
        throw "Target disk metadata could not be parsed."
    }

    $actualDiskSku = [string]$diskObject.sku.name
    $actualDiskSizeGb = [int]$diskObject.diskSizeGb
    $actualDiskSupportsHibernation = $false
    if ($diskObject.PSObject.Properties.Match('supportsHibernation').Count -gt 0 -and $null -ne $diskObject.supportsHibernation) {
        $actualDiskSupportsHibernation = [bool]$diskObject.supportsHibernation
    }

    if (-not [string]::Equals([string]$actualRegion, [string]$ExpectedRegion, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Target VM region mismatch. Expected '{0}', actual '{1}'." -f $ExpectedRegion, $actualRegion)
    }
    if (-not [string]::Equals([string]$actualVmSize, [string]$ExpectedVmSize, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Target VM size mismatch. Expected '{0}', actual '{1}'." -f $ExpectedVmSize, $actualVmSize)
    }
    if (-not [string]::Equals([string]$actualDiskSku, [string]$ExpectedDiskSku, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Target disk sku mismatch. Expected '{0}', actual '{1}'." -f $ExpectedDiskSku, $actualDiskSku)
    }
    if ($actualDiskSizeGb -ne $ExpectedDiskSizeGb) {
        throw ("Target disk size mismatch. Expected '{0}', actual '{1}'." -f $ExpectedDiskSizeGb, $actualDiskSizeGb)
    }
    if ([bool]$ExpectedDiskSupportsHibernation -ne [bool]$actualDiskSupportsHibernation) {
        throw ("Target disk hibernation-support mismatch. Expected '{0}', actual '{1}'." -f $ExpectedDiskSupportsHibernation, $actualDiskSupportsHibernation)
    }
    if ([bool]$ExpectedVmHibernationEnabled -ne [bool]$actualVmHibernation) {
        throw ("Target VM hibernation setting mismatch. Expected '{0}', actual '{1}'." -f $ExpectedVmHibernationEnabled, $actualVmHibernation)
    }

    return [pscustomobject]@{
        Vm = $vmObject
        Disk = $diskObject
    }
}

# Handles Invoke-AzVmMoveTargetHealthCheck.
function Invoke-AzVmMoveTargetHealthCheck {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$Platform,
        [string]$ExpectedRegion,
        [string]$ExpectedVmSize,
        [string]$ExpectedDiskSku,
        [int]$ExpectedDiskSizeGb,
        [bool]$ExpectedDiskSupportsHibernation,
        [bool]$ExpectedVmHibernationEnabled,
        [string]$SshPort,
        [string]$RdpPort
    )

    $parity = Assert-AzVmMoveTargetParity `
        -ResourceGroup $ResourceGroup `
        -VmName $VmName `
        -ExpectedRegion $ExpectedRegion `
        -ExpectedVmSize $ExpectedVmSize `
        -ExpectedDiskSku $ExpectedDiskSku `
        -ExpectedDiskSizeGb $ExpectedDiskSizeGb `
        -ExpectedDiskSupportsHibernation:$ExpectedDiskSupportsHibernation `
        -ExpectedVmHibernationEnabled:$ExpectedVmHibernationEnabled

    $execResult = Invoke-AzVmExecCommand `
        -Options @{ group = $ResourceGroup; 'vm-name' = $VmName; 'update-task' = '29' } `
        -AutoMode:$true `
        -WindowsFlag:([string]::Equals([string]$Platform, 'windows', [System.StringComparison]::OrdinalIgnoreCase)) `
        -LinuxFlag:([string]::Equals([string]$Platform, 'linux', [System.StringComparison]::OrdinalIgnoreCase)) `
        -TaskOutcomeModeOverride 'strict'

    $vmDetailContext = [ordered]@{
        ResourceGroup = $ResourceGroup
        VmName = $VmName
        AzLocation = $ExpectedRegion
        SshPort = $SshPort
    }
    $targetVmDetails = Get-AzVmVmDetails -Context $vmDetailContext
    $hostName = [string]$targetVmDetails.VmFqdn
    if ([string]::IsNullOrWhiteSpace([string]$hostName)) {
        $hostName = [string]$targetVmDetails.PublicIP
    }
    if ([string]::IsNullOrWhiteSpace([string]$hostName)) {
        throw "Target VM connection host could not be resolved."
    }

    $probePortText = if ([string]::Equals([string]$Platform, 'windows', [System.StringComparison]::OrdinalIgnoreCase)) { [string]$RdpPort } else { [string]$SshPort }
    $probeLabel = if ([string]::Equals([string]$Platform, 'windows', [System.StringComparison]::OrdinalIgnoreCase)) { 'rdp' } else { 'ssh' }
    $probePort = 0
    if (-not [int]::TryParse($probePortText, [ref]$probePort) -or $probePort -lt 1 -or $probePort -gt 65535) {
        throw ("Target VM {0} port could not be resolved from configuration." -f $probeLabel)
    }

    $reachable = Wait-AzVmTcpPortReachable -HostName $hostName -Port $probePort -MaxAttempts 18 -DelaySeconds 10 -TimeoutSeconds 5 -Label $probeLabel
    if (-not $reachable) {
        throw ("Target VM {0} port {1} did not become reachable on host '{2}'." -f $probeLabel, $probePort, $hostName)
    }

    return [pscustomobject]@{
        HostName = $hostName
        ProbePort = $probePort
        ProbeLabel = $probeLabel
        Vm = $parity.Vm
        Disk = $parity.Disk
    }
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
    $vmOptionValue = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-name')
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
        -VmName ([string]$context.VmName) `
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

        $selectedResourceGroup = Select-AzVmResourceGroupInteractive -DefaultResourceGroup $resourceGroup -VmName ([string]$context.VmName)
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
    $sourceResourceGroup = [string]$resourceGroup
    $sourceVmName = [string]$vmName
    $sourceLifecycleSnapshot = $null
    if ([string]::Equals([string]$OperationLabel, 'move', [System.StringComparison]::OrdinalIgnoreCase)) {
        $sourceLifecycleSnapshot = Get-AzVmVmLifecycleSnapshot -ResourceGroup $resourceGroup -VmName $vmName
    }
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

        $sourceOsDiskName = [string]$vmObject.storageProfile.osDisk.name
        if ([string]::IsNullOrWhiteSpace([string]$sourceOsDiskName)) {
            $sourceOsDiskName = [string]($sourceOsDiskId -split '/')[-1]
        }
        Assert-AzVmMoveSourceGroupPurgeSafe -ResourceGroup $resourceGroup -VmName $vmName -OsDiskName $sourceOsDiskName | Out-Null

        $sourceDiskJson = az disk show --ids $sourceOsDiskId -o json --only-show-errors
        Assert-LastExitCode "az disk show (source os disk)"
        $sourceDisk = ConvertFrom-JsonCompat -InputObject $sourceDiskJson
        $sourceDiskSku = [string]$sourceDisk.sku.name
        $sourceOsType = [string]$sourceDisk.osType
        $sourceDiskSizeGb = 0
        if ($null -ne $sourceDisk.diskSizeGb) {
            $sourceDiskSizeGb = [int]$sourceDisk.diskSizeGb
        }
        $sourceDiskSupportsHibernation = $false
        if ($sourceDisk.PSObject.Properties.Match('supportsHibernation').Count -gt 0 -and $null -ne $sourceDisk.supportsHibernation) {
            $sourceDiskSupportsHibernation = [bool]$sourceDisk.supportsHibernation
        }
        $sourceVmHibernationEnabled = $false
        if ($null -ne $sourceLifecycleSnapshot) {
            $sourceVmHibernationEnabled = [bool]$sourceLifecycleSnapshot.HibernationEnabled
        }
        if ([string]::IsNullOrWhiteSpace([string]$sourceDiskSku)) { $sourceDiskSku = "StandardSSD_LRS" }
        if ([string]::IsNullOrWhiteSpace([string]$sourceOsType)) { $sourceOsType = "Windows" }

        $targetRegionCode = Get-AzVmRegionCode -Location $targetRegion
        $nameTokens = @{
            VM_NAME = [string]$context.VmName
            REGION_CODE = [string]$targetRegionCode
        }

        $targetResourceGroupTemplate = [string](Get-ConfigValue -Config $effectiveConfigMap -Key "RESOURCE_GROUP_TEMPLATE" -DefaultValue "rg-{VM_NAME}-{REGION_CODE}-g{N}")
        $targetResourceGroup = Resolve-AzVmResourceGroupNameFromTemplate `
            -Template $targetResourceGroupTemplate `
            -VmName ([string]$context.VmName) `
            -RegionCode $targetRegionCode `
            -UseNextIndex

        $targetDiskTemplate = [string](Get-ConfigValue -Config $effectiveConfigMap -Key "VM_DISK_NAME_TEMPLATE" -DefaultValue "disk-{VM_NAME}-{REGION_CODE}-n{N}")
        $targetVnetTemplate = [string](Get-ConfigValue -Config $effectiveConfigMap -Key "VNET_NAME_TEMPLATE" -DefaultValue "net-{VM_NAME}-{REGION_CODE}-n{N}")
        $targetSubnetTemplate = [string](Get-ConfigValue -Config $effectiveConfigMap -Key "SUBNET_NAME_TEMPLATE" -DefaultValue "subnet-{VM_NAME}-{REGION_CODE}-n{N}")
        $targetNsgTemplate = [string](Get-ConfigValue -Config $effectiveConfigMap -Key "NSG_NAME_TEMPLATE" -DefaultValue "nsg-{VM_NAME}-{REGION_CODE}-n{N}")
        $targetNsgRuleTemplate = [string](Get-ConfigValue -Config $effectiveConfigMap -Key "NSG_RULE_NAME_TEMPLATE" -DefaultValue "nsgrule-{VM_NAME}-{REGION_CODE}-n{N}")
        $targetIpTemplate = [string](Get-ConfigValue -Config $effectiveConfigMap -Key "PUBLIC_IP_NAME_TEMPLATE" -DefaultValue "ip-{VM_NAME}-{REGION_CODE}-n{N}")
        $targetNicTemplate = [string](Get-ConfigValue -Config $effectiveConfigMap -Key "NIC_NAME_TEMPLATE" -DefaultValue "nic-{VM_NAME}-{REGION_CODE}-n{N}")

        $targetVmName = [string]$context.VmName
        $targetDiskName = Resolve-AzVmNameFromTemplate -Template $targetDiskTemplate -ResourceType 'disk' -VmName ([string]$context.VmName) -RegionCode $targetRegionCode -ResourceGroup $targetResourceGroup -UseNextIndex
        $targetVnetName = Resolve-AzVmNameFromTemplate -Template $targetVnetTemplate -ResourceType 'net' -VmName ([string]$context.VmName) -RegionCode $targetRegionCode -ResourceGroup $targetResourceGroup -UseNextIndex
        $targetSubnetName = Resolve-AzVmNameFromTemplate -Template $targetSubnetTemplate -ResourceType 'subnet' -VmName ([string]$context.VmName) -RegionCode $targetRegionCode -ResourceGroup $targetResourceGroup -UseNextIndex
        $targetNsgName = Resolve-AzVmNameFromTemplate -Template $targetNsgTemplate -ResourceType 'nsg' -VmName ([string]$context.VmName) -RegionCode $targetRegionCode -ResourceGroup $targetResourceGroup -UseNextIndex
        $targetNsgRuleName = Resolve-AzVmNameFromTemplate -Template $targetNsgRuleTemplate -ResourceType 'nsgrule' -VmName ([string]$context.VmName) -RegionCode $targetRegionCode -ResourceGroup $targetResourceGroup -UseNextIndex
        $targetIpName = Resolve-AzVmNameFromTemplate -Template $targetIpTemplate -ResourceType 'ip' -VmName ([string]$context.VmName) -RegionCode $targetRegionCode -ResourceGroup $targetResourceGroup -UseNextIndex
        $targetNicName = Resolve-AzVmNameFromTemplate -Template $targetNicTemplate -ResourceType 'nic' -VmName ([string]$context.VmName) -RegionCode $targetRegionCode -ResourceGroup $targetResourceGroup -UseNextIndex

        Write-Host ("Target naming resolved: rg={0}, vm={1}, disk={2}" -f $targetResourceGroup, $targetVmName, $targetDiskName)

        $targetGroupCreatedInRun = $false
        $sourceSnapshotName = ''
        $targetSnapshotName = ''
        $sourceSnapshotCreated = $false
        $targetSnapshotCreated = $false
        $targetVmCreated = $false
        $targetDiskCreated = $false
        $targetNetworkAttempted = $false
        $sourceNeedsStartRecovery = ($null -ne $sourceLifecycleSnapshot -and [string]::Equals([string]$sourceLifecycleSnapshot.NormalizedState, 'started', [System.StringComparison]::OrdinalIgnoreCase))
        $sourceWasDeallocatedInMove = $false

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
            $sourceAlreadyDeallocated = ($null -ne $sourceLifecycleSnapshot -and [string]$sourceLifecycleSnapshot.NormalizedState -in @('deallocated','hibernated'))
            if (-not $sourceAlreadyDeallocated) {
                Invoke-TrackedAction -Label ("az vm deallocate -g {0} -n {1}" -f $resourceGroup, $vmName) -Action {
                    az vm deallocate -g $resourceGroup -n $vmName -o none --only-show-errors
                    Assert-LastExitCode "az vm deallocate (source)"
                } | Out-Null
                $sourceDeallocated = Wait-AzVmVmPowerState -ResourceGroup $resourceGroup -VmName $vmName -DesiredPowerState "VM deallocated" -MaxAttempts 24 -DelaySeconds 10
                if (-not $sourceDeallocated) {
                    throw "Source VM did not reach deallocated state before snapshot creation."
                }
                $sourceWasDeallocatedInMove = $true
            }

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
            $sourceSnapshotName = ("snap-src-{0}-{1}" -f [string]$context.VmName, $stamp)
            $targetSnapshotName = ("snap-dst-{0}-{1}" -f [string]$context.VmName, $stamp)

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

            Wait-AzVmSnapshotCopyReady -ResourceGroup $targetResourceGroup -SnapshotName $targetSnapshotName -MaxAttempts 540 -DelaySeconds 20 -NoProgressAttemptLimit 45 | Out-Null

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

            if ($sourceDiskSupportsHibernation) {
                Invoke-TrackedAction -Label ("az disk update -g {0} -n {1} --set supportsHibernation=true" -f $targetResourceGroup, $targetDiskName) -Action {
                    az disk update -g $targetResourceGroup -n $targetDiskName --set supportsHibernation=true -o none --only-show-errors
                    Assert-LastExitCode "az disk update (target supportsHibernation)"
                } | Out-Null
            }

            $targetCreateJson = Invoke-TrackedAction -Label ("az vm create -g {0} -n {1} --attach-os-disk" -f $targetResourceGroup, $targetVmName) -Action {
                $vmCreateArgs = @("vm", "create", "--resource-group", $targetResourceGroup, "--name", $targetVmName, "--attach-os-disk", $targetDiskName, "--os-type", $sourceOsType, "--size", $currentSize, "--nics", $targetNicName, "-o", "json", "--only-show-errors")
                az @vmCreateArgs
            }
            Assert-LastExitCode "az vm create (target attach-os-disk)"
            $targetCreateObj = ConvertFrom-JsonCompat -InputObject $targetCreateJson
            if (-not $targetCreateObj.id) { throw "Target VM creation returned no VM id." }
            $targetVmCreated = $true

            $targetNeedsDeallocate = $sourceVmHibernationEnabled -or (-not [string]::Equals([string]$targetSize, [string]$currentSize, [System.StringComparison]::OrdinalIgnoreCase))
            if ($targetNeedsDeallocate) {
                Invoke-TrackedAction -Label ("az vm deallocate -g {0} -n {1}" -f $targetResourceGroup, $targetVmName) -Action {
                    az vm deallocate -g $targetResourceGroup -n $targetVmName -o none --only-show-errors
                    Assert-LastExitCode "az vm deallocate (target)"
                } | Out-Null
                $targetDeallocated = Wait-AzVmVmPowerState -ResourceGroup $targetResourceGroup -VmName $targetVmName -DesiredPowerState "VM deallocated" -MaxAttempts 18 -DelaySeconds 10
                if (-not $targetDeallocated) { throw "Target VM did not reach deallocated state before resize." }
            }

            if ($sourceVmHibernationEnabled) {
                Invoke-TrackedAction -Label ("az vm update -g {0} -n {1} --enable-hibernation true" -f $targetResourceGroup, $targetVmName) -Action {
                    az vm update -g $targetResourceGroup -n $targetVmName --enable-hibernation true -o none --only-show-errors
                    Assert-LastExitCode "az vm update (target enable hibernation)"
                } | Out-Null
            }

            if (-not [string]::Equals([string]$targetSize, [string]$currentSize, [System.StringComparison]::OrdinalIgnoreCase)) {
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
            $sourceRecoveryNote = ''
            if ($sourceNeedsStartRecovery -and $sourceWasDeallocatedInMove) {
                try {
                    Invoke-TrackedAction -Label ("az vm start -g {0} -n {1}" -f $sourceResourceGroup, $sourceVmName) -Action {
                        az vm start -g $sourceResourceGroup -n $sourceVmName -o none --only-show-errors
                        Assert-LastExitCode "az vm start (source recovery)"
                    } | Out-Null
                    $sourceRecovered = Wait-AzVmVmRunningState -ResourceGroup $sourceResourceGroup -VmName $sourceVmName -MaxAttempts 6 -DelaySeconds 10
                    if ($sourceRecovered) {
                        $sourceRecoveryNote = " Source VM was restarted after rollback."
                    }
                    else {
                        $sourceRecoveryNote = " Source VM restart was attempted after rollback but running state was not confirmed."
                    }
                }
                catch {
                    $sourceRecoveryNote = (" Source VM restart failed after rollback: {0}" -f $_.Exception.Message)
                }
            }
            Throw-FriendlyError `
                -Detail ("Snapshot-based region migration failed. Cleanup completed. Error: {0}.{1}" -f $innerError.Exception.Message, $sourceRecoveryNote) `
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
        try {
            $healthCheck = Invoke-AzVmMoveTargetHealthCheck `
                -ResourceGroup $activeResourceGroup `
                -VmName $activeVmName `
                -Platform $platform `
                -ExpectedRegion $targetRegion `
                -ExpectedVmSize $currentSize `
                -ExpectedDiskSku $sourceDiskSku `
                -ExpectedDiskSizeGb $sourceDiskSizeGb `
                -ExpectedDiskSupportsHibernation:$sourceDiskSupportsHibernation `
                -ExpectedVmHibernationEnabled:$sourceVmHibernationEnabled `
                -SshPort ([string]$context.SshPort) `
                -RdpPort ([string]$context.RdpPort)

            Write-Host ("Target move health gate passed: {0} {1}:{2}" -f [string]$healthCheck.ProbeLabel, [string]$healthCheck.HostName, [int]$healthCheck.ProbePort) -ForegroundColor Green
        }
        catch {
            Throw-FriendlyError `
                -Detail ("Target region cutover validation failed for VM '{0}' in resource group '{1}': {2}" -f $activeVmName, $activeResourceGroup, $_.Exception.Message) `
                -Code 62 `
                -Summary "Move command stopped before source cleanup because target validation did not pass." `
                -Hint "Review the target VM state, rerun the health check, and only delete the old source group after the target is confirmed healthy."
        }
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
        try {
            Invoke-TrackedAction -Label ("az group delete -n {0} --yes --no-wait" -f $sourceResourceGroup) -Action {
                az group delete -n $sourceResourceGroup --yes --no-wait --only-show-errors
                Assert-LastExitCode "az group delete (source cleanup)"
            } | Out-Null
            Invoke-TrackedAction -Label ("az group wait -n {0} --deleted" -f $sourceResourceGroup) -Action {
                az group wait -n $sourceResourceGroup --deleted --only-show-errors
                Assert-LastExitCode "az group wait --deleted (source cleanup)"
            } | Out-Null
        }
        catch {
            Throw-FriendlyError `
                -Detail ("Target cutover to resource group '{0}' succeeded, but old source resource group '{1}' could not be deleted: {2}" -f $activeResourceGroup, $sourceResourceGroup, $_.Exception.Message) `
                -Code 62 `
                -Summary "Move command completed target cutover but old-source cleanup failed." `
                -Hint ("Delete the old source group '{0}' manually after confirming the new target is healthy." -f $sourceResourceGroup)
        }

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
    $vmName = [string](Get-ConfigValue -Config $configMap -Key 'VM_NAME' -DefaultValue '')
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
        $resourceGroup = Select-AzVmResourceGroupInteractive -DefaultResourceGroup $defaultResourceGroup -VmName $vmName
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
                    -Hint "Set VM_NAME in .env to the exact Azure VM name in the selected group."
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

# Handles Test-AzVmLocalWindowsHost.
function Test-AzVmLocalWindowsHost {
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

# Handles Resolve-AzVmConnectionRoleName.
function Resolve-AzVmConnectionRoleName {
    param(
        [hashtable]$Options
    )

    $roleRaw = [string](Get-AzVmCliOptionText -Options $Options -Name 'user')
    if ([string]::IsNullOrWhiteSpace([string]$roleRaw)) {
        return 'manager'
    }

    $role = $roleRaw.Trim().ToLowerInvariant()
    if ($role -notin @('manager','assistant')) {
        Throw-FriendlyError `
            -Detail ("Unsupported connection user '{0}'." -f $roleRaw) `
            -Code 66 `
            -Summary "Connection user is invalid." `
            -Hint "Use --user=manager or --user=assistant."
    }

    return $role
}

# Handles Resolve-AzVmConnectionPortText.
function Resolve-AzVmConnectionPortText {
    param(
        [hashtable]$ConfigMap,
        [string]$Key,
        [string]$DefaultValue,
        [string]$Label
    )

    $rawValue = [string](Get-ConfigValue -Config $ConfigMap -Key $Key -DefaultValue $DefaultValue)
    $portText = $rawValue.Trim()
    if (-not ($portText -match '^\d+$')) {
        Throw-FriendlyError `
            -Detail ("Config value '{0}' is invalid for {1}: '{2}'." -f $Key, $Label, $rawValue) `
            -Code 66 `
            -Summary ("{0} port is invalid." -f $Label) `
            -Hint ("Set {0} to a numeric TCP port value in .env." -f $Key)
    }

    return $portText
}

# Handles Get-AzVmManagedVmMatchRows.
function Get-AzVmManagedVmMatchRows {
    param(
        [string]$VmName
    )

    $needle = [string]$VmName
    if ([string]::IsNullOrWhiteSpace([string]$needle)) {
        return @()
    }

    $matches = @()
    $groups = @(Get-AzVmManagedResourceGroupRows)
    foreach ($groupRow in @($groups)) {
        $resourceGroup = [string]$groupRow.name
        if ([string]::IsNullOrWhiteSpace([string]$resourceGroup)) {
            continue
        }

        $vmNames = @(Get-AzVmVmNamesForResourceGroup -ResourceGroup $resourceGroup)
        foreach ($candidateVmName in @($vmNames)) {
            if ([string]::Equals([string]$candidateVmName, $needle, [System.StringComparison]::OrdinalIgnoreCase)) {
                $matches += [pscustomobject]@{
                    ResourceGroup = $resourceGroup
                    VmName = [string]$candidateVmName
                }
            }
        }
    }

    return @($matches)
}

# Handles Resolve-AzVmManagedVmTarget.
function Resolve-AzVmManagedVmTarget {
    param(
        [hashtable]$Options,
        [hashtable]$ConfigMap,
        [string]$OperationName
    )

    $defaultResourceGroup = [string](Get-ConfigValue -Config $ConfigMap -Key 'RESOURCE_GROUP' -DefaultValue '')
    $defaultVmName = [string](Get-ConfigValue -Config $ConfigMap -Key 'VM_NAME' -DefaultValue '')
    $groupOption = [string](Get-AzVmCliOptionText -Options $Options -Name 'group')
    $vmNameOption = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-name')
    $requestedResourceGroup = $groupOption.Trim()
    $requestedVmName = $vmNameOption.Trim()

    if (-not [string]::IsNullOrWhiteSpace([string]$requestedResourceGroup)) {
        $resourceGroup = Resolve-AzVmTargetResourceGroup `
            -Options $Options `
            -AutoMode:$false `
            -DefaultResourceGroup $defaultResourceGroup `
            -VmName $requestedVmName `
            -OperationName $OperationName

        if ([string]::IsNullOrWhiteSpace([string]$requestedVmName)) {
            $vmName = Select-AzVmVmInteractive -ResourceGroup $resourceGroup -DefaultVmName $defaultVmName
        }
        else {
            $vmNames = @(Get-AzVmVmNamesForResourceGroup -ResourceGroup $resourceGroup)
            $resolvedVmName = @($vmNames | Where-Object { [string]::Equals([string]$_, $requestedVmName, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
            if (@($resolvedVmName).Count -eq 0) {
                Throw-FriendlyError `
                    -Detail ("VM '{0}' was not found in resource group '{1}'." -f $requestedVmName, $resourceGroup) `
                    -Code 66 `
                    -Summary ("{0} command could not resolve the target VM." -f $OperationName) `
                    -Hint "Provide an exact VM name in the selected resource group, or omit --vm-name to select interactively."
            }
            $vmName = [string]$resolvedVmName[0]
        }

        return [pscustomobject]@{
            ResourceGroup = $resourceGroup
            VmName = $vmName
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$requestedVmName)) {
        $activeGroupMatches = $false
        if (-not [string]::IsNullOrWhiteSpace([string]$defaultResourceGroup) -and (Test-AzVmResourceGroupManaged -ResourceGroup $defaultResourceGroup)) {
            $activeVmNames = @(Get-AzVmVmNamesForResourceGroup -ResourceGroup $defaultResourceGroup)
            foreach ($candidateVmName in @($activeVmNames)) {
                if ([string]::Equals([string]$candidateVmName, $requestedVmName, [System.StringComparison]::OrdinalIgnoreCase)) {
                    return [pscustomobject]@{
                        ResourceGroup = $defaultResourceGroup
                        VmName = [string]$candidateVmName
                    }
                }
            }
            $activeGroupMatches = $true
        }

        $matches = @(Get-AzVmManagedVmMatchRows -VmName $requestedVmName)
        if (@($matches).Count -eq 1) {
            return [pscustomobject]@{
                ResourceGroup = [string]$matches[0].ResourceGroup
                VmName = [string]$matches[0].VmName
            }
        }

        if (@($matches).Count -gt 1) {
            $matchGroups = @($matches | ForEach-Object { [string]$_.ResourceGroup } | Sort-Object -Unique)
            Throw-FriendlyError `
                -Detail ("VM name '{0}' was found in multiple managed resource groups: {1}." -f $requestedVmName, ($matchGroups -join ', ')) `
                -Code 66 `
                -Summary ("{0} command needs an explicit resource group." -f $OperationName) `
                -Hint "Provide --group=<resource-group> together with --vm-name=<name>."
        }

        $notFoundHint = if ($activeGroupMatches) {
            "Provide --group=<resource-group> or select another exact VM name."
        }
        else {
            "Select a managed resource group interactively or provide both --group and --vm-name."
        }

        Throw-FriendlyError `
            -Detail ("VM '{0}' was not found in az-vm managed resource groups." -f $requestedVmName) `
            -Code 66 `
            -Summary ("{0} command could not find the target VM." -f $OperationName) `
            -Hint $notFoundHint
    }

    $resourceGroup = Select-AzVmResourceGroupInteractive -DefaultResourceGroup $defaultResourceGroup -VmName $defaultVmName
    $vmName = Select-AzVmVmInteractive -ResourceGroup $resourceGroup -DefaultVmName $defaultVmName
    return [pscustomobject]@{
        ResourceGroup = $resourceGroup
        VmName = $vmName
    }
}

# Handles Resolve-AzVmConnectionTarget.
function Resolve-AzVmConnectionTarget {
    param(
        [hashtable]$Options,
        [hashtable]$ConfigMap,
        [string]$OperationName
    )

    return (Resolve-AzVmManagedVmTarget -Options $Options -ConfigMap $ConfigMap -OperationName $OperationName)
}

# Handles Resolve-AzVmDoActionName.
function Resolve-AzVmDoActionName {
    param(
        [string]$RawValue,
        [switch]$AllowEmpty
    )

    $action = if ($null -eq $RawValue) { '' } else { [string]$RawValue }
    $normalized = $action.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace([string]$normalized)) {
        if ($AllowEmpty) {
            return ''
        }

        Throw-FriendlyError `
            -Detail "Option '--vm-action' requires a value." `
            -Code 2 `
            -Summary "VM action is missing." `
            -Hint "Use --vm-action=status|start|restart|stop|deallocate|hibernate."
    }

    if ($normalized -eq 'release') {
        Throw-FriendlyError `
            -Detail "Option '--vm-action=release' is no longer supported." `
            -Code 2 `
            -Summary "VM action is invalid." `
            -Hint "Use --vm-action=deallocate."
    }

    if ($normalized -notin @('status','start','restart','stop','deallocate','hibernate')) {
        Throw-FriendlyError `
            -Detail ("Invalid --vm-action value '{0}'." -f $RawValue) `
            -Code 2 `
            -Summary "VM action is invalid." `
            -Hint "Use --vm-action=status|start|restart|stop|deallocate|hibernate."
    }

    return $normalized
}

# Handles Resolve-AzVmVmLifecycleFieldText.
function Resolve-AzVmVmLifecycleFieldText {
    param(
        [string]$DisplayText,
        [string]$CodeText,
        [string]$DefaultText = '(none)'
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$DisplayText)) {
        return [string]$DisplayText
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$CodeText)) {
        return [string]$CodeText
    }

    return [string]$DefaultText
}

# Handles Resolve-AzVmVmLifecycleStateLabel.
function Resolve-AzVmVmLifecycleStateLabel {
    param(
        [string]$PowerStateDisplay,
        [string]$PowerStateCode,
        [string]$HibernationStateDisplay,
        [string]$HibernationStateCode
    )

    $powerText = ((@([string]$PowerStateDisplay, [string]$PowerStateCode) -join ' ').Trim()).ToLowerInvariant()
    $hibernationText = ((@([string]$HibernationStateDisplay, [string]$HibernationStateCode) -join ' ').Trim()).ToLowerInvariant()

    if ($hibernationText -match 'hibernat') {
        return 'hibernated'
    }
    if ($powerText -match 'running') {
        return 'started'
    }
    if (($powerText -match 'stopped') -and -not ($powerText -match 'deallocated')) {
        return 'stopped'
    }
    if ($powerText -match 'deallocated') {
        return 'deallocated'
    }

    return 'other'
}

# Handles ConvertTo-AzVmVmLifecycleSnapshot.
function ConvertTo-AzVmVmLifecycleSnapshot {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [object]$VmObject,
        [object]$InstanceViewObject
    )

    $powerStateCode = ''
    $powerStateDisplay = ''
    $provisioningStateCode = ''
    $provisioningStateDisplay = ''
    $hibernationStateCode = ''
    $hibernationStateDisplay = ''

    $statusEntries = @()
    if ($null -ne $InstanceViewObject -and $InstanceViewObject.PSObject.Properties.Match('instanceView').Count -gt 0 -and $null -ne $InstanceViewObject.instanceView) {
        $statusEntries = @(ConvertTo-ObjectArrayCompat -InputObject $InstanceViewObject.instanceView.statuses)
    }
    if ($statusEntries.Count -eq 0) {
        $statusEntries = @(ConvertTo-ObjectArrayCompat -InputObject $InstanceViewObject.statuses)
    }

    foreach ($status in @($statusEntries)) {
        $statusCode = [string]$status.code
        $statusDisplay = [string]$status.displayStatus
        if ([string]::IsNullOrWhiteSpace([string]$statusCode)) {
            continue
        }

        if ($statusCode.StartsWith('PowerState/', [System.StringComparison]::OrdinalIgnoreCase)) {
            $powerStateCode = $statusCode
            $powerStateDisplay = $statusDisplay
            continue
        }
        if ($statusCode.StartsWith('ProvisioningState/', [System.StringComparison]::OrdinalIgnoreCase)) {
            $provisioningStateCode = $statusCode
            $provisioningStateDisplay = $statusDisplay
            continue
        }
        if ($statusCode.StartsWith('HibernationState/', [System.StringComparison]::OrdinalIgnoreCase)) {
            $hibernationStateCode = $statusCode
            $hibernationStateDisplay = $statusDisplay
            continue
        }
    }

    $hibernationEnabled = $false
    if ($null -ne $VmObject -and $VmObject.PSObject.Properties.Match('hibernationEnabled').Count -gt 0 -and $null -ne $VmObject.hibernationEnabled) {
        $hibernationEnabled = [bool]$VmObject.hibernationEnabled
    }
    elseif ($null -ne $VmObject -and $VmObject.PSObject.Properties.Match('additionalCapabilities').Count -gt 0 -and $null -ne $VmObject.additionalCapabilities) {
        if ($VmObject.additionalCapabilities.PSObject.Properties.Match('hibernationEnabled').Count -gt 0 -and $null -ne $VmObject.additionalCapabilities.hibernationEnabled) {
            $hibernationEnabled = [bool]$VmObject.additionalCapabilities.hibernationEnabled
        }
    }

    $normalizedState = Resolve-AzVmVmLifecycleStateLabel `
        -PowerStateDisplay $powerStateDisplay `
        -PowerStateCode $powerStateCode `
        -HibernationStateDisplay $hibernationStateDisplay `
        -HibernationStateCode $hibernationStateCode

    return [pscustomobject]@{
        ResourceGroup = [string]$ResourceGroup
        VmName = [string]$VmName
        OsType = [string]$VmObject.osType
        Location = [string]$VmObject.location
        HibernationEnabled = [bool]$hibernationEnabled
        ProvisioningStateCode = [string]$provisioningStateCode
        ProvisioningStateDisplay = [string]$provisioningStateDisplay
        PowerStateCode = [string]$powerStateCode
        PowerStateDisplay = [string]$powerStateDisplay
        HibernationStateCode = [string]$hibernationStateCode
        HibernationStateDisplay = [string]$hibernationStateDisplay
        NormalizedState = [string]$normalizedState
    }
}

# Handles Get-AzVmVmLifecycleSnapshot.
function Get-AzVmVmLifecycleSnapshot {
    param(
        [string]$ResourceGroup,
        [string]$VmName
    )

    $vmJson = az vm show `
        -g $ResourceGroup `
        -n $VmName `
        --query "{location:location,osType:storageProfile.osDisk.osType,hibernationEnabled:additionalCapabilities.hibernationEnabled}" `
        -o json `
        --only-show-errors
    Assert-LastExitCode "az vm show (do lifecycle)"
    $vmObject = ConvertFrom-JsonCompat -InputObject $vmJson
    if ($null -eq $vmObject) {
        throw "VM lifecycle metadata could not be parsed."
    }

    $instanceViewJson = az vm get-instance-view -g $ResourceGroup -n $VmName -o json --only-show-errors
    Assert-LastExitCode "az vm get-instance-view (do lifecycle)"
    $instanceViewObject = ConvertFrom-JsonCompat -InputObject $instanceViewJson
    if ($null -eq $instanceViewObject) {
        throw "VM instance view could not be parsed."
    }

    return (ConvertTo-AzVmVmLifecycleSnapshot -ResourceGroup $ResourceGroup -VmName $VmName -VmObject $vmObject -InstanceViewObject $instanceViewObject)
}

# Handles Format-AzVmVmLifecycleSummaryText.
function Format-AzVmVmLifecycleSummaryText {
    param(
        [psobject]$Snapshot
    )

    $powerStateText = Resolve-AzVmVmLifecycleFieldText -DisplayText ([string]$Snapshot.PowerStateDisplay) -CodeText ([string]$Snapshot.PowerStateCode)
    $hibernationStateText = Resolve-AzVmVmLifecycleFieldText -DisplayText ([string]$Snapshot.HibernationStateDisplay) -CodeText ([string]$Snapshot.HibernationStateCode)
    $provisioningStateText = Resolve-AzVmVmLifecycleFieldText -DisplayText ([string]$Snapshot.ProvisioningStateDisplay) -CodeText ([string]$Snapshot.ProvisioningStateCode) -DefaultText '(unknown)'
    $hibernationEnabledText = if ([bool]$Snapshot.HibernationEnabled) { 'true' } else { 'false' }

    return ("lifecycle={0}; power={1}; hibernation={2}; provisioning={3}; hibernationEnabled={4}" -f [string]$Snapshot.NormalizedState, $powerStateText, $hibernationStateText, $provisioningStateText, $hibernationEnabledText)
}

# Handles Get-AzVmDoAllowedSourceStates.
function Get-AzVmDoAllowedSourceStates {
    param(
        [string]$ActionName
    )

    switch ($ActionName) {
        'start' { return @('stopped','deallocated','hibernated') }
        'restart' { return @('started') }
        'stop' { return @('started') }
        'deallocate' { return @('started','stopped','hibernated') }
        'hibernate' { return @('started') }
        default { return @() }
    }
}

# Handles Assert-AzVmDoActionAllowed.
function Assert-AzVmDoActionAllowed {
    param(
        [string]$ActionName,
        [psobject]$Snapshot
    )

    if ($ActionName -eq 'status') {
        return
    }

    $provisioningSucceeded = $false
    if ([string]::Equals([string]$Snapshot.ProvisioningStateCode, 'ProvisioningState/succeeded', [System.StringComparison]::OrdinalIgnoreCase)) {
        $provisioningSucceeded = $true
    }
    elseif ([string]::Equals([string]$Snapshot.ProvisioningStateDisplay, 'Provisioning succeeded', [System.StringComparison]::OrdinalIgnoreCase)) {
        $provisioningSucceeded = $true
    }

    if (-not $provisioningSucceeded) {
        Throw-FriendlyError `
            -Detail ("Requested action '{0}' cannot continue for VM '{1}' in resource group '{2}' because provisioning is not ready. {3}" -f $ActionName, [string]$Snapshot.VmName, [string]$Snapshot.ResourceGroup, (Format-AzVmVmLifecycleSummaryText -Snapshot $Snapshot)) `
            -Code 66 `
            -Summary "VM action cannot continue because provisioning is not in succeeded state." `
            -Hint "Wait until provisioning succeeds, run '--vm-action=status', then retry."
    }

    if ($ActionName -eq 'hibernate' -and -not [bool]$Snapshot.HibernationEnabled) {
        Throw-FriendlyError `
            -Detail ("Requested action '{0}' cannot continue for VM '{1}' in resource group '{2}' because hibernation is not enabled. {3}" -f $ActionName, [string]$Snapshot.VmName, [string]$Snapshot.ResourceGroup, (Format-AzVmVmLifecycleSummaryText -Snapshot $Snapshot)) `
            -Code 66 `
            -Summary "Hibernate action is not available for this VM." `
            -Hint "Enable hibernation support first, or use stop/deallocate instead."
    }

    $allowedStates = @(Get-AzVmDoAllowedSourceStates -ActionName $ActionName)
    if ($allowedStates.Count -eq 0) {
        return
    }

    if ($allowedStates -notcontains [string]$Snapshot.NormalizedState) {
        Throw-FriendlyError `
            -Detail ("Requested action '{0}' cannot run for VM '{1}' in resource group '{2}'. {3}. Allowed source states: {4}." -f $ActionName, [string]$Snapshot.VmName, [string]$Snapshot.ResourceGroup, (Format-AzVmVmLifecycleSummaryText -Snapshot $Snapshot), ($allowedStates -join ', ')) `
            -Code 66 `
            -Summary ("VM action '{0}' is not valid for the current VM state." -f $ActionName) `
            -Hint ("Run '--vm-action=status' for current state details and retry only from: {0}." -f ($allowedStates -join ', '))
    }
}

# Handles Write-AzVmDoStatusReport.
function Write-AzVmDoStatusReport {
    param(
        [psobject]$Snapshot
    )

    $hibernationEnabledText = if ([bool]$Snapshot.HibernationEnabled) { 'true' } else { 'false' }
    Write-Host ("VM lifecycle status for '{0}' in group '{1}':" -f [string]$Snapshot.VmName, [string]$Snapshot.ResourceGroup) -ForegroundColor Cyan
    Write-Host ("- lifecycle = {0}" -f [string]$Snapshot.NormalizedState)
    Write-Host ("- power-state = {0}" -f (Resolve-AzVmVmLifecycleFieldText -DisplayText ([string]$Snapshot.PowerStateDisplay) -CodeText ([string]$Snapshot.PowerStateCode)))
    Write-Host ("- hibernation-state = {0}" -f (Resolve-AzVmVmLifecycleFieldText -DisplayText ([string]$Snapshot.HibernationStateDisplay) -CodeText ([string]$Snapshot.HibernationStateCode)))
    Write-Host ("- provisioning-state = {0}" -f (Resolve-AzVmVmLifecycleFieldText -DisplayText ([string]$Snapshot.ProvisioningStateDisplay) -CodeText ([string]$Snapshot.ProvisioningStateCode) -DefaultText '(unknown)'))
    Write-Host ("- hibernation-enabled = {0}" -f $hibernationEnabledText)
}

# Handles Assert-AzVmConnectionVmRunning.
function Assert-AzVmConnectionVmRunning {
    param(
        [string]$OperationName,
        [psobject]$Snapshot
    )

    if ([string]::Equals([string]$Snapshot.NormalizedState, 'started', [System.StringComparison]::OrdinalIgnoreCase)) {
        return
    }

    $commandLabel = ([string]$OperationName).ToUpperInvariant()
    Throw-FriendlyError `
        -Detail ("The {0} command cannot launch because VM '{1}' in resource group '{2}' is not running. {3}" -f $OperationName, [string]$Snapshot.VmName, [string]$Snapshot.ResourceGroup, (Format-AzVmVmLifecycleSummaryText -Snapshot $Snapshot)) `
        -Code 66 `
        -Summary ("{0} requires the VM to be running." -f $commandLabel) `
        -Hint ("Start the VM with 'az-vm do --vm-action=start --group={0} --vm-name={1}' and retry." -f [string]$Snapshot.ResourceGroup, [string]$Snapshot.VmName)
}

# Handles Read-AzVmDoActionInteractive.
function Read-AzVmDoActionInteractive {
    param(
        [psobject]$Snapshot
    )

    Write-Host ""
    Write-AzVmDoStatusReport -Snapshot $Snapshot
    Write-Host ""
    Write-Host "Available VM actions (select by number, default=status):" -ForegroundColor Cyan
    $choices = @(
        [pscustomobject]@{ Number = 1; Action = 'status'; Label = 'status (read-only)' },
        [pscustomobject]@{ Number = 2; Action = 'start'; Label = 'start' },
        [pscustomobject]@{ Number = 3; Action = 'restart'; Label = 'restart' },
        [pscustomobject]@{ Number = 4; Action = 'stop'; Label = 'stop' },
        [pscustomobject]@{ Number = 5; Action = 'deallocate'; Label = 'deallocate' },
        [pscustomobject]@{ Number = 6; Action = 'hibernate'; Label = 'hibernate' }
    )

    foreach ($choice in @($choices)) {
        Write-Host ("{0}. {1}" -f [int]$choice.Number, [string]$choice.Label)
    }

    while ($true) {
        $raw = Read-Host "Enter VM action number or name (default=status)"
        if ([string]::IsNullOrWhiteSpace([string]$raw)) {
            return 'status'
        }

        $text = [string]$raw
        $trimmed = $text.Trim()
        if ($trimmed -match '^\d+$') {
            $picked = @($choices | Where-Object { [int]$_.Number -eq [int]$trimmed } | Select-Object -First 1)
            if (@($picked).Count -gt 0) {
                return [string]$picked[0].Action
            }
        }

        try {
            return (Resolve-AzVmDoActionName -RawValue $trimmed)
        }
        catch {
            Write-Host "Invalid VM action selection. Please enter a valid number or action name." -ForegroundColor Yellow
        }
    }
}

# Handles Wait-AzVmDoLifecycleState.
function Wait-AzVmDoLifecycleState {
    param(
        [string]$ResourceGroup,
        [string]$VmName,
        [string]$DesiredState,
        [int]$MaxAttempts = 18,
        [int]$DelaySeconds = 10
    )

    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
    if ($MaxAttempts -gt 120) { $MaxAttempts = 120 }
    if ($DelaySeconds -lt 1) { $DelaySeconds = 1 }

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $snapshot = Get-AzVmVmLifecycleSnapshot -ResourceGroup $ResourceGroup -VmName $VmName
        $powerText = Resolve-AzVmVmLifecycleFieldText -DisplayText ([string]$snapshot.PowerStateDisplay) -CodeText ([string]$snapshot.PowerStateCode)
        $hibernationText = Resolve-AzVmVmLifecycleFieldText -DisplayText ([string]$snapshot.HibernationStateDisplay) -CodeText ([string]$snapshot.HibernationStateCode)
        Write-Host ("VM lifecycle state: {0}; power: {1}; hibernation: {2} (attempt {3}/{4})" -f [string]$snapshot.NormalizedState, $powerText, $hibernationText, $attempt, $MaxAttempts)

        if ([string]::Equals([string]$snapshot.NormalizedState, [string]$DesiredState, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $snapshot
        }

        Start-Sleep -Seconds $DelaySeconds
    }

    return $null
}

# Handles Invoke-AzVmDoAzureAction.
function Invoke-AzVmDoAzureAction {
    param(
        [string]$ActionName,
        [string]$ResourceGroup,
        [string]$VmName,
        [string[]]$AzArguments,
        [string]$AzContext
    )

    try {
        Invoke-TrackedAction -Label ("az " + (@($AzArguments) -join ' ')) -Action {
            az @AzArguments
            Assert-LastExitCode $AzContext
        } | Out-Null
    }
    catch {
        Throw-FriendlyError `
            -Detail ("Azure CLI rejected VM action '{0}' for VM '{1}' in resource group '{2}': {3}" -f $ActionName, $VmName, $ResourceGroup, $_.Exception.Message) `
            -Code 66 `
            -Summary ("VM action '{0}' failed." -f $ActionName) `
            -Hint "Review the Azure CLI error text above, correct the blocking condition, then retry."
    }
}

# Handles Invoke-AzVmDoCommand.
function Invoke-AzVmDoCommand {
    param(
        [hashtable]$Options
    )

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $target = Resolve-AzVmManagedVmTarget -Options $Options -ConfigMap $configMap -OperationName 'do'
    $action = Resolve-AzVmDoActionName -RawValue ([string](Get-AzVmCliOptionText -Options $Options -Name 'vm-action')) -AllowEmpty
    $snapshot = Get-AzVmVmLifecycleSnapshot -ResourceGroup ([string]$target.ResourceGroup) -VmName ([string]$target.VmName)

    if ([string]::IsNullOrWhiteSpace([string]$action)) {
        $action = Read-AzVmDoActionInteractive -Snapshot $snapshot
    }

    if ($action -eq 'status') {
        Write-AzVmDoStatusReport -Snapshot $snapshot
        return
    }

    Assert-AzVmDoActionAllowed -ActionName $action -Snapshot $snapshot

    $resourceGroup = [string]$target.ResourceGroup
    $vmName = [string]$target.VmName
    $desiredState = ''
    $successVerb = ''

    switch ($action) {
        'start' {
            $desiredState = 'started'
            $successVerb = 'started'
            Invoke-AzVmDoAzureAction `
                -ActionName $action `
                -ResourceGroup $resourceGroup `
                -VmName $vmName `
                -AzArguments @('vm','start','-g',$resourceGroup,'-n',$vmName,'-o','none','--only-show-errors') `
                -AzContext 'az vm start'
        }
        'restart' {
            $desiredState = 'started'
            $successVerb = 'restarted'
            Invoke-AzVmDoAzureAction `
                -ActionName $action `
                -ResourceGroup $resourceGroup `
                -VmName $vmName `
                -AzArguments @('vm','restart','-g',$resourceGroup,'-n',$vmName,'-o','none','--only-show-errors') `
                -AzContext 'az vm restart'
        }
        'stop' {
            $desiredState = 'stopped'
            $successVerb = 'stopped'
            Invoke-AzVmDoAzureAction `
                -ActionName $action `
                -ResourceGroup $resourceGroup `
                -VmName $vmName `
                -AzArguments @('vm','stop','-g',$resourceGroup,'-n',$vmName,'-o','none','--only-show-errors') `
                -AzContext 'az vm stop'
        }
        'deallocate' {
            $desiredState = 'deallocated'
            $successVerb = 'deallocated'
            Invoke-AzVmDoAzureAction `
                -ActionName $action `
                -ResourceGroup $resourceGroup `
                -VmName $vmName `
                -AzArguments @('vm','deallocate','-g',$resourceGroup,'-n',$vmName,'-o','none','--only-show-errors') `
                -AzContext 'az vm deallocate'
        }
        'hibernate' {
            $desiredState = 'hibernated'
            $successVerb = 'hibernated'
            Invoke-AzVmDoAzureAction `
                -ActionName $action `
                -ResourceGroup $resourceGroup `
                -VmName $vmName `
                -AzArguments @('vm','deallocate','-g',$resourceGroup,'-n',$vmName,'--hibernate','true','-o','none','--only-show-errors') `
                -AzContext 'az vm deallocate --hibernate'
        }
        default {
            throw ("Unsupported do action '{0}'." -f $action)
        }
    }

    $finalSnapshot = Wait-AzVmDoLifecycleState -ResourceGroup $resourceGroup -VmName $vmName -DesiredState $desiredState -MaxAttempts 24 -DelaySeconds 10
    if ($null -eq $finalSnapshot) {
        Throw-FriendlyError `
            -Detail ("VM '{0}' in resource group '{1}' did not reach expected '{2}' state after action '{3}'." -f $vmName, $resourceGroup, $desiredState, $action) `
            -Code 66 `
            -Summary ("VM action '{0}' did not reach the expected final state." -f $action) `
            -Hint "Check the VM status in Azure, run '--vm-action=status', then retry if needed."
    }

    Write-Host ("Do completed: VM '{0}' in resource group '{1}' is now {2}." -f $vmName, $resourceGroup, $successVerb) -ForegroundColor Green
    Write-AzVmDoStatusReport -Snapshot $finalSnapshot
}

# Handles Resolve-AzVmConnectionCredentials.
function Resolve-AzVmConnectionCredentials {
    param(
        [string]$RoleName,
        [hashtable]$ConfigMap,
        [string]$EnvFilePath
    )

    $role = [string]$RoleName
    $userKey = ''
    $passwordKey = ''
    $defaultUserName = ''
    switch ($role) {
        'assistant' {
            $userKey = 'VM_ASSISTANT_USER'
            $passwordKey = 'VM_ASSISTANT_PASS'
            $defaultUserName = 'assistant'
        }
        default {
            $role = 'manager'
            $userKey = 'VM_ADMIN_USER'
            $passwordKey = 'VM_ADMIN_PASS'
            $defaultUserName = 'manager'
        }
    }

    $resolvedUserName = [string](Get-ConfigValue -Config $ConfigMap -Key $userKey -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace([string]$resolvedUserName)) {
        $enteredUserName = Read-Host ("Enter username for {0} connection (default={1})" -f $role, $defaultUserName)
        if ([string]::IsNullOrWhiteSpace([string]$enteredUserName)) {
            $enteredUserName = $defaultUserName
        }
        $resolvedUserName = $enteredUserName.Trim()
        Set-DotEnvValue -Path $EnvFilePath -Key $userKey -Value $resolvedUserName
        $ConfigMap[$userKey] = $resolvedUserName
    }

    $resolvedPassword = [string](Get-ConfigValue -Config $ConfigMap -Key $passwordKey -DefaultValue '')
    if ([string]::IsNullOrWhiteSpace([string]$resolvedPassword)) {
        $securePassword = Read-Host ("Enter password for {0} connection user '{1}'" -f $role, $resolvedUserName) -AsSecureString
        $resolvedPassword = [System.Net.NetworkCredential]::new('', $securePassword).Password
        if ([string]::IsNullOrWhiteSpace([string]$resolvedPassword)) {
            Throw-FriendlyError `
                -Detail ("Password input for role '{0}' was empty." -f $role) `
                -Code 66 `
                -Summary "Connection password is required." `
                -Hint ("Enter a non-empty password for {0} and retry." -f $role)
        }
        Set-DotEnvValue -Path $EnvFilePath -Key $passwordKey -Value $resolvedPassword
        $ConfigMap[$passwordKey] = $resolvedPassword
    }

    return [pscustomobject]@{
        Role = $role
        UserName = $resolvedUserName
        Password = $resolvedPassword
    }
}

# Handles Resolve-AzVmLocalExecutablePath.
function Resolve-AzVmLocalExecutablePath {
    param(
        [string[]]$Candidates,
        [string]$FriendlyName
    )

    foreach ($candidate in @($Candidates)) {
        $candidateText = [string]$candidate
        if ([string]::IsNullOrWhiteSpace([string]$candidateText)) {
            continue
        }

        if ([System.IO.Path]::IsPathRooted($candidateText)) {
            if (Test-Path -LiteralPath $candidateText) {
                return (Resolve-Path -LiteralPath $candidateText).Path
            }
            continue
        }

        $command = Get-Command $candidateText -ErrorAction SilentlyContinue
        if ($command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
            return [string]$command.Source
        }
    }

    Throw-FriendlyError `
        -Detail ("Local executable for {0} was not found." -f $FriendlyName) `
        -Code 66 `
        -Summary ("{0} client is not available on this machine." -f $FriendlyName) `
        -Hint ("Install or expose the required executable for {0}, then retry." -f $FriendlyName)
}

# Handles Initialize-AzVmConnectionCommandContext.
function Initialize-AzVmConnectionCommandContext {
    param(
        [hashtable]$Options,
        [string]$OperationName
    )

    if (-not (Test-AzVmLocalWindowsHost)) {
        Throw-FriendlyError `
            -Detail ("The {0} command is only supported on Windows operator machines." -f $OperationName) `
            -Code 66 `
            -Summary "Local client launch is not supported on this operating system." `
            -Hint "Run this command from Windows."
    }

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $target = Resolve-AzVmManagedVmTarget -Options $Options -ConfigMap $configMap -OperationName $OperationName
    $lifecycleSnapshot = Get-AzVmVmLifecycleSnapshot -ResourceGroup ([string]$target.ResourceGroup) -VmName ([string]$target.VmName)
    Assert-AzVmConnectionVmRunning -OperationName $OperationName -Snapshot $lifecycleSnapshot
    $vmSshPort = Resolve-AzVmConnectionPortText -ConfigMap $configMap -Key 'VM_SSH_PORT' -DefaultValue (Get-AzVmDefaultSshPortText) -Label 'SSH'
    $vmRdpPort = Resolve-AzVmConnectionPortText -ConfigMap $configMap -Key 'VM_RDP_PORT' -DefaultValue (Get-AzVmDefaultRdpPortText) -Label 'RDP'
    $logicalRole = Resolve-AzVmConnectionRoleName -Options $Options
    $credentials = Resolve-AzVmConnectionCredentials -RoleName $logicalRole -ConfigMap $configMap -EnvFilePath $envFilePath

    $context = [ordered]@{
        ResourceGroup = [string]$target.ResourceGroup
        VmName = [string]$target.VmName
        AzLocation = ''
        VmUser = [string](Get-ConfigValue -Config $configMap -Key 'VM_ADMIN_USER' -DefaultValue '')
        VmPass = [string](Get-ConfigValue -Config $configMap -Key 'VM_ADMIN_PASS' -DefaultValue '')
        VmAssistantUser = [string](Get-ConfigValue -Config $configMap -Key 'VM_ASSISTANT_USER' -DefaultValue '')
        VmAssistantPass = [string](Get-ConfigValue -Config $configMap -Key 'VM_ASSISTANT_PASS' -DefaultValue '')
        SshPort = [string]$vmSshPort
        RdpPort = [string]$vmRdpPort
    }

    if ($logicalRole -eq 'manager') {
        $context.VmUser = [string]$credentials.UserName
        $context.VmPass = [string]$credentials.Password
    }
    else {
        $context.VmAssistantUser = [string]$credentials.UserName
        $context.VmAssistantPass = [string]$credentials.Password
    }

    $vmRuntimeDetails = Get-AzVmVmDetails -Context $context
    $resolvedHost = [string]$vmRuntimeDetails.VmFqdn
    if ([string]::IsNullOrWhiteSpace([string]$resolvedHost)) {
        $resolvedHost = [string]$vmRuntimeDetails.PublicIP
    }
    if ([string]::IsNullOrWhiteSpace([string]$resolvedHost)) {
        Throw-FriendlyError `
            -Detail ("Neither FQDN nor public IP could be resolved for VM '{0}'." -f [string]$target.VmName) `
            -Code 66 `
            -Summary ("{0} command could not resolve a connection host." -f $OperationName) `
            -Hint "Ensure the VM has a public endpoint and Azure can return VM runtime details."
    }

    $osType = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$lifecycleSnapshot.OsType)) {
        $osType = [string]$lifecycleSnapshot.OsType
    }
    if ($vmRuntimeDetails.VmDetails -and $vmRuntimeDetails.VmDetails.storageProfile -and $vmRuntimeDetails.VmDetails.storageProfile.osDisk) {
        $osType = [string]$vmRuntimeDetails.VmDetails.storageProfile.osDisk.osType
    }

    return [pscustomobject]@{
        EnvFilePath = $envFilePath
        ConfigMap = $configMap
        Context = $context
        ResourceGroup = [string]$target.ResourceGroup
        VmName = [string]$target.VmName
        ConnectionHost = $resolvedHost
        LifecycleSnapshot = $lifecycleSnapshot
        VmRuntimeDetails = $vmRuntimeDetails
        OsType = $osType
        SelectedRole = [string]$credentials.Role
        SelectedUserName = [string]$credentials.UserName
        SelectedPassword = [string]$credentials.Password
        VmSshPort = [string]$vmSshPort
        VmRdpPort = [string]$vmRdpPort
    }
}

# Handles Invoke-AzVmSshConnectCommand.
function Invoke-AzVmSshConnectCommand {
    param(
        [hashtable]$Options
    )

    $runtime = Initialize-AzVmConnectionCommandContext -Options $Options -OperationName 'ssh'
    $sshExePath = Resolve-AzVmLocalExecutablePath -Candidates @('ssh.exe', (Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe')) -FriendlyName 'Windows OpenSSH'
    $targetText = ("{0}@{1}" -f [string]$runtime.SelectedUserName, [string]$runtime.ConnectionHost)
    $sshArgs = @('-p', [string]$runtime.VmSshPort, $targetText)

    Write-Host ("Launching SSH client for VM '{0}' in group '{1}'..." -f [string]$runtime.VmName, [string]$runtime.ResourceGroup) -ForegroundColor Cyan
    Write-Host ("SSH target: {0}" -f $targetText) -ForegroundColor DarkCyan
    Write-Host "Password entry will appear in the external SSH console window." -ForegroundColor Yellow
    Start-Process -FilePath $sshExePath -ArgumentList $sshArgs | Out-Null
}

# Handles Invoke-AzVmRdpConnectCommand.
function Invoke-AzVmRdpConnectCommand {
    param(
        [hashtable]$Options
    )

    $runtime = Initialize-AzVmConnectionCommandContext -Options $Options -OperationName 'rdp'
    if (-not [string]::Equals(([string]$runtime.OsType).Trim(), 'Windows', [System.StringComparison]::OrdinalIgnoreCase)) {
        Throw-FriendlyError `
            -Detail ("VM '{0}' reports osType '{1}', so RDP launch is not supported." -f [string]$runtime.VmName, [string]$runtime.OsType) `
            -Code 66 `
            -Summary "RDP command is only available for Windows VMs." `
            -Hint "Use the ssh command for Linux VMs, or target a Windows VM."
    }

    $cmdKeyPath = Resolve-AzVmLocalExecutablePath -Candidates @((Join-Path $env:SystemRoot 'System32\cmdkey.exe'), 'cmdkey.exe') -FriendlyName 'Windows Credential Manager'
    $mstscPath = Resolve-AzVmLocalExecutablePath -Candidates @((Join-Path $env:SystemRoot 'System32\mstsc.exe'), 'mstsc.exe') -FriendlyName 'Remote Desktop Connection'
    $credentialTarget = ("TERMSRV/{0}" -f [string]$runtime.ConnectionHost)
    $rdpUserName = (".\{0}" -f [string]$runtime.SelectedUserName)
    $cmdKeyArgs = @("/generic:$credentialTarget", "/user:$rdpUserName", "/pass:$([string]$runtime.SelectedPassword)")

    Write-Host ("Staging RDP credentials for VM '{0}' in group '{1}'..." -f [string]$runtime.VmName, [string]$runtime.ResourceGroup) -ForegroundColor Cyan
    $cmdKeyProcess = Start-Process -FilePath $cmdKeyPath -ArgumentList $cmdKeyArgs -Wait -PassThru -WindowStyle Hidden
    if ($null -eq $cmdKeyProcess -or [int]$cmdKeyProcess.ExitCode -ne 0) {
        $exitCode = if ($null -eq $cmdKeyProcess) { -1 } else { [int]$cmdKeyProcess.ExitCode }
        Throw-FriendlyError `
            -Detail ("cmdkey failed while staging credentials for target '{0}' (exit={1})." -f $credentialTarget, $exitCode) `
            -Code 66 `
            -Summary "RDP credential staging failed." `
            -Hint "Verify local Windows credential manager access and retry."
    }

    Write-Host ("Launching mstsc for {0}:{1}..." -f [string]$runtime.ConnectionHost, [string]$runtime.VmRdpPort) -ForegroundColor Cyan
    Start-Process -FilePath $mstscPath -ArgumentList @("/v:{0}:{1}" -f [string]$runtime.ConnectionHost, [string]$runtime.VmRdpPort) | Out-Null
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
            'configure' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmConfigureCommand -Options $Options -AutoMode:$false -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag
                return
            }
            'group' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmGroupCommand -Options $Options
                return
            }
            'show' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmShowCommand -Options $Options -AutoMode:$false -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag
                return
            }
            'do' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmDoCommand -Options $Options
                return
            }
            'create' {
                $actionPlan = Resolve-AzVmActionPlan -CommandName 'create' -Options $Options
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                $createOverrides = @{ RESOURCE_GROUP = '' }
                $createVmName = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-name')
                if (-not [string]::IsNullOrWhiteSpace([string]$createVmName)) {
                    $createOverrides['VM_NAME'] = $createVmName.Trim()
                }

                # create always targets a new managed resource group name from template/index.
                Invoke-AzVmMain `
                    -WindowsFlag:$windowsFlag `
                    -LinuxFlag:$linuxFlag `
                    -CommandName 'create' `
                    -InitialConfigOverrides $createOverrides `
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
                $vmNameOverride = [string](Get-AzVmCliOptionText -Options $Options -Name 'vm-name')
                $vmName = if (-not [string]::IsNullOrWhiteSpace([string]$vmNameOverride)) { $vmNameOverride.Trim() } else { [string](Get-ConfigValue -Config $configMap -Key 'VM_NAME' -DefaultValue '') }
                $targetResourceGroup = Resolve-AzVmTargetResourceGroup `
                    -Options $Options `
                    -AutoMode:$script:AutoMode `
                    -DefaultResourceGroup $defaultResourceGroup `
                    -VmName $vmName `
                    -OperationName 'update'

                $updateOverrides = @{ RESOURCE_GROUP = $targetResourceGroup }
                if (-not [string]::IsNullOrWhiteSpace([string]$vmNameOverride)) {
                    $updateOverrides['VM_NAME'] = $vmNameOverride.Trim()
                }

                Invoke-AzVmMain `
                    -WindowsFlag:$windowsFlag `
                    -LinuxFlag:$linuxFlag `
                    -CommandName 'update' `
                    -InitialConfigOverrides $updateOverrides `
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
            'ssh' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmSshConnectCommand -Options $Options
                return
            }
            'rdp' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmRdpConnectCommand -Options $Options
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
                    -Hint "Use one command: create | update | configure | group | show | do | move | resize | set | exec | ssh | rdp | delete."
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
