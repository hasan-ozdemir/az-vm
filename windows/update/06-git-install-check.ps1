$ErrorActionPreference = "Stop"
$chocoExe = "$env:ProgramData\chocolatey\bin\choco.exe"
if (-not (Test-Path $chocoExe)) { throw "choco was not found." }
& $chocoExe upgrade git -y --no-progress | Out-Null
$refreshEnvCmd = "$env:ProgramData\chocolatey\bin\refreshenv.cmd"
if (Test-Path $refreshEnvCmd) { cmd.exe /c "`"$refreshEnvCmd`" >nul 2>&1" }
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    $existing = @()
    if (-not [string]::IsNullOrWhiteSpace($machinePath)) {
        $existing = $machinePath -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    foreach ($candidate in @("C:\Program Files\Git\cmd","C:\Program Files\Git\bin")) {
        if ((Test-Path $candidate) -and ($existing -notcontains $candidate)) { $existing += $candidate }
    }
    [Environment]::SetEnvironmentVariable("Path", ($existing -join ';'), "Machine")
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    if ([string]::IsNullOrWhiteSpace($userPath)) { $env:Path = $machinePath } else { $env:Path = "$machinePath;$userPath" }
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "git command was not found." }
git --version
