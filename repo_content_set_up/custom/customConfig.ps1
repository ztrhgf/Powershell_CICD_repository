<#

ZDE DEFINUJETE, JAKE SERVERY MAJI MIT LOKALNE JAKE SLOZKY Z CUSTOM SEKCE REPOZITARE (a s jakymi NTFS pravy)
!!! TO ZNAMENA, ZE PO UPRAVE, SE DATA SMAZOU ZE SERVERU, KDE (dle tohoto skriptu) JIZ BYT NEMAJI !!!
! tento skript se dot sourcuje v PS_env_set_up.ps1 a nesmi proto obsahovat nic krome promenne config.ps1!

$config je pole objektu, kde kazdy objekt reprezentuje jednu slozku v Custom adresari

objekt pak obsahuje nasledujici klice:
    - folderName
        (povinny) klic
        jmeno slozky (ktera se nachazi v Custom adresari)
        pozn.: pokud dojde ke smazani slozky, smazte i odpovidajici objekt v Custom jinak sync skript bude koncit chybou!
    - computerName
        (nepovinny) klic
        na jake servery se ma slozka synchronizovat (je mozne pouzit i promennou (napr. z Variables modulu) obsahujici seznam stroju)
        !pouze tyto stroje budou mit read pristup k teto slozce v DFS, zadne jine!
    - customNTFS
        (nepovinny) klic
        slouzi pro omezeni prav na kopii dane slozky na cilovem stroji
        pouze zadany ucet muze cist obsah teto slozky (jinak clenove Authenticated Users). SYSTEM a clenove skupin repo_reader, repo_writer a Administrators mohou cist obsah vzdy!
        pouze tomuto uctu se zaroven na (automaticky vytvarenem) Log pod adresari nastavi MODIFY prava (jinak opet clenum Authenticated Users)
        pr.: kontoso\o365sync$ (gMSA ucet) ci Local Service ci System atp
        !!!POZOR lze zadat pouze jeden ucet!!!
    - customShareNTFS
        (nepovinny) klic 
        slouzi pro omezeni prav na dane slozce v DFS share
        pouze zadane ucty budou mit pristup k teto slozce v DFS zadne jine
        !prebiji pravo, ktere by se jinak nastavilo pro stroje viz computerName!
        pozn.: u strojovych uctu je potreba zadat s dolarem na konci (APP-15$)


PRIKLAD:

$config = @(
    [PSCustomObject]@{
        folderName   = "slozkaX"
        computerName = "server-1", $servers_app
        customNTFS   = "kontoso\scv_o365$"
    }
    ,
    [PSCustomObject]@{
        folderName   = "slozkaY"
        computerName = "server-2"
    }
    ,
    [PSCustomObject]@{
        folderName   = "slozkaZ"
        computerName = "server-2"
        customNTFS   = "Local Service"
        customShareNTFS = "$appServers"

    }
)

V kazdem adresari (folderName) se na klientovi automaticky vytvori Log adresar s modify pravy (pro customNTFS nebo Auth users), aby skripty mohly logovat sve vystupy.
Log adresar se ignoruje pri porovnavani obsahu remote repo vs lokalni kopie a pri synchronizaci zmen je zachovan.
!!! pokud spoustene skripty generuji nejake soubory, at je ukladaji do tohoto Log adresare, jinak dojde pri kazde synchronizaci s remote repo ke smazani teto slozky (porovnavam velikosti adresaru v repo a lokalu).
#>

$config = @(
    [PSCustomObject]@{
        folderName   = "Repo_sync"
        computerName = $RepoSyncServer
    }
)