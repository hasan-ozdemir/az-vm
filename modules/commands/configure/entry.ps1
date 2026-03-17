# Configure command entry.

# Handles Invoke-AzVmConfigureCommand.
function Invoke-AzVmConfigureCommand {
    param(
        [hashtable]$Options,
        [switch]$AutoMode,
        [switch]$WindowsFlag,
        [switch]$LinuxFlag
    )

    $repoRoot = Get-AzVmRepoRoot
    $envFilePath = Join-Path $repoRoot '.env'
    Invoke-AzVmConfigureInteractiveEditor -RepoRoot $repoRoot -EnvFilePath $envFilePath -Perf:$PerfMode
}
