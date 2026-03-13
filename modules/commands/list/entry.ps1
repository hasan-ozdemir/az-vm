# List command entry.

function Invoke-AzVmListCommand {
    param(
        [hashtable]$Options
    )

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    $configMap = Read-DotEnvFile -Path $envFilePath
    $requestedTypes = @(Resolve-AzVmListRequestedTypes -Options $Options)
    $resourceGroups = @(Get-AzVmListTargetResourceGroups -Options $Options -ConfigMap $configMap)

    Write-Host "Managed az-vm inventory:" -ForegroundColor Cyan
    if (@($resourceGroups).Count -eq 0) {
        Write-Host "- No managed resource groups were found."
        return
    }

    foreach ($typeName in @($requestedTypes)) {
        $rows = @(Get-AzVmListSectionRows -TypeName ([string]$typeName) -ResourceGroups @($resourceGroups) -ConfigMap $configMap)
        Write-Host ""
        Write-Host ("{0}:" -f ([string]$typeName).ToUpperInvariant()) -ForegroundColor Cyan
        if (@($rows).Count -eq 0) {
            Write-Host "- (none)"
            continue
        }

        foreach ($row in @($rows)) {
            Write-Host ("- {0}" -f [string]$row)
        }
    }
}
