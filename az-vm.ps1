<#
Script Filename: az-vm.ps1
Script Description:
- Unified Azure VM provisioning flow for Windows and Linux.
- OS selection: --windows or --linux (or VM_OS_TYPE from .env).
- Init tasks run once on first VM creation via Azure Run Command task-batch.
- Update tasks run via persistent pyssh task-by-task.
#>

param(
    [Parameter(Position = 0)]
    [string]$Command,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$CliArgs
)

$script:ActiveCommand = ''
$script:AutoMode = $false
$script:UpdateMode = $false
$script:RenewMode = $false
$script:PerfMode = $false

$script:TranscriptStarted = $false
$script:HadError = $false
$script:ExitCode = 0
$script:ConfigOverrides = @{}
$script:ExecutionMode = if ($script:RenewMode) { 'destructive rebuild' } elseif ($script:UpdateMode) { 'update' } else { 'default' }
$script:AzCommandTimeoutSeconds = 1800
$script:SshTaskTimeoutSeconds = 180
$script:SshConnectTimeoutSeconds = 30
$script:AzCliExecutable = $null
$script:RetailPricingCacheByLocation = @{}
$script:RetailPricingMaxRetries = 4
$script:RetailPricingPageDelayMs = 120
$script:PerfSuppressAzTimingDepth = 0
$script:ManagedByTagKey = 'managed-by'
$script:ManagedByTagValue = 'az-vm'
$script:AzVmRepoRoot = $PSScriptRoot
$env:PYTHONDONTWRITEBYTECODE = '1'

$script:DefaultErrorSummary = 'An unexpected error occurred.'
$script:DefaultErrorHint = 'Review the error line and check script parameters and Azure connectivity.'

# Load modular function files in deterministic order from the leaf-file manifest.
$moduleManifestPath = Join-Path $PSScriptRoot 'modules/azvm-runtime-manifest.ps1'
if (-not (Test-Path -LiteralPath $moduleManifestPath)) {
    throw ("Required module manifest was not found: {0}" -f $moduleManifestPath)
}

$moduleFiles = @(& $moduleManifestPath)
if (@($moduleFiles).Count -eq 0) {
    throw "Module manifest returned no module files."
}

foreach ($moduleFile in @($moduleFiles)) {
    $modulePath = Join-Path $PSScriptRoot $moduleFile
    if (-not (Test-Path -LiteralPath $modulePath)) {
        throw ("Required module file was not found: {0}" -f $modulePath)
    }

    . $modulePath
}

if ($MyInvocation.InvocationName -eq '.') {
    return
}

try {
    $parsedCli = Parse-AzVmCliArguments -CommandToken $Command -RawArgs $CliArgs
    Invoke-AzVmCommandDispatcher -CommandName ([string]$parsedCli.Command) -Options $parsedCli.Options -HelpTopic ([string]$parsedCli.HelpTopic)
}
catch {
    $resolvedError = Resolve-AzVmFriendlyError -ErrorRecord $_ -DefaultErrorSummary $script:DefaultErrorSummary -DefaultErrorHint $script:DefaultErrorHint
    Write-Host ''
    Write-Host 'Script exited gracefully.' -ForegroundColor Yellow
    Write-Host ("Reason: {0}" -f $resolvedError.Summary) -ForegroundColor Red
    Write-Host ("Detail: {0}" -f $resolvedError.ErrorMessage)
    Write-Host ("Suggested action: {0}" -f $resolvedError.Hint) -ForegroundColor Cyan
    exit ([int]$resolvedError.Code)
}

