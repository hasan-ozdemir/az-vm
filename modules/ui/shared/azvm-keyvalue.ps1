# Shared UI key/value rendering helper.

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
