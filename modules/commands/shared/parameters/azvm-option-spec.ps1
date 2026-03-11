# Shared command option specification helpers.

function New-AzVmCommandOptionSpecification {
    param(
        [string]$Name,
        [scriptblock]$Validate = $null
    )

    return [pscustomobject]@{
        Name = [string]$Name
        Validate = $Validate
    }
}
