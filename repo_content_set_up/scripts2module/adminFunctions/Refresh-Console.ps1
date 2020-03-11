function Refresh-Console {
    <#
    .SYNOPSIS
    Use this function for forcing update of central repository data on MGM server, DFS repository share and on given computer ie downloading new repository data (modules, functions and variables) and importing them to this console.

    .DESCRIPTION
    Use this function for forcing update of central repository data on MGM server, DFS repository share and on given computer ie downloading new repository data (modules, functions and variables) and importing them to this console.

    Default behaviour:
    - pull new data to MGM server repository from cloud repository, than
    - update data in DFS repository share, than
    - download actual data from DFS repository to this client, than
    - import actual data to this running Powershell console
        - update of $env:PATH included

    .PARAMETER justLocalRefresh
    Skip update of MGM and DFS repository ie just download actual content from DFS repository.

    .PARAMETER computerName
    Remote computer where you want to sync new data.
    Powershell consoles won't be updated, so users will have to close and reopen them!

    .EXAMPLE
    Refresh-Console -verbose

    Start update of MGM server repository, than DFS repository and in the end download data from DFS to this client and import them to this console.
    Output verbose information to console.

    .EXAMPLE
    ref -computerName APP-15

    Start update of MGM server repository, than DFS repository and in the end download data from DFS to APP-15 client.

    .EXAMPLE
    Refresh-Console -computerName APP-15 -justLocalRefresh

    Skip update of MGM server repository and DFS repository and just download data from DFS to APP-15 client.
    #>

    [cmdletbinding()]
    [Alias("ref")]
    param (
        [switch] $justLocalRefresh
        ,
        [string] $computerName
    )

    $userName = $env:USERNAME
    $architecture = $env:PROCESSOR_ARCHITECTURE
    $psModulePath = $env:PSModulePath

    function Get-EnvironmentVariableNames([System.EnvironmentVariableTarget] $Scope) {
        switch ($Scope) {
            'User' { Get-Item 'HKCU:\Environment' | Select-Object -ExpandProperty Property }
            'Machine' { Get-Item 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' | Select-Object -ExpandProperty Property }
            'Process' { Get-ChildItem Env:\ | Select-Object -ExpandProperty Key }
            default { throw "Unsupported environment scope: $Scope" }
        }
    }

    function Get-EnvironmentVariable([string] $Name, [System.EnvironmentVariableTarget] $Scope) {
        [Environment]::GetEnvironmentVariable($Name, $Scope)
    }

    #
    # update of MGM and DFS repository
    if (!$justLocalRefresh) {
        # user want most actual data
        try {
            Invoke-Command -ComputerName $RepoSyncServer {
                $taskName = "Repo_sync"
                Start-ScheduledTask $taskName
                Write-Host "Waiting for end of DFS repository data sync, maximum wait time is 60 seconds"
                $count = 0
                while (((Get-ScheduledTask $taskName -errorAction silentlyContinue).state -ne "Ready") -and $count -le 600) {
                    Start-Sleep -Milliseconds 100
                    ++$count
                }
            } -ErrorAction stop
        } catch {
            Write-Warning "Unable to finish update of DFS repository data"
        }
    } else {
        Write-Warning "You skipped update of DFS repository data"
    }


    #
    # update of client data ie starting sched. task PS_env_set_up which will download actual data from DFS repository
    if (!$computerName) {
        $command = @'
    $taskName = "PS_env_set_up"
    Start-ScheduledTask $taskName
    echo "Waiting for end of local data update, maximum wait time is 30 seconds"
    $count = 0
    while (((Get-ScheduledTask $taskName -errorAction silentlyContinue).state -ne "Ready") -and $count -le 300) {
        Start-Sleep -Milliseconds 100
        ++$count
    }
'@

        $bytes = [System.Text.Encoding]::Unicode.GetBytes($command)
        $encodedCommand = [Convert]::ToBase64String($bytes)
        $pParams = @{
            filePath     = "powershell.exe"
            ArgumentList = "-noprofile -encodedCommand $encodedCommand"
            Wait         = $true
        }

        if (-not (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))) {
            # non-admin console ie I need to invoke new admin console to have enough permission to start PS_env_set_up sched. task
            $pParams.Verb = "runas"
            $pParams.Wait = $true
        } else {
            # admin console ie I have enough permission to start PS_env_set_up sched. task here
            $pParams.NoNewWindow = $true
        }

        try {
            Start-Process @pParams
        } catch {
            if ($_ -match "The operation was canceled by the user") {
                Write-Warning "You have skipped update of local client data"
            } else {
                Write-Error $_
            }
        }

        Write-Warning "To apply changes made in Powershell Profile you will have to open new PS console"

        #
        # update registry entry, that store commit identifier which was actual when this console started/was updated
        # to be able later compare it with actual system commit state and show number of commits behind in console Title (more about this in profile.ps1)
        $commitHistoryPath = "$env:SystemRoot\Scripts\commitHistory"
        if ($consoleCommit = Get-Content $commitHistoryPath -First 1 -ErrorAction SilentlyContinue) {
            $null = New-ItemProperty HKCU:\Software -Name "consoleCommit_$PID" -PropertyType string -Value $consoleCommit -Force
        }

        #
        # update of system environment variables (PATH included)
        # inspired by https://github.com/chocolatey/choco/blob/stable/src/chocolatey.resources/helpers/functions/Update-SessionEnvironment.ps1

        # User scope is last on purpose, to overwrite other scopes in case of conflict
        'Process', 'Machine', 'User' | % {
            $scope = $_
            Get-EnvironmentVariableNames -Scope $scope | % {
                Write-Verbose "Setting variable $_"
                Set-Item "Env:$($_)" -Value (Get-EnvironmentVariable -Scope $scope -Name $_)
            }
        }

        # save content of system and user PATH into console variable Env:PATH
        Write-Verbose "`nSetting variable PATH"
        $paths = 'Machine', 'User' | % {
            (Get-EnvironmentVariable -Name 'PATH' -Scope $_) -split ';'
        } | Select-Object -Unique
        $Env:PATH = $paths -join ';' -replace ";;", ";"


        #
        # because some variables values are replaced by incorrect values by this update process, replace them by correct one
        if ($userName) { $env:USERNAME = $userName }
        if ($architecture) { $env:PROCESSOR_ARCHITECTURE = $architecture }
        $env:PSModulePath = $psModulePath


        #
        # reimport of currently loaded PS modules
        # just modules that can be updated by this CI/CD solution, so just System modules
        $importedModule = Get-Module | where { $_.name -notmatch "^tmp_" -and $_.path -like "$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules\*" } | select -exp name
        if ($importedModule) {
            Write-Verbose "`nRemove loaded modules"
            $importedModule | Remove-Module -Force -Confirm:$false -WarningAction SilentlyContinue
            Write-Verbose "`nReimport modules again: $($importedModule.name -join ', ')"
            $importedModule | Import-Module -force -Global -WarningAction SilentlyContinue
        }
    } else {
        # update should be started on remote computer
        try {
            Invoke-Command -ComputerName $computerName {
                $taskName = "PS_env_set_up"
                Start-ScheduledTask $taskName -ErrorAction Stop
                Write-Host "Waiting for end of local data update on $env:COMPUTERNAME, maximum wait time is 30 seconds"
                $count = 0
                while (((Get-ScheduledTask $taskName -errorAction silentlyContinue).state -ne "Ready") -and $count -le 300) {
                    Start-Sleep -Milliseconds 100
                    ++$count
                }
            } -ErrorAction stop
        } catch {
            if ($_ -match "The system cannot find the file specified") {
                Write-Warning "Unable to finish the update on $env:COMPUTERNAME, because sched. task $taskName wasn't found.`nIs GPO PS_env_set_up linked to this computer?"
            } else {
                Write-Warning "Unable to finish the update on $env:COMPUTERNAME.`nError was:`n$_"
            }
        }
    }
}