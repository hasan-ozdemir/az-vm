$ErrorActionPreference = 'Stop'
Write-Host 'Update task started: configure-language-settings'

$taskName = '132-configure-language-settings'
$managerUser = '__VM_ADMIN_USER__'
$managerPassword = '__VM_ADMIN_PASS__'
$assistantUser = '__ASSISTANT_USER__'
$assistantPassword = '__ASSISTANT_PASS__'
$helperPath = 'C:\Windows\Temp\az-vm-interactive-session-helper.ps1'

$primaryLanguage = 'en-US'
$secondaryLanguage = 'tr-TR'

if (-not (Test-Path -LiteralPath $helperPath)) {
    throw ("Interactive session helper was not found: {0}" -f $helperPath)
}

. $helperPath

function Write-StateIntent {
    param([string]$Message)

    if (-not [string]::IsNullOrWhiteSpace([string]$Message)) {
        Write-Host ([string]$Message) -ForegroundColor DarkCyan
    }
}

function Write-StateStart {
    param([string]$Message)

    if (-not [string]::IsNullOrWhiteSpace([string]$Message)) {
        Write-Host ([string]$Message) -ForegroundColor Cyan
    }
}

function Write-StateSuccess {
    param([string]$Message)

    if (-not [string]::IsNullOrWhiteSpace([string]$Message)) {
        Write-Host ([string]$Message) -ForegroundColor Green
    }
}

function Write-StateSkip {
    param([string]$Message)

    if (-not [string]::IsNullOrWhiteSpace([string]$Message)) {
        Write-Host ([string]$Message) -ForegroundColor DarkCyan
    }
}

function Get-InstalledLanguageSafe {
    param([string]$LanguageTag)

    if ([string]::IsNullOrWhiteSpace([string]$LanguageTag)) {
        return @()
    }

    if (-not (Get-Command Get-InstalledLanguage -ErrorAction SilentlyContinue)) {
        return @()
    }

    return @(
        Get-InstalledLanguage -Language $LanguageTag -ErrorAction SilentlyContinue |
            Where-Object { $_ -ne $null }
    )
}

function Get-LanguageFeatureSummary {
    param([AllowNull()]$InstalledLanguage)

    if ($null -eq $InstalledLanguage) {
        return 'details not reported by Windows'
    }

    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($propertyName in @('LanguageFeatures', 'InstalledLanguageFeatures', 'Features')) {
        if ($InstalledLanguage.PSObject.Properties.Match($propertyName).Count -lt 1) {
            continue
        }

        $value = $InstalledLanguage.$propertyName
        if ($null -eq $value) {
            continue
        }

        foreach ($entry in @($value)) {
            $text = [string]$entry
            if ([string]::IsNullOrWhiteSpace([string]$text)) {
                continue
            }

            if (-not $parts.Contains($text)) {
                $parts.Add($text) | Out-Null
            }
        }
    }

    if ($parts.Count -eq 0) {
        foreach ($propertyName in @('BasicTyping', 'Handwriting', 'Ocr', 'Speech', 'TextToSpeech')) {
            if ($InstalledLanguage.PSObject.Properties.Match($propertyName).Count -lt 1) {
                continue
            }

            $parts.Add(("{0}={1}" -f $propertyName, [string]$InstalledLanguage.$propertyName)) | Out-Null
        }
    }

    if ($parts.Count -eq 0) {
        return 'details not reported by Windows'
    }

    return (@($parts.ToArray()) -join ', ')
}

function Get-SystemPreferredUiLanguageSafe {
    if (Get-Command Get-SystemPreferredUILanguage -ErrorAction SilentlyContinue) {
        try {
            return [string](Get-SystemPreferredUILanguage)
        }
        catch {
        }
    }

    return ''
}

function Get-LanguageCapabilityCatalog {
    param([string]$LanguageTag)

    $languageTagText = [string]$LanguageTag
    return [ordered]@{
        'Language.Basic'        = ("Language.Basic~~~{0}~0.0.1.0" -f $languageTagText)
        'Language.Handwriting'  = ("Language.Handwriting~~~{0}~0.0.1.0" -f $languageTagText)
        'Language.OCR'          = ("Language.OCR~~~{0}~0.0.1.0" -f $languageTagText)
        'Language.Speech'       = ("Language.Speech~~~{0}~0.0.1.0" -f $languageTagText)
        'Language.TextToSpeech' = ("Language.TextToSpeech~~~{0}~0.0.1.0" -f $languageTagText)
    }
}

function Get-LanguageCapabilityStateMap {
    param([string]$LanguageTag)

    $catalog = Get-LanguageCapabilityCatalog -LanguageTag $LanguageTag
    $stateMap = [ordered]@{}
    $availableCapabilities = @()
    if (Get-Command Get-WindowsCapability -ErrorAction SilentlyContinue) {
        $availableCapabilities = @(
            Get-WindowsCapability -Online -ErrorAction SilentlyContinue |
                Where-Object { $_ -ne $null -and -not [string]::IsNullOrWhiteSpace([string]$_.Name) }
        )
    }

    foreach ($capabilityName in @($catalog.Keys)) {
        $capabilityIdentity = [string]$catalog[$capabilityName]
        $capability = $availableCapabilities | Where-Object { [string]$_.Name -eq $capabilityIdentity } | Select-Object -First 1
        $stateMap[$capabilityName] = if ($null -eq $capability) { 'Unavailable' } else { [string]$capability.State }
    }

    return [pscustomobject]$stateMap
}

function Convert-LanguageCapabilityStateMapToSummary {
    param([AllowNull()]$StateMap)

    if ($null -eq $StateMap) {
        return 'unavailable'
    }

    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($capabilityName in @('Language.Basic', 'Language.Handwriting', 'Language.OCR', 'Language.Speech', 'Language.TextToSpeech')) {
        $stateValue = 'Unavailable'
        if ($StateMap.PSObject.Properties.Match($capabilityName).Count -gt 0) {
            $candidate = [string]$StateMap.$capabilityName
            if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                $stateValue = $candidate
            }
        }

        $parts.Add(("{0}={1}" -f [string]$capabilityName, [string]$stateValue)) | Out-Null
    }

    return (@($parts.ToArray()) -join ', ')
}

function Test-LanguageCapabilityStateSatisfied {
    param([AllowNull()]$StateMap)

    if ($null -eq $StateMap) {
        return $false
    }

    $basicState = ''
    if ($StateMap.PSObject.Properties.Match('Language.Basic').Count -gt 0) {
        $basicState = [string]$StateMap.'Language.Basic'
    }

    if ($basicState -notin @('Installed', 'InstallPending')) {
        return $false
    }

    foreach ($capabilityName in @('Language.Handwriting', 'Language.OCR', 'Language.Speech', 'Language.TextToSpeech')) {
        $capabilityState = 'Unavailable'
        if ($StateMap.PSObject.Properties.Match($capabilityName).Count -gt 0) {
            $candidate = [string]$StateMap.$capabilityName
            if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                $capabilityState = $candidate
            }
        }

        if ($capabilityState -notin @('Installed', 'InstallPending', 'Unavailable')) {
            return $false
        }
    }

    return $true
}

function Install-LanguageComponents {
    param(
        [string]$LanguageTag,
        [string]$DisplayName
    )

    Write-StateIntent ("Language components for {0} will be installed." -f [string]$DisplayName)
    Write-StateStart ("Installing language components for {0}..." -f [string]$DisplayName)

    $interactiveTaskName = ('{0}-install-{1}' -f $taskName, (($LanguageTag -replace '[^a-zA-Z0-9]+', '-').Trim('-')))
    $paths = Get-AzVmInteractivePaths -TaskName $interactiveTaskName
    $workerScript = @'
$ErrorActionPreference = "Stop"
$helperPath = "__HELPER_PATH__"
$resultPath = "__RESULT_PATH__"
$taskName = "__TASK_NAME__"
$languageTag = "__LANGUAGE_TAG__"

. $helperPath

function Get-LanguageCapabilityCatalog {
    param([string]$LanguageTag)

    $languageTagText = [string]$LanguageTag
    return [ordered]@{
        'Language.Basic'        = ("Language.Basic~~~{0}~0.0.1.0" -f $languageTagText)
        'Language.Handwriting'  = ("Language.Handwriting~~~{0}~0.0.1.0" -f $languageTagText)
        'Language.OCR'          = ("Language.OCR~~~{0}~0.0.1.0" -f $languageTagText)
        'Language.Speech'       = ("Language.Speech~~~{0}~0.0.1.0" -f $languageTagText)
        'Language.TextToSpeech' = ("Language.TextToSpeech~~~{0}~0.0.1.0" -f $languageTagText)
    }
}

function Get-LanguageCapabilityStateMap {
    param([string]$LanguageTag)

    $catalog = Get-LanguageCapabilityCatalog -LanguageTag $LanguageTag
    $stateMap = [ordered]@{}
    $availableCapabilities = @(
        Get-WindowsCapability -Online -ErrorAction SilentlyContinue |
            Where-Object { $_ -ne $null -and -not [string]::IsNullOrWhiteSpace([string]$_.Name) }
    )

    foreach ($capabilityName in @($catalog.Keys)) {
        $capabilityIdentity = [string]$catalog[$capabilityName]
        $capability = $availableCapabilities | Where-Object { [string]$_.Name -eq $capabilityIdentity } | Select-Object -First 1
        $stateMap[$capabilityName] = if ($null -eq $capability) { 'Unavailable' } else { [string]$capability.State }
    }

    return [pscustomobject]$stateMap
}

function Convert-LanguageCapabilityStateMapToSummary {
    param([AllowNull()]$StateMap)

    if ($null -eq $StateMap) {
        return 'unavailable'
    }

    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($capabilityName in @('Language.Basic', 'Language.Handwriting', 'Language.OCR', 'Language.Speech', 'Language.TextToSpeech')) {
        $stateValue = 'Unavailable'
        if ($StateMap.PSObject.Properties.Match($capabilityName).Count -gt 0) {
            $candidate = [string]$StateMap.$capabilityName
            if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                $stateValue = $candidate
            }
        }

        $parts.Add(("{0}={1}" -f [string]$capabilityName, [string]$stateValue)) | Out-Null
    }

    return (@($parts.ToArray()) -join ', ')
}

function Test-LanguageCapabilityStateSatisfied {
    param([AllowNull()]$StateMap)

    if ($null -eq $StateMap) {
        return $false
    }

    $basicState = ''
    if ($StateMap.PSObject.Properties.Match('Language.Basic').Count -gt 0) {
        $basicState = [string]$StateMap.'Language.Basic'
    }

    if ($basicState -notin @('Installed', 'InstallPending')) {
        return $false
    }

    foreach ($capabilityName in @('Language.Handwriting', 'Language.OCR', 'Language.Speech', 'Language.TextToSpeech')) {
        $capabilityState = 'Unavailable'
        if ($StateMap.PSObject.Properties.Match($capabilityName).Count -gt 0) {
            $candidate = [string]$StateMap.$capabilityName
            if (-not [string]::IsNullOrWhiteSpace([string]$candidate)) {
                $capabilityState = $candidate
            }
        }

        if ($capabilityState -notin @('Installed', 'InstallPending', 'Unavailable')) {
            return $false
        }
    }

    return $true
}

try {
    $installResult = Install-Language -Language $languageTag -ErrorAction Stop
    $rebootRequired = $false
    foreach ($propertyName in @('RestartNeeded', 'RebootRequired', 'RequiresRestart')) {
        if ($null -ne $installResult -and $installResult.PSObject.Properties.Match($propertyName).Count -gt 0 -and [bool]$installResult.$propertyName) {
            $rebootRequired = $true
            break
        }
    }

    $capabilityState = Get-LanguageCapabilityStateMap -LanguageTag $languageTag
    $capabilitySummary = Convert-LanguageCapabilityStateMapToSummary -StateMap $capabilityState
    if (-not (Test-LanguageCapabilityStateSatisfied -StateMap $capabilityState)) {
        throw ("Unable to verify installed language components for '{0}' inside the system worker. {1}" -f [string]$languageTag, [string]$capabilitySummary)
    }

    if ($capabilitySummary -match '(?i)InstallPending') {
        $rebootRequired = $true
    }

    Write-AzVmInteractiveResult -ResultPath $resultPath -TaskName $taskName -Success $true -Summary 'Language components installed.' -Details @(
        ("reboot-required={0}" -f [bool]$rebootRequired),
        ("language-capabilities={0}" -f [string]$capabilitySummary)
    )
}
catch {
    $exceptionMessage = [string]$_.Exception.Message
    $capabilityState = Get-LanguageCapabilityStateMap -LanguageTag $languageTag
    $capabilitySummary = Convert-LanguageCapabilityStateMapToSummary -StateMap $capabilityState
    $acceptPartialInstall = ($exceptionMessage -match '(?i)partially installed|0x80073CF1|2147009295') -and (Test-LanguageCapabilityStateSatisfied -StateMap $capabilityState)
    if ($acceptPartialInstall) {
        Write-AzVmInteractiveResult -ResultPath $resultPath -TaskName $taskName -Success $true -Summary 'Language components were queued successfully and require restart.' -Details @(
            'reboot-required=true',
            ("language-capabilities={0}" -f [string]$capabilitySummary),
            'language-install-partial=true'
        )
        return
    }

    Write-AzVmInteractiveResult -ResultPath $resultPath -TaskName $taskName -Success $false -Summary 'Language components failed.' -Details @(
        [string]$exceptionMessage,
        ("language-capabilities={0}" -f [string]$capabilitySummary)
    )
    throw
}
'@

    $workerScript = $workerScript.Replace('__HELPER_PATH__', $helperPath)
    $workerScript = $workerScript.Replace('__RESULT_PATH__', [string]$paths.ResultPath)
    $workerScript = $workerScript.Replace('__TASK_NAME__', $interactiveTaskName)
    $workerScript = $workerScript.Replace('__LANGUAGE_TAG__', $LanguageTag)

    $interactiveResult = Invoke-AzVmInteractiveDesktopAutomation `
        -TaskName $interactiveTaskName `
        -RunAsUser 'SYSTEM' `
        -RunAsPassword '' `
        -WorkerScriptText $workerScript `
        -WaitTimeoutSeconds 1800 `
        -HeartbeatSeconds 10

    $rebootRequired = $false
    $capabilitySummary = ''
    if ($null -ne $interactiveResult -and $interactiveResult.PSObject.Properties.Match('Details').Count -gt 0 -and $null -ne $interactiveResult.Details) {
        foreach ($detail in @($interactiveResult.Details)) {
            $detailText = [string]$detail
            if ($detailText -match '^reboot-required=(?<value>true|false)$') {
                $rebootRequired = [bool]::Parse([string]$Matches['value'])
                continue
            }
            if ($detailText -match '^language-capabilities=(?<value>.+)$') {
                $capabilitySummary = [string]$Matches['value']
            }
        }
    }

    $capabilityState = Get-LanguageCapabilityStateMap -LanguageTag $LanguageTag
    if ([string]::IsNullOrWhiteSpace([string]$capabilitySummary)) {
        $capabilitySummary = Convert-LanguageCapabilityStateMapToSummary -StateMap $capabilityState
    }

    $installedRows = @(Get-InstalledLanguageSafe -LanguageTag $LanguageTag)
    if (@($installedRows).Count -lt 1 -and -not (Test-LanguageCapabilityStateSatisfied -StateMap $capabilityState)) {
        throw ("Unable to verify installed language components for '{0}'." -f [string]$LanguageTag)
    }

    if (@($installedRows).Count -gt 0) {
        Write-Host ("language-components => {0} => {1}" -f [string]$LanguageTag, (Get-LanguageFeatureSummary -InstalledLanguage $installedRows[0]))
    }
    else {
        Write-Host ("language-capabilities => {0} => {1}" -f [string]$LanguageTag, [string]$capabilitySummary)
    }

    if ([string]$capabilitySummary -match '(?i)InstallPending') {
        $rebootRequired = $true
        Write-StateSuccess ("Language components for {0} were queued successfully and will finish after restart." -f [string]$DisplayName)
    }
    else {
        Write-StateSuccess ("Language components for {0} were installed successfully." -f [string]$DisplayName)
    }

    return [bool]$rebootRequired
}

function Invoke-UserLanguageConfiguration {
    param(
        [string]$UserName,
        [string]$UserPassword
    )

    Write-StateIntent ("Language settings for user '{0}' will be configured." -f [string]$UserName)
    Write-StateStart ("Configuring language settings for user '{0}'..." -f [string]$UserName)

    $interactiveTaskName = ('{0}-{1}' -f $taskName, [string]$UserName)
    $paths = Get-AzVmInteractivePaths -TaskName $interactiveTaskName
    $workerScript = @'
$ErrorActionPreference = "Stop"
$helperPath = "__HELPER_PATH__"
$resultPath = "__RESULT_PATH__"
$taskName = "__TASK_NAME__"
$primaryLanguage = "__PRIMARY_LANGUAGE__"
$secondaryLanguage = "__SECONDARY_LANGUAGE__"

. $helperPath

try {
    $languageList = New-WinUserLanguageList $primaryLanguage
    $secondaryEntries = New-WinUserLanguageList $secondaryLanguage
    if ($null -ne $secondaryEntries -and $secondaryEntries.Count -gt 0) {
        [void]$languageList.Add($secondaryEntries[0])
    }

    Set-WinUserLanguageList -LanguageList $languageList -Force
    Set-WinUILanguageOverride -Language $primaryLanguage

    $languageSummary = @(
        Get-WinUserLanguageList |
            ForEach-Object {
                $tips = if ($_.PSObject.Properties.Match('InputMethodTips').Count -gt 0 -and $null -ne $_.InputMethodTips) { (@($_.InputMethodTips) -join ',') } else { '' }
                ("{0}:{1}" -f [string]$_.LanguageTag, $tips)
            }
    ) -join '; '
    $cultureName = ''
    try {
        $cultureName = [string](Get-Culture).Name
    }
    catch {
    }

    $details = @(
        ("language-list={0}" -f [string]$languageSummary),
        ("culture={0}" -f [string]$cultureName)
    )
    Write-AzVmInteractiveResult -ResultPath $resultPath -TaskName $taskName -Success $true -Summary 'Language settings applied.' -Details $details
}
catch {
    Write-AzVmInteractiveResult -ResultPath $resultPath -TaskName $taskName -Success $false -Summary 'Language settings failed.' -Details @([string]$_.Exception.Message)
    throw
}
'@

    $workerScript = $workerScript.Replace('__HELPER_PATH__', $helperPath)
    $workerScript = $workerScript.Replace('__RESULT_PATH__', [string]$paths.ResultPath)
    $workerScript = $workerScript.Replace('__TASK_NAME__', $interactiveTaskName)
    $workerScript = $workerScript.Replace('__PRIMARY_LANGUAGE__', $primaryLanguage)
    $workerScript = $workerScript.Replace('__SECONDARY_LANGUAGE__', $secondaryLanguage)

    $null = Invoke-AzVmInteractiveDesktopAutomation `
        -TaskName $interactiveTaskName `
        -RunAsUser $UserName `
        -RunAsPassword $UserPassword `
        -WorkerScriptText $workerScript `
        -WaitTimeoutSeconds 900 `
        -HeartbeatSeconds 10

    Write-StateSuccess ("Language settings for user '{0}' were configured successfully." -f [string]$UserName)
}

function Set-SystemLanguageState {
    $systemPreferredUiBefore = Get-SystemPreferredUiLanguageSafe
    Write-StateIntent ('System language packages and UI settings will be configured.')
    Write-StateStart ('Configuring system language packages and UI settings...')

    $englishRebootRequired = Install-LanguageComponents -LanguageTag $primaryLanguage -DisplayName 'English (United States)'
    $turkishRebootRequired = Install-LanguageComponents -LanguageTag $secondaryLanguage -DisplayName 'Turkish (Turkey)'

    Write-StateStart ("Applying system preferred UI language '{0}'..." -f $primaryLanguage)
    Set-SystemPreferredUILanguage -Language $primaryLanguage
    $systemPreferredUiAfter = Get-SystemPreferredUiLanguageSafe

    if (-not [string]::Equals([string]$systemPreferredUiAfter, $primaryLanguage, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Unable to set the system preferred UI language to '{0}'." -f $primaryLanguage)
    }

    Write-StateSuccess('System language packages and UI settings were configured successfully.')

    return (
        [bool]$englishRebootRequired -or
        [bool]$turkishRebootRequired -or
        (-not [string]::Equals([string]$systemPreferredUiBefore, [string]$systemPreferredUiAfter, [System.StringComparison]::OrdinalIgnoreCase))
    )
}

$rebootRequired = $false

try {
    if (-not (Get-Command Install-Language -ErrorAction SilentlyContinue)) {
        throw 'Install-Language is not available on this image.'
    }
    if (-not (Get-Command Set-SystemPreferredUILanguage -ErrorAction SilentlyContinue)) {
        throw 'Set-SystemPreferredUILanguage is not available on this image.'
    }

    if (Set-SystemLanguageState) {
        $rebootRequired = $true
    }

    Write-StateStart("Applying language list and UI override for '{0}'..." -f $managerUser)
    Invoke-UserLanguageConfiguration -UserName $managerUser -UserPassword $managerPassword
    Write-StateStart("Applying language list and UI override for '{0}'..." -f $assistantUser)
    Invoke-UserLanguageConfiguration -UserName $assistantUser -UserPassword $assistantPassword

    Write-StateStart('Collecting final language verification output...')
    Write-Host ("language-targets => system-ui={0}; primary-language={1}; secondary-language={2}" -f $primaryLanguage, $primaryLanguage, $secondaryLanguage)
    Write-Host ("installed-language => {0} => {1}" -f $primaryLanguage, (Get-LanguageFeatureSummary -InstalledLanguage (@(Get-InstalledLanguageSafe -LanguageTag $primaryLanguage) | Select-Object -First 1)))
    Write-Host ("installed-language => {0} => {1}" -f $secondaryLanguage, (Get-LanguageFeatureSummary -InstalledLanguage (@(Get-InstalledLanguageSafe -LanguageTag $secondaryLanguage) | Select-Object -First 1)))

    if ($rebootRequired) {
        Write-Host 'TASK_REBOOT_REQUIRED:configure-language-settings'
    }

    Write-Host 'configure-language-settings-completed'
    Write-Host 'Update task completed: configure-language-settings'
}
catch {
    throw
}
