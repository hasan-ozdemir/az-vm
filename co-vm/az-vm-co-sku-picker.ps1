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

function ConvertFrom-JsonArrayCompat {
    param(
        [Parameter(Mandatory = $true)]
        [object]$JsonText
    )

    if ($null -eq $JsonText) {
        return @()
    }

    $parsed = $null
    if ($JsonText -is [string]) {
        $parsed = $JsonText | ConvertFrom-Json
    }
    elseif ($JsonText -is [System.Array]) {
        if ($JsonText.Length -eq 0) {
            return @()
        }

        $first = $JsonText[0]
        if ($first -is [string]) {
            $jsonJoined = (($JsonText | ForEach-Object { [string]$_ }) -join "`n")
            $parsed = $jsonJoined | ConvertFrom-Json
        }
        else {
            $parsed = $JsonText
        }
    }
    else {
        $text = [string]$JsonText
        if (-not [string]::IsNullOrWhiteSpace($text) -and ($text.TrimStart().StartsWith("{") -or $text.TrimStart().StartsWith("["))) {
            $parsed = $text | ConvertFrom-Json
        }
        else {
            $parsed = @($JsonText)
        }
    }

    if ($null -eq $parsed) {
        return @()
    }

    if ($parsed -is [System.Array]) {
        return $parsed
    }

    return @($parsed)
}

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

    $locations = ConvertFrom-JsonArrayCompat -JsonText $locationsJson
    if (-not $locations -or $locations.Count -eq 0) {
        $fallbackJson = az account list-locations `
            --only-show-errors `
            --query "[].{Name:name,DisplayName:displayName,RegionType:metadata.regionType}" `
            -o json
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($fallbackJson)) {
            $fallbackLocations = ConvertFrom-JsonArrayCompat -JsonText $fallbackJson
            $locations = @($fallbackLocations | Where-Object { $_.RegionType -eq "Physical" })
        }
    }
    if (-not $locations -or $locations.Count -eq 0) {
        Throw-FriendlyError `
            -Detail "Azure returned an empty physical deployment region list." `
            -Code 26 `
            -Summary "Azure region list could not be loaded." `
            -Hint "Check Azure account/subscription context and location metadata availability."
    }

    return @($locations | Sort-Object DisplayName, Name)
}

function Write-RegionSelectionGrid {
    param(
        [object[]]$Locations,
        [int]$DefaultIndex,
        [int]$Columns = 10
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
    Write-RegionSelectionGrid -Locations $locations -DefaultIndex $defaultIndex -Columns 10

    while ($true) {
        $inputValue = Read-Host "Enter region number (default=$defaultIndex)"
        if ([string]::IsNullOrWhiteSpace($inputValue)) {
            return $locations[$defaultIndex - 1].Name
        }

        if ($inputValue -match '^\d+$') {
            $selectedNo = [int]$inputValue
            if ($selectedNo -ge 1 -and $selectedNo -le $locations.Count) {
                return $locations[$selectedNo - 1].Name
            }
        }

        Write-Host "Invalid region selection. Please enter a valid number." -ForegroundColor Yellow
    }
}

function Get-LocationSkusForSelection {
    param(
        [string]$Location,
        [string]$SkuLike
    )

    $needle = ""
    if (-not [string]::IsNullOrWhiteSpace($SkuLike)) {
        $needle = $SkuLike.Trim().ToLowerInvariant()
    }
    $needleNormalized = $needle -replace '[^a-z0-9]', ''
    $needleWithoutStandard = if ($needleNormalized.StartsWith("standard")) {
        $needleNormalized.Substring("standard".Length)
    }
    else {
        $needleNormalized
    }

    $raw = az vm list-sizes -l $Location --only-show-errors -o json
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        Throw-FriendlyError `
            -Detail "az vm list-sizes failed for location '$Location' with exit code $LASTEXITCODE." `
            -Code 27 `
            -Summary "VM size list could not be loaded for the selected region." `
            -Hint "Verify the selected region and Azure subscription permissions."
    }

    $allSkus = ConvertFrom-JsonArrayCompat -JsonText $raw
    $standardSkus = @(
        $allSkus | Where-Object {
            $_.name -and ([string]$_.name).StartsWith("Standard_", [System.StringComparison]::OrdinalIgnoreCase)
        }
    )

    if ($needle -eq "") {
        return @($standardSkus | Sort-Object name -Unique)
    }

    $filtered = foreach ($sku in $standardSkus) {
        $name = [string]$sku.name
        $nameLower = $name.ToLowerInvariant()
        $nameNormalized = $nameLower -replace '[^a-z0-9]', ''

        $isMatch = $nameLower.Contains($needle)
        if (-not $isMatch -and $needleNormalized -ne "") {
            $isMatch = $nameNormalized.Contains($needleNormalized)
        }
        if (-not $isMatch -and $needleWithoutStandard -ne "") {
            $isMatch = $nameNormalized.Contains($needleWithoutStandard)
        }

        if ($isMatch) {
            $sku
        }
    }

    return @($filtered | Sort-Object name -Unique)
}

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

    $accessToken = ($tokenJson | ConvertFrom-Json).accessToken
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
        $response = Invoke-RestMethod -Method Get -Uri $url -Headers @{ Authorization = "Bearer $accessToken" } -ErrorAction Stop
    }
    catch {
        Throw-FriendlyError `
            -Detail "Resource SKU API call failed for availability check in '$Location'." `
            -Code 24 `
            -Summary "SKU availability pre-check could not be completed." `
            -Hint "Check Azure REST access and subscription permissions."
    }

    $items = @($response.value | Where-Object { $_.resourceType -eq "virtualMachines" })
    foreach ($item in $items) {
        if (-not $item.name) { continue }
        $itemName = [string]$item.name
        $skuKey = $itemName.ToLowerInvariant()
        if (-not $targetSkuSet.ContainsKey($skuKey)) { continue }

        $isUnavailable = $false
        foreach ($restriction in @($item.restrictions)) {
            if ($restriction.reasonCode -eq "NotAvailableForSubscription") {
                $isUnavailable = $true
                break
            }
            if ($restriction.type -eq "Location" -and (($restriction.values -and ($restriction.values -contains $Location)) -or -not $restriction.values)) {
                $isUnavailable = $true
                break
            }
        }

        $locationInfo = @($item.locationInfo | Where-Object { $_.location -ieq $Location })
        if ($isUnavailable -or -not $locationInfo) {
            $result[$itemName] = "no"
        }
        else {
            $result[$itemName] = "yes"
        }
    }

    return $result
}

function Get-SkuPriceMap {
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

    $baseFilter = "serviceName eq 'Virtual Machines' and armRegionName eq '$Location' and type eq 'Consumption' and unitOfMeasure eq '1 Hour'"
    $chunkSize = 15
    for ($i = 0; $i -lt $SkuNames.Count; $i += $chunkSize) {
        $end = [math]::Min($i + $chunkSize - 1, $SkuNames.Count - 1)
        $chunk = @($SkuNames[$i..$end])
        if (-not $chunk -or $chunk.Count -eq 0) { continue }

        $skuOrExpr = ($chunk | ForEach-Object { "armSkuName eq '$($_)'" }) -join " or "
        $filter = "$baseFilter and ($skuOrExpr)"
        $nextUri = "https://prices.azure.com/api/retail/prices?`$filter=" + [uri]::EscapeDataString($filter)

        while ($nextUri) {
            $response = Invoke-RestMethod -Uri $nextUri -Method Get -ErrorAction Stop
            foreach ($item in @($response.Items)) {
                if (-not $item.armSkuName -or $item.unitPrice -eq $null) { continue }
                $itemSkuName = [string]$item.armSkuName
                $itemKey = $itemSkuName.ToLowerInvariant()
                if (-not $targetSkuSet.ContainsKey($itemKey)) { continue }

                if ($item.productName -like "*Cloud Services*") { continue }
                $priceText = "$($item.productName) $($item.skuName) $($item.meterName) $($item.meterSubCategory)"
                if ($priceText -match '(?i)\bspot\b' -or $priceText -match '(?i)\blow\s+priority\b') { continue }

                if (-not $result.ContainsKey($itemSkuName)) {
                    $result[$itemSkuName] = [ordered]@{
                        LinuxPerHour   = $null
                        WindowsPerHour = $null
                        Currency       = $item.currencyCode
                    }
                }

                $entry = $result[$itemSkuName]
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

            $nextUri = $response.NextPageLink
        }
    }

    return $result
}

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

    return $rows
}

function Select-VmSkuInteractive {
    param(
        [string]$Location,
        [string]$DefaultVmSize,
        [int]$PriceHours
    )

    while ($true) {
        $skuLikeRaw = Read-Host "Enter partial VM type (examples: b2a, d2). Leave empty to list all"
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
            $selection = Read-Host "Enter VM SKU number (default=$defaultIndex, f=change filter)"
            if ([string]::IsNullOrWhiteSpace($selection)) {
                return [string]$rows[$defaultIndex - 1].Sku
            }
            if ($selection -match '^[fF]$') {
                break
            }

            if ($selection -match '^\d+$') {
                $selectedNo = [int]$selection
                if ($selectedNo -ge 1 -and $selectedNo -le $rows.Count) {
                    return [string]$rows[$selectedNo - 1].Sku
                }
            }

            Write-Host "Invalid VM SKU selection. Please enter a valid number." -ForegroundColor Yellow
        }
    }
}
