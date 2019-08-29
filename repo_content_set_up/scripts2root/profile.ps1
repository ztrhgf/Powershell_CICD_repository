<#

slouzi k nastaveni PS konzole.
tzn importu pouzivanych skriptu, modulu, promennych, definovani per user funkci, ...

kopiruje se pouze na stroje uvedene v $computerWithProfile

! tento profil ovlivnuje pouze lokalni session, ne remote !

!!! piste jej tak, aby definoval promenne a funkce, ale neprovadel zadne nechtene zmeny v systemu !!!

#>


# nema smysl spoustet pro startup skripty, sched. task skripty atd, ktere bezi pod systemovymi ucty
$whoami = whoami.exe
if ($whoami -in "NT AUTHORITY\SYSTEM", "NT AUTHORITY\NETWORK SERVICE", "NT AUTHORITY\LOCAL SERVICE") { return }
$local_user = $env:USERDOMAIN -eq $env:COMPUTERNAME

#
# aby jako pracovni adresar byla cesta do profilu uzivatele, pod kterym konzole bezi
Set-Location $env:USERPROFILE



#
# customizace chovani psreadline rozsireni
#

try {
    # aby TAB doplnoval i jmena souboru v adresari
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete -ErrorAction Stop # nebo Complete
    # identicke prikazy spustene vickrat po sobe se budou zobrazovat v historii pouze jednou
    Set-PSReadLineOption -HistoryNoDuplicates:$True -ErrorAction Stop
    # co se smi ulozit do historie prikazu
    # obecne ignoruji veci kolem hesel
    Set-PSReadLineOption -AddToHistoryHandler {
        Param([string]$line)
        if ($line -notmatch "runas|admpwd|-pswd ") {
            return $True
        } else {
            return $False
        }
    } -ErrorAction Stop
} catch {
    "nepodarilo se nastavit PSReadline"
}




#
# customizace vychozich parametru fci
#

$PSDefaultParameterValues = @{
    # ulozeni vystupu posledniho prikazu do $__
    'Out-Default:OutVariable' = '__'
}
# $PSDefaultParameterValues.Clear() # komplet zruseni
# $PSDefaultParameterValues.Add('Disabled', $true) # docasne zakazani obsahu $PSDefaultParameterValues
# $PSDefaultParameterValues.Remove('Disabled') # opetovne povoleni obsahu $PSDefaultParameterValues



#
# import modulu
#

if (!$local_user) {
    #
    # nactu promenne z Variables modulu
    <# kvuli rychlosti nepouzivam klasicky Import-Module, ale:
        - vytvorim synchronized hash hash_with_variables
        - vytvorim background runspace a predam do nej hash
        - v runspace nactu modul (tzn asynchronne)
        - ziskane promenne ulozim do hashe
        - v prompt funkci po dokonceni runspace jobu vytvorim z obsahu hashe opet promenne
            pozn.: prompt pouzivam, protoze nevim jak to automaticky provest jinak
    #>
    # $hash_with_variables = [hashtable]::Synchronized(@{})
    # $runspace = [runspacefactory]::CreateRunspace()
    # $runspace.Open()
    # $runspace.SessionStateProxy.SetVariable('hash_with_variables', $hash_with_variables)
    # $powershell = [powershell]::Create()
    # $powershell.Runspace = $runspace
    # $powershell.AddScript( {
    #         $var = Get-Variable | Select-Object -ExpandProperty Name
    #         Import-Module Variables -Force
    #         # ulozim vysledky do hashe
    #         Get-Variable -Exclude $var | % {
    #             $name = $_.Name
    #             $value = $_.Value
    #             $hash_with_variables.$name = $value
    #         }
    #     }) | Out-Null
    # # spustim ziskani promennych
    # $handle = $powershell.BeginInvoke()

    Import-Module Variables

    # aby nezdrzovalo spusteni, necham automaticky nacist az pri zavolani nejake fce z tohoto modulu
    #Import-Module Scripts -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
}

#
# customizace vzhledu konzole
#

# uprava Title konzole
$title = ''
$identity = [Security.Principal.WindowsIdentity]::GetCurrent() ; $principal = [Security.Principal.WindowsPrincipal] $identity
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) { $title = "[ELEVATED] " }
$title += ($env:USERNAME).toupper()
$title += "            " + (Get-Location).path
$Host.UI.RawUI.Windowtitle = $title
# uprava promptu, barevne odliseni podle toho jak privilegovany ucet konzoli spustil
function prompt {
    # nageneruji promenne z hodnot ulozenych v synchronized hashi, ktery byl naplnen background runspacem importujicim modul Variables
    # zde v promptu delam proto, ze nevim jak import provest automaticky po dokonceni runspace (+ je zaroven uklidit)
    # if ($hash_with_variables) {
    #     if ($handle.IsCompleted) {
    #         Write-Warning "Odted jsou dostupne promenne z modulu Variables (background runspace se prave ukoncil)"
    #         $powershell.EndInvoke($handle)
    #         $runspace.Close()
    #         $powershell.Dispose()

    #         $hash_with_variables.GetEnumerator() | % {
    #             New-Variable -Name $_.name -Value $_.value -Scope global
    #         }

    #         Remove-Variable hash_with_variables, runspace, powershell -Scope global -Force
    #     }
    # }

    # aktualizace cesty v title
    $titleItems = $Host.UI.RawUI.Windowtitle -split "\s+"
    $Host.UI.RawUI.Windowtitle = (($titleItems | Select-Object -First ($titleItems.count - 1)) -join " ") + "            " + (Get-Location).path

    # uprava promptu
    $color = "white"
    if ($env:USERNAME -match "^adm_") {
        $color = "red"
    }

    Write-Host "PS" -noNewLine -ForegroundColor $color
    return "> "
}


#
# funkce & aliasy
#

function PSAsAdmin { Start-Process powershell -Verb runAs }

function hypervConsole {
    if (Test-Path "$env:SystemRoot\System32\virtmgmt.msc" -ErrorAction SilentlyContinue) {
        Start-Process "$env:SystemRoot\System32\mmc.exe" -arg "$env:SystemRoot\System32\virtmgmt.msc"
    } else {
        if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
            Write-Error "Nemate nainstalovany Hyper-V Tools, pro jejich nainstalovani, spustte prikaz znovu, ale v admin konzoli."
        } else {
            while ($choice -notmatch "^[A|N]$") {
                $choice = Read-Host "Nemate nainstalovany Hyper-V Tools. Nainstalovat? (A|N)"
            }
            if ($choice -eq "N") {
                break
            } else {
                Enable-WindowsOptionalFeature -FeatureName Microsoft-Hyper-V-Tools-All -Online -NoRestart
                Start-Process "$env:SystemRoot\System32\mmc.exe" -arg "$env:SystemRoot\System32\virtmgmt.msc"
            }
        }
    }
}

function spp { Start-Process powershell }

function mgmt { param ($computerName) compmgmt.msc /computer=$computerName }

function ref {
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

function Search-GPO { param($name) Get-GPO -all | Where-Object { $_.displayname -like "*$name*" } | Select-Object -ExpandProperty displayname }


#
# aliasy
#

Set-Alias es Enter-PSSession


#
# per user nastaveni
#

switch ($env:USERNAME) {
    { $_ -in 'karel', 'admKarel' } {
        function temp { Set-Location "C:\temp" }
        function ttcmd { &"C:\DATA\totalcmd(x64)\TOTALCMD64.EXE" }
        function vmmConsole {
            try {
                & "C:\Program Files\Microsoft System Center\Virtual Machine Manager\bin\VmmAdminUI.exe"
            } catch {
                throw "nainstaluj si VMM konzoli"
            }
        }
    }

    { $_ -in 'Pepa' } {
        function ttcmd { & "C:\Program Files\totalcmd(x64)\TOTALCMD64.EXE" }
    }
}

#
# vypsani infa do konzole
#

# NEPOUZIVAT, jinak havaruji SCCM detekcni skripty