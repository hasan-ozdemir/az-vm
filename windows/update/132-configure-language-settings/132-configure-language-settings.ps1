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
$turkishInputTip = '041F:0000041F'
$turkishKeyboardLayout = '0000041f'
$turkeyTimeZoneId = 'Turkey Standard Time'
$turkishCulture = 'tr-TR'
$turkeyGeoId = 235
$utf8CodePage = '65001'
$shortTimePattern = 'HH:mm'
$longTimePattern = 'HH:mm:ss'

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
        return 'metadata-unavailable'
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
        return 'metadata-unavailable'
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

function Get-SystemLocaleNameSafe {
    if (Get-Command Get-WinSystemLocale -ErrorAction SilentlyContinue) {
        try {
            $locale = Get-WinSystemLocale
            if ($null -ne $locale -and $locale.PSObject.Properties.Match('Name').Count -gt 0) {
                return [string]$locale.Name
            }
            return [string]$locale
        }
        catch {
        }
    }

    return ''
}

function Get-TimeZoneIdSafe {
    try {
        $timeZone = Get-TimeZone -ErrorAction Stop
        if ($null -ne $timeZone -and $timeZone.PSObject.Properties.Match('Id').Count -gt 0) {
            return [string]$timeZone.Id
        }
    }
    catch {
    }

    return ''
}

function Get-RegistryValueString {
    param(
        [string]$Path,
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path) -or [string]::IsNullOrWhiteSpace([string]$Name)) {
        return ''
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }

    $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return ''
    }

    return [string]$item.$Name
}

function Set-RegistryValueString {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace([string]$Path) -or [string]::IsNullOrWhiteSpace([string]$Name)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    Set-ItemProperty -Path $Path -Name $Name -Value ([string]$Value) -Force
}

function Invoke-RegQuiet {
    param(
        [string]$Verb,
        [string[]]$Arguments
    )

    $segments = @('reg', [string]$Verb)
    foreach ($argument in @($Arguments)) {
        $segments += ('"{0}"' -f [string]$argument)
    }

    $command = ((@($segments) -join ' ') + ' >nul 2>&1')
    cmd.exe /d /c $command | Out-Null
    return [int]$LASTEXITCODE
}

function Remove-RegistryMountIfPresent {
    param([string]$MountName)

    if ([string]::IsNullOrWhiteSpace([string]$MountName)) {
        return
    }

    & reg.exe unload ("HKU\{0}" -f $MountName) | Out-Null
}

function Mount-RegistryHive {
    param(
        [string]$MountName,
        [string]$HiveFilePath
    )

    if ([string]::IsNullOrWhiteSpace([string]$MountName)) {
        throw 'Registry mount name is empty.'
    }
    if ([string]::IsNullOrWhiteSpace([string]$HiveFilePath) -or -not (Test-Path -LiteralPath $HiveFilePath)) {
        throw ("Registry hive file was not found: {0}" -f $HiveFilePath)
    }

    Remove-RegistryMountIfPresent -MountName $MountName
    & reg.exe load ("HKU\{0}" -f $MountName) $HiveFilePath | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw ("reg load failed for HKU\{0} => {1}" -f $MountName, $HiveFilePath)
    }

    return ("Registry::HKEY_USERS\{0}" -f $MountName)
}

function Dismount-RegistryHive {
    param([string]$MountName)

    if ([string]::IsNullOrWhiteSpace([string]$MountName)) {
        return
    }

    try {
        Set-Location -Path 'C:\'
    }
    catch {
    }

    foreach ($attempt in 1..6) {
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
        Start-Sleep -Milliseconds 250

        & reg.exe unload ("HKU\{0}" -f $MountName) | Out-Null
        if ($LASTEXITCODE -eq 0) {
            return
        }

        Start-Sleep -Milliseconds 500
    }

    $exitCode = Invoke-RegQuiet -Verb 'unload' -Arguments @(("HKU\{0}" -f $MountName))
    if ($exitCode -eq 0) {
        return
    }

    Write-Warning ("reg unload failed for HKU\{0} with exit code {1}" -f $MountName, $exitCode)
}

function Set-RegistryPreloadKeyboardState {
    param([string]$RootPath)

    if ([string]::IsNullOrWhiteSpace([string]$RootPath)) {
        return
    }

    $preloadPath = Join-Path $RootPath 'Keyboard Layout\Preload'
    $substitutesPath = Join-Path $RootPath 'Keyboard Layout\Substitutes'

    if (-not (Test-Path -LiteralPath $preloadPath)) {
        New-Item -Path $preloadPath -Force | Out-Null
    }

    $preloadItem = Get-Item -LiteralPath $preloadPath -ErrorAction Stop
    foreach ($property in @($preloadItem.Property)) {
        if ([string]$property -ne '1') {
            Remove-ItemProperty -Path $preloadPath -Name ([string]$property) -ErrorAction SilentlyContinue
        }
    }

    Set-RegistryValueString -Path $preloadPath -Name '1' -Value $turkishKeyboardLayout

    if (Test-Path -LiteralPath $substitutesPath) {
        Remove-Item -LiteralPath $substitutesPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Set-Registry24HourTimeState {
    param([string]$RootPath)

    if ([string]::IsNullOrWhiteSpace([string]$RootPath)) {
        return
    }

    $internationalPath = Join-Path $RootPath 'Control Panel\International'
    Set-RegistryValueString -Path $internationalPath -Name 'LocaleName' -Value $turkishCulture
    Set-RegistryValueString -Path $internationalPath -Name 'sShortTime' -Value $shortTimePattern
    Set-RegistryValueString -Path $internationalPath -Name 'sTimeFormat' -Value $longTimePattern
    Set-RegistryValueString -Path $internationalPath -Name 'iTime' -Value '1'
    Set-RegistryValueString -Path $internationalPath -Name 'iTLZero' -Value '1'
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
        -WaitTimeoutSeconds 1800

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
        [string]$UserPassword,
        [switch]$CopyToSystem
    )

    Write-StateIntent ("Language settings for user '{0}' will be configured." -f [string]$UserName)
    Write-StateStart ("Configuring language settings for user '{0}'..." -f [string]$UserName)

    $interactiveTaskName = ('{0}-{1}' -f $taskName, [string]$UserName)
    $paths = Get-AzVmInteractivePaths -TaskName $interactiveTaskName
    $copyFlagLiteral = if ($CopyToSystem) { '$true' } else { '$false' }
    $workerScript = @'
$ErrorActionPreference = "Stop"
$helperPath = "__HELPER_PATH__"
$resultPath = "__RESULT_PATH__"
$taskName = "__TASK_NAME__"
$primaryLanguage = "__PRIMARY_LANGUAGE__"
$secondaryLanguage = "__SECONDARY_LANGUAGE__"
$inputTip = "__INPUT_TIP__"
$turkishKeyboardLayout = "__TURKISH_KEYBOARD_LAYOUT__"
$turkishCulture = "__TURKISH_CULTURE__"
$shortTimePattern = "__SHORT_TIME__"
$longTimePattern = "__LONG_TIME__"
$turkeyGeoId = __TURKEY_GEO_ID__
$copyToSystem = __COPY_TO_SYSTEM__

. $helperPath

function Ensure-RegistryPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
}

function Set-RegistryValueString {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Value
    )

    Ensure-RegistryPath -Path $Path
    Set-ItemProperty -Path $Path -Name $Name -Value ([string]$Value) -Force
}

function Set-24HourFormatState {
    $internationalPath = 'HKCU:\Control Panel\International'
    Set-RegistryValueString -Path $internationalPath -Name 'LocaleName' -Value $turkishCulture
    Set-RegistryValueString -Path $internationalPath -Name 'sShortTime' -Value $shortTimePattern
    Set-RegistryValueString -Path $internationalPath -Name 'sTimeFormat' -Value $longTimePattern
    Set-RegistryValueString -Path $internationalPath -Name 'iTime' -Value '1'
    Set-RegistryValueString -Path $internationalPath -Name 'iTLZero' -Value '1'
}

function Set-TurkishQKeyboardOnly {
    $preloadPath = 'HKCU:\Keyboard Layout\Preload'
    $substitutesPath = 'HKCU:\Keyboard Layout\Substitutes'
    Ensure-RegistryPath -Path $preloadPath
    $preloadItem = Get-Item -LiteralPath $preloadPath -ErrorAction Stop
    foreach ($property in @($preloadItem.Property)) {
        if ([string]$property -ne '1') {
            Remove-ItemProperty -Path $preloadPath -Name ([string]$property) -ErrorAction SilentlyContinue
        }
    }
    Set-RegistryValueString -Path $preloadPath -Name '1' -Value $turkishKeyboardLayout
    if (Test-Path -LiteralPath $substitutesPath) {
        Remove-Item -LiteralPath $substitutesPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

try {
    $languageList = New-WinUserLanguageList $primaryLanguage
    $secondaryEntries = New-WinUserLanguageList $secondaryLanguage
    if ($null -ne $secondaryEntries -and $secondaryEntries.Count -gt 0) {
        [void]$languageList.Add($secondaryEntries[0])
    }

    Set-WinUserLanguageList -LanguageList $languageList -Force
    Set-WinUILanguageOverride -Language $primaryLanguage
    Set-WinDefaultInputMethodOverride -InputTip $inputTip
    Set-WinCultureFromLanguageListOptOut -OptOut $true
    Set-Culture -CultureInfo $turkishCulture
    Set-WinHomeLocation -GeoId $turkeyGeoId
    Set-24HourFormatState
    Set-TurkishQKeyboardOnly

    if ($copyToSystem) {
        Copy-UserInternationalSettingsToSystem -WelcomeScreen $true -NewUser $true
    }

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
        ("culture={0}" -f [string]$cultureName),
        ("copy-to-system={0}" -f [bool]$copyToSystem)
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
    $workerScript = $workerScript.Replace('__INPUT_TIP__', $turkishInputTip)
    $workerScript = $workerScript.Replace('__TURKISH_KEYBOARD_LAYOUT__', $turkishKeyboardLayout)
    $workerScript = $workerScript.Replace('__TURKISH_CULTURE__', $turkishCulture)
    $workerScript = $workerScript.Replace('__SHORT_TIME__', $shortTimePattern)
    $workerScript = $workerScript.Replace('__LONG_TIME__', $longTimePattern)
    $workerScript = $workerScript.Replace('__TURKEY_GEO_ID__', [string]$turkeyGeoId)
    $workerScript = $workerScript.Replace('__COPY_TO_SYSTEM__', $copyFlagLiteral)

    $null = Invoke-AzVmInteractiveDesktopAutomation `
        -TaskName $interactiveTaskName `
        -RunAsUser $UserName `
        -RunAsPassword $UserPassword `
        -WorkerScriptText $workerScript `
        -WaitTimeoutSeconds 900

    Write-StateSuccess ("Language settings for user '{0}' were configured successfully." -f [string]$UserName)
}

function Set-SystemLanguageState {
    $systemPreferredUiBefore = Get-SystemPreferredUiLanguageSafe
    $systemLocaleBefore = Get-SystemLocaleNameSafe
    $timeZoneBefore = Get-TimeZoneIdSafe
    $acpBefore = Get-RegistryValueString -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name 'ACP'
    $oemcpBefore = Get-RegistryValueString -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name 'OEMCP'

    Write-StateIntent ('System language, locale, and time settings will be configured.')
    Write-StateStart ('Configuring system language, locale, and time settings...')

    Install-LanguageComponents -LanguageTag $primaryLanguage -DisplayName 'English (United States)' | Out-Null
    Install-LanguageComponents -LanguageTag $secondaryLanguage -DisplayName 'Turkish (Turkey)' | Out-Null

    Set-SystemPreferredUILanguage -Language $primaryLanguage
    Set-WinSystemLocale -SystemLocale $turkishCulture
    Set-TimeZone -Id $turkeyTimeZoneId
    Set-WinHomeLocation -GeoId $turkeyGeoId
    Set-RegistryValueString -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name 'ACP' -Value $utf8CodePage
    Set-RegistryValueString -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name 'OEMCP' -Value $utf8CodePage

    $systemPreferredUiAfter = Get-SystemPreferredUiLanguageSafe
    $systemLocaleAfter = Get-SystemLocaleNameSafe
    $timeZoneAfter = Get-TimeZoneIdSafe
    $acpAfter = Get-RegistryValueString -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name 'ACP'
    $oemcpAfter = Get-RegistryValueString -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Nls\CodePage' -Name 'OEMCP'

    if (-not [string]::Equals([string]$systemPreferredUiAfter, $primaryLanguage, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Unable to set the system preferred UI language to '{0}'." -f $primaryLanguage)
    }
    if (-not [string]::Equals([string]$systemLocaleAfter, $turkishCulture, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Unable to set the system locale to '{0}'." -f $turkishCulture)
    }
    if (-not [string]::Equals([string]$timeZoneAfter, $turkeyTimeZoneId, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Unable to set the time zone to '{0}'." -f $turkeyTimeZoneId)
    }
    if (-not [string]::Equals([string]$acpAfter, $utf8CodePage, [System.StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals([string]$oemcpAfter, $utf8CodePage, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unable to set UTF-8 ANSI and OEM code pages.'
    }

    Write-StateSuccess('System language, locale, and time settings were configured successfully.')

    return (
        (-not [string]::Equals([string]$systemPreferredUiBefore, [string]$systemPreferredUiAfter, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (-not [string]::Equals([string]$systemLocaleBefore, [string]$systemLocaleAfter, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (-not [string]::Equals([string]$timeZoneBefore, [string]$timeZoneAfter, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (-not [string]::Equals([string]$acpBefore, [string]$acpAfter, [System.StringComparison]::OrdinalIgnoreCase)) -or
        (-not [string]::Equals([string]$oemcpBefore, [string]$oemcpAfter, [System.StringComparison]::OrdinalIgnoreCase))
    )
}

function Set-WelcomeScreenAndDefaultUserState {
    Write-StateIntent('Welcome screen and new-user language settings will be normalized.')
    Write-StateStart('Configuring welcome screen and new-user language settings...')

    Set-RegistryPreloadKeyboardState -RootPath 'Registry::HKEY_USERS\.DEFAULT'
    Set-Registry24HourTimeState -RootPath 'Registry::HKEY_USERS\.DEFAULT'

    $defaultProfileHive = 'C:\Users\Default\NTUSER.DAT'
    if (Test-Path -LiteralPath $defaultProfileHive) {
        $defaultMountName = 'AzVm132Default'
        $defaultRoot = $null
        try {
            $defaultRoot = Mount-RegistryHive -MountName $defaultMountName -HiveFilePath $defaultProfileHive
            Set-RegistryPreloadKeyboardState -RootPath $defaultRoot
            Set-Registry24HourTimeState -RootPath $defaultRoot
        }
        finally {
            if (-not [string]::IsNullOrWhiteSpace([string]$defaultMountName)) {
                Dismount-RegistryHive -MountName $defaultMountName
            }
        }
    }

    Write-StateSuccess('Welcome screen and new-user language settings were configured successfully.')
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

    Invoke-UserLanguageConfiguration -UserName $managerUser -UserPassword $managerPassword -CopyToSystem
    Invoke-UserLanguageConfiguration -UserName $assistantUser -UserPassword $assistantPassword
    Set-WelcomeScreenAndDefaultUserState

    Write-Host ("language-targets => system-ui={0}; system-locale={1}; timezone={2}; primary-language={3}; secondary-language={4}; keyboard={5}; utf8-codepage={6}" -f $primaryLanguage, $turkishCulture, $turkeyTimeZoneId, $primaryLanguage, $secondaryLanguage, $turkishInputTip, $utf8CodePage)
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
