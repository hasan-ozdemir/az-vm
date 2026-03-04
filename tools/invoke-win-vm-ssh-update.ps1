param(
    [string]$HostName = "",
    [string]$ResourceGroup = "",
    [string]$VmName = "",
    [int]$Port = 444,
    [string]$UserName = "manager",
    [string]$Password = "",
    [string]$ToolsRoot = (Join-Path $PSScriptRoot "putty"),
    [string]$LocalUpdateScriptPath = (Join-Path (Split-Path -Path $PSScriptRoot -Parent) "win-vm\\az-vm-win-update.ps1"),
    [string]$RemoteUpdateScriptPath = "",
    [switch]$RunUpdateScript
)

$ErrorActionPreference = "Stop"

function Get-EnvValueFromFile {
    param(
        [string]$Path,
        [string]$Key
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    foreach ($rawLine in Get-Content -Path $Path) {
        $line = $rawLine.Trim()
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith("#")) {
            continue
        }

        $match = [regex]::Match($line, '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)\s*$')
        if (-not $match.Success) {
            continue
        }

        if ([string]::Equals([string]$match.Groups[1].Value, [string]$Key, [System.StringComparison]::OrdinalIgnoreCase)) {
            $value = [string]$match.Groups[2].Value
            if (
                ($value.StartsWith('"') -and $value.EndsWith('"')) -or
                ($value.StartsWith("'") -and $value.EndsWith("'"))
            ) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            return $value.Trim()
        }
    }

    return ""
}

function Invoke-LocalProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [switch]$AllowNonZeroExit
    )

    $argText = if ($Arguments) { $Arguments -join " " } else { "" }
    Write-Host ("running: {0} {1}" -f $FilePath, $argText)
    & $FilePath @Arguments
    $exitCode = $LASTEXITCODE
    if (-not $AllowNonZeroExit -and $exitCode -ne 0) {
        throw ("Process failed with exit code {0}: {1}" -f $exitCode, $FilePath)
    }
    return $exitCode
}

$plinkPath = Join-Path $ToolsRoot "plink.exe"
$pscpPath = Join-Path $ToolsRoot "pscp.exe"
if (-not (Test-Path -LiteralPath $plinkPath) -or -not (Test-Path -LiteralPath $pscpPath)) {
    throw "PuTTY tools are missing. Run tools/install-putty-tools.ps1 first."
}

if ([string]::IsNullOrWhiteSpace($HostName)) {
    if (-not [string]::IsNullOrWhiteSpace($ResourceGroup) -and -not [string]::IsNullOrWhiteSpace($VmName)) {
        $resolvedFqdn = az vm show -g $ResourceGroup -n $VmName -d --query "fqdns" -o tsv
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$resolvedFqdn)) {
            $HostName = [string]$resolvedFqdn
        }
    }
}
if ([string]::IsNullOrWhiteSpace($HostName)) {
    throw "HostName is required (or provide ResourceGroup + VmName for auto-resolution)."
}

$envPath = Join-Path (Split-Path -Path $PSScriptRoot -Parent) "win-vm\\.env"
if ([string]::IsNullOrWhiteSpace($Password)) {
    $Password = Get-EnvValueFromFile -Path $envPath -Key "VM_PASS"
}
if ([string]::IsNullOrWhiteSpace($Password)) {
    throw "Password is empty. Pass -Password or set VM_PASS in win-vm/.env."
}

if ([string]::IsNullOrWhiteSpace($RemoteUpdateScriptPath)) {
    $RemoteUpdateScriptPath = ("C:\\Users\\{0}\\az-vm-win-update.ps1" -f $UserName)
}

# First connection: trust host key automatically for quick lab workflow.
$acceptHostKeyCmd = ('echo y | "{0}" -ssh -P {1} -l "{2}" -pw "{3}" "{4}" exit' -f $plinkPath, $Port, $UserName, $Password, $HostName)
Invoke-LocalProcess -FilePath "cmd.exe" -Arguments @("/d", "/c", $acceptHostKeyCmd) -AllowNonZeroExit | Out-Null

$basePlinkArgs = @(
    "-batch",
    "-ssh",
    "-P", [string]$Port,
    "-l", $UserName,
    "-pw", $Password,
    $HostName
)

$quickCommands = @(
    "whoami",
    "hostname",
    "powershell -NoProfile -Command ""`$PSVersionTable.PSVersion.ToString()""",
    "powershell -NoProfile -Command ""Get-Service sshd,TermService -ErrorAction SilentlyContinue | Select-Object Name,Status,StartType | Format-Table -AutoSize"""
)

foreach ($command in $quickCommands) {
    Write-Host ""
    Write-Host ("remote> {0}" -f $command) -ForegroundColor Cyan
    Invoke-LocalProcess -FilePath $plinkPath -Arguments ($basePlinkArgs + @($command))
}

if ($RunUpdateScript) {
    if (-not (Test-Path -LiteralPath $LocalUpdateScriptPath)) {
        throw "Local update script was not found: $LocalUpdateScriptPath"
    }

    Write-Host ""
    Write-Host "Copying update script to VM..." -ForegroundColor Cyan
    $remoteCopyTarget = ('{0}@{1}:"{2}"' -f $UserName, $HostName, $RemoteUpdateScriptPath)
    $copyArgs = @(
        "-batch",
        "-P", [string]$Port,
        "-pw", $Password,
        $LocalUpdateScriptPath,
        $remoteCopyTarget
    )
    Invoke-LocalProcess -FilePath $pscpPath -Arguments $copyArgs

    Write-Host ""
    Write-Host "Running update script on VM over SSH..." -ForegroundColor Cyan
    $remoteRun = ('powershell -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $RemoteUpdateScriptPath)
    Invoke-LocalProcess -FilePath $plinkPath -Arguments ($basePlinkArgs + @($remoteRun))
}
