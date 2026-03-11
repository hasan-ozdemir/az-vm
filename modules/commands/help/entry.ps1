# Help command entry.

function Invoke-AzVmHelpEntry {
    param(
        [string]$HelpTopic = ''
    )

    Invoke-AzVmHelpCommand -HelpTopic $HelpTopic
}
