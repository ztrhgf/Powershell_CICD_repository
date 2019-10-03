<#
    .SYNOPSIS
    skript pro zpracovani a distribuci obsahu GIT repo z cloudoveho GIT repo do DFS lokace
    funnguje tak, ze:
    - lokalne klonuje obsah cloud GIT repo
    - obsah zpracuje (vygeneruje moduly z scripts2module, rozkopiruje Custom obsah, ktery ma jit do sdilenych slozek,..)
    - nakopiruje do cilove sdilene slozky (DFS) ze ktere si obsah stahuji klienti

    BACHA aby fungovalo, je potreba mit na repo_puller uctu nastaveno alternate credentials v GIT web rozhrani a ty mit vyexportovane do login.xml pod uctem, pod kterym pobezi tento skript

    .NOTES
    Author: Ondřej Šebela - ztrhgf@seznam.cz
#>

# pro lepsi debugging
Start-Transcript -Path "$env:SystemRoot\temp\repo_sync.log" -Force

$ErrorActionPreference = "stop"

$logFolder = Join-Path $PSScriptRoot "Log"

# nekdy se stavalo, ze pod SYSTEM uctem nefungoval autoload funkci z modulu
Import-Module Scripts -Function Send-Email -ErrorAction SilentlyContinue

# aby nespamovalo v pripade chyby, umoznuji poslat max 1 mail za 30 minut
$lastSendEmail = Join-Path $logFolder "lastSendEmail"
$treshold = 30

$destination = "TODONAHRADIT" # sitova cesta k DFS repozitari (napr.: \\mojedomena\dfs\repository)


# skupina ktera ma pravo cist obsah DFS repozitare (i lokalni kopie)
[string] $readUser = "repo_reader"
# skupina ktera ma pravo editovat obsah DFS repozitare (i lokalni kopie)
[string] $writeUser = "repo_writer"


#
# pomocne funkce
function _updateRepo {
    <#
    .SYNOPSIS
        Funkce pro nakopirovani lokalnich !commitnutych! zmen z GIT repozitare do naseho remote DFS repozitare.
        Standardne resi vykopirovani pouze zmen z posledniho commitu. Pokud chcete full synchronizaci, pouzijte -Force.
        Preskoci soubory, ktere jsou rozpracovane (modifikovane, ale necomitnute ci untracked).

    .DESCRIPTION
        Funkce pro nakopirovani lokalnich !commitnutych! zmen z GIT repozitare do naseho remote DFS repozitare.
        Standardne resi vykopirovani pouze zmen z posledniho commitu. Pokud chcete full synchronizaci, pouzijte -Force.
        Preskoci soubory, ktere jsou rozpracovane (modifikovane, ale necomitnute ci untracked).

        - Ze skriptu ve slozkach ulozenych v scripts2module se generuji PS moduly do \Modules\.
            Tzn samotne skripty z scripts2module se do DFS repo nekopiruji
        - Obsah Modules se kopiruje do Modules v DFS repozitari.
        - Obsah scripts2root se kopiruje do rootu DFS repozitare.
        - Obsah Custom se kopiruje do Custom v DFS repo (a odtud potom na zadane servery dle zadani v customConfig.ps1)

        Vychozi chovani je takove, ze se kopiruji i nezmenene veci (abych prepsal pripadne zmeny, ktere nekdo provedl primo v DFS)

    .PARAMETER source
        Cesta k lokalne ulozenemu GIT repozitari.

    .PARAMETER destination
        Cesta do centralniho (DFS) repozitare.

    .PARAMETER force
        Vykopiruje vsechny soubory, at uz doslo k jejich modifikaci ci nikoli.
        Stale se vsak preskoci soubory, ktere jsou rozpracovane (modifikovane, ale necomitnute ci untracked)!

    .EXAMPLE
        _updateRepo -source C:\DATA\repo\Powershell\ -destination \\somedomain\repository
    #>

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $True)]
        [ValidateNotNullOrEmpty()]
        [ValidateScript( {
                If (Test-Path $_) {
                    $true
                } else {
                    Throw "Zadejte cestu k lokalni kopii repozitare"
                }
            })]
        [string] $source
        ,
        [ValidateNotNullOrEmpty()]
        [string] $destination
        ,
        [switch] $force
    )

    # Test-Path hrozne dlouho timeoutuje, pro zrychleni kontroluji jestli je toto pc vubec v domene (takovy nazev se da cekat bude obsahovat tecku)
    $inDomain = (Get-WmiObject Win32_ComputerSystem).Domain -match "\."
    # cesta, kam se lokalne generuji psm moduly (odtud se pote kopiruji do centralniho repozitare)
    $modules = Join-Path $source "modules"
    # kam se maji moduly v ramci centralniho repozitare nakopirovat
    $destModule = Join-Path $destination "modules"
    # cesta obsahuje slozky se skripty, ze kterych se generuji moduly
    $scripts2module = Join-Path $source "scripts2module"
    # cesta ke slozce jejiz obsah se kopiruje do korene DFS repozitare
    $scripts2root = Join-Path $source "scripts2root"

    $somethingChanged = 0
    $moduleChanged = 0

    if (!$inDomain -or !(Test-Path $destination -ErrorAction SilentlyContinue)) {
        throw "Cesta $destination neni dostupna"
    }

    # import promennych
    # kvuli omezeni NTFS prav na slozkach v Custom a souboru profile.ps1
    try {
        # nejdriv zkusim naimportovat nejaktualnejsi verzi Variables modulu primo z lokalni kopie repozitare
        Import-Module (Join-Path $modules "Variables") -ErrorAction Stop
    } catch {
        # pokud se nepodari, zkusim import ze systemoveho umisteni PS modulu
        # chyby ignorujeme, protoze na fresh stroji, modul bude az po prvnim spusteni PS_env_set_up potazmo tohoto skriptu, ne driv :)
        Import-Module Variables -ErrorAction "Continue"
    }



    #
    # zjistim rozdelane a smazane soubory
    #

    # bude obsahovat soubory, ktere nelze kvuli jejich stavu rozkopirovat
    $unfinishedFile = @()
    # ziskam potrebna data prikazem git
    $location = Get-Location
    Set-Location $source
    try {
        # stav lokalniho repozitare vuci remote repozitari
        $repoStatus = git status -uno
        # seznam nepushnutych commitu
        $unpushedCommit = git log origin/master..HEAD
        # soubory v poslednim commitu
        $commitedFile = @(git show HEAD --pretty="" --name-only)
        # deleted soubory v poslednim commitu
        $commitedDeletedFile = @(git show HEAD --pretty="" --name-status | ? { $_ -match "^D\s+" } | % { $_ -replace "^D\s+" })
        # deleted, ale ne v staging area soubory
        $uncommitedDeletedFile = @(git ls-files -d)
        # modifikovane, ale ne v staging area soubory (vypisuje i smazane)
        $unfinishedFile += @(git ls-files -m)
        # untracked soubory (dosud nikdy commitnute)
        $unfinishedFile += @(git ls-files --others --exclude-standard)
    } catch {
        $err = $_
        if ($err -match "is not recognized as the name of a cmdlet") {
            Set-Location $location
            throw "Nepodarilo se vykonat git prikaz. Zrejme GIT neni nainstalovan. Chyba byla:`n$err"
        } else {
            Set-Location $location
            throw "$err"
        }
    }
    Set-Location $location

    #
    # kontrola, ze repo obsahuje aktualni data
    # tzn nejsem pozadu za remote repozitarem
    if ($repoStatus -match "Your branch is behind") {
        throw "Repozitar neobsahuje aktualni data. Stahnete je prikazem 'git pull' (Sync ve VSC editoru) a spustte znovu"
    }

    # ulozim jestli pouzil force prepinac
    $isForced = ($PSBoundParameters.GetEnumerator() | ? { $_.key -eq "force" }).value.isPresent

    if (!$unpushedCommit -and $isForced -ne "True") {
        Write-Warning "`nV repozitari neni zadny nepushnuty commit. Funkce rozkopiruje pouze zmeny z posledniho commitu.`nPokud chcete rozkopirovat vse, pouzijte -force`n`n"
    }

    # git prikazy vraci s unix lomitky, zmenim na zpetna
    $unfinishedFile = $unfinishedFile -replace "/", "\"
    $commitedFile = $commitedFile -replace "/", "\"
    $commitedDeletedFile = $commitedDeletedFile -replace "/", "\"
    $uncommitedDeletedFile = $uncommitedDeletedFile -replace "/", "\"

    # ulozim s absolutnimi cestami
    $unfinishedFileAbsPath = $unfinishedFile | % { Join-Path $source $_ }

    #
    # vytvorim si string ve tvaru, ktery vyzaduje /XF parametr robocopy
    # pujde o seznam souboru, ktere chci ignorovat pri kopirovani skrze robocopy (necomitnute zmenene a untracked soubory)
    # cesty musi byt absolutni a odkazovat na soubory v source adresari
    $excludeFile = ""
    if ($unfinishedFileAbsPath) {
        $unfinishedFileAbsPath | % {
            $excludeFile += " " + "`"$_`""
        }
    }
    # ignorovat musim take smazane, ale necomitnute soubory
    # ty naopak musi mit cestu odpovidajici cilovemu (destination) souboru, aby nedoslo k jeho smazani
    $folderWithUncommitedDeletedFile = @()

    if ($uncommitedDeletedFile) {
        $uncommitedDeletedFile | % {
            $file = $_
            $destAbsPath = ""
            if ($file -match "scripts2root\\") {
                # obsah scripts2root jde primo do rootu DFS
                $file = Split-Path $file -Leaf
                $destAbsPath = Join-Path $destination $file
            } elseif ($file -match "scripts2module\\") {
                # skripty ze kterych se generuji moduly, se do DFS nekopiruji, tzn ignoruji
            } else {
                # cesta v GIT repo odpovida ceste v DFS
                $destAbsPath = Join-Path $destination $_
            }

            if ($destAbsPath) {
                $excludeFile += " " + "`"$destAbsPath`""
                $folderWithUncommitedDeletedFile += Split-Path $destAbsPath -Parent
            }
        }
    }

    # a ignorovat musim i adresare, v nichz se neco smazalo (pokud se totiz smaznul komplet cely adresar, tak nestaci mit exclude na jednotlive smazane soubory, protoze by se i tak smazal v cili!)
    # $excludeFolder teda pouziju u /XD parametru robocopy
    $folderWithUncommitedDeletedFile = $folderWithUncommitedDeletedFile | Select-Object -Unique
    $excludeFolder = ""
    if ($folderWithUncommitedDeletedFile) {
        $folderWithUncommitedDeletedFile | % {
            $excludeFolder += " " + "`"$_`""
        }
    }

    # prevedu na arraylist, abych mohl snadno pridavat/odebirat prvky
    [System.Collections.ArrayList] $commitedFile = @($commitedFile)
    [System.Collections.ArrayList] $unfinishedFile = @($unfinishedFile)




    #
    # ze seznamu commitnutych souboru odeberu ty, ktere po pridani do staging area uzivatel opet upravil
    #

    # uzivatel totiz mohl pridat soubor do staging area, pak soubor zmodifikovat a pak commitnout obsah staging area
    # kontrolu delam jen proto, abych neexportoval zbytecne modul, do nejz stejne modifikovane skripty nepridam
    # ! ma smysl kontrolovat pouze pokud commit dosud nebyl pushnut, jinak
    if ($commitedFile) {
        Write-Verbose "Posledni commit obsahuje tyto soubory:`n$($commitedFile -join ', ')"
        $commitedFile2 = $commitedFile.Clone()
        $commitedFile2 | % {
            $file = $_
            $commitedFileMatch = [regex]::Escape($file) + "$"
            if ($unfinishedFile -match $commitedFileMatch -or $uncommitedDeletedFile -match $commitedFileMatch) {
                Write-Warning "Soubor $file je v commitu, ale po jeho pridani do staging area doslo k dalsi modifikaci. Nerozkopiruji jej"
                $commitedFile.remove($file)
            }
        }
    }

    if ($unfinishedFile) {
        Write-Warning "Preskakuji tyto zmenene, ale necomitnute soubory:`n$($unfinishedFileAbsPath -join "`n")"
    }
    if ($uncommitedDeletedFile) {
        Write-Verbose "Preskakuji tyto smazane, ale necomitnute soubory:`n$($uncommitedDeletedFile -join "`n")"
    }





    #
    # ze skriptu ve slozkach ulozenych v scripts2module vygeneruji psm moduly
    # a az ten nakopiruji do remote repozitare + ostatni zmenene moduly
    #

    # do $configHash si znacim, jake moduly se maji (a z ceho generovat) kvuli zavolani funkce _exportScriptsToModule
    $configHash = @{ }

    if ($force) {
        # pregeneruji vsechny moduly at uz v nich doslo ke zmene ci nikoli
        Get-ChildItem $scripts2module -Directory | Select-Object -ExpandProperty FullName | % {
            $moduleName = Split-Path $_ -Leaf
            $absPath = $_
            # prvni pismeno nazvu modulu udelam upper case
            $TextInfo = (Get-Culture).TextInfo
            $moduleName = $TextInfo.ToTitleCase($moduleName)
            $configHash[$absPath] = Join-Path $modules $moduleName
        }

        ++$moduleChanged
    } else {
        # modul vygeneruji pouze pokud commit obsahuje nejaky ze souboru, ze kterych jej generuji == je potreba update modulu
        $commitedFile | ? { $_ -match "^scripts2module\\" } | % { ($_ -split "\\")[-2] } | Select-Object -Unique | % {
            $moduleName = $_
            $absPath = Join-Path $scripts2module $moduleName
            # prvni pismeno nazvu modulu udelam upper case
            $TextInfo = (Get-Culture).TextInfo
            $moduleName = $TextInfo.ToTitleCase($moduleName)
            $configHash[$absPath] = Join-Path $modules $moduleName
        }

        if ($commitedFile -match "^modules\\") {
            # doslo ke zmene v nejakem modulu, poznacim, ze se ma rozkopirovat
            Write-Output "Doslo ke zmene v nejakem modulu, rozkopiruji"
            ++$moduleChanged
        }
    }

    #
    # ze skriptu vygeneruji odpovidajici moduly
    if ($configHash.Keys.count) {
        ++$somethingChanged

        _exportScriptsToModule -configHash $configHash -dontIncludeRequires
    }


    #
    # ZESYNCHRONIZUJI OBSAH Modules GIT >> DFS
    #
    if ($moduleChanged -or $configHash.Keys.count) {
        [Void][System.IO.Directory]::CreateDirectory("$destModule")
        if (!(Test-Path $destModule -ErrorAction SilentlyContinue)) {
            throw "Cesta $destModule neni dostupna"
        }

        ++$somethingChanged

        Write-Output "Kopiruji moduly: $(((Get-ChildItem $modules).name) -join ', ') do $destModule`n"

        # z exclude docasne vyradim soubory z automaticky nagenerovanych modulu (z ps1 v scripts2module)
        # v exclude se mohou objevit proto, ze nebudou uvedeny v .gitignore >> jsou untracked
        if ($configHash.Keys.count) {
            $reg = ""

            $configHash.Values | % {
                Write-Verbose "Obsah $_ nepreskocim, jde o automaticky vyexportovany modul"
                $esc = [regex]::Escape($_)
                if ($reg) {
                    $reg += "|$esc"
                } else {
                    $reg += "$esc"
                }
            }

            $excludeFile2 = $excludeFile | ? { $_ -notmatch $reg }

            if ($excludeFile.count -ne $excludeFile2.count) {
                Write-Warning "Pri kopirovani modulu preskocim pouze: $($excludeFile2 -join ', ')"
            }
        } else {
            $excludeFile2 = $excludeFile
        }

        # zamerne kopiruji i nezmenene moduly, kdyby nekdo udelal zmenu primo v remote repo, abych ji prepsal
        # result bude obsahovat smazane soubory a pripadne chyby
        # pres Invoke-Expression musim delat, aby se spravne aplikoval obsah excludeFile
        # /S tzn nekopiruji prazdne adresare
        $result = Invoke-Expression "Robocopy.exe `"$modules`" `"$destModule`" /MIR /S /NFL /NDL /NJH /NJS /R:4 /W:5 /XF $excludeFile2 /XD $excludeFolder"

        # vypisi smazane soubory
        $deleted = $result | ? { $_ -match [regex]::Escape("*EXTRA File") } | % { ($_ -split "\s+")[-1] }
        if ($deleted) {
            Write-Output "Smazal jsem jiz nepotrebne soubory:`n$($deleted -join "`n")"
        }

        # result by mel obsahovat pouze chybove vypisy
        # *EXTRA File\Dir jsou vypisy smazanych souboru\adresaru (/MIR)
        $result = $result | ? { $_ -notmatch [regex]::Escape("*EXTRA ") }
        if ($result) {
            Write-Error "Pri kopirovani modulu $($_.name) se vyskytl nasledujici problem:`n`n$result`n`nPokud slo o chybu, opetovne spustte rozkopirovani prikazem:`n$($MyInvocation.Line) -force"
        }
    }

    #
    # smazu z remote repo modules prazdne adresare (neobsahuji soubory)
    Get-ChildItem $destModule -Directory | % {
        $item = $_.FullName
        if (!(Get-ChildItem $item -Recurse -File)) {
            try {
                Write-Verbose "Mazu prazdny adresar $item"
                Remove-Item $item -Force -Recurse -Confirm:$false
            } catch {
                Write-Error "Pri mazani $item doslo k chybe:`n`n$_`n`nOpetovne spustte rozkopirovani prikazem:`n$($MyInvocation.Line) -force"
            }
        }
    }



    #
    # NAKOPIRUJI OBSAH scripts2root DO KORENE DFS REPO
    #

    if ($commitedFile -match "^scripts2root" -or $force) {
        # doslo ke zmene v adresari scripts2root, vykopiruji do remote repozitare
        Write-Output "Kopiruji root skripty z $scripts2root do $destination`n"

        # if ($force) {
        # zkopiruji vsechny, ktere nejsou modifikovane
        # zamerne kopiruji i nezmenene, kdyby nekdo udelal zmenu primo v remote repo, abych ji prepsal
        $script2Copy = (Get-ChildItem $scripts2root -File).FullName | ? {
            if ($unfinishedFileAbsPath -match [regex]::Escape($_)) {
                return $false
            } else {
                return $true
            }
        }
        # } else {
        #     # z $commitedFile uz jsou odfiltrovane modifikovane soubory, netreba dal kontrolovat
        #     $script2Copy = $commitedFile -match "scripts2root"
        #     # git vraci relativni cestu, udelam absolutni
        #     $script2Copy = $script2Copy | % {
        #         Join-Path $source $_
        #     }
        # }

        if ($script2Copy) {
            ++$somethingChanged

            $script2Copy | % {
                $item = $_
                Write-Output (" - " + ([System.IO.Path]::GetFileName("$item")))

                try {
                    Copy-Item $item $destination -Force -ErrorAction Stop

                    # u profile.ps1 omezim pristup (skrze NTFS prava) pouze na stroje, na nez se ma kopirovat
                    if ($item -match "\\profile\.ps1$") {
                        $destProfile = (Join-Path $destination "profile.ps1")
                        if ($computerWithProfile) {
                            # computer AD ucty maji $ za svym jmenem, pridam
                            [string[]] $readUserP = $computerWithProfile | % { $_ + "$" }

                            "omezuji NTFS prava na $destProfile (pristup pouze pro: $($readUserP -join ', '))"
                            _setPermissions $destProfile -readUser $readUserP -writeUser $writeUser
                        } else {
                            "nastavuji vychozi prava na $destProfile"
                            _setPermissions $destProfile -resetACL
                        }
                    }
                } catch {
                    Write-Error "Pri kopirovani root skriptu $item doslo k chybe:`n`n$_`n`nOpetovne spustte rozkopirovani prikazem:`n$($MyInvocation.Line) -force"
                }
            }
        }

        #
        # SMAZU Z KORENE DFS REPO SOUBORY, KTERE TAM JIZ NEMAJI BYT
        # vytahnu soubory s koncovkou (v rootu mam i soubor bez koncovky s upozornenim at se delaji zmeny v GIT a ne v DFS, ktery by ale v samotnem GIT repo mohl mast)
        $DFSrootFile = Get-ChildItem $destination -File | ? { $_.extension }
        $GITrootFileName = Get-ChildItem $scripts2root -File | Select-Object -ExpandProperty Name
        $uncommitedDeletedRootFileName = $uncommitedDeletedFile | ? { $_ -match "scripts2root\\" } | % { ([System.IO.Path]::GetFileName($_)) }
        $DFSrootFile | % {
            if ($GITrootFileName -notcontains $_.Name -and $uncommitedDeletedRootFileName -notcontains $_.Name) {
                # soubor jiz regulerne neni v GIT repo == smazu jej
                try {
                    Write-Verbose "Mazu $($_.FullName)"
                    Remove-Item $_.FullName -Force -Confirm:$false -ErrorAction Stop
                } catch {
                    Write-Error "Pri mazani $item doslo k chybe:`n`n$_`n`nOpetovne spustte rozkopirovani prikazem:`n$($MyInvocation.Line) -force"
                }
            }
        }
    } # konec sekce scripts2root




    #
    # ZESYNCHRONIZUJI OBSAH Custom GIT >> DFS
    #

    if ($commitedFile -match "^custom\\.+" -or $force) {
        # doslo ke zmene v adresari custom\
        $customSource = Join-Path $source "custom"
        $customDestination = Join-Path $destination "custom"

        if (!(Test-Path $customSource -ErrorAction SilentlyContinue)) {
            throw "Cesta $customSource neni dostupna"
        }

        Write-Output "Kopiruji Custom data z $customSource do $customDestination`n"
        # pres Invoke-Expression musim delat, aby se spravne aplikoval obsah excludeFile
        # /S tzn nekopiruji prazdne adresare

        $result = Invoke-Expression "Robocopy.exe $customSource $customDestination /S /MIR /NFL /NDL /NJH /NJS /R:4 /W:5 /XF $excludeFile /XD $excludeFolder"

        # vypisi smazane soubory
        $deleted = $result | ? { $_ -match [regex]::Escape("*EXTRA File") } | % { ($_ -split "\s+")[-1] }
        if ($deleted) {
            Write-Verbose "Smazal jsem jiz nepotrebne soubory:`n$($deleted -join "`n")"
        }

        # result by mel obsahovat pouze chybove vypisy
        # *EXTRA File\Dir jsou vypisy smazanych souboru\adresaru (/MIR)
        $result = $result | ? { $_ -notmatch [regex]::Escape("*EXTRA ") }
        if ($result) {
            Write-Error "Pri kopirovani Custom sekce se vyskytl nasledujici problem:`n`n$result`n`nPokud slo o chybu, opetovne spustte rozkopirovani prikazem:`n$($MyInvocation.Line) -force"
        }


        # omezeni NTFS prav
        # aby mely pristup pouze stroje, ktere maji dany obsah stahnout dle $customConfig atributu computerName
        # slozky, ktere nemaji definovan computerName budou mit vychozi nastaveni
        # pozn. nastavuji pokazde, protoze pokud by v customConfig byly nejake cilove stroje definovany clenstvim v AD skupine ci OU, tak nemam sanci to jinak poznat

        foreach ($folder in (Get-ChildItem $customDestination -Directory)) {
            $folder = $folder.FullName
            $folderName = Split-Path $folder -Leaf

            # pozn.: $customConfig jsem dostal dot sourcingem customConfig.ps1 skriptu
            $configData = $customConfig | ? { $_.folderName -eq $folderName }
            if ($configData -and ($configData.computerName -or $configData.customSourceNTFS)) {
                # pro danou slozku je definovano, kam se ma kopirovat
                # omezim nalezite pristup

                # custom share NTFS prava maji prednost pred omezenim prav na stroje, kam se ma kopirovat
                # tzn pokud je definovano oboje, nastavim co je v customSourceNTFS atributu
                if ($configData.customSourceNTFS) {
                    [string[]] $readUserC = $configData.customSourceNTFS
                } else {
                    [string[]] $readUserC = $configData.computerName
                    # computer AD ucty maji $ za svym jmenem, pridam
                    $readUserC = $readUserC | % { $_ + "$" }
                }

                "omezuji NTFS prava na $folder (pristup pouze pro: $($readUserC -join ', '))"
                _setPermissions $folder -readUser $readUserC -writeUser $writeUser
            } else {
                # pro danou slozku neni definovano, kam se ma kopirovat
                # zresetuji prava na vychozi
                "nastavuji vychozi prava na $folder"
                _setPermissions $folder -resetACL
            }
        }


        ++$somethingChanged
    } # konec sekce Custom




    #
    # upozorneni pokud se nedetekovala zadna zmena (nemelo by nastat)
    #

    # tyto zmeny se do DFS nerozkopirovavaji, tak aby se nevypisovala chyba, ze nedoslo ke zmene, pokud clovek nic jineho neupravuje v commitu
    if ($commitedFile -match "\.githooks\\|\.vscode\\|\.gitignore|!!!README!!!|powershell\.json") {
        ++$somethingChanged
    }

    if (!$somethingChanged) {
        Write-Error "`nV $source nedoslo k zadne zmene == neni co rozkopirovat!`nPokud chcete vynutit rozkopirovani aktualniho obsahu, pouzijte:`n$($MyInvocation.Line) -force`n"
    }
}

function _exportScriptsToModule {
    <#
    .SYNOPSIS
        Funkce pro vytvoreni PS modulu z PS funkci ulozenych v ps1 souborech v zadanem adresari.
        Krome funkci exportuje take jejich aliasy at uz zadane skrze Set-Alias ci [Alias("Some-Alias")]
        !!! Aby se v generovanych modulech korektne exportovaly funkce je potreba,
        mit funkce ulozene v ps1 souboru se shodnym nazvem (Invoke-Command2 funkci v Invoke-Command2.ps1 souboru)

        !!! POZOR v PS konzoli musi byt vybran font, ktery nekazi UTF8 znaky, jinak zpusobuje problemy!!!

    .PARAMETER configHash
        Hash obsahujici dvojice, kde klicem je cesta k adresari se skripty a hodnotou cesta k adresari, do ktereho se vygeneruje modul.
        napr.: @{"C:\temp\scripts" = "C:\temp\Modules\Scripts"}

    .PARAMETER enc
        Jake kodovani se ma pouzit pro vytvareni modulu a cteni skriptu

        Vychozi je UTF8.

    .PARAMETER includeUncommitedUntracked
        Vyexportuje i necomitnute a untracked funkce z repozitare

    .PARAMETER dontCheckSyntax
        Prepinac rikajici, ze se u vytvoreneho modulu nema kontrolovat syntax.
        Kontrola muze byt velmi pomala, pripadne mohla byt uz provedena v ramci kontroly samotnych skriptu

    .PARAMETER dontIncludeRequires
        Prepinac rikajici, ze se do modulu nepridaji pripadne #requires modulu skriptu.

    .EXAMPLE
        _exportScriptsToModule @{"C:\DATA\POWERSHELL\repo\scripts" = "c:\DATA\POWERSHELL\repo\modules\Scripts"}
    #>

    [CmdletBinding()]
    param (
        [ValidateNotNullOrEmpty()]
        $configHash
        ,
        $enc = 'utf8'
        ,
        [switch] $includeUncommitedUntracked
        ,
        [switch] $dontCheckSyntax
        ,
        [switch] $dontIncludeRequires
    )

    if (!(Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue) -and !$dontCheckSyntax) {
        Write-Warning "Syntaxe se nezkontroluje, protoze neni dostupna funkce Invoke-ScriptAnalyzer (soucast modulu PSScriptAnalyzer)"
    }
    function _generatePSModule {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            $scriptFolder
            ,
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            $moduleFolder
            ,
            [switch] $includeUncommitedUntracked
        )

        if (!(Test-Path $scriptFolder)) {
            throw "Cesta $scriptFolder neexistuje"
        }

        $modulePath = Join-Path $moduleFolder ((Split-Path $moduleFolder -Leaf) + ".psm1")
        $function2Export = @()
        $alias2Export = @()
        $lastCommitFileContent = @{ }
        # necomitnute zmenene skripty a untracked do modulu nepridam, protoze nejsou hotove
        $location = Get-Location
        Set-Location $scriptFolder
        $unfinishedFile = @()
        try {
            # necomitnute zmenene soubory
            $unfinishedFile += @(git ls-files -m --full-name)
            # untracked
            $unfinishedFile += @(git ls-files --others --exclude-standard --full-name)
        } catch {
            throw "Zrejme neni nainstalovan GIT, nepodarilo se ziskat seznam zmenenych souboru v repozitari $scriptFolder"
        }
        Set-Location $location

        #
        # existuji modifikovane necomitnute/untracked soubory
        # abych je jen tak nepreskocil pri generovani modulu, zkusim dohledat verzi z posledniho commitu a tu pouzit
        if ($unfinishedFile) {
            [System.Collections.ArrayList] $unfinishedFile = @($unfinishedFile)

            # _startProcess umi vypsat vystup (vcetne chyb) primo do konzole, takze se da pres Select-String poznat, jestli byla chyba
            function _startProcess {
                [CmdletBinding()]
                param (
                    [string] $filePath = 'notepad.exe',
                    [string] $argumentList = '/c dir',
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
                # $p.WaitForExit() # s timto pokud git show HEAD:$file neco vratilo, se proces nikdy neukoncil..
                $p.StandardOutput.ReadToEnd()
                $p.StandardError.ReadToEnd()
            }

            Set-Location $scriptFolder
            $unfinishedFile2 = $unfinishedFile.Clone()
            $unfinishedFile2 | % {
                $file = $_
                $lastCommitContent = _startProcess git "show HEAD:$file"
                if (!$lastCommitContent -or $lastCommitContent -match "^fatal: ") {
                    Write-Warning "Preskakuji zmeneny ale necomitnuty/untracked soubor: $file"
                } else {
                    $fName = [System.IO.Path]::GetFileNameWithoutExtension($file)
                    # upozornim, ze pouziji verzi z posledniho commitu, protoze aktualni je nejak upravena
                    Write-Warning "$fName ma necommitnute zmeny. Pro vygenerovani modulu pouziji jeho verzi z posledniho commitu"
                    # ulozim obsah souboru tak jak vypadal pri poslednim commitu
                    $lastCommitFileContent.$fName = $lastCommitContent
                    # z $unfinishedFile odeberu, protoze obsah souboru pridam, i kdyz z posledniho commitu
                    $unfinishedFile.Remove($file)
                }
            }
            Set-Location $location

            # unix / nahradim za \
            $unfinishedFile = $unfinishedFile -replace "/", "\"
            $unfinishedFileName = $unfinishedFile | % { [System.IO.Path]::GetFileName($_) }

            if ($includeUncommitedUntracked -and $unfinishedFileName) {
                Write-Warning "Vyexportuji i tyto zmenene, ale necomitnute/untracked funkce: $($unfinishedFileName -join ', ')"
                $unfinishedFile = @()
            }
        }

        #
        # v seznamu ps1 k exportu do modulu ponecham pouze ty, ktere jsou v konzistentnim stavu
        $script2Export = (Get-ChildItem (Join-Path $scriptFolder "*.ps1") -File).FullName | where {
            $partName = ($_ -split "\\")[-2..-1] -join "\"
            if ($unfinishedFile -and $unfinishedFile -match [regex]::Escape($partName)) {
                return $false
            } else {
                return $true
            }
        }

        if (!$script2Export -and $lastCommitFileContent.Keys.Count -eq 0) {
            Write-Warning "V $scriptFolder neni zadna vyhovujici funkce k exportu do $moduleFolder. Ukoncuji"
            return
        }

        # smazu existujici modul
        if (Test-Path $modulePath -ErrorAction SilentlyContinue) {
            Remove-Item $moduleFolder -Recurse -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep 1
        }

        # vytvorim slozku modulu
        [Void][System.IO.Directory]::CreateDirectory($moduleFolder)

        Write-Verbose "Do $modulePath`n"

        # do hashe $lastCommitFileContent pridam dvojice, kde klic je jmeno funkce a hodnotou jeji textova definice
        $script2Export | % {
            $script = $_
            $fName = [System.IO.Path]::GetFileNameWithoutExtension($script)
            if ($fName -match "\s+") {
                throw "Soubor $script obsahuje v nazvu mezeru coz je nesmysl. Jmeno souboru musi odpovidat funkci v nem ulozene a funkce nemohou v nazvu obsahovat mezery"
            }
            if (!$lastCommitFileContent.containsKey($fName)) {
                # obsah skriptu (funkci) pridam pouze pokud jiz neni pridan, abych si neprepsal fce vytazene z posledniho commitu

                #
                # provedu nejdriv kontrolu, ze je ve skriptu definovana pouze jedna funkce a nic jineho
                $ast = [System.Management.Automation.Language.Parser]::ParseFile("$script", [ref] $null, [ref] $null)
                # mel by existovat pouze end block
                if ($ast.BeginBlock -or $ast.ProcessBlock) {
                    throw "Soubor $script neni ve spravnem tvaru. Musi obsahovat pouze definici jedne funkce (pripadne nastaveni aliasu pomoci Set-Alias, komentar ci requires)!"
                }

                # ziskam definovane funkce (v rootu skriptu)
                $functionDefinition = $ast.FindAll( {
                        param([System.Management.Automation.Language.Ast] $ast)

                        $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        # Class methods have a FunctionDefinitionAst under them as well, but we don't want them.
                        ($PSVersionTable.PSVersion.Major -lt 5 -or
                            $ast.Parent -isnot [System.Management.Automation.Language.FunctionMemberAst])
                    }, $false)

                if ($functionDefinition.count -ne 1) {
                    throw "Soubor $script bud neobsahuje zadnou funkci ci obsahuje vic nez jednu. To neni povoleno."
                }

                #TODO pouzivat pro jmeno funkce jeji skutecne jmeno misto nazvu souboru?.
                # $fName = $functionDefinition.name

                #
                # nadefinuji znovu obsah funkce z AST a ten teprve dam do modulu (takto mam jistotu, ze tam nebude zadny bordel navic)
                $content = ""
                if (!$dontIncludeRequires) {
                    # pridam puvodne definovane requires, ale pouze pro moduly
                    $requiredModules = $ast.scriptRequirements.requiredModules.name
                    if ($requiredModules) {
                        $content += "#Requires -Modules $($requiredModules -join ',')`n`n"
                    }
                }
                # nahradim zavadne znaky za legitimni
                $functionText = $functionDefinition.extent.text -replace [char]0x2013, "-" -replace [char]0x2014, "-"

                # pridam i text funkce :)
                $content += $functionText

                # pridam aliasy definovane skrze Set-Alias
                # $ast.EndBlock.Statements obsahuje bloky kodu
                # zajimaji mne pouze ty, ktere definuji alias
                $ast.EndBlock.Statements | ? { $_ -match "^\s*Set-Alias .+" } | % { $_.extent.text } | % {
                    $parts = $_ -split "\s+"
                    # pridam text aliasu
                    $content += "`n$_"

                    if ($_ -match "-na") {
                        # alias nastaven jmennym parametrem
                        # ziskam hodnotu parametru
                        $i = 0
                        $parPosition
                        $parts | % {
                            if ($_ -match "-na") {
                                $parPosition = $i
                            }
                            ++$i
                        }

                        # poznacim alias pro pozdejsi export z modulu
                        $alias2Export += $parts[$parPosition + 1]
                        Write-Verbose "- exportuji alias: $($parts[$parPosition + 1])"
                    } else {
                        # alias nastaven pozicnim parametrem
                        # poznacim alias pro pozdejsi export z modulu
                        $alias2Export += $parts[1]
                        Write-Verbose "- exportuji alias: $($parts[1])"
                    }
                }

                # pridam aliasy definovane skrze [Alias("Some-Alias")]
                $innerAliasDefinition = $ast.FindAll( {
                        param([System.Management.Automation.Language.Ast] $ast)

                        $ast -is [System.Management.Automation.Language.AttributeAst]
                    }, $true) | ? { $_.parent.extent.text -match '^param' } | Select-Object -ExpandProperty PositionalArguments | Select-Object -ExpandProperty Value -ErrorAction SilentlyContinue # odfitrluji aliasy definovane pro parametry funkce

                if ($innerAliasDefinition) {
                    $innerAliasDefinition | % {
                        $alias2Export += $_
                        Write-Verbose "- exportuji inner alias: $_"
                    }
                }

                $lastCommitFileContent.$fName = $content
            }
        }

        #
        # z hodnot v hashi (jmeno funkce a jeji textovy obsah) vygeneruji psm modul
        # poznacim jmeno funkce a pripadne aliasy pro Export-ModuleMember
        $lastCommitFileContent.GetEnumerator() | % {
            $fName = $_.Key
            $content = $_.Value

            Write-Verbose "- exportuji funkci: $fName"

            $function2Export += $fName


            $content | Out-File $modulePath -Append $enc
            "" | Out-File $modulePath -Append $enc
        }

        # nastavim, co se ma z modulu exportovat
        # rychlejsi (pri naslednem importu modulu) je, pokud se exportuji jen explicitne vyjmenovane funkce/aliasy nez pouziti *
        # 300ms vs 15ms :)

        if (!$function2Export) {
            throw "Neexistuji zadne funkce k exportu! Spatne zadana cesta??"
        } else {
            if ($function2Export -match "#") {
                Remove-Item $modulePath -recurse -force -confirm:$false
                throw "Exportovane funkce obsahuji v nazvu nepovoleny znak #. Modul jsem smazal."
            }

            $function2Export = $function2Export | Select-Object -Unique | Sort-Object

            "Export-ModuleMember -function $($function2Export -join ', ')" | Out-File $modulePath -Append $enc
        }

        if ($alias2Export) {
            if ($alias2Export -match "#") {
                Remove-Item $modulePath -recurse -force -confirm:$false
                throw "Exportovane aliasy obsahuji v nazvu nepovoleny znak #. Modul jsem smazal."
            }

            $alias2Export = $alias2Export | Select-Object -Unique | Sort-Object

            "Export-ModuleMember -alias $($alias2Export -join ', ')" | Out-File $modulePath -Append $enc
        }
    } # konec funkce _generatePSModule

    # ze skriptu vygeneruji modul
    $configHash.GetEnumerator() | % {
        $scriptFolder = $_.key
        $moduleFolder = $_.value

        $param = @{
            scriptFolder = $scriptFolder
            moduleFolder = $moduleFolder
            verbose      = $VerbosePreference
        }
        if ($includeUncommitedUntracked) {
            $param["includeUncommitedUntracked"] = $true
        }

        Write-Output "Generuji modul $moduleFolder ze skriptu v $scriptFolder"
        _generatePSModule @param

        if (!$dontCheckSyntax -and (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue)) {
            # zkontroluji syntax vytvoreneho modulu
            $syntaxError = Invoke-ScriptAnalyzer $moduleFolder -Severity Error
            if ($syntaxError) {
                Write-Warning "V modulu $moduleFolder byly nalezeny tyto problemy:"
                $syntaxError
            }
        }
    }
}

function _emailAndExit {
    param ($body)

    $body

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

Function _copyFolder {
    [cmdletbinding()]
    Param (
        [string] $source
        ,
        [string] $destination
        ,
        [string] $excludeFolder = ""
        ,
        [switch] $mirror
    )

    Process {
        if ($mirror) {
            $result = Robocopy.exe "$source" "$destination" /MIR /E /NFL /NDL /NJH /R:4 /W:5 /XD "$excludeFolder"
        } else {
            $result = Robocopy.exe "$source" "$destination" /E /NFL /NDL /NJH /R:4 /W:5 /XD "$excludeFolder"
        }

        $copied = 0
        $failures = 0
        $duration = ""
        $deleted = @()
        $errMsg = @()

        $result | ForEach-Object {
            if ($_ -match "\s+Dirs\s+:") {
                $lineAsArray = (($_.Split(':')[1]).trim()) -split '\s+'
                $copied += $lineAsArray[1]
                $failures += $lineAsArray[4]
            }
            if ($_ -match "\s+Files\s+:") {
                $lineAsArray = ($_.Split(':')[1]).trim() -split '\s+'
                $copied += $lineAsArray[1]
                $failures += $lineAsArray[4]
            }
            if ($_ -match "\s+Times\s+:") {
                $lineAsArray = ($_.Split(':', 2)[1]).trim() -split '\s+'
                $duration = $lineAsArray[0]
            }
            if ($_ -match "\*EXTRA \w+") {
                $deleted += @($_ | ForEach-Object { ($_ -split "\s+")[-1] })
            }
            if ($_ -match "^ERROR: ") {
                $errMsg += ($_ -replace "^ERROR:\s+")
            }
        }

        return [PSCustomObject]@{
            'Copied'   = $copied
            'Failures' = $failures
            'Duration' = $duration
            'Deleted'  = $deleted
            'ErrMsg'   = $errMsg
        }
    }
}

function _setPermissions {
    [cmdletbinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $path
        ,
        $readUser
        ,
        $writeUser
        ,
        [switch] $resetACL
    )

    if (!(Test-Path $path)) {
        throw "zadana cesta neexistuje"
    }

    # osetrim pripad, kdy zadana kombinace stringu a pole
    function Flatten-Array {
        param (
            [array] $inputArray
        )

        foreach ($item in $inputArray) {
            if ($item -ne $null) {
                # recurse for arrays
                if ($item.gettype().BaseType -eq [System.Array]) {
                    Flatten-Array $item
                } else {
                    # output non-arrays
                    $item
                }
            }
        }
    }
    $readUser = Flatten-Array $readUser
    $writeUser = Flatten-Array $writeUser

    $permissions = @()

    if (Test-Path $path -PathType Container) {
        # je to adresar

        # vytvorim prazdne ACL
        $acl = New-Object System.Security.AccessControl.DirectorySecurity

        if ($resetACL) {
            # reset ACL, tzn zruseni explicitnich ACL a povoleni dedeni
            $acl.SetAccessRuleProtection($false, $false)
        } else {
            # zakazani dedeni a odebrani zdedenych prav
            $acl.SetAccessRuleProtection($true, $false)

            $readUser | % {
                $permissions += @(, ("$_", "ReadAndExecute", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            }

            $writeUser | % {
                $permissions += @(, ("$_", "FullControl", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            }
        }
    } else {
        # je to soubor

        # vytvorim prazdne ACL
        $acl = New-Object System.Security.AccessControl.FileSecurity

        if ($resetACL) {
            # reset ACL, tzn zruseni explicitnich ACL a povoleni dedeni
            $acl.SetAccessRuleProtection($false, $false)
        } else {
            # zakazani dedeni a odebrani zdedenych prav
            $acl.SetAccessRuleProtection($true, $false)

            $readUser | % {
                $permissions += @(, ("$_", "ReadAndExecute", 'Allow'))
            }

            $writeUser | % {
                $permissions += @(, ("$_", "FullControl", 'Allow'))
            }
        }
    }

    # naplneni noveho ACL
    $permissions | % {
        $ace = New-Object System.Security.AccessControl.FileSystemAccessRule $_
        try {
            $acl.AddAccessRule($ace)
        } catch {
            Write-Warning "Pravo se nepodarilo nastavit. Existuje zadany ucet?"
        }
    }

    # nastaveni ACL
    try {
        # Set-Acl nejde pouzit protoze bug https://stackoverflow.com/questions/31611103/setting-permissions-on-a-windows-fileshare
        (Get-Item $path).SetAccessControl($acl)
    } catch {
        throw "nepodarilo se nastavit opravneni: $_"
    }
}

# zabalim vse do try catch, abych v pripade chyby mohl poslat email s upozornenim
try {
    #
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
        git --version
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
                "nedoslo k zadnym zmenam, ukoncuji"
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
        # provedu git clone
        #TODONAHRADIT do login.xml vyexportujte GIT credentials (alternate credentials), pripadne access token a (detaily viz https://docs.microsoft.com/cs-cz/azure/devops/repos/git/auth-overview?view=azure-devops) uctu, pod kterym budete stahovat obsah GIT repo (repo_puller). Navod viz slajdy
        $acc = Import-Clixml "$PSScriptRoot\login.xml"
        $l = $acc.UserName
        $p = $acc.GetNetworkCredential().Password
        try {
            _startProcess git -argumentList "clone `"https://$l`:$p@TODONAHRADIT`" `"$PS_repo`"" # misto TODONAHRADIT dejteURL vaseho repo (neco jako: dev.azure.com/ztrhgf/WUG_show/_git/WUG_show). Vysledne URL pak bude vypadat cca takto https://altLogin:altHeslo@dev.azure.com/ztrhgf/WUG_show/_git/WUG_show)
        } catch {
            Remove-Item $PS_repo -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
            _emailAndExit -body "Ahoj,`nnepovedlo se naklonovat git repo. Nezmenilo se heslo u servisniho uctu? Pripadne nagenerujte nove credentials do login.xml."
        }
    }


    #
    # zmeny nakopiruji do DFS repo
    try {
        # nactu $customConfig
        $customSource = Join-Path $PS_repo "custom"
        $customConfigScript = Join-Path $customSource "customConfig.ps1"

        if (!(Test-Path $customConfigScript -ea SilentlyContinue)) {
            Write-Warning "$customConfigScript neexistuje, to je na 99,99% problem!"
        } else {
            # nactu customConfig.ps1 skript respektive $customConfig promennou v nem definovanou
            . $customConfigScript
        }

        _updateRepo -source $PS_repo -destination $destination -force
    } catch {
        _emailAndExit "Pri rozkopirovani zmen do DFS repo se vyskytla chyba:`n$_"
    }

    #
    # nakopiruji do sdilenych slozek Custom data, ktera maji definovano customShareDestination
    # pozn.: nejde o synchronizaci DFS repozitare, ale jinde nedavalo smysl
    "synchronizace Custom dat, jejichz cilem je sdilena slozka"
    $folderToUnc = $customConfig | ? { $_.customShareDestination }

    foreach ($configData in $folderToUnc) {
        $folderName = $configData.folderName
        $copyJustContent = $configData.copyJustContent
        $customNTFS = $configData.customDestinationNTFS
        $customShareDestination = $configData.customShareDestination
        $folderSource = Join-Path $destination "Custom\$folderName"

        "Slozka $folderName by se mela nakopirovat do $($configData.customShareDestination)"

        # kontrola, ze jde o UNC cestu
        if ($customShareDestination -notmatch "^\\\\") {
            Write-Warning "$customShareDestination neni UNC cesta, preskakuji"
            continue
        }

        # kontrola, ze existuje zdrojova slozka (to ze je v $customConfig neznamena, ze realne existuje)
        if (!(Test-Path $folderSource -ea SilentlyContinue)) {
            Write-Warning "$folderSource neexistuje, preskakuji"
            continue
        }

        if ($copyJustContent) {
            $folderDestination = $customShareDestination

            "nakopiruji do $folderDestination (v merge modu)"

            $result = _copyFolder -source $folderSource -destination $folderDestination
        } else {
            $folderDestination = Join-Path $customShareDestination $folderName
            $customLogFolder = Join-Path $folderDestination "Log"

            "nakopiruji do $folderDestination (v replace modu)"

            $result = _copyFolder -source $folderSource -destination $folderDestination -excludeFolder $customLogFolder -mirror

            # vytvoreni zanoreneho Log adresare
            if (!(Test-Path $customLogFolder -ea SilentlyContinue)) {
                "vytvorim Log adresar $customLogFolder"

                New-Item $customLogFolder -ItemType Directory -Force -Confirm:$false
            }
        }

        if ($result.failures) {
            # neskoncim s chybou, protoze se da cekat, ze pri dalsim pokusu uz to projde (ted muze napr bezet skript z teto slozky atp)
            Write-Warning "Pri kopirovani $folderName se vyskytl problem`n$($result.errMsg)"
        }

        # omezeni NTFS prav
        # pozn. nastavuji pokazde, protoze pokud by v customConfig bylo definovano dynamicky (clenstvim v AD skupine ci OU), tak nemam sanci to poznat
        if ($customNTFS -and !$copyJustContent) {
            "nastavim READ pristup uctum v customDestinationNTFS na $folderDestination"
            _setPermissions $folderDestination -readUser $customNTFS -writeUser $writeUser

            "nastavim FULLCONTROL pristup uctum v customDestinationNTFS na $customLogFolder"
            _setPermissions $customLogFolder -readUser $customNTFS -writeUser $writeUser, $customNTFS
        } elseif (!$customNTFS -and !$copyJustContent) {
            # nemaji se nastavit zadna custom prava
            # pro jistotu udelam reset NTFS prav (mohl jsem je jiz v minulosti nastavit)
            # ale pouze pokud na danem adresari najdu read_user ACL == nastavil jsem v minulosti custom prava
            # pozn.: detekuji tedy dle NTFS opravneni (pokud by se nenastavovalo, bude potreba zvolit jinou metodu detekce!)
            $folderhasCustomNTFS = Get-Acl -path $folderDestination | ? { $_.accessToString -like "*$readUser*" }
            if ($folderhasCustomNTFS) {
                "adresar $folderDestination ma custom NTFS i kdyz je jiz nema mit, zresetuji NTFS prava"
                _setPermissions -path $folderDestination -resetACL

                "zresetuji i na Log podadresari"
                _setPermissions -path $customLogFolder -resetACL
            }
        }
    }
} catch {
    _emailAndExit -body "Ahoj,`npri synchronizaci GIT repo >> DFS repo se obevila chyba:`n$_"
}