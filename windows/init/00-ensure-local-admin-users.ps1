$ErrorActionPreference = "Stop"
Write-Host "Init task started: ensure-local-admin-users"

$vmUser = "__VM_USER__"
$vmPass = "__VM_PASS__"
$assistantUser = "__ASSISTANT_USER__"
$assistantPass = "__ASSISTANT_PASS__"

function Normalize-Identity {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
    return $Value.Trim().ToLowerInvariant()
}

function Ensure-GroupMembership {
    param(
        [string]$GroupName,
        [string]$MemberName
    )

    $shortMember = [string]$MemberName
    if ($MemberName -match '^[^\\]+\\(.+)$') {
        $shortMember = [string]$Matches[1]
    }

    $memberAliases = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @($MemberName, $shortMember, "$env:COMPUTERNAME\\$shortMember", ".\\$shortMember")) {
        $normalized = Normalize-Identity -Value ([string]$candidate)
        if (-not [string]::IsNullOrWhiteSpace($normalized)) {
            [void]$memberAliases.Add($normalized)
        }
    }

    $alreadyMember = $false
    try {
        $members = Get-LocalGroupMember -Group $GroupName -ErrorAction Stop
        foreach ($member in $members) {
            $existingMember = Normalize-Identity -Value ([string]$member.Name)
            if ($memberAliases.Contains($existingMember)) {
                $alreadyMember = $true
                break
            }
        }
    }
    catch {
        Write-Warning "Get-LocalGroupMember failed for '$GroupName', fallback to net localgroup."
        $groupOutput = net localgroup "$GroupName"
        if ($LASTEXITCODE -eq 0) {
            $groupText = (@($groupOutput) | ForEach-Object { [string]$_ }) -join "`n"
            $escapedShortMember = [regex]::Escape($shortMember)
            $escapedFullMember = [regex]::Escape($MemberName)
            if (
                $groupText -match ("(?im)^\s*(?:.+\\)?{0}\s*$" -f $escapedShortMember) -or
                $groupText -match ("(?im)^\s*{0}\s*$" -f $escapedFullMember)
            ) {
                $alreadyMember = $true
            }
        }
    }

    if ($alreadyMember) {
        Write-Host "User '$MemberName' is already in local group '$GroupName'."
        return
    }

    $lastAddExitCode = 1
    $addCandidates = @($MemberName, $shortMember, ".\\$shortMember")
    $addTried = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($addCandidate in @($addCandidates)) {
        if ([string]::IsNullOrWhiteSpace([string]$addCandidate)) { continue }
        if (-not $addTried.Add([string]$addCandidate)) { continue }

        net localgroup "$GroupName" $addCandidate /add
        $lastAddExitCode = [int]$LASTEXITCODE

        if ($lastAddExitCode -eq 0) {
            Write-Host "User '$addCandidate' was added to local group '$GroupName'."
            return
        }

        if ($lastAddExitCode -eq 1378) {
            Write-Host "User '$addCandidate' is already in local group '$GroupName' (system error 1378)."
            return
        }
    }

    throw "Adding '$MemberName' to '$GroupName' failed with exit code $lastAddExitCode."
}

function Ensure-LocalUserUnlocked {
    param([string]$TargetUser)

    try {
        net user $TargetUser /active:yes
    }
    catch {
        Write-Warning "Could not enforce active state for '$TargetUser': $($_.Exception.Message)"
    }

    try {
        $adsiPath = "WinNT://$env:COMPUTERNAME/$TargetUser,user"
        $adsiUser = [ADSI]$adsiPath
        $isLocked = $false
        try { $isLocked = [bool]$adsiUser.InvokeGet("IsAccountLocked") } catch { }
        if ($isLocked) {
            $adsiUser.InvokeSet("IsAccountLocked", $false)
            $adsiUser.SetInfo()
            Write-Host "User '$TargetUser' lockout state was cleared."
        }
    }
    catch {
        Write-Warning "User '$TargetUser' lockout verification failed: $($_.Exception.Message)"
    }
}

function Ensure-LocalPowerAdmin {
    param(
        [string]$UserName,
        [string]$Password
    )

    if (-not (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
        $securePass = ConvertTo-SecureString $Password -AsPlainText -Force
        New-LocalUser -Name $UserName -Password $securePass -PasswordNeverExpires -AccountNeverExpires -FullName $UserName -Description "Azure VM Power Admin user"
    }
    else {
        net user $UserName $Password
    }

    Ensure-LocalUserUnlocked -TargetUser $UserName
    Ensure-GroupMembership -GroupName "Administrators" -MemberName $UserName
    Ensure-GroupMembership -GroupName "Remote Desktop Users" -MemberName $UserName
}

Ensure-LocalPowerAdmin -UserName $vmUser -Password $vmPass
Ensure-LocalPowerAdmin -UserName $assistantUser -Password $assistantPass

Write-Host "local-admin-users-ready"
Write-Host "Init task completed: ensure-local-admin-users"
