# Group command runtime helpers.

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
