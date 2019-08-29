# skript pro zpracovani a distribuci obshau GIT repo z cloudoveho GIT repo do DFS lokace

# BACHA aby fungovalo, je potreba mit na repo_puller uctu nastaveno alternate credentials v GIT web rozhrani a ty mit vyexportovane do login.xml pod uctem, pod kterym pobezi tento skript

# postup:
# git pull pro stazeni aktualniho obsahu repo
# nagenerovani PS modulu
# nakopirovani do prislusnych slozek v DFS


$ErrorActionPreference = "stop"

$logFolder = Join-Path $PSScriptRoot "Log"

# aby nespamovalo v pripade chyby, umoznuji poslat max 1 mail za 30 minut
$lastSendEmail = Join-Path $logFolder "lastSendEmail"
$treshold = 30

$destination = "TODONAHRADIT" # sitova cesta k DFS repozitari (napr.: \\mojedomena\dfs\repository)

function _emailAndExit {
    param ($body)

    if ((Test-Path $lastSendEmail -ea SilentlyContinue) -and (Get-Item $lastSendEmail).LastWriteTime -gt [datetime]::Now.AddMinutes(-$treshold)) {
        "posledni chybovy email byl poslan min nez pred $treshold minutami...jen ukoncim"
        throw 1
    } else {
        $body = $body + "`n`n`nPripadna dalsi chyba se posle nejdriv za $treshold minut"
        Send-Email -body $body
        New-Item $lastSendEmail -Force
        throw 1
    }
}

function _startProcess {
    <#
        oproti Start-Process vypisuje vystup (vcetne chyb) primo do konzole
    #>
    [CmdletBinding()]
    param (
        [string] $filePath = '',
        [string] $argumentList = '',
        [string] $workingDirectory = (Get-Location)
    )

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError = $true
    $p.StartInfo.WorkingDirectory = $workingDirectory
    $p.StartInfo.FileName = $filePath
    $p.StartInfo.Arguments = $argumentList
    [void]$p.Start()
    $p.WaitForExit()
    $p.StandardOutput.ReadToEnd()
    $p.StandardError.ReadToEnd()
}

try {
    # kontrola, ze mam pravo zapisu do DFS repo
    try {
        $rFile = Join-Path $destination Get-Random
        $null = New-Item -Path ($rFile) -ItemType File -Force -Confirm:$false
    } catch {
        _emailAndExit -body "Ahoj,`nskript nema pravo zapisu do $destination. Tzn zmeny v GIT repo se nemohou zpropagovat.`nJe ucet stroje $env:COMPUTERNAME ve skupine repo_writer?"
    }
    Remove-Item $rFile -Force -Confirm:$false

    #
    # kontrola ze je nainstalovan GIT
    try {
        git.exe --version
    } catch {
        _emailAndExit -body "Ahoj,`ngit neni na $env:COMPUTERNAME nainstalovan. Tzn zmeny v GIT repo se nemohou zpropagovat do $destination.`nNainstalujte jej"
    }

    #
    # stahnu aktualni obsah repo
    $PS_repo = Join-Path $logFolder PS_repo # do adresare Log ukladam protoze jeho obsah se ignoruje pri synchronizaci skrze PS_env_set_up tzn nezapocita se do velikosti tzn nedojde k replace daty z DFS repo

    if (Test-Path $PS_repo -ea SilentlyContinue) {
        # existuje lokalni kopie repo
        # provedu stazeni novych dat (a replace starych)
        Set-Location $PS_repo
        try {
            # nemohu pouzit klasicky git pull, protoze chci prepsat pripadne lokalni zmeny bez reseni nejakych konfliktu atd
            # abych zachytil pripadne chyby pouzivam _startProcess
            _startProcess git -argumentList "fetch --all" # downloads the latest from remote without trying to merge or rebase anything.

            # ukoncim pokud nedoslo k zadne zmene
            # ! pripadne manualni upravy v DFS repo se tim padem prepisi az po zmene v cloud repo, ne driv !
            $status = _startProcess git -argumentList "status"
            if ($status -match "Your branch is up to date with") {
                exit
            }

            _startProcess git -argumentList "reset --hard origin/master" # resets the master branch to what you just fetched. The --hard option changes all the files in your working tree to match the files in origin/master
            _startProcess git -argumentList "clean -fd" # odstraneni untracked souboru a adresaru (vygenerovane moduly z scripts2module atp)
        } catch {
            Set-Location ..
            Remove-Item $PS_repo -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
            _emailAndExit -body "Ahoj,`nnepovedlo se stahnout aktualni data z repo. Smazal jsem lokalni kopii a pri pristim behu udelam git clone.`nChyba byla:`n$_."
        }
    } else {
        # NEexistuje lokalni kopie repo
        # vytvorim jej naklonovani cloud repozitare
        #TODONAHRADIT do login.xml vyexportujte GIT credentials (alternate credentials), pripadne access token a (detaily viz https://docs.microsoft.com/cs-cz/azure/devops/repos/git/auth-overview?view=azure-devops) uctu, pod kterym budete stahovat obsah GIT repo (repo_puller). Navod viz slajdy
        $acc = Import-Clixml "$PSScriptRoot\login.xml"
        $l = $acc.UserName
        $p = $acc.GetNetworkCredential().Password
        try {
            # abych zachytil pripadne chyby pouzivam _startProcess
            _startProcess git -argumentList "clone `"https://$l`:$p@TODONAHRADIT`" `"$PS_repo`"" # misto TODONAHRADIT dejteURL vaseho repo (neco jako: dev.azure.com/ztrhgf/WUG_show/_git/WUG_show). Vysledne URL pak bude vypadat cca takto https://altLogin:altHeslo@dev.azure.com/ztrhgf/WUG_show/_git/WUG_show)
        } catch {
            Remove-Item $PS_repo -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
            _emailAndExit -body "Ahoj,`nnepovedlo se naklonovat git repo. Nezmenilo se heslo u servisniho uctu? Pripadne nagenerujte nove credentials do login.xml."
        }
    }


    #
    # zmeny nakopiruji do DFS repo
    try {
        Update-Repo -source $PS_repo -destination $destination -force
    } catch {
        _emailAndExit "Pri rozkopirovani zmen do DFS repo se vyskytla chyba:`n$_" #`n`nVyres a rozkopiruj sam prikazem:`nUpdate-Repo -source $unc -destination $destination -force!
    }
} catch {
    _emailAndExit -body "Ahoj,`npri synchronizaci GIT repo >> DFS repo se obevila chyba:`n$_"
}