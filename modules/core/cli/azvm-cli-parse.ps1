# Shared CLI parsing and action-plan helpers.

# Handles Convert-AzVmCliTextToTokens.
function Convert-AzVmCliTextToTokens {
    param(
        [object]$Text
    )

    $parts = @()
    if ($Text -is [System.Array]) {
        foreach ($entry in @($Text)) {
            $parts += [string]$entry
        }
    }
    elseif ($null -ne $Text) {
        $parts += [string]$Text
    }

    $joined = ($parts -join "`n")
    return @(
        [regex]::Split([string]$joined, '\s+') |
            ForEach-Object { [string]$_ } |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
    )
}

# Handles Parse-AzVmCliArguments.
function Parse-AzVmCliArguments {
    param(
        [string]$CommandToken,
        [string[]]$RawArgs
    )

    $rawCommand = if ($null -eq $CommandToken) { '' } else { [string]$CommandToken }
    $remaining = @()
    if (-not [string]::IsNullOrWhiteSpace($rawCommand) -and $rawCommand.StartsWith('-')) {
        $remaining += $rawCommand
        $rawCommand = ''
    }
    $remaining += @($RawArgs)

    $validCommands = Get-AzVmValidCommandList

    $normalizedArgs = @()
    for ($i = 0; $i -lt @($remaining).Count; $i++) {
        $rawArgText = if ($null -eq $remaining[$i]) { '' } else { [string]$remaining[$i] }
        if ([string]::IsNullOrWhiteSpace($rawArgText)) {
            continue
        }

        if (-not $rawArgText.StartsWith('-') -or $rawArgText.StartsWith('--')) {
            $normalizedArgs += $rawArgText
            continue
        }

        if ($rawArgText -match '^-g=(.+)$') {
            $normalizedArgs += ("--group={0}" -f [string]$Matches[1])
            continue
        }
        if ($rawArgText -eq '-g') {
            if (($i + 1) -ge @($remaining).Count) {
                Throw-FriendlyError `
                    -Detail "Option '-g' requires a value." `
                    -Code 2 `
                    -Summary "Invalid option format." `
                    -Hint "Use '-g <resource-group>' or '--group=<resource-group>'."
            }

            $nextArgText = if ($null -eq $remaining[$i + 1]) { '' } else { [string]$remaining[$i + 1] }
            if ([string]::IsNullOrWhiteSpace([string]$nextArgText) -or $nextArgText.StartsWith('-')) {
                Throw-FriendlyError `
                    -Detail "Option '-g' requires a value." `
                    -Code 2 `
                    -Summary "Invalid option format." `
                    -Hint "Use '-g <resource-group>' or '--group=<resource-group>'."
            }

            $normalizedArgs += ("--group={0}" -f $nextArgText)
            $i++
            continue
        }

        if ($rawArgText -eq '-y') {
            $normalizedArgs += "--yes=true"
            continue
        }

        if ($rawArgText -eq '-a') {
            $normalizedArgs += "--auto=true"
            continue
        }

        if ($rawArgText -eq '-h') {
            $normalizedArgs += "--help=true"
            continue
        }

        Throw-FriendlyError `
            -Detail ("Unsupported short option format '{0}'." -f $rawArgText) `
            -Code 2 `
            -Summary "Invalid option format." `
            -Hint "Supported short options: -g, -y, -a, -h. Use long options for others."
    }

    $options = @{}
    $positionals = @()
    foreach ($arg in @($normalizedArgs)) {
        $text = if ($null -eq $arg) { '' } else { [string]$arg }
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        if ($text.StartsWith('--')) {
            $body = $text.Substring(2)
            if ([string]::IsNullOrWhiteSpace($body)) {
                continue
            }

            $name = $body
            $value = $true
            $eqIndex = $body.IndexOf('=')
            if ($eqIndex -ge 0) {
                $name = $body.Substring(0, $eqIndex)
                $value = $body.Substring($eqIndex + 1)
            }

            $nameKey = [string]$name
            $nameKey = $nameKey.Trim().ToLowerInvariant()
            if ([string]::IsNullOrWhiteSpace($nameKey)) {
                continue
            }

            $options[$nameKey] = $value
            continue
        }

        $positionals += $text
    }

    $command = ''
    $helpTopic = ''
    if (-not [string]::IsNullOrWhiteSpace($rawCommand)) {
        $command = $rawCommand.Trim().ToLowerInvariant()
        if ($validCommands -notcontains $command) {
            Throw-FriendlyError `
                -Detail ("Unknown command '{0}'." -f $rawCommand) `
                -Code 2 `
                -Summary "Unknown command." `
                -Hint "Use one command: create | update | configure | list | show | do | task | move | resize | set | exec | ssh | rdp | delete | help."
        }
    }
    elseif ($options.ContainsKey('help')) {
        $command = 'help'
        if ($positionals.Count -eq 0) {
            $helpTopic = '__overview__'
        }
    }
    else {
        Throw-FriendlyError `
            -Detail "No command was provided." `
            -Code 2 `
            -Summary "Command is required." `
            -Hint "Use one command: create | update | configure | list | show | do | task | move | resize | set | exec | ssh | rdp | delete | help. Example: az-vm create --auto"
    }

    if ($command -eq 'help') {
        if ($positionals.Count -gt 1) {
            Throw-FriendlyError `
                -Detail ("Too many help topics were provided: {0}" -f ($positionals -join ', ')) `
                -Code 2 `
                -Summary "Too many help topic arguments were provided." `
                -Hint "Use only one help topic. Example: az-vm help create"
        }

        $positionalTopic = ''
        if ($positionals.Count -eq 1) {
            $positionalTopic = [string]$positionals[0]
            $positionalTopic = $positionalTopic.Trim().ToLowerInvariant()
        }

        if (-not [string]::IsNullOrWhiteSpace($positionalTopic)) {
            $helpTopic = $positionalTopic
        }
        elseif ($helpTopic -ne '__overview__') {
            $helpTopic = ''
        }
    }
    else {
        if ($positionals.Count -gt 0) {
            Throw-FriendlyError `
                -Detail ("Unexpected positional argument(s): {0}" -f ($positionals -join ', ')) `
                -Code 2 `
                -Summary "Unexpected arguments were provided." `
                -Hint "Use only --option or --option=value syntax after the command."
        }
    }

    return [pscustomobject]@{
        Command = $command
        Options = $options
        HelpTopic = $helpTopic
    }
}

# Handles Get-AzVmCliOptionRaw.
function Get-AzVmCliOptionRaw {
    param(
        [hashtable]$Options,
        [string]$Name
    )

    if ($null -eq $Options) {
        return $null
    }

    $key = [string]$Name
    if ([string]::IsNullOrWhiteSpace($key)) {
        return $null
    }

    $key = $key.Trim().ToLowerInvariant()
    if ($Options.ContainsKey($key)) {
        return $Options[$key]
    }

    return $null
}

# Handles Test-AzVmCliOptionPresent.
function Test-AzVmCliOptionPresent {
    param(
        [hashtable]$Options,
        [string]$Name
    )

    if ($null -eq $Options) {
        return $false
    }

    $key = [string]$Name
    if ([string]::IsNullOrWhiteSpace($key)) {
        return $false
    }

    return $Options.ContainsKey($key.Trim().ToLowerInvariant())
}

# Handles Convert-AzVmCliValueToBool.
function Convert-AzVmCliValueToBool {
    param(
        [string]$OptionName,
        [object]$RawValue
    )

    if ($RawValue -is [bool]) {
        return [bool]$RawValue
    }

    $text = [string]$RawValue
    $trimmed = $text.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $true
    }
    if ($trimmed -in @('1','true','yes','y','on')) {
        return $true
    }
    if ($trimmed -in @('0','false','no','n','off')) {
        return $false
    }

    Throw-FriendlyError `
        -Detail ("Option '--{0}' received invalid boolean value '{1}'." -f $OptionName, $text) `
        -Code 2 `
        -Summary "Invalid boolean option value." `
        -Hint ("Use '--{0}' or '--{0}=true|false'." -f $OptionName)
}

# Handles Get-AzVmCliOptionBool.
function Get-AzVmCliOptionBool {
    param(
        [hashtable]$Options,
        [string]$Name,
        [bool]$DefaultValue = $false
    )

    if (-not (Test-AzVmCliOptionPresent -Options $Options -Name $Name)) {
        return [bool]$DefaultValue
    }

    $raw = Get-AzVmCliOptionRaw -Options $Options -Name $Name
    return (Convert-AzVmCliValueToBool -OptionName $Name -RawValue $raw)
}

# Handles Get-AzVmCliOptionText.
function Get-AzVmCliOptionText {
    param(
        [hashtable]$Options,
        [string]$Name
    )

    if (-not (Test-AzVmCliOptionPresent -Options $Options -Name $Name)) {
        return $null
    }

    $raw = Get-AzVmCliOptionRaw -Options $Options -Name $Name
    if ($raw -is [bool]) {
        if ([bool]$raw) {
            return ''
        }

        return $null
    }

    return [string]$raw
}

# Handles Get-AzVmActionOrder.
function Get-AzVmActionOrder {
    return @('configure', 'group', 'network', 'vm-deploy', 'vm-init', 'vm-update', 'vm-summary')
}

# Handles Resolve-AzVmActionValue.
function Resolve-AzVmActionValue {
    param(
        [string]$OptionName,
        [string]$RawValue
    )

    $text = if ($null -eq $RawValue) { '' } else { [string]$RawValue }
    $normalized = $text.Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        Throw-FriendlyError `
            -Detail ("Option '--{0}' requires a value." -f $OptionName) `
            -Code 2 `
            -Summary "Step option value is missing." `
            -Hint ("Use '--{0}=configure|group|network|vm-deploy|vm-init|vm-update|vm-summary'." -f $OptionName)
    }

    $allowed = Get-AzVmActionOrder
    if ($allowed -notcontains $normalized) {
        Throw-FriendlyError `
            -Detail ("Option '--{0}' received invalid value '{1}'." -f $OptionName, $RawValue) `
            -Code 2 `
            -Summary "Invalid step option value." `
            -Hint ("Valid values: {0}" -f ($allowed -join ', '))
    }

    return $normalized
}

# Handles Resolve-AzVmActionPlan.
function Resolve-AzVmActionPlan {
    param(
        [string]$CommandName,
        [hashtable]$Options
    )

    $order = Get-AzVmActionOrder
    $supportsActionOptions = ($CommandName -in @('create', 'update'))
    $hasFrom = Test-AzVmCliOptionPresent -Options $Options -Name 'step-from'
    $hasTo = Test-AzVmCliOptionPresent -Options $Options -Name 'step-to'
    $hasSingle = Test-AzVmCliOptionPresent -Options $Options -Name 'step'

    if (-not $supportsActionOptions -and ($hasFrom -or $hasTo -or $hasSingle)) {
        Throw-FriendlyError `
            -Detail ("Step options are not supported for command '{0}'." -f $CommandName) `
            -Code 2 `
            -Summary "Unsupported command option." `
            -Hint "Use --step-from/--step-to/--step only with create or update."
    }

    if ($hasSingle -and ($hasFrom -or $hasTo)) {
        Throw-FriendlyError `
            -Detail "Option '--step' cannot be combined with '--step-from' or '--step-to'." `
            -Code 2 `
            -Summary "Conflicting step options were provided." `
            -Hint "Use --step alone, or use --step-from/--step-to as a range."
    }

    if (-not $hasFrom -and -not $hasTo -and -not $hasSingle) {
        return [pscustomobject]@{
            Mode = 'full'
            Target = 'vm-summary'
            Actions = @($order)
        }
    }

    if ($hasSingle) {
        $singleTarget = Resolve-AzVmActionValue -OptionName 'step' -RawValue ([string](Get-AzVmCliOptionText -Options $Options -Name 'step'))
        return [pscustomobject]@{
            Mode = 'single'
            Target = $singleTarget
            Actions = @($singleTarget)
        }
    }

    $fromStep = if ($hasFrom) {
        Resolve-AzVmActionValue -OptionName 'step-from' -RawValue ([string](Get-AzVmCliOptionText -Options $Options -Name 'step-from'))
    }
    else {
        [string]$order[0]
    }
    $toStep = if ($hasTo) {
        Resolve-AzVmActionValue -OptionName 'step-to' -RawValue ([string](Get-AzVmCliOptionText -Options $Options -Name 'step-to'))
    }
    else {
        [string]$order[$order.Count - 1]
    }

    $fromIndex = [array]::IndexOf($order, $fromStep)
    $toIndex = [array]::IndexOf($order, $toStep)
    if ($fromIndex -lt 0 -or $toIndex -lt 0) {
        throw ("Step range '{0}' -> '{1}' could not be mapped." -f $fromStep, $toStep)
    }
    if ($fromIndex -gt $toIndex) {
        Throw-FriendlyError `
            -Detail ("Option '--step-from={0}' is after '--step-to={1}'." -f $fromStep, $toStep) `
            -Code 2 `
            -Summary "Invalid step range." `
            -Hint "Provide a forward step range where step-from is before or equal to step-to."
    }

    $actions = @()
    for ($i = $fromIndex; $i -le $toIndex; $i++) {
        $actions += [string]$order[$i]
    }

    return [pscustomobject]@{
        Mode = 'range'
        Target = $toStep
        Start = $fromStep
        Actions = @($actions)
    }
}

# Handles Test-AzVmActionIncluded.
function Test-AzVmActionIncluded {
    param(
        [psobject]$ActionPlan,
        [string]$ActionName
    )

    if ($null -eq $ActionPlan) {
        return $false
    }

    $name = if ($null -eq $ActionName) { '' } else { [string]$ActionName.Trim().ToLowerInvariant() }
    if ([string]::IsNullOrWhiteSpace($name)) {
        return $false
    }

    return (@($ActionPlan.Actions) -contains $name)
}
