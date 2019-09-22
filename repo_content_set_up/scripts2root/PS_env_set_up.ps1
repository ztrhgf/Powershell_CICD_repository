<#
    .SYNOPSIS
    Skript slouzi k synchronizaci:
     - PS modulu
     - globalniho PS profilu
     - per server skriptu (obsah Custom)
    z centralniho repozitare do C:\Windows\System32\WindowsPowerShell\v1.0\... v pripade profilu a modulu a C:\Windows\Scripts v pripade per server skriptu.

    Vedle synchronizace dat, skript take nastavuje NTFS prava pro lokalni kopii dat:
     - editovat mohou pouze clenove repo_writer + SYSTEM
     - cist ma pravo skupina repo_reader + Authenticated Users

    U per server (Custom) dat se navic vytvari Log adresar, do nejz muze zapisovat uzivatel zadany v customDestinationNTFS parametru (a pokud neni, tak clenove Authenticated Users)
    Skript je urcen pro pravidelne spousteni skrze scheduled task.

    Vyhodou oproti pridani UNC adresare s moduly do $psmodulepath je ten,
    ze moduly jsou dostupne i v remote session a take pod lokalnimi uzivateli (bez pristupu do site),
    navic u nekterych modulu pouzivajicich dll knihovny, byl problem se spoustenim z UNC

    
    .NOTES
    Author: Ondřej Šebela - ztrhgf@seznam.cz
#>

#TODONAHRADIT upravte funkci Send-Email aby odpovidala vasemu prostredi, ci uplne zruste jeji pouziti


# pro lepsi debugging
Start-Transcript -Path "$env:SystemRoot\temp\PS_env_set_up.log" -Force

$ErrorActionPreference = 'stop'
# cesta k DFS repozitari
$repoSrc = "\\TODONAHRADIT" # cesta do centralniho (DFS) repo napr.: \\contoso\repository


# pokud prestanu nastavovat specificka prava pro vybranou AD skupinu, bude potreba upravit detekci techto custom modulu viz nize!
function Set-Permissions {
    <#
    dle readUser detekuji moduly, ktere jsem nakopiroval timto sync skriptem

    pokud uzivatel nema pristup k jednomu z modulu v "System32\WindowsPowerShell\v1.0\Modules\", tak se nenactou zadne moduly z tohoto adresare!
    #>
    [cmdletbinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string] $path
        ,
        $readUser
        ,
        $writeUser
        ,
        [switch] $justGivenUser
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

            $permissions += @(, ("System", "FullControl", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            # hardcoded, abych nastavil skutecne vzdy
            $permissions += @(, ("repo_reader", "ReadAndExecute", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))

            if (!$justGivenUser) {
                # pristup pro cteni povolim vsem
                $permissions += @(, ("Authenticated Users", "ReadAndExecute", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            }

            $readUser | ForEach-Object {
                $permissions += @(, ("$_", "ReadAndExecute", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            }

            $writeUser | ForEach-Object {
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

            $permissions += @(, ("System", "FullControl", 'Allow'))
            # hardcoded, abych nastavil skutecne vzdy
            $permissions += @(, ("repo_reader", "ReadAndExecute", 'Allow'))

            if (!$justGivenUser) {
                # pristup pro cteni povolim vsem
                $permissions += @(, ("Authenticated Users", "ReadAndExecute", 'Allow'))
            }

            $readUser | ForEach-Object {
                $permissions += @(, ("$_", "ReadAndExecute", 'Allow'))
            }

            $writeUser | ForEach-Object {
                $permissions += @(, ("$_", "FullControl", 'Allow'))
            }
        }
    }

    $permissions | ForEach-Object {
        $ace = New-Object System.Security.AccessControl.FileSystemAccessRule $_
        $acl.AddAccessRule($ace)
    }

    # nastaveni ACL
    try {
        # Set-Acl nejde pouzit protoze bug https://stackoverflow.com/questions/31611103/setting-permissions-on-a-windows-fileshare
        (Get-Item $path).SetAccessControl($acl)
    } catch {
        throw "nepodarilo se nastavit opravneni: $_"
    }

    # reset ACL na obsahu slozky (pro pripad, ze nekdo upravil NTFS prava)
    # pozn. ownership nemenim
    #TODO nekdy se na tomto kroku zaseklo, odkomentovat po vyreseni
    # if (Test-Path $path -PathType Container) {
    #     # Start the job that will reset permissions for each file, don't even start if there are no direct sub-files
    #     $SubFiles = Get-ChildItem $Path -File
    #     If ($SubFiles) {
    #         Start-Job -ScriptBlock { $args[0] | ForEach-Object { icacls.exe $_.FullName /Reset /C } } -ArgumentList $SubFiles
    #     }

    #     # Now go through each $Path's direct folder (if there's any) and start a process to reset the permissions, for each folder.
    #     $SubFolders = Get-ChildItem $Path -Directory
    #     If ($SubFolders) {
    #         Foreach ($SubFolder in $SubFolders) {
    #             # Start a process rather than a job, icacls should take way less memory than Powershell+icacls
    #             Start-Process icacls -WindowStyle Hidden -ArgumentList """$($SubFolder.FullName)"" /Reset /T /C" -PassThru
    #         }
    #     }
    # }
}

Function Copy-Folder {
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



#
# SYNCHRONIZACE MODULU
#

$moduleSrcFolder = Join-Path $repoSrc "modules"
$moduleDstFolder = Join-Path $env:systemroot "System32\WindowsPowerShell\v1.0\Modules\"
# skupina ktera ma pravo cist obsah DFS repozitare (i lokalni kopie)
# zaroven pouzivam pro detekci, co jsem nakopiroval timto skriptem == NERUSIT (nebo adekvatne upravit cely skript)
# PRI ZMENE ZMENIT I V SET-PERMISSIONS kde je hardcoded, aby i nadale fungovala spravne detekce
[string] $readUser = "repo_reader"
# skupina ktera ma pravo editovat obsah DFS repozitare (i lokalni kopie)
[string] $writeUser = "repo_writer"

if (!(Test-Path $moduleSrcFolder -ErrorAction SilentlyContinue)) {
    throw "Cesta s moduly ($moduleSrcFolder) neni dostupna!"
}

#
# smazani lokalnich souboru/slozek, ktere jiz v centralnim repo neexistuji
if (Test-Path $moduleDstFolder -ea SilentlyContinue) {
    # dohledam soubory/slozky, ktere jsem v minulosti nakopiroval do cilove slozky
    # pozn.: poznam je dle NTFS opravneni (pokud by se nenastavovalo, bude potreba zvolit jinou metodu detekce!)
    $repoModuleInDestination = Get-ChildItem $moduleDstFolder -Directory | Get-Acl | Where-Object { $_.accessToString -like "*$readUser*" } | Select-Object -exp PSChildName
    if ($repoModuleInDestination) {
        $sourceModuleName = @((Get-ChildItem $moduleSrcFolder -Directory).Name)

        $repoModuleInDestination | ForEach-Object {
            if ($sourceModuleName -notcontains $_) {
                "mazu nadbytecny modul $_"
                Remove-Item (Join-Path $moduleDstFolder $_) -Force -Confirm:$false -Recurse
            }
        }
    }
}

#
# nakopirovani zmenenych PS modulu (po celych adresarich)
Get-ChildItem $moduleSrcFolder -Directory | ForEach-Object {
    $moduleDstPath = Join-Path $moduleDstFolder $_.Name

    if (Test-Path $moduleDstPath -ea SilentlyContinue) {
        # kopirovany modul jiz v cili existuje
        # jestli je potreba provest nejake zmeny necham posoudit robocopy
        try {
            "nakopiruji {0} do {1}" -f $_.FullName, $moduleDstPath

            $result = Copy-Folder $_.FullName $moduleDstPath -mirror

            if ($result.failures) {
                # neskoncim s chybou, protoze se da cekat, ze pri dalsim pokusu uz to projde (ted muze napr bezet skript z teto slozky atp)
                "Pri kopirovani $($_.FullName) se vyskytl problem`n$($result.errMsg)"
            }

            if ($result.copied) {
                "nastavuji NTFS prava"
                Set-Permissions $moduleDstPath -readUser $readUser -writeUser $writeUser
            }
        } catch {
            "nepovedlo se zesynchronizovat $moduleDstPath, chyba byla`n$_"
        }
    } else {
        # modul v cili neexistuje, nakopiruji
        "nakopiruji {0} do {1}" -f $_.FullName, $moduleDstPath
        $result = Copy-Folder $_.FullName $moduleDstPath

        if ($result.failures) {
            # neskoncim s chybou, protoze se da cekat, ze pri dalsim pokusu uz to projde (ted muze napr bezet skript z teto slozky atp)
            "Pri kopirovani $($_.FullName) se vyskytl problem`n$($result.errMsg)"
        }

        "nastavuji NTFS prava"
        Set-Permissions $moduleDstPath -readUser $readUser -writeUser $writeUser
    }
}




#
# IMPORT PROMENNYCH
#

# kvuli Custom sekci (resp. aby slo pouzivat v definici computerName promenne) a kvuli specifikovani kam se ma kopirovat profile.ps1
# chybu ignorujeme, protoze na fresh stroji, modul bude az po prvnim spusteni tohoto skriptu, ne driv :)
# pozn.: import delam az po nakopirovani aktualizovanych modulu, abych pracoval s nejnovejsimi daty
Import-Module Variables -ErrorAction "Continue"




#
# SYNCHRONIZACE PS PROFILU
#

$profileSrc = Join-Path $repoSrc "profile.ps1"
$profileDst = Join-Path $env:systemroot "System32\WindowsPowerShell\v1.0\profile.ps1"
$profileDstFolder = Split-Path $profileDst -Parent
$isOurProfile = Get-Acl -Path $profileDst -ea silentlyContinue | Where-Object { $_.accessToString -like "*$readUser*" }

if (Test-Path $profileSrc -ea SilentlyContinue) {
    # v DFS repo je soubor profile.ps1
    if ($env:COMPUTERNAME -in $computerWithProfile) {
        # profile.ps1 se ma na tento stroj nakopirovat
        if (Test-Path $profileDst -ea SilentlyContinue) {
            # kopirovany soubor jiz v cili existuje, zkontroluji zdali nedoslo ke zmene

            # porovnani dle velikosti neni dobre, protoze neakcentuje drobne upravy
            $sourceModified = (Get-Item $profileSrc).LastWriteTime
            $destinationModified = (Get-Item $profileDst).LastWriteTime
            # doslo ke zmene, nahradim stary za novy
            if ($sourceModified -ne $destinationModified) {
                "nakopiruji {0} do {1}" -f $profileSrc, $profileDstFolder
                Copy-Item $profileSrc $profileDstFolder -Force -Confirm:$false
                "nastavuji NTFS prava"
                Set-Permissions $profileDst -readUser $readUser -writeUser $writeUser
            }
        } else {
            # soubor v cili neexistuje, nakopiruji
            "nakopiruji {0} do {1}" -f $profileSrc, $profileDstFolder
            Copy-Item $profileSrc $profileDstFolder -Force -Confirm:$false
            "nastavuji NTFS prava"
            Set-Permissions $profileDst -readUser $readUser -writeUser $writeUser
        }
    } else {
        # profile.ps1 se nema na tento stroj kopirovat
        if ((Test-Path $profileDst -ea SilentlyContinue) -and $isOurProfile) {
            # je ale nakopirovan lokalne a nakopiroval jej tento skript == smazu
            "smazu $profileDst"
            Remove-Item $profileDst -force -confirm:$false
        }
    }
} else {
    # v DFS repo neni soubor profile.ps1
    if ((Test-Path $profileDst -ea SilentlyContinue) -and ($env:COMPUTERNAME -in $computerWithProfile) -and $isOurProfile) {
        # je ale nakopirovan lokalne a nakopiroval jej tento skript == smazu
        "smazu $profileDst"
        Remove-Item $profileDst -force -confirm:$false
    }
}



#
# SYNCHRONIZACE PER SERVER DAT (obsah slozky Custom)
#

<#
Custom adresar v repozitari obsahuje slozky, ktere se maji kopirovat JEN NA VYBRANE stroje.
To na jake stroje se budou kopirovat, je receno v promenne $config, ktera je definovana v customConfig.ps1!
Data se na klientech kopiruji do C:\Windows\Scripts\

V kazdem adresari (folderName) se na klientovi automaticky navic vytvori Log adresar s modify pravy (pro customDestinationNTFS nebo Auth users), aby skripty mohly logovat sve vystupy.
Log adresar se ignoruje pri porovnavani obsahu remote repo vs lokalni kopie a pri synchronizaci zmen je zachovan.
!!! pokud spoustene skripty generuji nejake soubory, at je ukladaji do tohoto Log adresare, jinak dojde pri kazde synchronizaci s remote repo ke smazani teto slozky (porovnavam velikosti adresaru v repo a lokalu)
#>

$customConfig = Join-Path $repoSrc "Custom\customConfig.ps1"

if (!(Test-Path $customConfig -ErrorAction SilentlyContinue)) {
    Import-Module Scripts -Function Send-Email
    Send-Email -subject "Sync of PS scripts: Custom" -body "Hi,`non $env:COMPUTERNAME script $($MyInvocation.ScriptName) detected missing config file $customConfig. Event if you do not want to copy any Custom folders to any server, create empty $customConfig."
    throw "Missing Custom config file"
}

# nactu customConfig.ps1 skript respektive $config promennou v nem definovanou
# nastaveni Custom sekce schvalne definuji v samostatnem souboru kvuli lepsi prehlednosti a editovatelnosti
"zpristupnim `$config promennou"
. $customConfig

# zdrojova slozka custom dat
$customSrcFolder = Join-Path $repoSrc "Custom"
# cilova slozka custom dat
$customDstFolder = Join-Path $env:systemroot "Scripts"


#
# zjistim, u kterych Custom slozek, je uvedeny tento stroj
$hostname = $env:COMPUTERNAME
$thisPCCustom = @()
$thisPCCustFolder = @()

$config | ForEach-Object {
    if ($hostname -in $_.computerName) {
        $thisPCCustom += $_
        $thisPCCustFolder += $_.folderName
    }
}

#
# odstraneni jiz nepotrebnych Custom slozek
Get-ChildItem $customDstFolder -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $folder = $_
    if ($folder.name -notin $thisPCCustFolder) {

        try {
            "mazu jit nepotrebnou $($folder.FullName)"
            Remove-Item $folder.FullName -Recurse -Force -Confirm:$false -ErrorAction Stop
            # obsah adresare muze byt zrovna pouzivan == nepovede se jej smazat == email poslu pouze pokud se povedlo
            Import-Module Scripts -Function Send-Email
            Send-Email -subject "Sync of PS scripts: Deletion of useless folder" -body "Hi,`non $env:COMPUTERNAME script $($MyInvocation.ScriptName) deleted folder $($folder.FullName), because it is no more required here."
        } catch {
            "nepovedlo se smazat $($folder.FullName), chyba byla`n$_"
        }
    }
}


#
# nakopirovani pozadovanych Custom slozek z repozitare
if ($thisPCCustom) {
    [Void][System.IO.Directory]::CreateDirectory("$customDstFolder")

    $thisPCCustom | ForEach-Object {
        $folderSrcPath = Join-Path $customSrcFolder $_.folderName
        $folderDstPath = Join-Path $customDstFolder $_.folderName

        # zmenim cilove umisteni, pokud vyzadovano
        if ($_.customLocalDestination) {
            if ($_.copyJustContent) {
                $folderDstPath = $_.customLocalDestination
            } else {
                $folderDstPath = Join-Path $_.customLocalDestination $_.folderName
            }

            [Void][System.IO.Directory]::CreateDirectory("$folderDstPath")
        }

        # kontrola, ze existuje zdrojovy adresar (to ze je v config neznamena, ze realne existuje)
        if (!(Test-Path $folderSrcPath -ErrorAction SilentlyContinue)) {
            Import-Module Scripts -Function Send-Email
            Send-Email -subject "Sync of PS scripts: Missing folder" -body "Hi,`non $env:COMPUTERNAME it is not possible to copy $folderSrcPath, because it does not exist.`nSynchronization will not work until you solve this problem."
            throw "Non existing source folder $folderSrcPath"
        }

        # kontrola, ze neexistuje ve zdrojovem adresari Log adresar (ten vytvarime az lokalne na strojich a nepocitam s variantou, ze by se nasynchronizoval z repo)
        if (Test-Path (Join-Path $folderSrcPath "Log") -ErrorAction SilentlyContinue) {
            Import-Module Scripts -Function Send-Email
            Send-Email -subject "Sync of PS scripts: Existing Log folder" -body "Hi,`nin $folderSrcPath exist folder 'Log' which is not supported. Delete it.`nSynchronization will not work until you solve this problem."
            throw "Existing Log folder in $folderSrcPath"
        }

        # kontrola, ze zadany account jde na danem stroji pouzit
        $customNTFS = $_.customDestinationNTFS
        # $customNTFSWithoutDomain = ($customNTFS -split "\\")[-1]
        if ($customNTFS) {
            #TODO toto nelze pouzit pro gMSA ucty, upravit
            # if (!(Get-WmiObject -Class win32_userAccount -Filter "name=`'$customNTFSWithoutDomain`'")) {
            #     Import-Module Scripts -Function Send-Email
            #     Send-Email -subject "Sync of PS scripts: Missing account" -body "Hi,`non $env:COMPUTERNAME it is not possible to grant NTFS permission to $folderDstPath to account $customNTFS. Is `$config configuration correct?`nSynchronization of $folderSrcPath will not work until you solve this problem."
            #     throw "Non existing account $customNTFS"
            # }
        }

        $change = 0
        $customLogFolder = Join-Path $folderDstPath "Log"

        #
        # nakopiruji Custom slozku do zadaneho cile
        if ($_.copyJustContent) {
            # kopiruji pouze obsah slozky
            # nemohu tak pouzit robocopy mirror, protoze se da cekat, ze v cili budou i jine soubory
            "nakopiruji {0} do {1}" -f $folderSrcPath, $folderDstPath
            $result = Copy-Folder $folderSrcPath $folderDstPath
        } else {
            # kopiruji celou slozku
            "nakopiruji {0} do {1}" -f $folderSrcPath, $folderDstPath
            $result = Copy-Folder $folderSrcPath $folderDstPath -mirror -excludeFolder $customLogFolder

            # vypisi smazane soubory
            if ($result.deleted) {
                "Smazal jsem jiz nepotrebne soubory:`n$(($result.deleted) -join "`n")"
            }
        }

        if ($result.failures) {
            # neskoncim s chybou, protoze se da cekat, ze pri dalsim pokusu uz to projde (ted muze napr bezet skript z teto slozky atp)
            "Pri kopirovani $folderSrcPath se vyskytl problem`n$($result.errMsg)"
        }

        if ($result.copied) {
            ++$change
        }

        #
        # vytvorim Log adresar pokud dava smysl
        if (!$_.copyJustContent -or ($_.copyJustContent -and !$_.customLocalDestination)) {
            [Void][System.IO.Directory]::CreateDirectory("$customLogFolder")
        }

        #
        # nastavim NTFS prava
        # delam pokazde (commit mohl zmenit customDestinationNTFS aniz by se zmenil obsah slozky, tzn nelze menit pouze pri zmene dat
        # pokud zadana custom destinace, nastavim prava pouze pokud je definovano customDestinationNTFS a zaroven nekopiruji pouze obsah slozky (bylo by slozite/pomale/kontraproduktivni?!)
        if (!($_.customLocalDestination) -or ($_.customLocalDestination -and $_.customDestinationNTFS -and !($_.copyJustContent))) {
            $permParam = @{path = $folderDstPath; readUser = $readUser, "Administrators"; writeUser = $writeUser, "Administrators" }
            if ($customNTFS) {
                $permParam.readUser = "Administrators", $customNTFS
                $permParam.justGivenUser = $true
            }

            try {
                "nastavim prava na $folderDstPath"
                Set-Permissions @permParam
            } catch {
                Import-Module Scripts -Function Send-Email
                Send-Email -subject "Sync of PS scripts: Set permission error" -body "Hi,`nthere was failure:`n$_`n`n when set up permission (read: $readUser, write: $writeUser) on folder $folderDstPath"
                throw "NTFS permission set up failure (read: $readUser, write: $writeUser) on $folderDstPath"
            }

            # nastavim i na Log podadresari
            $permParam = @{ path = $customLogFolder; readUser = $readUser; writeUser = $writeUser }
            if ($customNTFS) {
                $permParam.readUser = "Administrators"
                $permParam.writeUser = "Administrators", $customNTFS
                $permParam.justGivenUser = $true
            } else {
                # nezadal custom ucet tzn nevim pod kym to pobezi tzn nastavim write pro Authenticated Users
                $permParam.writeUser = $permParam.writeUser, "Authenticated Users"
            }

            try {
                "nastavim prava na $customLogFolder"
                Set-Permissions @permParam
            } catch {
                Import-Module Scripts -Function Send-Email
                Send-Email -subject "Sync of PS scripts: Set permission error" -body "Hi,`nthere was failure:`n$_`n`n when set up permission (read: $readUser, write: $writeUser) on folder $customLogFolder"
                throw "NTFS permission set up failure (read: $readUser, write: $writeUser) on $customLogFolder"
            }

        } elseif ($_.customLocalDestination -and !$_.customDestinationNTFS -and !$_.copyJustContent) {
            #FIXME otestovat
            # nemaji se nastavit zadna custom prava
            # pro jistotu udelam reset NTFS prav (mohl jsem je jiz v minulosti nastavit)
            # ale pouze pokud na danem adresari najdu read_user ACL == nastavil jsem v minulosti custom prava
            # pozn.: detekuji tedy dle NTFS opravneni (pokud by se nenastavovalo, bude potreba zvolit jinou metodu detekce!)
            $folderhasCustomNTFS = Get-Acl -path $folderDstPath | ? { $_.accessToString -like "*$readUser*" }
            if ($folderhasCustomNTFS) {
                "adresar $folderDstPath ma custom NTFS i kdyz je jiz nema mit, zresetuji NTFS prava"
                Set-Permissions -path $folderDstPath -resetACL

                "zresetuji i na Log podadresari"
                Set-Permissions -path $customLogFolder -resetACL
            }
        }
    }
} # konec nakopirovani pozadovanych Custom slozek