<#
Zde se definuje, co se ma dit s obsahem slozky Custom.
Tzn na jake stroje, do jakeho umisteni a s jakymi pravy (vse definovano v $customConfig viz nize) se ma obsah kopirovat.
Standardne se obsah kopiruje do C:\Windows\Scripts a dochazi automaticky k mazani toho, co tam jiz byt nema.
Tento skript se dot sourcuje v PS_env_set_up.ps1 a nesmi proto obsahovat nic krome promenne customConfig!

Pozn.: DFS oznacuje sdilenou slozku, kde hostujete vas repozitar (z ktere klienti stahuji obsah k sobe na lokal)

Jak ma vypadat $customConfig a co muze obsahovat:
$customConfig je pole objektu, kde kazdy objekt reprezentuje jednu slozku v Custom adresari.
Objekt pak obsahuje nasledujici klice:

    - folderName
        (povinny) klic
        jmeno slozky (ktera se nachazi v Custom adresari)
        pozn.:
            - pokud dojde ke smazani slozky, smazte i odpovidajici objekt v Custom jinak sync skript bude koncit chybou!

    - computerName
        (nepovinny) klic
        na jake servery se ma slozka synchronizovat (je mozne pouzit i promennou (napr. z Variables modulu) obsahujici seznam stroju)
        !pouze tyto stroje budou mit read pristup k teto slozce v DFS, zadne jine!

    - customDestinationNTFS
        (nepovinny) klic
        slouzi pro omezeni prav na kopii dane slozky na cilovem stroji / kopii v cilove sitove slozce (customShareDestination)
        pouze zadany ucet bude mit READ na zadane slozce (jinak clenove Authenticated Users).
            POZOR, pri kopirovani do lokalni slozky, bude mit pravo READ take SYSTEM a clenove skupin repo_reader, repo_writer, Administrators!
            POZOR, clenove skupiny repo_writer maji vzdy full control
        pouze tomuto uctu se zaroven na (automaticky vytvarenem) Log pod adresari nastavi MODIFY prava (jinak opet clenum Authenticated Users)
        pr.: kontoso\o365sync$ (gMSA ucet) ci Local Service ci System atp

    - customSourceNTFS
        (nepovinny) klic
        slouzi pro omezeni prav na dane slozce v DFS share repozitari
        pouze zadane ucty budou mit pristup k teto slozce v DFS zadne jine
        !prebiji pravo, ktere by se jinak nastavilo pro stroje viz computerName!
        pozn.:
            - u strojovych uctu je potreba zadat s dolarem na konci (APP-15$)

    - customLocalDestination
        (nepovinny) klic
        slouzi pro zmenu cilove slozky, do ktere se ma adresar z DFS zkopirovat (misto %WINDIR%\Scripts)
        musi jit o lokalni cestu (napr.: C:\Skripty)
        pozn.:
            - pouzije se v ramci PS_env_set_up.ps1 skriptu
            - aby fungovalo, musi mit do dane cesty ucet SYSTEM pravo full control!
            - pri kopirovani se pouzije robocopy mirror, tzn jakekoli soubory, ktere nejsou ve zdrojove slozce v DFS, budou z cilove slozky odstraneny!
            - po zmene cesty nedojde k odstraneni jiz nakopirovanych dat
            - nedojde k nastaveni NTFS prav, pokud neni definovano customDestinationNTFS (mohlo by byt kontraproduktivni), to same plati pro zanoreny Log adresar

    - customShareDestination
        (nepovinny) klic
        slouzi pro zadani sitove cilove slozky, do ktere se ma adresar z DFS zkopirovat (pokud zaroven zadate computerName, nakopiruje se i do %WINDIR%\Scripts)
        musi jit o cestu v UNC tvaru (napr.: \\dfs\skripty)
        pouzije se v ramci repo_sync.ps1 skriptu
        pozn.:
            - aby fungovalo, musi mit do dane cesty clenove skupiny repo_writer pravo full control!
            - pri kopirovani se pouzije robocopy mirror, tzn jakekoli soubory, ktere nejsou ve zdrojove slozce v DFS, budou z cilove slozky odstraneny!
            - po zmene cesty nedojde k odstraneni jiz nakopirovanych dat
            - nedojde k nastaveni NTFS prav, pokud neni definovano customDestinationNTFS (share jako takovy uz ma nastavena prava, tak by mohlo byt kontraproduktivni), to same plati pro zanoreny Log adresar

    - copyJustContent
        (nepovinny) klic
        slouzi pro urceni, ze se do cile nema kopirovat cela slozka, ale pouze jeji obsah
        typicky pro kopirovani configu, ini atp, takze do cile chci co nejmene zasahovat
        pozn.:
            - nedojde k nastaveni NTFS prav (ani customDestinationNTFS)!
            - nevytvori se Log podadresar
            - jiz nepotrebne soubory nebudou smazany (nepouzije se robocopy mirror)
            - aplikuje se pouze pri nastaveni customLocalDestination ci customShareDestination

    - scheduledTask
        (nepovinny) klic
        slouzi pro zadani nazvu XML souboru (bez koncovky) s definici scheduled tasku, ktery se ma na stroji vytvorit
        pozn.:
            - XML musi byt ulozeno v rootu Custom slozky
                - XML s definici tasku ziskate klasicky exportem tasku v Task Scheduler konzoli
            - vytvoreny task se bude jmenovat dle nazvu XML, at uz je v obsahu XML definovano cokoli
            - task se vzdy vytvori v rootu Task Scheduler konzole
            - jako autor se nastavi nazev sync skriptu (PS_env_set_up), kvuli dohledatelnosti a nasledne sprave
            - pri zmene v definici, dojde k modifikaci tasku
            - tasky, ktere jiz na klientovi byt nemaji, budou smazany

PRIKLADY:

$customConfig = @(
    # vykopirovani "SomeTools" na APP-1 a stroje v $servers_app do C:\Windows\Scripts\SomeTools s tim, ze pouze o365sync$ ucet bude mit READ prava
    [PSCustomObject]@{
        folderName   = "SomeTools"
        computerName = "APP-1", $servers_app
        customDestinationNTFS   = "contoso\o365sync$"
    },
    # nakopirovani slozky "Monitoring_Scripts" s monitorovacimi skripty na server $monitoringServer do C:\Windows\Scripts\Monitoring_Scripts
    # a vytvoreni scheduled tasku z XML definice ulozene v monitor_AD_Admins.xml, monitor_backup.xml (ktere budou tyto skripty volat)
    [PSCustomObject]@{
        folderName   = "Monitoring_Scripts" # obsahuje skripty + xml definice scheduled tasku
        scheduledTask = "monitor_AD_Admins", "monitor_backup"
        computerName = $monitoringServer
    },
    # ukazka, ze computerName se muze dynamicky plnit dle obsahu OU Notebooks
    [PSCustomObject]@{
        folderName   = "slozkaY"
        computerName = (New-Object System.DirectoryServices.DirectorySearcher((New-Object System.DirectoryServices.DirectoryEntry("LDAP://OU=Notebooks,OU=Computer_Accounts,DC=contoso,DC=com")) , "objectCategory=computer")).FindAll() | ForEach-Object { $_.Properties.name }
    },
    # nakopirovani web.config z IISConfig do "C:\inetpub\wwwroot\" na webovem serveru
    [PSCustomObject]@{
        folderName   = "IISConfig" # obsahuje web.config
        computerName = $webServer
        customLocalDestination = "C:\inetpub\wwwroot\"
        copyJustContent   = 1
    },
    # nakopirovani slozky "Secrets" do sdilene slozky "\\DFS\root\skripty", pricemz pouze "APP-1$", "APP-2$", "domain admins" budou mit moznost cist jeji obsah
    [PSCustomObject]@{
        folderName   = "Secrets"
        customShareDestination = "\\DFS\root\skripty"
        customDestinationNTFS   = "APP-1$", "APP-2$", "domain admins"
    },
    # nakopirovani "Admin_Secrets" do DFS repozitare\Custom (ale na klienty uz ne) pricemz pouze "Domain Admins" budou mit READ prava na teto slozce
    [PSCustomObject]@{
        folderName   = "Admin_Secrets"
        customSourceNTFS = "Domain Admins"
    }
)

V kazdem nakopirovanem adresari (folderName) se automaticky vytvori Log adresar s modify pravy (pro customDestinationNTFS nebo Auth users), aby skripty mohly logovat sve vystupy (neplati pokud se ma kopirovat pouze obsah slozky (copyJustContent)).
Log adresar se ignoruje pri porovnavani obsahu remote repo vs lokalni kopie a pri synchronizaci zmen je zachovan.
!!! pokud spoustene skripty generuji nejake soubory, at je ukladaji do tohoto Log adresare, jinak dojde pri kazde synchronizaci s remote repo k jejich smazani (protoze robocopy mirror).
#>

$customConfig = @(
    [PSCustomObject]@{
        folderName   = "Repo_sync"
        computerName = $RepoSyncServer
    }
)