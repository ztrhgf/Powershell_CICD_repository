<#
    Skript slouzi k synchronizaci:
     - PS modulu
     - globalniho PS profilu
     - per server skriptu (obsah Custom)
    z centralniho repozitare do C:\Windows\System32\WindowsPowerShell\v1.0\... v pripade profilu a modulu a C:\Windows\Scripts v pripade per server skriptu.

    Vedle synchronizace dat, skript take nastavuje NTFS prava pro lokalni kopii dat:
     - editovat mohou pouze clenove repo_writer + SYSTEM
     - cist ma pravo skupina repo_reader + Authenticated Users

    U per server (Custom) dat se navic vytvari Log adresar, do nejz muze zapisovat uzivatel zadany v customNTFS parametru (pokud neni, tak clenove Authenticated Users)

    pozn.:
    Skript je urcen pro pravidelne spousteni skrze scheduled task.

    Vyhodou oproti pridani UNC adresare s moduly do $psmodulepath je ten,
    ze moduly jsou dostupne i v remote session a take pod lokalnimi uzivateli (bez pristupu do site),
    navic u nekterych modulu pouzivajicich dll knihovny, byl problem se spoustenim z UNC
#>

#TODONAHRADIT upravte funkci Send-Email aby odpovidala vasemu prostredi, ci uplne zruste jeji pouziti

# pro potreby debugingu odkomentujte
# Start-Transcript -Path "C:\windows\temp\psenv.log" -Force

$ErrorActionPreference = 'stop'

# cesta k DFS repozitari
$repoSrc = "\\TODONAHRADIT" # cesta do centralniho (DFS) repo napr.: \\contoso\repository

# nacteni $config promenne (potreba pro deploy Custom sekce repo)
$customConfig = Join-Path $repoSrc "Custom\customConfig.ps1"

# import promennych
# kvuli Custom sekci (resp. aby slo pouzivat v definici computerName promenne)
# a kvuli specifikovani kam se ma kopirovat profile.ps1
# chybu ignorujeme, protoze na fresh stroji, modul bude az po prvnim spusteni tohoto skriptu, ne driv :)
Import-Module Variables -ErrorAction "Continue"

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
        [Parameter()]
        [string[]] $readUser
        ,
        [Parameter()]
        [string[]] $writeUser
        ,
        [switch] $justGivenUser
    )

    if (!(Test-Path $path)) {
        throw "zadana cesta neexistuje"
    }

    # vytvorim prazdne ACL
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    # zakazani dedeni a odebrani zdedenych prav
    $acl.SetAccessRuleProtection($true, $false)

    if (Test-Path $path -PathType Container) {
        # je to adresar
        $permissions = @()
        $permissions += @(, ("System", "FullControl", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        # hardcoded, abych nastavil skutecne vzdy
        $permissions += @(, ("TODONAHRADITzaNETBIOSVASIDOMENY\repo_reader", "ReadAndExecute", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))

        if (!$justGivenUser) {
            # pristup pro cteni povolim vsem
            $permissions += @(, ("Authenticated Users", "ReadAndExecute", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
        }

        if ($readUser) {
            $readUser | ForEach-Object {
                $permissions += @(, ("$_", "ReadAndExecute", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            }
        }

        if ($writeUser) {
            $writeUser | ForEach-Object {
                $permissions += @(, ("$_", "Modify", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            }
        }
    } else {
        # je to soubor
        $permissions = @()
        $permissions += @(, ("System", "FullControl", 'Allow'))
        # hardcoded, abych nastavil skutecne vzdy
        $permissions += @(, ("TODONAHRADITzaNETBIOSVASIDOMENY\repo_reader", "ReadAndExecute", 'Allow'))

        if (!$justGivenUser) {
            # pristup pro cteni povolim vsem
            $permissions += @(, ("Authenticated Users", "ReadAndExecute", 'Allow'))
        }

        if ($readUser) {
            $readUser | ForEach-Object {
                $permissions += @(, ("$_", "ReadAndExecute", 'Allow'))
            }
        }

        if ($writeUser) {
            $writeUser | ForEach-Object {
                $permissions += @(, ("$_", "Modify", 'Allow'))
            }
        }
    }

    $permissions | ForEach-Object {
        $ace = New-Object System.Security.AccessControl.FileSystemAccessRule $_
        $acl.AddAccessRule($ace)
    }

    # nastaveni ACL
    try {
        Set-Acl -Path $path -AclObject $acl -ea stop
    } catch {
        throw "nepodarilo se nastavit opravneni: $_"
    }

    # reset ACL na obsahu slozky (pro pripad, ze nekdo upravil NTFS prava)
    # pozn. ownership nemenim
    if (Test-Path $path -PathType Container) {
        #Start the job that will reset permissions for each file, don't even start if there are no direct sub-files
        $SubFiles = Get-ChildItem $Path -File
        If ($SubFiles) {
            Start-Job -ScriptBlock { $args[0] | ForEach-Object { icacls.exe $_.FullName /Reset /C } } -ArgumentList $SubFiles
        }

        #Now go through each $Path's direct folder (if there's any) and start a process to reset the permissions, for each folder.
        $SubFolders = Get-ChildItem $Path -Directory
        If ($SubFolders) {
            Foreach ($SubFolder in $SubFolders) {
                #Start a process rather than a job, icacls should take way less memory than Powershell+icacls
                Start-Process icacls -WindowStyle Hidden -ArgumentList """$($SubFolder.FullName)"" /Reset /T /C" -PassThru
            }
        }
    }
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
[string] $readUser = "TODONAHRADITzaNETBIOSVASIDOMENY\repo_reader"
# skupina ktera ma pravo editovat obsah DFS repozitare (i lokalni kopie)
[string] $writeUser = "TODONAHRADITzaNETBIOSVASIDOMENY\repo_writer"

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
                "mazu $_"
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

        Set-Permissions $moduleDstPath -readUser $readUser -writeUser $writeUser
    }
}



#
# SYNCHRONIZACE PS PROFILU
#

$profileSrc = Join-Path $repoSrc "profile.ps1"
$profileDst = Join-Path $env:systemroot "System32\WindowsPowerShell\v1.0\profile.ps1"
$profileDstFolder = Split-Path $profileDst -Parent
# dle NTFS poznam, zdali byl profil nakopirovan timto skriptem
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
                Set-Permissions $profileDst -readUser $readUser -writeUser $writeUser
            }
        } else {
            # soubor v cili neexistuje, nakopiruji
            "nakopiruji {0} do {1}" -f $profileSrc, $profileDstFolder
            Copy-Item $profileSrc $profileDstFolder -Force -Confirm:$false
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

V kazdem adresari (folderName) se na klientovi automaticky navic vytvori Log adresar s modify pravy (pro ucet v customNTFS nebo Auth users), aby skripty mohly logovat sve vystupy.
Log adresar se ignoruje pri porovnavani obsahu remote repo vs lokalni kopie a pri synchronizaci zmen je zachovan.
!!! pokud spoustene skripty generuji nejake soubory, at je ukladaji do tohoto Log adresare, jinak dojde pri kazde synchronizaci s remote repo ke smazani teto slozky (porovnavam velikosti adresaru v repo a lokalu)
#>


#
# nactu promennou $config
# schvalne definuji v samostatnem souboru kvuli lepsi prehlednosti a editovatelnosti
if (!(Test-Path $customConfig -ErrorAction SilentlyContinue)) {
    Import-Module Scripts -Function Send-Email
    Send-Email -subject "Sync of PS scripts: Custom" -body "Hi,`non $env:COMPUTERNAME script $($MyInvocation.ScriptName) detected missing config file $customConfig. Even if you do not want to copy any Custom folders to any server, create empty $customConfig."
    throw "Missing Custom config file"
}

# nactu customConfig.ps1 skript respektive $config promennou v nem definovanou
. $customConfig

# zdrojova slozka custom dat
$customSrcFolder = Join-Path $repoSrc "Custom"
# cilova slozka custom dat
$customDstFolder = Join-Path $env:systemroot "Scripts"

$hostname = $env:COMPUTERNAME
# vyfiltruji z $config pouze objekty odpovidajici tomuto stroji
$thisPCCustom = @()
# jake Custom slozky se maji kopirovat na tento stroj
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
        $customNTFS = $_.customNTFS
        # $customNTFSWithoutDomain = ($customNTFS -split "\\")[-1]
        if ($customNTFS) {
            if ($customNTFS.getType().name -ne "String") {
                Import-Module Scripts -Function Send-Email
                Send-Email -subject "Sync of PS scripts: Multiple accounts defined" -body "Hi,`nin `$config configuration it is forbidden to define multiple customNTFS accounts!`nSynchronization of $folderSrcPath will not work until you solve this problem."
                throw "Multiple accounts in `$customNTFS"
            }
        }

        # nakopirovani
        $change = 0
        if (Test-Path $folderDstPath -ea SilentlyContinue) {
            # adresar v cili jiz existuje
            # jestli je potreba provest jeji zmeny necham posoudit robocopy

            # Log adresar nechci pri mirroru smazat, proto exclude
            $excludeFolder = Join-Path $folderDstPath "Log"
            "nakopiruji {0} do {1}" -f $folderSrcPath, $folderDstPath
            $result = Copy-Folder $folderSrcPath $folderDstPath -mirror -excludeFolder $excludeFolder

            # vypisi smazane soubory
            if ($result.deleted) {
                Write-Output "Smazal jsem jiz nepotrebne soubory:`n$(($result.deleted) -join "`n")"
            }

            if ($result.failures) {
                # neskoncim s chybou, protoze se da cekat, ze pri dalsim pokusu uz to projde (ted muze napr bezet skript z teto slozky atp)
                "Pri kopirovani $folderSrcPath se vyskytl problem`n$($result.errMsg)"
            }

            if ($result.copied) {
                ++$change
            }

        } else {
            # adresar v cili neexistuje, nakopiruji
            "nakopiruji {0} do {1}" -f $folderSrcPath, $folderDstPath
            $result = Copy-Folder $folderSrcPath $folderDstPath

            if ($result.failures) {
                throw "Pri kopirovani $folderSrcPath do $folderDstPath se vyskytl problem`n$($result.errMsg)"
            }

            ++$change
        }

        #
        # doslo ke zmene v Custom datech == nastavim znovu NTFS prava
        if ($change) {
            $permParam = @{path = $folderDstPath; readUser = $readUser, "Administrators"; writeUser = $writeUser, "Administrators" }
            if ($customNTFS) {
                $permParam.readUser = $customNTFS, "Administrators"
                $permParam.justGivenUser = $true
            }

            try {
                Set-Permissions @permParam
            } catch {
                Import-Module Scripts -Function Send-Email
                Send-Email -subject "Sync of PS scripts: Set permission error" -body "Hi,`nthere was failure:`n$_`n`n when set up permission (read: $readUser, write: $writeUser) on folder $folderDstPath"
                throw "NTFS permission set up failure (read: $readUser, write: $writeUser) on $folderDstPath"
            }
        }

        #
        # vytvorim navic Log adresar a nastavim na nem Modify pro ucet v customNTFS ci Authenticated Users
        # aby Custom skripty mohly i pres omezena NTFS prava logovat svuj vystup
        $logFolder = Join-Path $folderDstPath "Log"

        if (!(Test-Path $logFolder -ErrorAction SilentlyContinue)) {
            ++$logDidntExist
            New-Item $logFolder -ItemType Directory -Force -Confirm:$false
        }

        # doslo ke zmene v Custom datech == doslo k resetu NTFS na celem obsahu == nastavim znovu NTFS prava na Log adresari
        if ($logDidntExist -or $change) {
            $permParam = @{ path = $logFolder; readUser = $readUser; writeUser = $writeUser }
            if ($customNTFS) {
                $permParam.readUser = "Administrators"
                $permParam.writeUser = $customNTFS, "Administrators"
                $permParam.justGivenUser = $true
            } else {
                # nezadal custom ucet tzn nevim pod kym to pobezi tzn nastavim write pro Authenticated Users
                $permParam.writeUser = $permParam.writeUser, "Authenticated Users"
            }

            try {
                Set-Permissions @permParam
            } catch {
                Import-Module Scripts -Function Send-Email
                Send-Email -subject "Sync of PS scripts: Set permission error" -body "Hi,`nthere was failure:`n$_`n`n when set up permission (read: $readUser, write: $writeUser) on folder $logFolder"
                throw "NTFS permission set up failure (read: $readUser, write: $writeUser) on $logFolder"
            }
        }
    }
} # konec nakopirovani pozadovanych Custom slozek