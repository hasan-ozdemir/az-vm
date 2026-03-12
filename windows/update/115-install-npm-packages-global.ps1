$ErrorActionPreference = "Stop"
Write-Host "Update task started: install-npm-packages-global"

function Refresh-SessionPath {
    $refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
    if (Test-Path -LiteralPath $refreshEnvCmd) {
        cmd.exe /d /c "`"$refreshEnvCmd`""
    }

    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ([string]::IsNullOrWhiteSpace($userPath)) {
        $env:Path = $machinePath
    }
    else {
        $env:Path = "$machinePath;$userPath"
    }
}

function Resolve-NpmExecutable {
    $command = Get-Command npm -ErrorAction SilentlyContinue
    if ($command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source) -and (Test-Path -LiteralPath ([string]$command.Source))) {
        return [string]$command.Source
    }

    foreach ($candidate in @(
        'C:\Program Files\nodejs\npm.cmd',
        'C:\Program Files\nodejs\npm.exe',
        'C:\Program Files (x86)\nodejs\npm.cmd',
        'C:\Program Files (x86)\nodejs\npm.exe'
    )) {
        if (Test-Path -LiteralPath $candidate) {
            return [string]$candidate
        }
    }

    return ''
}

function Get-GlobalNpmPrefixPath {
    if (-not [string]::IsNullOrWhiteSpace([string]$script:GlobalNpmPrefixPath)) {
        return [string]$script:GlobalNpmPrefixPath
    }

    $applicationDataPath = [Environment]::GetFolderPath('ApplicationData')
    if ([string]::IsNullOrWhiteSpace([string]$applicationDataPath)) {
        return (Join-Path $env:USERPROFILE 'AppData\Roaming\npm')
    }

    return (Join-Path $applicationDataPath 'npm')
}

function Get-GlobalNpmNodeModulesPath {
    if (-not [string]::IsNullOrWhiteSpace([string]$script:GlobalNpmNodeModulesPath)) {
        return [string]$script:GlobalNpmNodeModulesPath
    }

    return (Join-Path (Get-GlobalNpmPrefixPath) 'node_modules')
}

function Ensure-GlobalNpmLayout {
    foreach ($path in @((Get-GlobalNpmPrefixPath), (Get-GlobalNpmNodeModulesPath))) {
        if (-not (Test-Path -LiteralPath $path)) {
            [void](New-Item -ItemType Directory -Path $path -Force)
        }
    }
}

function Resolve-GlobalNpmPaths {
    param([string]$NpmExe)

    $defaultPrefixPath = Get-GlobalNpmPrefixPath
    $defaultNodeModulesPath = Join-Path $defaultPrefixPath 'node_modules'

    $resolvedNodeModulesPath = ''
    $resolvedPrefixPath = ''

    $nodeModulesOutput = @(& $NpmExe @('root', '-g') 2>$null)
    if ($LASTEXITCODE -eq 0 -and @($nodeModulesOutput).Count -gt 0) {
        $resolvedNodeModulesPath = [string](@($nodeModulesOutput)[-1]).Trim()
    }

    $prefixOutput = @(& $NpmExe @('config', 'get', 'prefix') 2>$null)
    if ($LASTEXITCODE -eq 0 -and @($prefixOutput).Count -gt 0) {
        $resolvedPrefixPath = [string](@($prefixOutput)[-1]).Trim()
    }

    if ([string]::IsNullOrWhiteSpace([string]$resolvedPrefixPath) -and -not [string]::IsNullOrWhiteSpace([string]$resolvedNodeModulesPath)) {
        $resolvedPrefixPath = Split-Path -Path $resolvedNodeModulesPath -Parent
    }

    if ([string]::IsNullOrWhiteSpace([string]$resolvedPrefixPath)) {
        $resolvedPrefixPath = $defaultPrefixPath
    }

    if ([string]::IsNullOrWhiteSpace([string]$resolvedNodeModulesPath)) {
        $resolvedNodeModulesPath = $defaultNodeModulesPath
    }

    $script:GlobalNpmPrefixPath = [string]$resolvedPrefixPath
    $script:GlobalNpmNodeModulesPath = [string]$resolvedNodeModulesPath
    Write-Host ("Resolved global npm prefix: {0}" -f $script:GlobalNpmPrefixPath)
    Write-Host ("Resolved global npm root: {0}" -f $script:GlobalNpmNodeModulesPath)
}

function Get-GlobalNpmPackageInstallPath {
    param([string]$PackageName)

    $packagePath = [string](Get-GlobalNpmNodeModulesPath)
    foreach ($segment in @([string]$PackageName -split '/')) {
        if ([string]::IsNullOrWhiteSpace([string]$segment)) {
            continue
        }

        $packagePath = Join-Path $packagePath ([string]$segment)
    }

    return [string]$packagePath
}

function Test-GlobalNpmPackageInstalled {
    param(
        [string]$PackageName,
        [string[]]$ExpectedBinNames = @()
    )

    $packagePath = Get-GlobalNpmPackageInstallPath -PackageName $PackageName
    if (-not (Test-Path -LiteralPath $packagePath)) {
        return $false
    }

    if (@($ExpectedBinNames).Count -eq 0) {
        return $true
    }

    $prefixPath = Get-GlobalNpmPrefixPath
    foreach ($binName in @($ExpectedBinNames)) {
        if ([string]::IsNullOrWhiteSpace([string]$binName)) {
            continue
        }

        if (Test-Path -LiteralPath (Join-Path $prefixPath ([string]$binName))) {
            return $true
        }
    }

    Write-Host ("Global npm package path exists without a resolved shim; accepting the installed package directory as authoritative: {0}" -f $PackageName)
    return $true
}

function Get-MissingGlobalNpmPackages {
    param([hashtable[]]$PackageDefinitions)

    $missingPackages = @()
    foreach ($definition in @($PackageDefinitions)) {
        $packageName = [string]$definition.PackageName
        $expectedBinNames = @($definition.ExpectedBinNames)
        if (Test-GlobalNpmPackageInstalled -PackageName $packageName -ExpectedBinNames $expectedBinNames) {
            Write-Host ("Global npm package is already installed: {0}" -f $packageName)
            continue
        }

        $missingPackages += $definition
    }

    return @($missingPackages)
}

function Install-MissingGlobalNpmPackages {
    param(
        [string]$NpmExe,
        [hashtable[]]$PackageDefinitions
    )

    $installSpecs = @($PackageDefinitions | ForEach-Object { [string]$_.InstallSpec })
    if (@($installSpecs).Count -eq 0) {
        return
    }

    Write-Host ("Running: npm install -g --no-audit --no-fund --no-progress {0}" -f (($installSpecs -join ' ')))
    & $NpmExe @('install', '-g', '--no-audit', '--no-fund', '--no-progress') @($installSpecs)
    if ($LASTEXITCODE -ne 0) {
        throw ("npm install failed with exit code {0}." -f $LASTEXITCODE)
    }
}

function Assert-GlobalNpmPackagesInstalled {
    param([hashtable[]]$PackageDefinitions)

    foreach ($definition in @($PackageDefinitions)) {
        $packageName = [string]$definition.PackageName
        $expectedBinNames = @($definition.ExpectedBinNames)
        if (-not (Test-GlobalNpmPackageInstalled -PackageName $packageName -ExpectedBinNames $expectedBinNames)) {
            throw ("Global npm package '{0}' could not be verified after installation." -f $packageName)
        }
    }
}

Refresh-SessionPath

$npmExe = Resolve-NpmExecutable
if ([string]::IsNullOrWhiteSpace([string]$npmExe)) {
    throw "npm command was not found. NodeJS task must run before install-npm-packages-global."
}

Ensure-GlobalNpmLayout
Resolve-GlobalNpmPaths -NpmExe $npmExe

$globalPackages = @(
    @{
        PackageName = '@openai/codex'
        InstallSpec = '@openai/codex@latest'
        ExpectedBinNames = @('codex.cmd', 'codex')
    },
    @{
        PackageName = '@google/gemini-cli'
        InstallSpec = '@google/gemini-cli@latest'
        ExpectedBinNames = @('gemini.cmd', 'gemini')
    },
    @{
        PackageName = '@github/copilot'
        InstallSpec = '@github/copilot@latest'
        ExpectedBinNames = @('copilot.cmd', 'copilot')
    }
)

$missingPackages = @(Get-MissingGlobalNpmPackages -PackageDefinitions $globalPackages)
if (@($missingPackages).Count -gt 0) {
    Install-MissingGlobalNpmPackages -NpmExe $npmExe -PackageDefinitions $missingPackages
}
else {
    Write-Host 'All required global npm packages are already installed.'
}

Assert-GlobalNpmPackagesInstalled -PackageDefinitions $globalPackages

Write-Host "install-npm-packages-global-completed"
Write-Host "Update task completed: install-npm-packages-global"
