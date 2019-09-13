function Update-Repo {
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
        Update-Repo -source C:\DATA\Powershell_Repo\ -destination \\domena\dfs\repository

    .NOTES
        Author: Ondřej Šebela - ztrhgf@seznam.cz
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
        $repoStatus = git.exe status -uno
        # seznam nepushnutych commitu
        $unpushedCommit = git.exe log origin/master..HEAD
        # soubory v poslednim commitu
        $commitedFile = @(git.exe show HEAD --pretty="" --name-only)
        # deleted soubory v poslednim commitu
        $commitedDeletedFile = @(git.exe show HEAD --pretty="" --name-status | Where-Object { $_ -match "^D\s+" } | ForEach-Object { $_ -replace "^D\s+" })
        # deleted, ale ne v staging area soubory
        $uncommitedDeletedFile = @(git.exe ls-files -d)
        # modifikovane, ale ne v staging area soubory (vypisuje i smazane)
        $unfinishedFile += @(git.exe ls-files -m)
        # untracked soubory (dosud nikdy commitnute)
        $unfinishedFile += @(git.exe ls-files --others --exclude-standard)
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
    $isForced = ($PSBoundParameters.GetEnumerator() | Where-Object { $_.key -eq "force" }).value.isPresent

    if (!$unpushedCommit -and $isForced -ne "True") {
        Write-Warning "`nV repozitari neni zadny nepushnuty commit. Funkce rozkopiruje pouze zmeny z posledniho commitu.`nPokud chcete rozkopirovat vse, pouzijte -force`n`n"
    }

    # git prikazy vraci s unix lomitky, zmenim na zpetna
    $unfinishedFile = $unfinishedFile -replace "/", "\"
    $commitedFile = $commitedFile -replace "/", "\"
    $commitedDeletedFile = $commitedDeletedFile -replace "/", "\"
    $uncommitedDeletedFile = $uncommitedDeletedFile -replace "/", "\"

    # ulozim s absolutnimi cestami
    $unfinishedFileAbsPath = $unfinishedFile | ForEach-Object { Join-Path $source $_ }

    #
    # vytvorim si string ve tvaru, ktery vyzaduje /XF parametr robocopy
    # pujde o seznam souboru, ktere chci ignorovat pri kopirovani skrze robocopy (necomitnute zmenene a untracked soubory)
    # cesty musi byt absolutni a odkazovat na soubory v source adresari
    $excludeFile = ""
    if ($unfinishedFileAbsPath) {
        $unfinishedFileAbsPath | ForEach-Object {
            $excludeFile += " " + "`"$_`""
        }
    }
    # ignorovat musim take smazane, ale necomitnute soubory
    # ty naopak musi mit cestu odpovidajici cilovemu (destination) souboru, aby nedoslo k jeho smazani
    $folderWithUncommitedDeletedFile = @()

    if ($uncommitedDeletedFile) {
        $uncommitedDeletedFile | ForEach-Object {
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
        $folderWithUncommitedDeletedFile | ForEach-Object {
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
        $commitedFile2 | ForEach-Object {
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
    # ze skriptu ve slozkazch ulozenych v scripts2module vygeneruji psm moduly
    # a az ten nakopiruji do remote repozitare + ostatni zmenene moduly
    #

    # do $configHash si znacim, jake moduly se maji (a z ceho generovat) kvuli zavolani funkce Export-ScriptsToModule
    $configHash = @{ }

    if ($force) {
        # pregeneruji vsechny moduly at uz v nich doslo ke zmene ci nikoli
        Get-ChildItem $scripts2module -Directory | Select-Object -ExpandProperty FullName | ForEach-Object {
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
        $commitedFile | Where-Object { $_ -match "^scripts2module\\" } | ForEach-Object { ($_ -split "\\")[-2] } | Select-Object -Unique | ForEach-Object {
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

        Export-ScriptsToModule -configHash $configHash -dontIncludeRequires
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

            $configHash.Values | ForEach-Object {
                Write-Verbose "Obsah $_ nepreskocim, jde o automaticky vyexportovany modul"
                $esc = [regex]::Escape($_)
                if ($reg) {
                    $reg += "|$esc"
                } else {
                    $reg += "$esc"
                }
            }

            $excludeFile2 = $excludeFile | Where-Object { $_ -notmatch $reg }

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
        $deleted = $result | Where-Object { $_ -match [regex]::Escape("*EXTRA File") } | ForEach-Object { ($_ -split "\s+")[-1] }
        if ($deleted) {
            Write-Output "Smazal jsem jiz nepotrebne soubory:`n$($deleted -join "`n")"
        }

        # result by mel obsahovat pouze chybove vypisy
        # *EXTRA File\Dir jsou vypisy smazanych souboru\adresaru (/MIR)
        $result = $result | Where-Object { $_ -notmatch [regex]::Escape("*EXTRA ") }
        if ($result) {
            Write-Error "Pri kopirovani modulu $($_.name) se vyskytl nasledujici problem:`n`n$result`n`nPokud slo o chybu, opetovne spustte rozkopirovani prikazem:`n$($MyInvocation.Line) -force"
        }
    }

    #
    # smazu z remote repo modules prazdne adresare (neobsahuji soubory)
    Get-ChildItem $destModule -Directory | ForEach-Object {
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
        $script2Copy = (Get-ChildItem $scripts2root -File).FullName | Where-Object {
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

            $script2Copy | ForEach-Object {
                $item = $_
                Write-Output (" - " + ([System.IO.Path]::GetFileName("$item")))

                try {
                    Copy-Item $item $destination -Force -ErrorAction Stop
                } catch {
                    Write-Error "Pri kopirovani root skriptu $item doslo k chybe:`n`n$_`n`nOpetovne spustte rozkopirovani prikazem:`n$($MyInvocation.Line) -force"
                }
            }
        }

        #
        # SMAZU Z KORENE DFS REPO SOUBORY, KTERE TAM JIZ NEMAJI BYT
        # vytahnu soubory s koncovkou (v rootu mam i soubor bez koncovky s upozornenim at se delaji zmeny v GIT a ne v DFS, ktery by ale v samotnem GIT repo mohl mast)
        $DFSrootFile = Get-ChildItem $destination -File | Where-Object { $_.extension }
        $GITrootFileName = Get-ChildItem $scripts2root -File | Select-Object -ExpandProperty Name
        $uncommitedDeletedRootFileName = $uncommitedDeletedFile | Where-Object { $_ -match "scripts2root\\" } | ForEach-Object { ([System.IO.Path]::GetFileName($_)) }
        $DFSrootFile | ForEach-Object {
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
        $deleted = $result | Where-Object { $_ -match [regex]::Escape("*EXTRA File") } | ForEach-Object { ($_ -split "\s+")[-1] }
        if ($deleted) {
            Write-Verbose "Smazal jsem jiz nepotrebne soubory:`n$($deleted -join "`n")"
        }

        # result by mel obsahovat pouze chybove vypisy
        # *EXTRA File\Dir jsou vypisy smazanych souboru\adresaru (/MIR)
        $result = $result | Where-Object { $_ -notmatch [regex]::Escape("*EXTRA ") }
        if ($result) {
            Write-Error "Pri kopirovani Custom sekce se vyskytl nasledujici problem:`n`n$result`n`nPokud slo o chybu, opetovne spustte rozkopirovani prikazem:`n$($MyInvocation.Line) -force"
        }

        # omezeni NTFS prav
        # aby mely pristup pouze stroje, ktere maji dany obsah stahnout dle $config atributu computerName
        # slozky, ktere nemaji definovan computerName budou mit vychozi nastaveni
        # pozn. nastavuji pokazde, protoze pokud by v customConfig byly nejake cilove stroje definovany clenstvim v AD skupine ci OU, tak nemam sanci to jinak poznat
        $customConfig = Join-Path $customDestination "customConfig.ps1"
        if (Test-Path $customConfig -ea SilentlyContinue) {
            # customConfig existuje, tzn je mozne zjistit, jak se maji omezit NTFS prava

            # import promennych
            # kvuli zjisteni, kam se ma ktera slozka kopirovat a dle toho omezit NTFS prava
            # chybu ignorujeme, protoze na fresh stroji, modul bude az po prvnim spusteni tohoto skriptu, ne driv :)
            Import-Module Variables -ErrorAction "Continue"

            # nactu customConfig.ps1 skript respektive $config promennou v nem definovanou
            . $customConfig

            # skupina ktera ma pravo cist obsah DFS repozitare (i lokalni kopie)
            [string] $readUser = "TODONAHRADITzaNETBIOSVASIDOMENY\repo_reader"
            # skupina ktera ma pravo editovat obsah DFS repozitare (i lokalni kopie)
            [string] $writeUser = "TODONAHRADITzaNETBIOSVASIDOMENY\repo_writer"
            function _setPermissions {
                [cmdletbinding()]
                param (
                    [Parameter(Mandatory = $true)]
                    [string] $path
                    ,
                    [Parameter(Mandatory = $true)]
                    [string[]] $readUser
                    ,
                    [Parameter(Mandatory = $true)]
                    [string[]] $writeUser
                    ,
                    [switch] $resetACL
                )

                if (!(Test-Path $path)) {
                    throw "zadana cesta neexistuje"
                }

                # vytvorim prazdne ACL
                $acl = New-Object System.Security.AccessControl.DirectorySecurity

                $permissions = @()

                if (Test-Path $path -PathType Container) {
                    # je to adresar

                    if ($resetACL) {
                        # reset ACL, tzn zruseni explicitnich ACL a povoleni dedeni
                        $acl.SetAccessRuleProtection($false, $false)
                    } else {
                        # zakazani dedeni a odebrani zdedenych prav
                        $acl.SetAccessRuleProtection($true, $false)

                        $readUser | ForEach-Object {
                            $permissions += @(, ("$_", "ReadAndExecute", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                        }

                        $writeUser | ForEach-Object {
                            $permissions += @(, ("$_", "FullControl", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                        }
                    }
                } else {
                    "nemelo by nastat, Custom ma obsahovat pouze soubory"
                }

                # naplneni noveho ACL
                $permissions | ForEach-Object {
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

            foreach ($folder in (Get-ChildItem $customDestination -Directory)) {
                $folder = $folder.FullName
                $folderName = Split-Path $folder -Leaf

                $configData = $config | ? { $_.folderName -eq $folderName }
                if ($configData -and ($configData.computerName -or $configData.customShareNTFS)) {
                    # pro danou slozku je definovano, kam se ma kopirovat
                    # omezim nalezite pristup

                    # custom share NTFS prava maji prednost pred omezenim prav na stroje, kam se ma kopirovat
                    # tzn pokud je definovano oboje, nastavim co je v customShareNTFS atributu
                    if ($configData.customShareNTFS) {
                        [string[]] $readUser = $configData.customShareNTFS
                    } else {
                        [string[]] $readUser = $configData.computerName
                        # computer AD ucty maji $ za svym jmenem, pridam
                        $readUser = $readUser | % { $_ + "$" }
                    }

                    "omezuji NTFS prava na $folder (pristup pouze pro: $($readUser -join ', '))"
                    _setPermissions $folder -readUser $readUser -writeUser $writeUser
                } else {
                    # pro danou slozku neni definovano, kam se ma kopirovat
                    # zresetuji prava na vychozi
                    "nastavuji vychozi prava na $folder"
                    _setPermissions $folder -readUser $readUser -writeUser $writeUser -resetACL
                }
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