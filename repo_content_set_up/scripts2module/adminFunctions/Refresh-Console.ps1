function Refresh-Console {
    <#
    .SYNOPSIS
    Funkce slouzi k aktualizace Powershell prostredi.

    .DESCRIPTION
    Funkce slouzi k aktualizace Powershell prostredi.
    Ve vychozim nastaveni provede:
    - update DFS repo (Cloud repo >> DFS)
    - update lokalniho prostredi (DFS >> klient)
    - refresh PS konzole, ze ktere doslo ke spusteni funkce, tzn nacte nove verze modulu a sys. promennych (pokud nespoustite vuci remote stroji)

    .PARAMETER justLocalRefresh
    Pro vynechani aktualizace DFS repo.
    Tzn dojde pouze ke stazeni zmen DFS >> klient, ale ne Cloud repo >> DFS.

    .PARAMETER computerName
    Remote stroj, na kterem se ma provest update PS prostredi.
    PS konzole na danem stroji se neupdatuji!

    .EXAMPLE
    ref -verbose

    Provede update DFS repo, nasledne lokalnich PS dat a nakonec provede refresh konzole a vypise, co vse se znovu naimportovalo.

    .EXAMPLE
    ref -computerName APP-15

    Provede update DFS repo (z Cloud repo) a nasledne lokalnich PS dat na APP-15 (z DFS).

    .EXAMPLE
    ref -computerName APP-15 -justLocalRefresh

    Provede stazeni dat z DFS repo na APP-15. Bez provedeni updatu samotneho DFS z Cloud Repo.
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
    # vynuceni stazeni nejaktualnejsich dat z GIT repo do DFS repo
    if (!$justLocalRefresh) {
        try {
            Invoke-Command -ComputerName $RepoSyncServer {
                $taskName = "Repo_sync"
                Start-ScheduledTask $taskName
                Write-Host "Cekam na dokonceni aktualizace DFS repo, max vsak 60 sekund"
                $count = 0
                while (((Get-ScheduledTask $taskName -errorAction silentlyContinue).state -ne "Ready") -and $count -le 600) {
                    Start-Sleep -Milliseconds 100
                    ++$count
                }
            } -ErrorAction stop
        } catch {
            Write-Warning "Nepodarilo se provest aktualizaci DFS repozitare"
        }
    } else {
        Write-Warning "Preskocili jste stazeni aktualnich dat do DFS repozitare"
    }


    #
    # aktualizace PS prostredi == spusteni sched tasku kvuli stazeni aktualniho obsahu z remote repozitare
    if (!$computerName) {
        # delam lokalne
        # stahnu aktualni data z DFS a provedu refresh konzole
        $command = @'
    $taskName = "PS_env_set_up"
    Start-ScheduledTask $taskName
    echo "Cekam na dokonceni aktualizace PS prostredi, max vsak 30 sekund"
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
            # ne-admin konzole
            $pParams.Verb = "runas"
            $pParams.Wait = $true
        } else {
            # admin konzole
            $pParams.NoNewWindow = $true
        }

        try {
            Start-Process @pParams
        } catch {
            if ($_ -match "The operation was canceled by the user") {
                Write-Warning "Preskocili jste stazeni aktualnich dat z remote repozitare"
            } else {
                Write-Error $_
            }
        }

        #
        # znovu nacteni ps profilu
        Write-Warning "Pro opetovne nacteni PS profilu je potreba spustit novou konzoli"

        #
        # nastaveni aktualnich sys. promennych vcetne PATH
        # vykradeno z https://github.com/chocolatey/choco/blob/stable/src/chocolatey.resources/helpers/functions/Update-SessionEnvironment.ps1

        # User je schvalne posledni, aby v pripade konfliktu vyhrala jeho nastaveni nad systemovymi
        'Process', 'Machine', 'User' | ForEach-Object {
            $scope = $_
            Get-EnvironmentVariableNames -Scope $scope | ForEach-Object {
                Write-Verbose "Nastavuji promennou $_"
                Set-Item "Env:$($_)" -Value (Get-EnvironmentVariable -Scope $scope -Name $_)
            }
        }

        # do PATH v konzoli ulozim jak obsah systemove, tak uzivatelske
        Write-Verbose "`nNastavuji promennou PATH"
        $paths = 'Machine', 'User' | ForEach-Object {
            (Get-EnvironmentVariable -Name 'PATH' -Scope $_) -split ';'
        } | Select-Object -Unique
        $Env:PATH = $paths -join ';' -replace ";;", ";"


        # kdyby nahodou v prubehu doslo k uprave techto promennych (jakoze se to deje)
        # tak vratim hodnoty pred provedenim ref
        if ($userName) { $env:USERNAME = $userName }
        if ($architecture) { $env:PROCESSOR_ARCHITECTURE = $architecture }
        $env:PSModulePath = $psModulePath


        #
        # znovunacteni aktualne nactenych modulu
        $importedModule = (Get-Module).name | Where-Object { $_ -notmatch "^tmp_" }
        if ($importedModule) {
            Write-Verbose "`nOdstranuji nactene moduly"
            $importedModule | Remove-Module -Force -Confirm:$false -WarningAction SilentlyContinue
            Write-Verbose "`nZnovu importuji moduly: $($importedModule.name -join ', ')"
            $importedModule | Import-Module -force -Global -WarningAction SilentlyContinue
        }
    } else {
        # zadal computerName, spustim sched. task pro stazeni aktualnich dat z DFS na danem stroji
        # PS konzole neaktualizuji
        try {
            Invoke-Command -ComputerName $computerName {
                $taskName = "PS_env_set_up"
                Start-ScheduledTask $taskName -ErrorAction Stop
                Write-Host "Cekam na dokonceni aktualizace PS prostredi na $env:COMPUTERNAME, max vsak 30 sekund"
                $count = 0
                while (((Get-ScheduledTask $taskName -errorAction silentlyContinue).state -ne "Ready") -and $count -le 300) {
                    Start-Sleep -Milliseconds 100
                    ++$count
                }
            } -ErrorAction stop
        } catch {
            if ($_ -match "The system cannot find the file specified") {
                Write-Warning "Nepodarilo se provest aktualizaci PS prostredi, protoze synchronizacni sched. task nebyl nalezen.`nMa stroj $computerName pravo na sebe aplikovat GPO PS_env_set_up?"
            } else {
                Write-Warning "Nepodarilo se provest aktualizaci PS prostredi.`nChyba byla:`n$_"
            }
        }
    }
}