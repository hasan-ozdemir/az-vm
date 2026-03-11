# Help command runtime helper.

function Invoke-AzVmHelpCommand {
    param(
        [string]$HelpTopic = ''
    )

    if ([string]::Equals([string]$HelpTopic, '__overview__', [System.StringComparison]::OrdinalIgnoreCase)) {
        Show-AzVmCommandHelp -Overview
    }
    else {
        Show-AzVmCommandHelp -Topic $HelpTopic
    }
}
