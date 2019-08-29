<#

ZDE DEFINUJETE, JAKE SERVERY MAJI MIT LOKALNE JAKE SLOZKY Z CUSTOM SEKCE REPOZITARE (a s jakymi NTFS pravy)
!!! TO ZNAMENA, ZE PO UPRAVE, SE DATA SMAZOU ZE SERVERU, KDE (dle tohoto skriptu) JIZ BYT NEMAJI !!!
! tento skript se dot sourcuje v PS_env_set_up.ps1 a nesmi proto obsahovat nic krome promenne config.ps1!

$config je pole objektu, kde kazdy objekt reprezentuje jednu slozku v Custom adresari

objekt pak obsahuje nasledujici klice:
    - (povinny) klic folderName = jmeno slozky (ktera se nachazi v Custom adresari)
        pozn.: pokud dojde ke smazani slozky, smazte i odpovidajici objekt v Custom jinak sync skript bude koncit chybou!
    - (povinny) klic computerName = na jake servery se ma slozka synchronizovat (je mozne pouzit i promennou (dokonce z Variables modulu) obsahujici seznam stroju)
   - (nepovinny) klic customNTFS = pouze zadany ucet muze cist obsah teto slozky (jinak clenove Authenticated Users). SYSTEM a clenove skupin repo_reader, repo_writer a Administrators mohou cist obsah vzdy! Pouze tomuto uctu se zaroven na (automaticky vytvarenem) Log pod adresari nastavi MODIFY prava (jinak opet clenum Authenticated Users)
        pr.: kontoso\svc_o365$ (gMSA ucet) ci Local Service atp

        !!!POZOR lze zadat pouze jeden ucet!!!


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
    }
)

V kazdem adresari (folderName) se na klientovi automaticky vytvori Log adresar s modify pravy (pro customNTFS nebo Auth users), aby skripty mohly logovat sve vystupy.
Log adresar se ignoruje pri porovnavani obsahu remote repo vs lokalni kopie a pri synchronizaci zmen je zachovan.
!!! pokud spoustene skripty generuji nejake soubory, at je ukladaji do tohoto Log adresare, jinak dojde pri kazde synchronizaci s remote repo ke smazani teto slozky (porovnavam velikosti adresaru v repo a lokalu).
#>

$config = @(
    [PSCustomObject]@{
        folderName   = "Repo_Sync"
        computerName = $RepoSyncServer
        customNTFS   = "Network Service"
    }
)