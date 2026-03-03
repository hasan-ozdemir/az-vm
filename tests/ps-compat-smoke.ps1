param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$global:TestPassCount = 0
$global:TestFailCount = 0

function Write-TestResult {
    param(
        [bool]$Success,
        [string]$Name,
        [string]$Detail
    )

    if ($Success) {
        $global:TestPassCount++
        Write-Host ("[PASS] {0}" -f $Name) -ForegroundColor Green
        return
    }

    $global:TestFailCount++
    Write-Host ("[FAIL] {0}: {1}" -f $Name, $Detail) -ForegroundColor Red
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        [object]$Expected,
        [object]$Actual,
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw ("{0}. Expected='{1}', Actual='{2}'" -f $Message, $Expected, $Actual)
    }
}

function Has-Utf8Bom {
    param(
        [byte[]]$Bytes
    )

    if (-not $Bytes -or $Bytes.Length -lt 3) {
        return $false
    }

    return ($Bytes[0] -eq 239 -and $Bytes[1] -eq 187 -and $Bytes[2] -eq 191)
}

function Invoke-TestCase {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    try {
        . $Action
        Write-TestResult -Success $true -Name $Name -Detail ""
    }
    catch {
        Write-TestResult -Success $false -Name $Name -Detail $_.Exception.Message
    }
}

function Test-PsSyntaxAllFiles {
    $ps1Files = Get-ChildItem -Path $RepoRoot -Recurse -Filter *.ps1 | Sort-Object FullName
    Assert-True -Condition ($ps1Files.Count -gt 0) -Message "No .ps1 files were found."

    foreach ($file in $ps1Files) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        if ($errors -and $errors.Count -gt 0) {
            $firstError = $errors[0]
            throw ("Parse error in '{0}' at line {1}: {2}" -f $file.FullName, $firstError.Extent.StartLineNumber, $firstError.Message)
        }
    }
}

function Test-JsonCompatFunctions {
    $objFromText = ConvertFrom-JsonCompat -InputObject '{"id":"123","name":"demo"}'
    Assert-Equal -Expected "123" -Actual ([string]$objFromText.id) -Message "ConvertFrom-JsonCompat should parse json object text"

    $objFromLines = ConvertFrom-JsonCompat -InputObject @('{', '  "x": 2', '}')
    Assert-Equal -Expected "2" -Actual ([string]$objFromLines.x) -Message "ConvertFrom-JsonCompat should parse line-array json text"

    $arrayFromScalar = ConvertFrom-JsonArrayCompat -InputObject '{"name":"single"}'
    Assert-Equal -Expected 1 -Actual (@($arrayFromScalar).Count) -Message "ConvertFrom-JsonArrayCompat should wrap scalar values"
    Assert-Equal -Expected "single" -Actual ([string]$arrayFromScalar[0].name) -Message "ConvertFrom-JsonArrayCompat wrapped value should be accessible"

    $arrayFromNull = ConvertTo-ObjectArrayCompat -InputObject $null
    Assert-Equal -Expected 0 -Actual $arrayFromNull.Count -Message "ConvertTo-ObjectArrayCompat should return empty array for null"

    $arrayFromString = ConvertTo-ObjectArrayCompat -InputObject "abc"
    Assert-Equal -Expected 1 -Actual $arrayFromString.Count -Message "ConvertTo-ObjectArrayCompat should keep string as scalar item"
    Assert-Equal -Expected "abc" -Actual ([string]$arrayFromString[0]) -Message "ConvertTo-ObjectArrayCompat should preserve scalar value"
}

function Test-ConfigFallbackBehavior {
    $script:ConfigOverrides = @{}
    $value1 = Get-ConfigValue -Config $null -Key "AZ_LOCATION" -DefaultValue "austriaeast"
    Assert-Equal -Expected "austriaeast" -Actual $value1 -Message "Get-ConfigValue should return default when config is null"

    $config = @{ AZ_LOCATION = "eastus" }
    $value2 = Get-ConfigValue -Config $config -Key "AZ_LOCATION" -DefaultValue "austriaeast"
    Assert-Equal -Expected "eastus" -Actual $value2 -Message "Get-ConfigValue should read hashtable value"

    $script:ConfigOverrides["AZ_LOCATION"] = "westindia"
    $value3 = Get-ConfigValue -Config $config -Key "AZ_LOCATION" -DefaultValue "austriaeast"
    Assert-Equal -Expected "westindia" -Actual $value3 -Message "Get-ConfigValue should prioritize override"
}

function Test-NormalizedFileWritePolicy {
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("az-vm-encoding-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    try {
        $linuxPath = Join-Path $tmpDir "linux-update.sh"
        $linuxMixed = "line-a`r`nline-b`rline-c`n"
        Write-TextFileNormalized `
            -Path $linuxPath `
            -Content $linuxMixed `
            -Encoding "utf8NoBom" `
            -LineEnding "lf" `
            -EnsureTrailingNewline

        $linuxBytes = [System.IO.File]::ReadAllBytes($linuxPath)
        Assert-True -Condition (-not (Has-Utf8Bom -Bytes $linuxBytes)) -Message "Linux write should be UTF-8 without BOM"
        $linuxText = [System.Text.Encoding]::UTF8.GetString($linuxBytes)
        Assert-True -Condition (-not $linuxText.Contains("`r")) -Message "Linux write should use LF only"
        Assert-True -Condition $linuxText.EndsWith("`n") -Message "Linux write should end with newline"

        $envPath = Join-Path $tmpDir ".env"
        Write-TextFileNormalized `
            -Path $envPath `
            -Content "A=1`nB=2" `
            -Encoding "utf8NoBom" `
            -LineEnding "crlf" `
            -EnsureTrailingNewline

        $envBytes = [System.IO.File]::ReadAllBytes($envPath)
        Assert-True -Condition (-not (Has-Utf8Bom -Bytes $envBytes)) -Message ".env write should be UTF-8 without BOM"
        $envText = [System.Text.Encoding]::UTF8.GetString($envBytes)
        Assert-True -Condition $envText.Contains("`r`n") -Message ".env write should contain CRLF line endings"
    }
    finally {
        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-CompatFingerprint {
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("az-vm-fp-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    try {
        $samplePath = Join-Path $tmpDir "fingerprint.txt"
        $sampleContent = "line-1`r`nline-2`nline-3`rline-4`nunicode-cf-test"
        Write-TextFileNormalized `
            -Path $samplePath `
            -Content $sampleContent `
            -Encoding "utf8NoBom" `
            -LineEnding "lf" `
            -EnsureTrailingNewline

        $bytes = [System.IO.File]::ReadAllBytes($samplePath)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha.ComputeHash($bytes)
        }
        finally {
            if ($sha) { $sha.Dispose() }
        }

        return ([System.BitConverter]::ToString($hashBytes)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-RunCommandJsonBehavior {
    $okSingle = '{"value":{"code":"ComponentStatus/StdOut/succeeded","message":"single-ok"}}'
    $messageSingle = Get-CoRunCommandResultMessage -TaskName "single" -RawJson $okSingle -ModeLabel "compat-smoke"
    Assert-True -Condition ($messageSingle -like "*single-ok*") -Message "Run-command parser should process single message objects"

    $okArray = '{"value":[{"code":"ComponentStatus/StdOut/succeeded","message":"line-1"},{"code":"ComponentStatus/StdOut/succeeded","message":"line-2"}]}'
    $messageArray = Get-CoRunCommandResultMessage -TaskName "array" -RawJson $okArray -ModeLabel "compat-smoke"
    Assert-True -Condition ($messageArray -like "*line-1*") -Message "Run-command parser should include first message"
    Assert-True -Condition ($messageArray -like "*line-2*") -Message "Run-command parser should include second message"

    $failed = '{"value":{"code":"ComponentStatus/StdErr/failed","message":"boom"}}'
    $threw = $false
    try {
        [void](Get-CoRunCommandResultMessage -TaskName "failed" -RawJson $failed -ModeLabel "compat-smoke")
    }
    catch {
        $threw = $true
        Assert-True -Condition ($_.Exception.Message -like "*reported error*") -Message "Run-command parser should surface failure message"
    }
    Assert-True -Condition $threw -Message "Run-command parser should throw on failed status code"
}

function Test-SkuFilterBehaviorWithMockAz {
    $script:DefaultErrorSummary = "compat-smoke"
    $script:DefaultErrorHint = "compat-smoke"

    function global:az {
        $argLine = ($args -join " ")
        if ($argLine -like "vm list-sizes*") {
            $global:LASTEXITCODE = 0
            return @'
[
  {"name":"Standard_A1_v2","numberOfCores":1,"memoryInMB":2048},
  {"name":"Standard_A2av2","numberOfCores":2,"memoryInMB":4096},
  {"name":"Standard_B2as_v2","numberOfCores":2,"memoryInMB":8192},
  {"name":"Standard_B2s","numberOfCores":2,"memoryInMB":4096},
  {"name":"Standard_B1axxxv2","numberOfCores":2,"memoryInMB":4096},
  {"name":"Standard_B12axv2","numberOfCores":2,"memoryInMB":4096},
  {"name":"Standard_D2as_v5","numberOfCores":2,"memoryInMB":8192},
  {"name":"Basic_A1","numberOfCores":1,"memoryInMB":1792}
]
'@
        }

        $global:LASTEXITCODE = 1
        throw ("Mock az received an unexpected command: {0}" -f $argLine)
    }

    try {
        $b2a = Get-LocationSkusForSelection -Location "austriaeast" -SkuLike "b2a"
        Assert-Equal -Expected 1 -Actual (@($b2a).Count) -Message "SKU filter 'b2a' should return only matching SKU(s)"
        Assert-Equal -Expected "Standard_B2as_v2" -Actual ([string]$b2a[0].name) -Message "SKU filter 'b2a' should match Standard_B2as_v2"

        $standardB2 = Get-LocationSkusForSelection -Location "austriaeast" -SkuLike "standard_b2"
        Assert-Equal -Expected 2 -Actual (@($standardB2).Count) -Message "SKU filter 'standard_b2' should match Standard_B2* SKUs"

        $standardA = Get-LocationSkusForSelection -Location "austriaeast" -SkuLike "standard_a"
        $standardAStar = Get-LocationSkusForSelection -Location "austriaeast" -SkuLike "standard_a*"
        Assert-Equal -Expected 2 -Actual (@($standardA).Count) -Message "SKU filter 'standard_a' should return only names containing 'standard_a'"
        Assert-Equal -Expected (@($standardA).Count) -Actual (@($standardAStar).Count) -Message "SKU filter 'standard_a' and 'standard_a*' should return the same count"
        $aNames = @($standardA | ForEach-Object { [string]$_.name } | Sort-Object)
        $aStarNames = @($standardAStar | ForEach-Object { [string]$_.name } | Sort-Object)
        Assert-Equal -Expected ($aNames -join "|") -Actual ($aStarNames -join "|") -Message "SKU filter 'standard_a' and 'standard_a*' should return the same names"

        $wildcard = Get-LocationSkusForSelection -Location "austriaeast" -SkuLike "standard_b?a*v2"
        Assert-Equal -Expected 2 -Actual (@($wildcard).Count) -Message "Wildcard filter should support ? and * semantics"
        $wildcardNames = @($wildcard | ForEach-Object { [string]$_.name } | Sort-Object)
        Assert-Equal -Expected "Standard_B1axxxv2|Standard_B2as_v2" -Actual ($wildcardNames -join "|") -Message "Wildcard filter should match expected SKU names only"

        $caseInsensitive = Get-LocationSkusForSelection -Location "austriaeast" -SkuLike "StAnDaRd_A"
        Assert-Equal -Expected (@($standardA).Count) -Actual (@($caseInsensitive).Count) -Message "Filtering should be case-insensitive"

        $all = Get-LocationSkusForSelection -Location "austriaeast" -SkuLike ""
        Assert-Equal -Expected 8 -Actual (@($all).Count) -Message "Empty SKU filter should return all region SKUs with names"
    }
    finally {
        Remove-Item -Path Function:\global:az -ErrorAction SilentlyContinue
    }
}

function Test-GuestTaskAndScriptBuild {
    $context = [ordered]@{
        VmUser = "manager"
        VmPass = "demo-pass"
        VmAssistantUser = "assistant"
        VmAssistantPass = "<runtime-secret>"
        SshPort = "444"
        TcpPorts = @("444", "11434", "3389")
        ResourceGroup = "rg-demo"
        VmName = "vm-demo"
        AzLocation = "austriaeast"
    }

    $linuxTasks = Resolve-CoVmGuestTaskBlocks -Platform "linux" -Context $context
    Assert-True -Condition (@($linuxTasks).Count -ge 7) -Message "Linux task list should contain expected tasks"
    $linuxScript = Get-CoVmUpdateScriptContentFromTasks -Platform "linux" -TaskBlocks $linuxTasks
    Assert-True -Condition ($linuxScript -like "*Update phase started.*") -Message "Linux update script should include update start marker"
    Assert-True -Condition ($linuxScript -like "*Port 444*") -Message "Linux update script should include resolved SSH port"
    Assert-True -Condition ($linuxScript -like "*11434*") -Message "Linux update script should include resolved TCP ports"
    Assert-True -Condition ($linuxScript -like "*assistant*") -Message "Linux update script should include assistant user operations"
    Assert-True -Condition ($linuxScript -like "*usermod -aG sudo*") -Message "Linux update script should include admin-group grant logic"
    Assert-True -Condition ($linuxScript -like "*NOPASSWD:ALL*") -Message "Linux update script should include root-equivalent sudo rule"

    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("az-vm-guest-task-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    try {
        $initPath = Join-Path $tmpDir "init.ps1"
        Write-TextFileNormalized -Path $initPath -Content (Get-CoVmWindowsInitScriptContent) -Encoding "utf8NoBom" -LineEnding "crlf" -EnsureTrailingNewline
        $windowsTasks = Resolve-CoVmGuestTaskBlocks -Platform "windows" -Context $context -VmInitScriptFile $initPath
        Assert-True -Condition (@($windowsTasks).Count -ge 10) -Message "Windows task list should contain expected tasks"
        $windowsScript = Get-CoVmUpdateScriptContentFromTasks -Platform "windows" -TaskBlocks $windowsTasks
        Assert-True -Condition ($windowsScript -like "*Update phase started.*") -Message "Windows update script should include update start marker"
        Assert-True -Condition ($windowsScript -like "*Allow-SSH-444*") -Message "Windows update script should include resolved SSH firewall rule"
        Assert-True -Condition ($windowsScript -like "*11434*") -Message "Windows update script should include resolved TCP port values"
        Assert-True -Condition ($windowsScript -like '*$assistantUser = "assistant"*') -Message "Windows update script should include assistant user variable replacement"
        Assert-True -Condition ($windowsScript -like '*Ensure-LocalPowerAdmin -UserName $assistantUser*') -Message "Windows update script should ensure assistant local power admin rights"
    }
    finally {
        Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-ConnectionDisplayModelDualUsers {
    function global:Get-CoVmVmDetails {
        param(
            [hashtable]$Context
        )

        return [ordered]@{
            PublicIP = "203.0.113.10"
            VmFqdn = "demo.austriaeast.cloudapp.azure.com"
        }
    }

    try {
        $context = [ordered]@{
            ResourceGroup = "rg-demo"
            VmName = "vm-demo"
            AzLocation = "austriaeast"
        }

        $linuxModel = Get-CoVmConnectionDisplayModel `
            -Context $context `
            -ManagerUser "manager" `
            -AssistantUser "assistant" `
            -SshPort "444" `
            -IncludeRdp
        Assert-Equal -Expected 2 -Actual (@($linuxModel.SshConnections).Count) -Message "Connection model should return two SSH entries"
        Assert-Equal -Expected 2 -Actual (@($linuxModel.RdpConnections).Count) -Message "Connection model should return two RDP entries when requested"
        Assert-True -Condition ((@($linuxModel.SshConnections | ForEach-Object { [string]$_.User }) -contains "manager")) -Message "Connection model should include manager SSH entry"
        Assert-True -Condition ((@($linuxModel.SshConnections | ForEach-Object { [string]$_.User }) -contains "assistant")) -Message "Connection model should include assistant SSH entry"
    }
    finally {
        Remove-Item -Path Function:\global:Get-CoVmVmDetails -ErrorAction SilentlyContinue
    }
}

Write-Host "Running compatibility smoke tests in host: $($PSVersionTable.PSVersion.ToString())"
Write-Host "Repo root: $RepoRoot"

Invoke-TestCase -Name "Syntax parse for all .ps1 files" -Action { Test-PsSyntaxAllFiles }

try {
    $coVmRoot = Join-Path $RepoRoot "co-vm"
    $imports = @(
        "az-vm-co-core.ps1",
        "az-vm-co-config.ps1",
        "az-vm-co-azure.ps1",
        "az-vm-co-guest.ps1",
        "az-vm-co-orchestration.ps1",
        "az-vm-co-runcommand.ps1",
        "az-vm-co-sku-picker.ps1"
    )
    foreach ($fileName in $imports) {
        $filePath = Join-Path $coVmRoot $fileName
        if (-not (Test-Path -LiteralPath $filePath)) {
            throw ("Shared module was not found: {0}" -f $filePath)
        }
        . $filePath
    }
    Write-TestResult -Success $true -Name "Import shared co-vm modules" -Detail ""
}
catch {
    Write-TestResult -Success $false -Name "Import shared co-vm modules" -Detail $_.Exception.Message
}

Invoke-TestCase -Name "JSON compatibility helpers" -Action { Test-JsonCompatFunctions }
Invoke-TestCase -Name "Config fallback behavior" -Action { Test-ConfigFallbackBehavior }
Invoke-TestCase -Name "Deterministic UTF-8 no-BOM + line-ending policy" -Action { Test-NormalizedFileWritePolicy }
Invoke-TestCase -Name "Run-command JSON parser behavior" -Action { Test-RunCommandJsonBehavior }
Invoke-TestCase -Name "Interactive SKU partial filter behavior" -Action { Test-SkuFilterBehaviorWithMockAz }
Invoke-TestCase -Name "Guest task catalog and update-script build behavior" -Action { Test-GuestTaskAndScriptBuild }
Invoke-TestCase -Name "Connection display model dual-user behavior" -Action { Test-ConnectionDisplayModelDualUsers }

if (Get-Command Write-TextFileNormalized -ErrorAction SilentlyContinue) {
    $fingerprint = Get-CompatFingerprint
    Write-Host ("COMPAT_FINGERPRINT: {0}" -f $fingerprint)
}

Write-Host ""
Write-Host ("Compatibility smoke summary -> Passed: {0}, Failed: {1}" -f $global:TestPassCount, $global:TestFailCount)
if ($global:TestFailCount -gt 0) {
    exit 1
}
