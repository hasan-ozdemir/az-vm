param(
    [string]$ToolsRoot = (Join-Path $PSScriptRoot "putty")
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ToolsRoot)) {
    New-Item -Path $ToolsRoot -ItemType Directory -Force | Out-Null
}

$downloads = @(
    @{ Name = "putty.exe"; Url = "https://the.earth.li/~sgtatham/putty/latest/w64/putty.exe" },
    @{ Name = "plink.exe"; Url = "https://the.earth.li/~sgtatham/putty/latest/w64/plink.exe" },
    @{ Name = "pscp.exe"; Url = "https://the.earth.li/~sgtatham/putty/latest/w64/pscp.exe" }
)

foreach ($item in $downloads) {
    $targetPath = Join-Path $ToolsRoot ([string]$item.Name)
    Write-Host ("Downloading {0} -> {1}" -f [string]$item.Name, $targetPath)
    Invoke-WebRequest -Uri ([string]$item.Url) -OutFile $targetPath -UseBasicParsing
}

Write-Host ""
Write-Host "PuTTY tools are ready:"
Get-ChildItem -Path $ToolsRoot -File | Select-Object Name,Length,LastWriteTime | Format-Table -AutoSize
