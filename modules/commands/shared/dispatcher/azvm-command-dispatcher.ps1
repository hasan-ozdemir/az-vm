# Shared command dispatcher.

function Invoke-AzVmCommandDispatcher {
    param(
        [string]$CommandName,
        [hashtable]$Options,
        [string]$HelpTopic = ''
    )

    Assert-AzVmCommandOptions -CommandName $CommandName -Options $Options

    $autoRequested = Get-AzVmCliOptionBool -Options $Options -Name 'auto' -DefaultValue $false
    $script:AutoMode = ($CommandName -in @('create','update','delete')) -and $autoRequested
    $script:PerfMode = Get-AzVmCliOptionBool -Options $Options -Name 'perf' -DefaultValue $false
    $windowsFlag = Get-AzVmCliOptionBool -Options $Options -Name 'windows' -DefaultValue $false
    $linuxFlag = Get-AzVmCliOptionBool -Options $Options -Name 'linux' -DefaultValue $false
    if ($windowsFlag -and $linuxFlag) {
        Throw-FriendlyError -Detail 'Both --windows and --linux were provided.' -Code 2 -Summary 'Conflicting OS selection flags were provided.' -Hint 'Use only one of --windows or --linux.'
    }

    $script:ConfigOverrides = @{}
    $script:ActiveCommand = [string]$CommandName
    $helpRequested = Get-AzVmCliOptionBool -Options $Options -Name 'help' -DefaultValue $false

    $commandPerfWatch = $null
    if ($script:PerfMode) {
        $commandPerfWatch = [System.Diagnostics.Stopwatch]::StartNew()
    }

    try {
        if ($helpRequested -and $CommandName -ne 'help') {
            Show-AzVmCommandHelp -Topic $CommandName
            return
        }

        switch ($CommandName) {
            'help' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmHelpEntry -HelpTopic $HelpTopic
                return
            }
            'configure' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmConfigureCommand -Options $Options -AutoMode:$false -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag
                return
            }
            'group' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmGroupCommand -Options $Options
                return
            }
            'show' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmShowCommand -Options $Options -AutoMode:$false -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag
                return
            }
            'do' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmDoCommand -Options $Options
                return
            }
            'task' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmTaskCommand -Options $Options -AutoMode:$false -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag | Out-Null
                return
            }
            'create' {
                Invoke-AzVmCreateCommand -Options $Options -AutoMode:$script:AutoMode -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag
                return
            }
            'update' {
                Invoke-AzVmUpdateCommand -Options $Options -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag -AutoMode:$script:AutoMode
                return
            }
            'move' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmMoveCommand -Options $Options -AutoMode:$script:AutoMode -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag
                return
            }
            'resize' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmResizeCommand -Options $Options -AutoMode:$script:AutoMode -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag
                return
            }
            'set' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmSetCommand -Options $Options -AutoMode:$script:AutoMode -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag
                return
            }
            'exec' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmExecCommand -Options $Options -AutoMode:$script:AutoMode -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag
                return
            }
            'ssh' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmSshConnectCommand -Options $Options
                return
            }
            'rdp' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmRdpConnectCommand -Options $Options
                return
            }
            'delete' {
                $script:UpdateMode = $false
                $script:RenewMode = $false
                $script:ExecutionMode = 'default'
                Invoke-AzVmDeleteCommand -Options $Options -AutoMode:$script:AutoMode -WindowsFlag:$windowsFlag -LinuxFlag:$linuxFlag
                return
            }
            default {
                Throw-FriendlyError -Detail ("Unknown command '{0}'." -f $CommandName) -Code 2 -Summary "Unknown command." -Hint "Use one command: create | update | configure | group | show | do | task | exec | ssh | rdp | move | resize | set | delete | help."
            }
        }
    }
    finally {
        if ($script:PerfMode -and $null -ne $commandPerfWatch) {
            if ($commandPerfWatch.IsRunning) {
                $commandPerfWatch.Stop()
            }

            Write-AzVmPerfTiming -Category 'command' -Label ([string]$CommandName) -Seconds $commandPerfWatch.Elapsed.TotalSeconds
        }
    }
}
