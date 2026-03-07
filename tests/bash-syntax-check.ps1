param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# Validates every Linux shell script with bash -n on the current host.
function Test-LinuxShellSyntax {
    param(
        [string]$RootPath
    )

    $linuxRoot = Join-Path $RootPath "linux"
    if (-not (Test-Path -LiteralPath $linuxRoot)) {
        Write-Host "linux directory was not found. Bash syntax check skipped." -ForegroundColor Yellow
        return
    }

    $failed = @()
    $isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)

    if ($isWindowsHost) {
        $wsl = Get-Command wsl -ErrorAction SilentlyContinue
        if (-not $wsl) {
            throw "WSL is required to validate Linux shell syntax on Windows."
        }

        Get-ChildItem -Path $linuxRoot -Recurse -File -Filter *.sh | ForEach-Object {
            $fullPath = (Resolve-Path -LiteralPath $_.FullName).Path
            $wslPath = '/mnt/' + $fullPath.Substring(0, 1).ToLowerInvariant() + '/' + ($fullPath.Substring(3) -replace '\\', '/')
            & $wsl.Source bash -n $wslPath
            if ($LASTEXITCODE -ne 0) {
                $failed += $fullPath
            }
        }
    }
    else {
        $bash = Get-Command bash -ErrorAction SilentlyContinue
        if (-not $bash) {
            throw "bash command was not found."
        }

        Get-ChildItem -Path $linuxRoot -Recurse -File -Filter *.sh | ForEach-Object {
            & $bash.Source -n $_.FullName
            if ($LASTEXITCODE -ne 0) {
                $failed += $_.FullName
            }
        }
    }

    if ($failed.Count -gt 0) {
        throw ("bash -n failed for: {0}" -f ($failed -join ", "))
    }
}

Test-LinuxShellSyntax -RootPath $RepoRoot
Write-Host "Bash syntax checks passed." -ForegroundColor Green
