#Requires -Version 3.0

<#
    .SYNOPSIS
    Script is used to synchronize:
     - PS modules
     - global PS profile
     - per server scripts/data (content of Custom)
    from DFS share (repository) to client:
     - C:\Windows\System32\WindowsPowerShell\v1.0\... in case of profile and modules and generally to C:\Windows\Scripts in case of Custom per server files.

    Script should be regularly run through scheduled task created by PS_env_set_up GPO

    Moreover script configures NTFS access to these locally copied data:
     - edit content can just members of group repo_writer + SYSTEM
     - read can just members of group repo_reader + Authenticated Users

    In case of per server data (Custom), script furthemore create Log subfolder, which must be used for any additional content which will be created on client itself. To this Log folder can write just accounts defined in customDestinationNTFS key and if not defined members of Authenticated Users.
    
    .NOTES
    Author: Ondřej Šebela - ztrhgf@seznam.cz
#>

#__TODO__ modify function Send-Email to suit your company environment or comment its usage here


# for debugging purposes
Start-Transcript -Path "$env:SystemRoot\temp\PS_env_set_up.log" -Force

$ErrorActionPreference = 'stop'

# UNC path to (DFS) repository ie \\someDomain\DFS\repository
$repoSrc = "\\__TODO__"

# skupina ktera ma pravo cist obsah DFS repozitare (i lokalni kopie)
# zaroven pouzivam pro detekci, co jsem nakopiroval timto skriptem == NERUSIT (nebo adekvatne upravit cely skript)
# PRI ZMENE ZMENIT I V SET-PERMISSIONS kde je hardcoded, aby i nadale fungovala spravne detekce
[string] $readUser = "repo_reader"
# skupina ktera ma pravo editovat obsah DFS repozitare (i lokalni kopie)
[string] $writeUser = "repo_writer"

"start synchronizing data from $repoSrc"

$hostname = $env:COMPUTERNAME

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
        throw "Path isn't accessible"
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
        throw "There was an error when setting NTFS rights: $_"
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

function Copy-Folder {
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

function Send-EmailAndFail {
    param ([string] $subject, [string] $body, [string] $throw)

    $subject2 = "Sync of PS scripts on $env:COMPUTERNAME: " + $subject
    $body2 = "Hi,`n" + $body

    Import-Module Scripts -Function Send-Email

    Send-Email -subject $subject2 -body $body2

    if (!$throw) { $throw = $body }
    throw $throw
}

function Send-EmailAndContinue {
    param ([string] $subject, [string] $body)

    $subject = "Sync of PS scripts on $env:COMPUTERNAME: " + $subject
    $body = "Hi,`n" + $body

    Import-Module Scripts -Function Send-Email

    Send-Email -subject $subject -body $body
}





#
# IMPORT PROMENNYCH z Variables modulu
#

# kvuli Custom sekci (resp. aby slo pouzivat v definici computerName promenne) a kvuli specifikovani kam se ma kopirovat profile.ps1
# chybu ignorujeme, protoze na fresh stroji, modul bude az po prvnim spusteni tohoto skriptu, ne driv :)
# pozn.: importuji z DFS share, abych pracoval s nejnovejsimi daty
try {
    Import-Module (Join-Path $repoSrc "modules\Variables") -ErrorAction Stop
} catch {
    # pokud selze, zkusim pouzit lokalni kopii modulu Variables
    # muze napr selhat, protoze je umisteno v share
    "Module Variables cannot be loaded from DFS, trying to use local copy"
    Import-Module "Variables" -ErrorAction SilentlyContinue
}




#
# SYNCHRONIZACE MODULU
#

$moduleSrcFolder = Join-Path $repoSrc "modules"
$moduleDstFolder = Join-Path $env:systemroot "System32\WindowsPowerShell\v1.0\Modules\"

if (!(Test-Path $moduleSrcFolder -ErrorAction SilentlyContinue)) {
    throw "Path with modules ($moduleSrcFolder) isn't accessible!"
}

$customModulesScript = Join-Path $moduleSrcFolder "modulesConfig.ps1"

# nactu modulesConfig.ps1 skript respektive $modulesConfig promennou v nem definovanou
# schvalne definuji v samostatnem souboru kvuli lepsi prehlednosti a editovatelnosti
try {
    "Dot sourcing of modulesConfig.ps1 (to import variable `$modulesConfig)"
    . $customModulesScript
} catch {
    "There was an error when dot sourcing $customModulesScript"
    "Error was $_"
}

# jmena modulu, ktere maji omezeno, kam se maji kopirovat
$customModules = @()
# jmena modulu, ktere se maji kopirovat na tento stroj
$thisPCModules = @()

$modulesConfig | ForEach-Object {
    $customModules += $_.folderName

    if ($hostname -in $_.computerName) {
        $thisPCModules += $_.folderName
    }
}


#
# nakopirovani zmenenych PS modulu (po celych adresarich)
foreach ($module in (Get-ChildItem $moduleSrcFolder -Directory)) {
    $moduleName = $module.Name

    if ($moduleName -notin $customModules -or ($moduleName -in $customModules -and $moduleName -in $thisPCModules)) {
        $moduleDstPath = Join-Path $moduleDstFolder $moduleName
        # jestli je potreba provest nejake zmeny necham posoudit robocopy
        try {
            "Copying module {0}" -f $moduleName

            $result = Copy-Folder $module.FullName $moduleDstPath -mirror

            if ($result.failures) {
                # neskoncim s chybou, protoze se da cekat, ze pri dalsim pokusu uz to projde (ted muze napr bezet skript z teto slozky atp)
                "There was an error when copying $($module.FullName)`n$($result.errMsg)"
            }

            if ($result.copied) {
                "Change detected, setting NTFS rights"
                Set-Permissions $moduleDstPath -readUser $readUser -writeUser $writeUser
            }
        } catch {
            "There was an error when copying $moduleDstPath, error was`n$_"
        }
    } else {
        "Module $moduleName shouldn't be copied to this computer"
    }
}





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
                "Copying global PS profile to {0}" -f $profileDstFolder
                Copy-Item $profileSrc $profileDstFolder -Force -Confirm:$false
                "Setting NTFS rights to $profileDst"
                Set-Permissions $profileDst -readUser $readUser -writeUser $writeUser
            }
        } else {
            # soubor v cili neexistuje, nakopiruji
            "Copying global PS profile to {0}" -f $profileDstFolder
            Copy-Item $profileSrc $profileDstFolder -Force -Confirm:$false
            "Setting NTFS rights to $profileDst"
            Set-Permissions $profileDst -readUser $readUser -writeUser $writeUser
        }
    } else {
        # profile.ps1 se nema na tento stroj kopirovat
        if ((Test-Path $profileDst -ea SilentlyContinue) -and $isOurProfile) {
            # je ale nakopirovan lokalne a nakopiroval jej tento skript == smazu
            "Deleting $profileDst"
            Remove-Item $profileDst -force -confirm:$false
        }
    }
} else {
    # v DFS repo neni soubor profile.ps1
    if ((Test-Path $profileDst -ea SilentlyContinue) -and ($env:COMPUTERNAME -in $computerWithProfile) -and $isOurProfile) {
        # je ale nakopirovan lokalne a nakopiroval jej tento skript == smazu
        "Deleting $profileDst"
        Remove-Item $profileDst -force -confirm:$false
    }
}



#
# SYNCHRONIZACE CUSTOM DAT
#

<#
Custom adresar v repozitari obsahuje slozky, ktere se maji kopirovat JEN NA VYBRANE stroje.
To na jake stroje se budou kopirovat, je receno v promenne $customConfig, ktera je definovana v customConfig.ps1!
Data se na klientech kopiruji do C:\Windows\Scripts\

V kazdem adresari (folderName) se na klientovi automaticky navic vytvori Log adresar s modify pravy (pro customDestinationNTFS nebo Auth users), aby skripty mohly logovat sve vystupy.
Log adresar se ignoruje pri porovnavani obsahu remote repo vs lokalni kopie a pri synchronizaci zmen je zachovan.
!!! pokud spoustene skripty generuji nejake soubory, at je ukladaji do tohoto Log adresare, jinak dojde pri kazde synchronizaci s remote repo ke smazani teto slozky (porovnavam velikosti adresaru v repo a lokalu)
#>

$customConfigScript = Join-Path $repoSrc "Custom\customConfig.ps1"

if (!(Test-Path $customConfigScript -ErrorAction SilentlyContinue)) {
    Send-EmailAndFail -subject "Custom" -body "script detected missing config file $customConfigScript. Event if you do not want to copy any Custom folders to any server, create empty $customConfigScript."
}

# nactu customConfig.ps1 skript respektive $customConfig promennou v nem definovanou
# nastaveni Custom sekce schvalne definuji v samostatnem souboru kvuli lepsi prehlednosti a editovatelnosti
"Dot sourcing customConfig.ps1 (to import variable `$customConfig)"
. $customConfigScript

# zdrojova slozka custom dat
$customSrcFolder = Join-Path $repoSrc "Custom"
# cilova slozka custom dat
$customDstFolder = Join-Path $env:systemroot "Scripts"

# objekty reprezentujici Custom slozky, ktere se maji kopirovat na tento stroj
$thisPCCustom = @()
# jmena Custom slozek, ktere se maji kopirovat do \Windows\Scripts\
$thisPCCustFolder = @()
# jmena Custom slozek, ktere se maji nakopirovat do systemoveho Modules adresare
$thisPCCustToModules = @()

$customConfig | ForEach-Object {
    if ($hostname -in $_.computerName) {
        $thisPCCustom += $_

        if (!$_.customLocalDestination) {
            # pridam pouze pokud se kopiruji do vychozi slozky (Scripts)
            $thisPCCustFolder += $_.folderName
        }

        $normalizedModuleDstFolder = $moduleDstFolder -replace "\\$"
        $modulesFolderRegex = "^" + ([regex]::Escape($normalizedModuleDstFolder)) + "$"
        $normalizedCustomLocalDestination = $_.customLocalDestination -replace "\\$"
        if ($_.customLocalDestination -and $normalizedCustomLocalDestination -match $modulesFolderRegex -and (!$_.copyJustContent -or ($_.copyJustContent -and $_.customDestinationNTFS))) {
            # pozn. pokud ma copyJustContent ale ne customDestinationNTFS, tak se nenastavi prava pro $read_user >> adresar se nebude automaticky mazat, tzn je zbytecne pro nej delat vyjimku
            $thisPCCustToModules += $_.folderName
        }
    }
}

#
# odstraneni jiz nepotrebnych Custom slozek
Get-ChildItem $customDstFolder -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $folder = $_
    if ($folder.name -notin $thisPCCustFolder) {
        try {
            "Deleting unnecessary $($folder.FullName)"
            Remove-Item $folder.FullName -Recurse -Force -Confirm:$false -ErrorAction Stop
            # obsah adresare muze byt zrovna pouzivan == nepovede se jej smazat == email poslu pouze pokud se povedlo
            Send-EmailAndContinue -subject "Deletion of useless folder" -body "script deleted folder $($folder.FullName), because it is no more required here."
        } catch {
            "There was an error when deleting $($folder.FullName), error was`n$_"
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
            Send-EmailAndFail -subject "Missing folder" -body "it is not possible to copy $folderSrcPath, because it does not exist.`nSynchronization will not work until you solve this problem."
        }

        # kontrola, ze neexistuje ve zdrojovem adresari Log adresar (ten vytvarime az lokalne na strojich a nepocitam s variantou, ze by se nasynchronizoval z repo)
        if (Test-Path (Join-Path $folderSrcPath "Log") -ErrorAction SilentlyContinue) {
            Send-EmailAndFail -subject "Sync of PS scripts: Existing Log folder" -body "in $folderSrcPath exist folder 'Log' which is not supported. Delete it.`nSynchronization will not work until you solve this problem."
        }

        # kontrola, ze zadany account jde na danem stroji pouzit
        $customNTFS = $_.customDestinationNTFS
        # $customNTFSWithoutDomain = ($customNTFS -split "\\")[-1]
        if ($customNTFS) {
            #TODO toto nelze pouzit pro gMSA ucty, upravit
            # if (!(Get-WmiObject -Class win32_userAccount -Filter "name=`'$customNTFSWithoutDomain`'")) {
            #     Import-Module Scripts -Function Send-Email
            #     Send-Email -subject "Sync of PS scripts: Missing account" -body "Hi,`non $env:COMPUTERNAME it is not possible to grant NTFS permission to $folderDstPath to account $customNTFS. Is `$customConfig configuration correct?`nSynchronization of $folderSrcPath will not work until you solve this problem."
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
            "Copying content of Custom folder {0} to {1}" -f (Split-Path $folderSrcPath -leaf), $folderDstPath
            $result = Copy-Folder $folderSrcPath $folderDstPath
        } else {
            # kopiruji celou slozku
            "Copying of Custom folder {0} to {1}" -f (Split-Path $folderSrcPath -leaf), (Split-Path $folderDstPath -Parent)
            $result = Copy-Folder $folderSrcPath $folderDstPath -mirror -excludeFolder $customLogFolder

            # vypisi smazane soubory
            if ($result.deleted) {
                "Deletion of unnecessary files:`n$(($result.deleted) -join "`n")"
            }
        }

        if ($result.failures) {
            # neskoncim s chybou, protoze se da cekat, ze pri dalsim pokusu uz to projde (ted muze napr bezet skript z teto slozky atp)
            "There was an error when copying $folderSrcPath`n$($result.errMsg)"
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
                "Setting NTFS right on $folderDstPath"
                Set-Permissions @permParam
            } catch {
                Send-EmailAndFail -subject "Set permission error" -body "there was failure:`n$_`n`n when set up permission (read: $readUser, write: $writeUser) on folder $folderDstPath"
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
                "Setting NTFS rights on $customLogFolder"
                Set-Permissions @permParam
            } catch {
                Send-EmailAndFail -subject "Set permission error" -body "there was failure:`n$_`n`n when set up permission (read: $readUser, write: $writeUser) on folder $customLogFolder"
            }

        } elseif ($_.customLocalDestination -and !$_.customDestinationNTFS -and !$_.copyJustContent) {
            # nemaji se nastavit zadna custom prava
            # pro jistotu udelam reset NTFS prav (mohl jsem je jiz v minulosti nastavit)
            # ale pouze pokud na danem adresari najdu read_user ACL == nastavil jsem v minulosti custom prava
            # pozn.: detekuji tedy dle NTFS opravneni (pokud by se nenastavovalo, bude potreba zvolit jinou metodu detekce!)
            $folderhasCustomNTFS = Get-Acl -path $folderDstPath | ? { $_.accessToString -like "*$readUser*" }
            if ($folderhasCustomNTFS) {
                "Folder $folderDstPath has custom NTFS rights even it shouldn't, resetting"
                Set-Permissions -path $folderDstPath -resetACL

                "Resetting also on Log subfolder"
                Set-Permissions -path $customLogFolder -resetACL
            }
        }

        #
        # vytvorim Scheduled tasky z XML definici
        # pripadne zmodifikuji/smazu existujici
        # tasky se pojmenuji dle nazvu XML, kvuli vetsi prehlednosti (budou teda vzdy v rootu sched. task manageru)
        # autora zmenim na nazev tohoto skriptu, kvuli jejich snadne identifikaci

        # seznam sched. tasku, ktere se maji na tomto stroji vytvaret
        $scheduledTask = $_.scheduledTask

        if ($scheduledTask) {
            foreach ($taskName in $scheduledTask) {
                $definitionPath = Join-Path $folderSrcPath "$taskName.xml"
                # zkontroluji, ze existuje XML s konfiguraci pro dany task
                if (!(Test-Path $definitionPath -ea SilentlyContinue)) {
                    Send-EmailAndFail -subject "Custom" -body "script detected missing XML definition $definitionPath for scheduled task $taskName."
                }

                [xml]$xmlDefinition = Get-Content $definitionPath
                $runasAccountSID = $xmlDefinition.task.Principals.Principal.UserId
                # kontrola, ze runas ucet lze pouzit na tomto stroji
                try {
                    $runasAccount = ((New-Object System.Security.Principal.SecurityIdentifier($runasAccountSID)).Translate([System.Security.Principal.NTAccount])).Value
                } catch {
                    Send-EmailAndFail -subject "Custom" -body "script tried to create scheduled task $taskName, but runas account $runasAccountSID cannot be translated to account here."
                }

                #TODO?
                # emailem upozornim, pokud vytvarim novy task:
                # - ktery ma bezet pod gMSA uctem, ze je potreba povolit pro dany stroj
                # - a Custom adresar obsahuje xml kredence (pravdepodobne jsou v ramci tasku pouzity), ze je potreba je znovu exportovat
                # $taskExists = schtasks /tn "$taskName"
                # if (!$taskExists) { }

                # pred vytvorenim tasku, zmenim jmeno autora na nazev tohoto skriptu
                $xmlDefinition.task.RegistrationInfo.Author = $MyInvocation.MyCommand.Name
                $xmlDefinitionCustomized = "$env:TEMP\22630001418512454850000.xml"
                $xmlDefinition.Save($xmlDefinitionCustomized)

                schtasks /CREATE /XML "$xmlDefinitionCustomized" /TN "$taskName" /F

                if (!$?) {
                    Remove-Item $xmlDefinitionCustomized -Force -Confirm:$false
                    throw "Unable to create scheduled task $taskName"
                } else {
                    Remove-Item $xmlDefinitionCustomized -Force -Confirm:$false
                    # Created/modified scheduled task
                }
            }
        } # konec zpracovani sched. tasku
    } # konec zpracovani Custom objektu pro tento stroj
} # konec nakopirovani pozadovanych Custom slozek


#
# smazani sched. tasku, ktere jsem v minulosti vytvoril v ramci Custom, ale jiz zde byt nemaji
# hledam pouze v rootu, protoze je vytvarim pouze v rootu
$taskInRoot = schtasks /QUERY /FO list | ? { $_ -match "^TaskName:\s+\\[^\\]+$" } | % { $_ -replace "^TaskName:\s+\\" }
foreach ($taskName in $taskInRoot) {
    if ($taskName -notin $scheduledTask) {
        # pred smazanim overim, ze byl vytvoren timto skriptem
        [xml]$xmlDefinitionExt = schtasks.exe /QUERY /XML /TN "$taskName"
        if ($xmlDefinitionExt.task.RegistrationInfo.Author -eq $MyInvocation.MyCommand.Name) {
            schtasks /DELETE /TN "$taskName" /F

            if (!$?) {
                throw "Unable to delete scheduled task $taskName"
            }
        }
    }
} # konec mazani nezadoucich sched. tasku


#
# smazani lokalnich Modulu, ktere jiz v centralnim repo neexistuji
# zamerne az za Custom sekci, abych nemusel 2x nacitat customConfig
if (Test-Path $moduleDstFolder -ea SilentlyContinue) {
    # dohledam soubory/slozky, ktere jsem v minulosti nakopiroval do lokalnich Modules
    # pozn.: poznam je dle NTFS opravneni (pokud by se nenastavovalo, bude potreba zvolit jinou metodu detekce!)
    $repoModuleInDestination = Get-ChildItem $moduleDstFolder -Directory | Get-Acl | Where-Object { $_.accessToString -like "*$readUser*" } | Select-Object -ExpandProperty PSChildName
    if ($repoModuleInDestination) {
        $sourceModuleName = @((Get-ChildItem $moduleSrcFolder -Directory).Name)

        $repoModuleInDestination | ForEach-Object {
            if (($sourceModuleName -notcontains $_ -and $thisPCCustToModules -notcontains $_) -or ($customModules -contains $_ -and $thisPCModules -notcontains $_)) {
                "Deletion of unnecessary module $_"
                Remove-Item (Join-Path $moduleDstFolder $_) -Force -Confirm:$false -Recurse
            }
        }
    }
}