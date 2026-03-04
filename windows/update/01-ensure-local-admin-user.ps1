$ErrorActionPreference = "Stop"
$vmUser = "__VM_USER__"
$vmPass = "__VM_PASS__"
$assistantUser = "__ASSISTANT_USER__"
$assistantPass = "__ASSISTANT_PASS__"

function Ensure-GroupMembership {
    param(
        [string]$GroupName,
        [string]$MemberName
    )

    function Normalize-Identity {
        param(
            [string]$Value
        )

        if ([string]::IsNullOrWhiteSpace($Value)) {
            return ""
        }

        return $Value.Trim().ToLowerInvariant()
    }

    $shortMember = [string]$MemberName
    if ($MemberName -match '^[^\\]+\\(.+)$') {
        $shortMember = [string]$Matches[1]
    }

    $memberAliases = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in @(
        $MemberName,
        $shortMember,
        "$env:COMPUTERNAME\$shortMember",
        ".\$shortMember"
    )) {
        $normalizedCandidate = Normalize-Identity -Value ([string]$candidate)
        if (-not [string]::IsNullOrWhiteSpace($normalizedCandidate)) {
            [void]$memberAliases.Add($normalizedCandidate)
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
        $groupOutput = net localgroup "$GroupName" 2>&1
        if ($LASTEXITCODE -eq 0) {
            $groupOutputText = (@($groupOutput) | ForEach-Object { [string]$_ }) -join "`n"
            $escapedShortMember = [regex]::Escape($shortMember)
            $escapedFullMember = [regex]::Escape($MemberName)
            if (
                $groupOutputText -match ("(?im)^\s*(?:.+\\)?{0}\s*$" -f $escapedShortMember) -or
                $groupOutputText -match ("(?im)^\s*{0}\s*$" -f $escapedFullMember)
            ) {
                $alreadyMember = $true
            }
        }
    }

    if ($alreadyMember) {
        Write-Output "User '$MemberName' is already in local group '$GroupName'."
        return
    }

    $lastAddExitCode = 1
    $addCandidates = @(
        $MemberName,
        $shortMember,
        ".\$shortMember"
    )
    $addTried = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($addCandidate in @($addCandidates)) {
        if ([string]::IsNullOrWhiteSpace([string]$addCandidate)) {
            continue
        }

        if (-not $addTried.Add([string]$addCandidate)) {
            continue
        }

        net localgroup "$GroupName" $addCandidate /add | Out-Null
        $lastAddExitCode = $LASTEXITCODE

        if ($lastAddExitCode -eq 0) {
            Write-Output "User '$addCandidate' was added to local group '$GroupName'."
            return
        }

        if ($lastAddExitCode -eq 1378) {
            Write-Output "User '$addCandidate' is already in local group '$GroupName' (system error 1378)."
            return
        }
    }

    if ($lastAddExitCode -ne 0) {
        throw "Adding '$MemberName' to '$GroupName' failed with exit code $lastAddExitCode."
    }
}

function Ensure-LocalPowerAdmin {
    param(
        [string]$UserName,
        [string]$Password
    )

    if (-not (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue)) {
        $securePass = ConvertTo-SecureString $Password -AsPlainText -Force
        New-LocalUser -Name $UserName -Password $securePass -PasswordNeverExpires -AccountNeverExpires -FullName $UserName -Description "Azure VM Power Admin user" | Out-Null
    }
    else {
        net user $UserName $Password | Out-Null
    }
    Ensure-GroupMembership -GroupName "Administrators" -MemberName $UserName
    Ensure-GroupMembership -GroupName "Remote Desktop Users" -MemberName $UserName
}

Ensure-LocalPowerAdmin -UserName $vmUser -Password $vmPass
Ensure-LocalPowerAdmin -UserName $assistantUser -Password $assistantPass
Write-Output "local-admin-users-ready"
