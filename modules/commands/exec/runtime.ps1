# Exec command runtime helpers.

# Handles Resolve-AzVmTaskSelection.
function Resolve-AzVmTaskSelection {
    param(
        [object[]]$TaskBlocks,
        [string]$TaskNumberOrName,
        [string]$Stage,
        [switch]$AutoMode
    )

    $allTasks = @($TaskBlocks)
    if ($allTasks.Count -eq 0) {
        Throw-FriendlyError `
            -Detail ("No active {0} tasks were found." -f $Stage) `
            -Code 60 `
            -Summary "Task list is empty." `
            -Hint ("Add files under the '{0}' task directory." -f $Stage)
    }

    $selectedToken = if ($null -eq $TaskNumberOrName) { '' } else { [string]$TaskNumberOrName }
    $selectedToken = $selectedToken.Trim()
    if ([string]::IsNullOrWhiteSpace($selectedToken)) {
        if ($AutoMode) {
            Throw-FriendlyError `
                -Detail ("Option '--{0}-task' is required in auto mode." -f $Stage) `
                -Code 60 `
                -Summary "Task selection is required in auto mode." `
                -Hint ("Provide --{0}-task=<task-number>." -f $Stage)
        }

        Write-Host ("Available {0} tasks:" -f $Stage) -ForegroundColor Cyan
        for ($i = 0; $i -lt $allTasks.Count; $i++) {
            Write-Host ("{0}. {1}" -f ($i + 1), [string]$allTasks[$i].Name)
        }
        while ($true) {
            $pickRaw = Read-Host ("Enter {0} task number" -f $Stage)
            if ($pickRaw -match '^\d+$') {
                $pickNumber = [int]$pickRaw
                if ($pickNumber -ge 1 -and $pickNumber -le $allTasks.Count) {
                    return $allTasks[$pickNumber - 1]
                }
            }
            Write-Host "Invalid task selection. Please enter a valid number." -ForegroundColor Yellow
        }
    }

    $selectedTask = $null
    if ($selectedToken -match '^\d+$') {
        $requestedTaskNumber = [int]$selectedToken
        $selectedTask = @(
            $allTasks |
                Where-Object {
                    $candidateTaskNumber = -1
                    if ($_.PSObject.Properties.Match('TaskNumber').Count -gt 0 -and $null -ne $_.TaskNumber) {
                        $candidateTaskNumber = [int]$_.TaskNumber
                    }
                    elseif (([string]$_.Name) -match '^(?<n>\d{2,5})-') {
                        $candidateTaskNumber = [int]$Matches.n
                    }

                    $candidateTaskNumber -eq $requestedTaskNumber
                } |
                Select-Object -First 1
        )
    }
    else {
        $selectedTask = @($allTasks | Where-Object { [string]::Equals([string]$_.Name, $selectedToken, [System.StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
    }

    if ($null -eq $selectedTask -or @($selectedTask).Count -eq 0) {
        Throw-FriendlyError `
            -Detail ("Task '{0}' was not found in {1} catalog." -f $selectedToken, $Stage) `
            -Code 60 `
            -Summary "Task selection is invalid." `
            -Hint ("List valid {0} task numbers with 'az-vm task --list --vm-{0}'." -f $Stage)
    }

    return $selectedTask[0]
}
