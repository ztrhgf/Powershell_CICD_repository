<#
    .SYNOPSIS
    script is inteded for processing of cloud repository content and distribution that content to DFS repository
    how it works:
    - pull/clone cloud repository locally
    - process cloned content (generate PSM modules from scripts2module, copy Custom content to shares,..)
    - copy processed content which is intended for clients to shared folder (DFS)

    BEWARE, repo_puller account has to have alternate credentials created in cloud GIT repository and these credentials has to be exported to login.xml (under account which is used to run this script)
    
    .NOTES
    Author: Ondřej Šebela - ztrhgf@seznam.cz
    #>

# for debugging purposes
Start-Transcript -Path "$env:SystemRoot\temp\repo_sync.log" -Force

$ErrorActionPreference = "stop"

$logFolder = Join-Path $PSScriptRoot "Log"

# nekdy se stavalo, ze pod SYSTEM uctem nefungoval autoload funkci z modulu
Import-Module Scripts -Function Send-Email -ErrorAction SilentlyContinue

# aby nespamovalo v pripade chyby, umoznuji poslat max 1 mail za 30 minut
$lastSendEmail = Join-Path $logFolder "lastSendEmail"
$treshold = 30

$destination = "__TODO__" # UNC path to DFS repository (ie.: \\myDomain\dfs\repository)

# skupina ktera ma pravo cist obsah DFS repozitare (i lokalni kopie)
[string] $readUser = "repo_reader"
# skupina ktera ma pravo editovat obsah DFS repozitare (i lokalni kopie)
[string] $writeUser = "repo_writer"

#__TODO__ configure and uncomment one of the rows that initialize variable $signingCert, if you want automatic code signing to happen (using specified certificate)

# certificate which will be used to sign ps1, psm1, psd1 and ps1xml files
# USE ONLY IF YOU KNOW, WHAT ARE YOU DOING
# tutorial how to create self signed certificate http://woshub.com/how-to-sign-powershell-script-with-a-code-signing-certificate/
# set correct path to signing certificate and uncomment to start signing
# $signingCert = (Get-ChildItem cert:\LocalMachine\my –CodeSigningCert)[0] # something like this, if certificate is in store
if ($signingCert -and $signingCert.EnhancedKeyUsageList.friendlyName -ne "Code Signing") {
    throw "Certificate $($signingCert.DnsNameList) is not valid Code Signing certificate"
}

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
                    Throw "Enter path to locally cloned repository"
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
        throw "Path $destination is not available"
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
            throw "git command failed. Is GIT installed? Error was:`n$err"
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
        throw "Repository doesn't contain actual data. Pull them using command 'git pull' (Sync in VSC editor) and run again"
    }

    # ulozim jestli pouzil force prepinac
    $isForced = ($PSBoundParameters.GetEnumerator() | ? { $_.key -eq "force" }).value.isPresent

    if (!$unpushedCommit -and $isForced -ne "True") {
        Write-Warning "`nIn repository there is none unpushed commit. Function will copy just changes from last commit.`nIf you want to copy all, use -force switch`n`n"
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
        Write-Verbose "Last commit contains these files:`n$($commitedFile -join ', ')"
        $commitedFile2 = $commitedFile.Clone()
        $commitedFile2 | % {
            $file = $_
            $commitedFileMatch = [regex]::Escape($file) + "$"
            if ($unfinishedFile -match $commitedFileMatch -or $uncommitedDeletedFile -match $commitedFileMatch) {
                Write-Warning "File $file is in commit, but is also modified outside staging area. Skipping"
                $commitedFile.remove($file)
            }
        }
    }

    if ($unfinishedFile) {
        Write-Warning "Skipping these changed, but uncommited files:`n$($unfinishedFileAbsPath -join "`n")"
    }
    if ($uncommitedDeletedFile) {
        Write-Verbose "Skipping these deleted, but uncommited files:`n$($uncommitedDeletedFile -join "`n")"
    }





    
    #
    # poznacim historii commitu do souboru, abych v PS konzoli mohl ukazat o kolik commitu je pozadu
    #
    if ($commitHistory) {
        $commitHistory | Out-File (Join-Path $destination commitHistory) -Force
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
            Write-Output "Some modules changed, copying"
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
            throw "Path $destModule isn't accessible"
        }

        ++$somethingChanged

        Write-Output "### Copying modules to $destModule"

        # z exclude docasne vyradim soubory z automaticky nagenerovanych modulu (z ps1 v scripts2module)
        # v exclude se mohou objevit proto, ze nebudou uvedeny v .gitignore >> jsou untracked
        if ($configHash.Keys.count) {
            $reg = ""

            $configHash.Values | % {
                Write-Verbose "Don't skip content of $_, its automatically generated module"
                $esc = [regex]::Escape($_)
                if ($reg) {
                    $reg += "|$esc"
                } else {
                    $reg += "$esc"
                }
            }

            $excludeFile2 = $excludeFile | ? { $_ -notmatch $reg }

            if ($excludeFile.count -ne $excludeFile2.count) {
                Write-Warning "When copy modules skip just these: $($excludeFile2 -join ', ')"
            }
        } else {
            $excludeFile2 = $excludeFile
        }

        # podepsani skriptu
        if ($signingCert) {
            Get-ChildItem $modules -Recurse -Include *.ps1, *.psm1, *.psd1, *.ps1xml -File | % {
                Set-AuthenticodeSignature -Certificate $signingCert -FilePath $_.FullName
            }
        }

        # zamerne kopiruji i nezmenene moduly, kdyby nekdo udelal zmenu primo v remote repo, abych ji prepsal
        # result bude obsahovat smazane soubory a pripadne chyby
        # pres Invoke-Expression musim delat, aby se spravne aplikoval obsah excludeFile
        # /S tzn nekopiruji prazdne adresare
        $result = Invoke-Expression "Robocopy.exe `"$modules`" `"$destModule`" /MIR /S /NFL /NDL /NJH /NJS /R:4 /W:5 /XF $excludeFile2 /XD $excludeFolder"

        # vypisi smazane soubory
        $deleted = $result | ? { $_ -match [regex]::Escape("*EXTRA File") } | % { ($_ -split "\s+")[-1] }
        if ($deleted) {
            Write-Output "Deletion of unnecessary files:`n$($deleted -join "`n")"
        }

        # result by mel obsahovat pouze chybove vypisy
        # *EXTRA File\Dir jsou vypisy smazanych souboru\adresaru (/MIR)
        $result = $result | ? { $_ -notmatch [regex]::Escape("*EXTRA ") }
        if ($result) {
            Write-Error "There was an error when copying module $($_.name):`n`n$result`n`nRun again command: $($MyInvocation.Line) -force"
        }

        # omezeni NTFS prav
        # aby mely pristup pouze stroje, ktere maji dany obsah stahnout dle atributu computerName v $modulesConfig
        # slozky, ktere nemaji definovan computerName budou mit vychozi NTFS prava
        # pozn. nastavuji pokazde, protoze pokud by v customConfig byly nejake cilove stroje definovany promennou, nemam sanci zjistit jestli se jeji obsah odminula nezmenil
        "### Setting NTFS rights on modules"
        foreach ($folder in (Get-ChildItem $destModule -Directory)) {
            $folder = $folder.FullName
            $folderName = Split-Path $folder -Leaf

            # pozn.: $modulesConfig jsem dostal dot sourcingem modulesConfig.ps1 skriptu
            $configData = $modulesConfig | ? { $_.folderName -eq $folderName }
            if ($configData -and ($configData.computerName)) {
                # pro danou slozku je definovano, kam se ma kopirovat
                # omezim nalezite pristup

                [string[]] $readUserC = $configData.computerName
                # computer AD ucty maji $ za svym jmenem, pridam
                $readUserC = $readUserC | % { $_ + "$" }

                " - limiting NTFS rights on $folder (grant access just to: $($readUserC -join ', '))"
                _setPermissions $folder -readUser $readUserC -writeUser $writeUser
            } else {
                # pro danou slozku neni definovano, kam se ma kopirovat
                # zresetuji prava na vychozi
                " - resetting NTFS rights on $folder"
                _setPermissions $folder -resetACL
            }
        }
    }

    #
    # smazu z remote repo modules prazdne adresare (neobsahuji soubory)
    Get-ChildItem $destModule -Directory | % {
        $item = $_.FullName
        if (!(Get-ChildItem $item -Recurse -File)) {
            try {
                Write-Verbose "Deleting empty folder $item"
                Remove-Item $item -Force -Recurse -Confirm:$false
            } catch {
                Write-Error "There was an error when deleting $item`:`n`n$_`n`nRun again command: $($MyInvocation.Line) -force"
            }
        }
    }



    #
    # NAKOPIRUJI OBSAH scripts2root DO KORENE DFS REPO
    #

    if ($commitedFile -match "^scripts2root" -or $force) {
        # doslo ke zmene v adresari scripts2root, vykopiruji do remote repozitare
        Write-Output "### Copying root files from $scripts2root to $destination`n"

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
                    # podepsani skriptu
                    if ($signingCert -and $item -match "ps1$|psd1$|psm1$|ps1xml$") {
                        Set-AuthenticodeSignature -Certificate $signingCert -FilePath $item
                    }

                    Copy-Item $item $destination -Force -ErrorAction Stop

                    # u profile.ps1 omezim pristup (skrze NTFS prava) pouze na stroje, na nez se ma kopirovat
                    if ($item -match "\\profile\.ps1$") {
                        $destProfile = (Join-Path $destination "profile.ps1")
                        if ($computerWithProfile) {
                            # computer AD ucty maji $ za svym jmenem, pridam
                            [string[]] $readUserP = $computerWithProfile | % { $_ + "$" }

                            "  - limiting NTFS rights on $destProfile (grant access just to: $($readUserP -join ', '))"
                            _setPermissions $destProfile -readUser $readUserP -writeUser $writeUser
                        } else {
                            "  - resetting NTFS rights on $destProfile"
                            _setPermissions $destProfile -resetACL
                        }
                    }
                } catch {
                    Write-Error "There was an error when copying root file $item`:`n`n$_`n`nRun again command: $($MyInvocation.Line) -force"
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
                    Write-Verbose "Deleting $($_.FullName)"
                    Remove-Item $_.FullName -Force -Confirm:$false -ErrorAction Stop
                } catch {
                    Write-Error "There was an error when deleting file $item`:`n`n$_`n`nRun again command: $($MyInvocation.Line) -force"
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
            throw "Path $customSource isn't accessible"
        }

        Write-Output "### Copying Custom data from $customSource to $customDestination`n"
        # pres Invoke-Expression musim delat, aby se spravne aplikoval obsah excludeFile
        # /S tzn nekopiruji prazdne adresare

        # podepsani skriptu
        if ($signingCert) {
            Get-ChildItem $customSource -Recurse -Include *.ps1, *.psm1, *.psd1, *.ps1xml -File | % {
                Set-AuthenticodeSignature -Certificate $signingCert -FilePath $_.FullName
            }
        }

        $result = Invoke-Expression "Robocopy.exe $customSource $customDestination /S /MIR /NFL /NDL /NJH /NJS /R:4 /W:5 /XF $excludeFile /XD $excludeFolder"

        # vypisi smazane soubory
        $deleted = $result | ? { $_ -match [regex]::Escape("*EXTRA File") } | % { ($_ -split "\s+")[-1] }
        if ($deleted) {
            Write-Verbose "Unnecessary files was deleted:`n$($deleted -join "`n")"
        }

        # result by mel obsahovat pouze chybove vypisy
        # *EXTRA File\Dir jsou vypisy smazanych souboru\adresaru (/MIR)
        $result = $result | ? { $_ -notmatch [regex]::Escape("*EXTRA ") }
        if ($result) {
            Write-Error "There was an error when copying Custom section`:`n`n$result`n`nRun again command: $($MyInvocation.Line) -force"
        }


        # omezeni NTFS prav
        # aby mely pristup pouze stroje, ktere maji dany obsah stahnout dle atributu computerName v $customConfig
        # slozky, ktere nemaji definovan computerName budou mit vychozi NTFS prava
        # pozn. nastavuji pokazde, protoze pokud by v customConfig byly nejake cilove stroje definovany promennou, nemam sanci zjistit jestli se jeji obsah odminula nezmenil
        "### Setting NTFS rights on Custom"
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

                " - limiting NTFS rights on $folder (grant access just to: $($readUserC -join ', '))"
                _setPermissions $folder -readUser $readUserC -writeUser $writeUser
            } else {
                # pro danou slozku neni definovano, kam se ma kopirovat
                # zresetuji prava na vychozi
                " - resetting NTFS rights on $folder"
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
        Write-Error "`nIn $source there was no change == there is nothing to copy!`nIf you wish to force copying of current content, use:`n$($MyInvocation.Line) -force`n"
    }
} # end of _updateRepo

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
        Write-Warning "Syntax won't be checked, because function Invoke-ScriptAnalyzer is not available (part of module PSScriptAnalyzer)"
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
            throw "Path $scriptFolder is not accessible"
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
            throw "It seems GIT isn't installed. I was unable to get list of changed files in repository $scriptFolder"
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
                    Write-Warning "Skipping changed but uncommited/untracked file: $file"
                } else {
                    $fName = [System.IO.Path]::GetFileNameWithoutExtension($file)
                    # upozornim, ze pouziji verzi z posledniho commitu, protoze aktualni je nejak upravena
                    Write-Warning "$fName has uncommited changed. For module generation I will user his version from previous commit"
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
                Write-Warning "Exporting changed but uncommited/untracked functions: $($unfinishedFileName -join ', ')"
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
            Write-Warning "In $scriptFolder there is none usable function to export to $moduleFolder. Exiting"
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
                throw "File $script contains space in name which is nonsense. Name of file has to be same to the name of functions it defines and functions can't contain space in it's names."
            }
            if (!$lastCommitFileContent.containsKey($fName)) {
                # obsah skriptu (funkci) pridam pouze pokud jiz neni pridan, abych si neprepsal fce vytazene z posledniho commitu

                #
                # provedu nejdriv kontrolu, ze je ve skriptu definovana pouze jedna funkce a nic jineho
                $ast = [System.Management.Automation.Language.Parser]::ParseFile("$script", [ref] $null, [ref] $null)
                # mel by existovat pouze end block
                if ($ast.BeginBlock -or $ast.ProcessBlock) {
                    throw "File $script isn't in correct format. It has to contain just function definition (+ alias definition, comment or requires)!"
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
                    throw "File $script doesn't contain any function or contain's more than one."
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
                        Write-Verbose "- exporting alias: $($parts[$parPosition + 1])"
                    } else {
                        # alias nastaven pozicnim parametrem
                        # poznacim alias pro pozdejsi export z modulu
                        $alias2Export += $parts[1]
                        Write-Verbose "- exporting alias: $($parts[1])"
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
                        Write-Verbose "- exporting 'inner' alias: $_"
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

            Write-Verbose "- exporting function: $fName"

            $function2Export += $fName


            $content | Out-File $modulePath -Append $enc
            "" | Out-File $modulePath -Append $enc
        }

        # nastavim, co se ma z modulu exportovat
        # rychlejsi (pri naslednem importu modulu) je, pokud se exportuji jen explicitne vyjmenovane funkce/aliasy nez pouziti *
        # 300ms vs 15ms :)

        if (!$function2Export) {
            throw "There are none functions to export! Wrong path??"
        } else {
            if ($function2Export -match "#") {
                Remove-Item $modulePath -recurse -force -confirm:$false
                throw "Exported function contains unnaproved character # in it's name. Module was removed."
            }

            $function2Export = $function2Export | Select-Object -Unique | Sort-Object

            "Export-ModuleMember -function $($function2Export -join ', ')" | Out-File $modulePath -Append $enc
        }

        if ($alias2Export) {
            if ($alias2Export -match "#") {
                Remove-Item $modulePath -recurse -force -confirm:$false
                throw "Exported alias contains unnaproved character # in it's name. Module was removed."
            }

            $alias2Export = $alias2Export | Select-Object -Unique | Sort-Object

            "Export-ModuleMember -alias $($alias2Export -join ', ')" | Out-File $modulePath -Append $enc
        }
    } # konec funkce _generatePSModule

    # ze skriptu vygeneruji modul
    "### Generating modules from corresponding scripts2module folder"
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

        Write-Output " - $moduleFolder"
        _generatePSModule @param

        if (!$dontCheckSyntax -and (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue)) {
            # zkontroluji syntax vytvoreneho modulu
            $syntaxError = Invoke-ScriptAnalyzer $moduleFolder -Severity Error
            if ($syntaxError) {
                Write-Warning "In module $moduleFolder was found these problems:"
                $syntaxError
            }
        }
    }
} # end of _exportScriptsToModule

function _emailAndExit {
    param ($body)

    $body

    if ((Test-Path $lastSendEmail -ea SilentlyContinue) -and (Get-Item $lastSendEmail).LastWriteTime -gt [datetime]::Now.AddMinutes(-$treshold)) {
        "last error email was sent less than $treshold minutes...just end"
        throw 1
    } else {
        $body = $body + "`n`n`nNext failure will be emailed at first after $treshold minutes"
        Send-Email -body $body
        New-Item $lastSendEmail -Force
        throw 1
    }
} # end of _emailAndExit

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
} # end of _startProcess

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
} # end of _copyFolder

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
            Write-Warning "Setting of NTFS right wasn't successful. Does given user account exists?"
        }
    }

    # nastaveni ACL
    try {
        # Set-Acl nejde pouzit protoze bug https://stackoverflow.com/questions/31611103/setting-permissions-on-a-windows-fileshare
        (Get-Item $path).SetAccessControl($acl)
    } catch {
        throw "Setting of NTFS rights wasn't successful: $_"
    }
} # end of _setPermissions


try {
    #
    # kontrola, ze mam pravo zapisu do DFS repo
    try {
        $rFile = Join-Path $destination Get-Random
        $null = New-Item -Path ($rFile) -ItemType File -Force -Confirm:$false
    } catch {
        _emailAndExit -body "Hi,`nscript doesn't have right to write in $destination. Changes in GIT repository can't be propagated.`nIs computer account $env:COMPUTERNAME in group repo_writer?"
    }
    Remove-Item $rFile -Force -Confirm:$false

    #
    # kontrola ze je nainstalovan GIT
    try {
        git --version
    } catch {
        _emailAndExit -body "Hi,`nGIT isn't installed on $env:COMPUTERNAME. Changes in GIT repository can't be propagated to $destination.`nInstall it."
    }

    #
    # download current content of cloud GIT repository
    $PS_repo = Join-Path $logFolder PS_repo # do adresare Log ukladam protoze jeho obsah se ignoruje pri synchronizaci skrze PS_env_set_up tzn nezapocita se do velikosti tzn nedojde k replace daty z DFS repo

    if (Test-Path $PS_repo -ea SilentlyContinue) {
        # existuje lokalni kopie repo
        # provedu stazeni novych dat (a replace starych)
        Set-Location $PS_repo
        try {
            # nemohu pouzit klasicky git pull, protoze chci prepsat pripadne lokalni zmeny bez reseni nejakych konfliktu atd
            # abych zachytil pripadne chyby pouzivam _startProcess
            _startProcess git -argumentList "fetch --all" # downloads the latest from remote without trying to merge or rebase anything.

            # # ukoncim pokud nedoslo k zadne zmene
            # # ! pripadne manualni upravy v DFS repo se tim padem prepisi az po zmene v cloud repo, ne driv !
            # $status = _startProcess git -argumentList "status"
            # if ($status -match "Your branch is up to date with") {
            #     "nedoslo k zadnym zmenam, ukoncuji"
            #     exit
            # }

            _startProcess git -argumentList "reset --hard origin/master" # resets the master branch to what you just fetched. The --hard option changes all the files in your working tree to match the files in origin/master
            _startProcess git -argumentList "clean -fd" # odstraneni untracked souboru a adresaru (vygenerovane moduly z scripts2module atp)
            
            $commitHistory = _startProcess git -argumentList "log --pretty=format:%h -20" # poslednich 20 commitu, od nejnovejsiho
            $commitHistory = $commitHistory -split "`n" | ? { $_ }
        } catch {
            Set-Location ..
            Remove-Item $PS_repo -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
            _emailAndExit -body "Hi,`nthere was an error when pulling changes from repository. Script deleted local copy of repository and will try git clone next time.`nError was:`n$_."
        }
    } else {
        # NEexistuje lokalni kopie repo
        # provedu git clone
        #__TODO__ to login.xml export GIT credentials (alternate credentials), or access token of repo_puller account (read only account which is used to clone your repository) (details here https://docs.microsoft.com/cs-cz/azure/devops/repos/git/auth-overview?view=azure-devops) how to export credentials here https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20-%20INITIAL%20CONFIGURATION.md
        $acc = Import-Clixml "$PSScriptRoot\login.xml"
        $l = $acc.UserName
        $p = $acc.GetNetworkCredential().Password
        try {
            _startProcess git -argumentList "clone `"https://$l`:$p@__TODO__`" `"$PS_repo`"" # instead __TODO__ use URL of your company repository (ie somethink like: dev.azure.com/ztrhgf/WUG_show/_git/WUG_show). Finished URL will be look like this: https://altLogin:altPassword@dev.azure.com/ztrhgf/WUG_show/_git/WUG_show)
        } catch {
            Remove-Item $PS_repo -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
            _emailAndExit -body "Hi,`nthere was an error when cloning repository. Wasn't the password of service account changed? Try generate new credentials to login.xml."
        }
    }


    #
    # importing variables
    # to be able to limit NTFS rights on folders in Custom, Modules and profile.ps1 etc
    # need to be done before dot sourcing customConfig.ps1 and modulesConfig.ps1
    $repoModules = Join-Path $PS_repo "modules"
    try {
        # at first try to import Variables module pulled from cloud repo
        Import-Module (Join-Path $repoModules "Variables") -ErrorAction Stop
    } catch {
        # if error, try to import Variables from system location
        # errors are ignored, because on fresh machine, module will be presented right after first run of PS_env_set_up.ps1 not sooner :)
        "importing Variables module from $((Join-Path $repoModules "Variables")) was unsuccessful"
        Import-Module Variables -ErrorAction "Continue"
    }


    #
    # zmeny nakopiruji do DFS repo
    try {
        # nactu $customConfig
        $customSource = Join-Path $PS_repo "custom"
        $customConfigScript = Join-Path $customSource "customConfig.ps1"

        if (!(Test-Path $customConfigScript -ea SilentlyContinue)) {
            Write-Warning "$customConfigScript is missing, it is problem for 99,99%!"
        } else {
            # nactu customConfig.ps1 skript respektive $customConfig promennou v nem definovanou
            . $customConfigScript
        }


        # nactu $modulesConfig
        $modulesSource = Join-Path $PS_repo "modules"
        $modulesConfigScript = Join-Path $modulesSource "modulesConfig.ps1"

        if (!(Test-Path $modulesConfigScript -ea SilentlyContinue)) {
            Write-Warning "$modulesConfigScript is missing"
        } else {
            # nactu $modulesConfig.ps1 skript respektive $modulesConfig promennou v nem definovanou
            . $modulesConfigScript
        }


        _updateRepo -source $PS_repo -destination $destination -force
    } catch {
        _emailAndExit "There was an error when copying changes to DFS repository:`n$_"
    }


    #
    # nakopiruji do sdilenych slozek Custom data, ktera maji definovano customShareDestination
    # pozn.: nejde o synchronizaci DFS repozitare, ale jinde nedavalo smysl
    "### Synchronization of Custom data, which are supposed to be in specified shared folder"
    $folderToUnc = $customConfig | ? { $_.customShareDestination }

    foreach ($configData in $folderToUnc) {
        $folderName = $configData.folderName
        $copyJustContent = $configData.copyJustContent
        $customNTFS = $configData.customDestinationNTFS
        $customShareDestination = $configData.customShareDestination
        $folderSource = Join-Path $destination "Custom\$folderName"

        " - folder $folderName should be copied to $($configData.customShareDestination)"

        # kontrola, ze jde o UNC cestu
        if ($customShareDestination -notmatch "^\\\\") {
            Write-Warning "$customShareDestination isn't UNC path, skipping"
            continue
        }

        # kontrola, ze existuje zdrojova slozka (to ze je v $customConfig neznamena, ze realne existuje)
        if (!(Test-Path $folderSource -ea SilentlyContinue)) {
            Write-Warning "$folderSource doen't exist, skipping"
            continue
        }

        if ($copyJustContent) {
            $folderDestination = $customShareDestination

            " - copying to $folderDestination (in merge mode)"

            $result = _copyFolder -source $folderSource -destination $folderDestination
        } else {
            $folderDestination = Join-Path $customShareDestination $folderName
            $customLogFolder = Join-Path $folderDestination "Log"

            " - copying to $folderDestination (in replace mode)"

            $result = _copyFolder -source $folderSource -destination $folderDestination -excludeFolder $customLogFolder -mirror

            # vytvoreni zanoreneho Log adresare
            if (!(Test-Path $customLogFolder -ea SilentlyContinue)) {
                " - creation of Log folder $customLogFolder"

                New-Item $customLogFolder -ItemType Directory -Force -Confirm:$false
            }
        }

        if ($result.failures) {
            # neskoncim s chybou, protoze se da cekat, ze pri dalsim pokusu uz to projde (ted muze napr bezet skript z teto slozky atp)
            Write-Warning "There was an error when copy $folderName`n$($result.errMsg)"
        }

        # omezeni NTFS prav
        # pozn. nastavuji pokazde, protoze pokud by v customConfig byly nejake cilove stroje definovany promennou, nemam sanci zjistit jestli se jeji obsha odminula nezmenil
        if ($customNTFS -and !$copyJustContent) {
            " - set READ access to accounts in customDestinationNTFS to $folderDestination"
            _setPermissions $folderDestination -readUser $customNTFS -writeUser $writeUser

            " - set FULL CONTROL access to accounts in customDestinationNTFS to $customLogFolder"
            _setPermissions $customLogFolder -readUser $customNTFS -writeUser $writeUser, $customNTFS
        } elseif (!$customNTFS -and !$copyJustContent) {
            # nemaji se nastavit zadna custom prava
            # pro jistotu udelam reset NTFS prav (mohl jsem je jiz v minulosti nastavit)
            # ale pouze pokud na danem adresari najdu read_user ACL == nastavil jsem v minulosti custom prava
            # pozn.: detekuji tedy dle NTFS opravneni (pokud by se nenastavovalo, bude potreba zvolit jinou metodu detekce!)
            $folderhasCustomNTFS = Get-Acl -path $folderDestination | ? { $_.accessToString -like "*$readUser*" }
            if ($folderhasCustomNTFS) {
                " - folder $folderDestination has some custom NTFS even it shouldn't have, resetting"
                _setPermissions -path $folderDestination -resetACL

                " - resetting also on Log subfolder"
                _setPermissions -path $customLogFolder -resetACL
            }
        }
    }
} catch {
    _emailAndExit -body "Hi,`nthere was an error when synchronizing GIT repository to DFS repository share:`n$_"
}