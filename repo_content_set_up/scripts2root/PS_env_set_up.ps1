#Requires -Version 3.0

<#
    .SYNOPSIS
    Script is invoked from clients to synchronize:
     - PS modules
     - global PS profile
     - per server scripts/data (content of repository Custom folder)
    from DFS share (repository) locally to client:
     - C:\Windows\System32\WindowsPowerShell\v1.0\... in case of profile and modules and generally to C:\Windows\Scripts in case of Custom folder content.

    Script should be regularly run through the scheduled task created by PS_env_set_up GPO

    Script also configures NTFS permissions on locally copied data:
     - content can MODIFY just members of group repo_writer + SYSTEM
     - READ content can just members of group repo_reader + Authenticated Users

    In case of per server data (Custom), script creates Log subfolder in root of copied folder.
    Always use this folder to store scripts output and never store it in copied folder root (otherwise whole folder will be replaced on next sync cycle!). To this Log folder can write just accounts defined in customDestinationNTFS key or members of Authenticated Users.

    .PARAMETER synchronize
    What kind of sync actions should be taken.

    Default is module, custom and profile i.e. full synchronization should occur.

    .PARAMETER moduleToSync
    Can be used to limit synchronization of PowerShell modules, so just subset of them will be synced.
    Accept list of modules names.

    .PARAMETER customToSync
    Can be used to limit synchronization of Custom folders, so just subset of them will be synced.
    Accept list of Custom folder names.

    .PARAMETER omitDeletion
    Switch to omit deletion of unused modules, scheduled tasks, PowerShell profile or custom folders.
    Use when you want sync cycle to end as fast as possible.

    .NOTES
    Author: Ondřej Šebela - ztrhgf@seznam.cz
#>

param (
    # in case of new values, add them to Refresh-Console too!
    [ValidateSet('module', 'custom', 'profile')]
    [string[]] $synchronize = @('module', 'custom', 'profile')
    ,
    [string[]] $moduleToSync
    ,
    [string[]] $customToSync
    ,
    [switch] $omitDeletion
)

# just in case auto-loading of modules doesn't work
Import-Module Microsoft.PowerShell.Host
Import-Module Microsoft.PowerShell.Security

# for debugging purposes
Start-Transcript (Join-Path "$env:SystemRoot\temp" ((Split-Path $PSCommandPath -Leaf) + ".log"))


$ErrorActionPreference = 'stop'

if ($moduleToSync -and $synchronize -notcontains "module") {
    $synchronize += "module"
}
if ($customToSync -and $synchronize -notcontains "custom") {
    $synchronize += "custom"
}

# UNC path to (DFS) share, where repository data for clients are stored
$repository = "__REPLACEME__1"

# AD group that has READ right on DFS share
# also used to identify data, that was copied through this script and therefore be able to delete them if needed
# in case that group name would change, made change also in _setPermissions where it is hardcoded
[string] $readUser = "repo_reader"
# AD group that has MODIFY right on DFS share
[string] $writeUser = "repo_writer"

# source Custom folder (in DFS share)
$customSrcFolder = Join-Path $repository "Custom"
# destination path for Custom content
$customDstFolder = Join-Path $env:systemroot "Scripts"

if ($synchronize.count -ne 3 -or $moduleToSync -or $customToSync -or $omitDeletion) {
    $customized = " (CUSTOMIZED)"
}

$hostname = $env:COMPUTERNAME

# modules etc that wasn't synced successfully
$failedSync = @()

"$(Get-Date -Format HH:mm:ss) - START synchronizing data from $repository$customized"

#region helper functions
function _isFilelocked {
    param ([string] $file)

    if ([System.IO.File]::Exists($file)) {
        try {
            $fileStream = [System.IO.File]::Open($file, 'Open', 'Write')

            $fileStream.Close()
            $fileStream.Dispose()

            return $False
        } catch [System.UnauthorizedAccessException] {
            return 'AccessDenied'
        } catch {
            return $True
        }
    }
}

function _flattenArray {
    # flattens input in case, that string and arrays are entered at the same time
    param (
        [array] $inputArray,

        [switch] $fqdnToHostname
    )

    foreach ($item in $inputArray) {
        if ($item -ne $null) {
            # recurse for arrays
            if ($item.gettype().BaseType -eq [System.Array]) {
                _flattenArray $item
            } else {
                # output non-arrays
                if ($fqdnToHostname -and $item -like "*.*") {
                    # return just hostname part
                    ($item -split "\.")[0]
                } else {
                    $item
                }
            }
        }
    }
}

function _setPermissions {
    <#
    BEWARE that readUser is also used for detection, which modules and other data this script copied
    and data detected this way can be therefore deleted in case, they are not needed anymore
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

    $readUser = _flattenArray $readUser
    $writeUser = _flattenArray $writeUser

    $permissions = @()

    if (Test-Path $path -PathType Container) {
        # it is folder
        $acl = New-Object System.Security.AccessControl.DirectorySecurity

        if ($resetACL) {
            # reset ACL, ie remove explicit ACL and enable inheritance
            $acl.SetAccessRuleProtection($false, $false)
        } else {
            # disable inheritance and remove inherited ACL
            $acl.SetAccessRuleProtection($true, $false)

            $permissions += @(, ("System", "FullControl", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            # hardcoded, to be sure, that this right will be set at any circumstances
            $permissions += @(, ("repo_reader", "ReadAndExecute", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))

            if (!$justGivenUser) {
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
        # it is file

        $acl = New-Object System.Security.AccessControl.FileSecurity
        if ($resetACL) {
            # reset ACL, ie remove explicit ACL and enable inheritance
            $acl.SetAccessRuleProtection($false, $false)
        } else {
            # disable inheritance and remove inherited ACL
            $acl.SetAccessRuleProtection($true, $false)

            $permissions += @(, ("System", "FullControl", 'Allow'))
            # hardcoded, to be sure, that this right will be set at any circumstances
            $permissions += @(, ("repo_reader", "ReadAndExecute", 'Allow'))

            if (!$justGivenUser) {
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

    try {
        # Set-Acl cannot be used because of bug https://stackoverflow.com/questions/31611103/setting-permissions-on-a-windows-fileshare
        (Get-Item $path).SetAccessControl($acl)
    } catch {
        throw "There was an error when setting NTFS rights: $_"
    }

    # reset NTFS permissions on folder content (just in case somebody modified it)
    #TODO sometimes it froze on this step, so uncomment after resolving this issue
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
    #             # Start a process rather than a job, icacls should take way less memory than PowerShell+icacls
    #             Start-Process icacls -WindowStyle Hidden -ArgumentList """$($SubFolder.FullName)"" /Reset /T /C" -PassThru
    #         }
    #     }
    # }
}

function _copyFolder {
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
            $result = Robocopy.exe "$source" "$destination" /MIR /E /NFL /NDL /NJH /R:0 /W:0 /XD "$excludeFolder"
        } else {
            $result = Robocopy.exe "$source" "$destination" /E /NFL /NDL /NJH /R:0 /W:0 /XD "$excludeFolder"
        }

        $copied = 0
        $failures = 0
        $duration = ""
        $deleted = @()
        $errMsg = @()

        $i = 0

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
            # errors like:
            #  2022/11/18 07:58:34 ERROR 5 (0x00000005) Copying File C:\temp\test.rtf
            #  Access is denied.
            if ($match = ([regex]"^[0-9 /]+ [0-9:]+ ERROR \d+ \([0-9x]+\) (.+)").Match($_).captures.groups) {
                $errorText = $match[1].value -replace "Copying File "
                $errorDetails = $result[($i + 1)]

                if ($errorDetails -like "*The process cannot access the file because it is being used by another process.*") {
                    # make error msg shorter
                    $errMsg += "$errorText - file is in use"
                } else {
                    $errMsg += "$errorText - $errorDetails"
                }
            }

            ++$i
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

function _sendEmailAndFail {
    param ([string] $subject, [string] $body, [string] $throw)

    $subject2 = "Sync of PS scripts on $env:COMPUTERNAME`: " + $subject
    $body2 = "Hi,`n" + $body

    Import-Module Scripts -Function Send-Email

    Send-Email -subject $subject2 -body $body2

    if (!$throw) { $throw = $body }
    throw $throw
}

function _sendEmailAndContinue {
    param ([string] $subject, [string] $body)

    $subject = "Sync of PS scripts on $env:COMPUTERNAME`: " + $subject
    $body = "Hi,`n" + $body

    Import-Module Scripts -Function Send-Email

    Send-Email -subject $subject -body $body
}
#endregion helper functions



#
# IMPORT VARIABLES FROM VARIABLES MODULE
#
if (("profile" -in $synchronize) -or ("module" -in $synchronize -and !$moduleToSync) -or ("custom" -in $synchronize -and !$customToSync)) {
    "$(Get-Date -Format HH:mm:ss) - Importing Variables module"
    # to support using variables from module Variables as value of computerName key in customConfig.ps1 and because of specifying computers where profile.ps1 should be copied
    # need to be done before dot sourcing customConfig.ps1 and modulesConfig.ps1
    try {
        # at first try to import most current Variables module (from DFS share)
        Import-Module (Join-Path $repository "modules\Variables") -ErrorAction Stop
    } catch {
        # import from DFS share failed, try import local copy
        "Module Variables cannot be loaded from DFS, trying to use local copy"
        # ignore errors, because on computer, where this script run for the first time, module Variables wont be present
        Import-Module "Variables" -ErrorAction SilentlyContinue
    }
}



#
# SYNCHRONIZATION OF PowerShell MODULES
#

#region sync of PowerShell modules
if ($synchronize -contains "module") {
    "$(Get-Date -Format HH:mm:ss) - Synchronization of PowerShell Modules"
    $moduleSrcFolder = Join-Path $repository "modules"
    $moduleDstFolder = Join-Path $env:systemroot "System32\WindowsPowerShell\v1.0\Modules\"

    if (!(Test-Path $moduleSrcFolder -ErrorAction SilentlyContinue)) {
        throw "Path with modules ($moduleSrcFolder) isn't accessible!"
    }

    $customModulesScript = Join-Path $moduleSrcFolder "modulesConfig.ps1"

    try {
        " - dot sourcing of modulesConfig.ps1"
        . $customModulesScript
    } catch {
        "   - there was an error when dot sourcing $customModulesScript"
        "   - error was $_"
    }

    # names of modules, that should be copied just to subset of computers
    $customModules = @()
    # names of modules, that should be copied just to this computer
    $thisPCModules = @()

    $modulesConfig | ForEach-Object {
        $customModules += $_.folderName

        if ($hostname -in (_flattenArray $_.computerName -fqdnToHostname)) {
            $thisPCModules += $_.folderName
        }
    }

    #
    # copy PS modules
    " - processing Modules"
    foreach ($module in (Get-ChildItem $moduleSrcFolder -Directory)) {
        $moduleName = $module.Name
        if ($moduleToSync -and $moduleName -notin $moduleToSync) {
            "   - skipping module $moduleName (not in moduleToSync argument)"
            continue
        }

        if ($moduleName -notin $customModules -or $moduleName -in $thisPCModules) {
            # module should be on this computer
            $moduleDstPath = Join-Path $moduleDstFolder $moduleName

            # if some dll file in destination folder is locked, copy cannot be successful, skip it
            # this often happens for dll(s), because VSC loads them automatically
            # it seems that robocopy if unable to access file, thinks it was changed hence tries to update it (in mirror mode)
            if (Test-Path $moduleDstPath -ea SilentlyContinue) {
                $lockedFile = $null

                foreach ($dll in (Get-ChildItem $moduleDstPath -Recurse -Filter "*.dll")) {
                    if (_isFilelocked $dll.FullName) {
                        $lockedFile = $dll.name
                        break
                    }
                }

                if ($lockedFile) {
                    $failedSync += "module $moduleName"
                    "   - skipping module $moduleName (file '$lockedFile' is locked)"
                    continue
                }
            }
            try {
                "   - copying module $moduleName (if necessary)"

                $result = _copyFolder $module.FullName $moduleDstPath -mirror

                if ($result.failures) {
                    $failedSync += "module $moduleName"
                    # just warn about error, it is likely, that it will end successfully next time (module can be in use etc)
                    "       - there was an error when copying $($module.FullName)`n        $($result.errMsg)"
                }

                if ($result.copied) {
                    "       - change detected (copied $($result.copied) files), setting NTFS rights"
                    _setPermissions $moduleDstPath -readUser $readUser -writeUser $writeUser
                }
            } catch {
                $failedSync += "module $moduleName"
                "       - there was an error when copying $moduleDstPath, error was`n        $_"
            }
        } else {
            # module shouldn't be on this computer
            "   - skipping module $moduleName (not for this computer)"
        }
    }
}
#endregion sync of PowerShell modules



#
# SYNCHRONIZATION OF COMMIT HISTORY
#

$commitHistorySrc = Join-Path $repository "commitHistory"
# copy file with commit history locally
# so prompt function in profile.ps1 where this file is used to check how much is that console obsolete, will be as fast as possible
if ((Test-Path $commitHistorySrc -ea SilentlyContinue) -and ($env:COMPUTERNAME -in (_flattenArray $_computerWithProfile -fqdnToHostname))) {
    [Void][System.IO.Directory]::CreateDirectory($customDstFolder)
    Copy-Item $commitHistorySrc $customDstFolder -Force -Confirm:$false
}



#
# SYNCHRONIZATION OF POWERSHELL GLOBAL PROFILE
#

#region sync of global PS profile
if ($synchronize -contains "profile") {
    "$(Get-Date -Format HH:mm:ss) - Synchronization of PowerShell Profile"
    $profileSrc = Join-Path $repository "profile.ps1"
    $profileDst = Join-Path $env:systemroot "System32\WindowsPowerShell\v1.0\profile.ps1"
    $profileDstFolder = Split-Path $profileDst -Parent
    $isOurProfile = Get-Acl -Path $profileDst -ea silentlyContinue | Where-Object { $_.accessToString -like "*$readUser*" }

    if (Test-Path $profileSrc -ea SilentlyContinue) {
        # DFS share contains profile.ps1
        if ($env:COMPUTERNAME -in (_flattenArray $_computerWithProfile -fqdnToHostname)) {
            # profile.ps1 should be copied to this computer
            if (Test-Path $profileDst -ea SilentlyContinue) {
                # profile.ps1 already exist on this computer, check whether it differs

                $sourceModified = (Get-Item $profileSrc).LastWriteTime
                $destinationModified = (Get-Item $profileDst).LastWriteTime
                if ($sourceModified -ne $destinationModified) {
                    # profile.ps1 was changed, overwrite it
                    " - copying global PS profile to $profileDstFolder"
                    Copy-Item $profileSrc $profileDstFolder -Force -Confirm:$false
                    "   - setting NTFS rights to $profileDst"
                    _setPermissions $profileDst -readUser $readUser -writeUser $writeUser
                }
            } else {
                # profile.ps1 doesn't exist on this computer
                " - copying global PS profile to $profileDstFolder"
                Copy-Item $profileSrc $profileDstFolder -Force -Confirm:$false
                "   - setting NTFS rights to $profileDst"
                _setPermissions $profileDst -readUser $readUser -writeUser $writeUser
            }
        } else {
            # profile.ps1 shouldn't be on this computer
            if ((Test-Path $profileDst -ea SilentlyContinue) -and $isOurProfile -and !$omitDeletion) {
                # profile.ps1 is on this computer and was copied by this script == delete it
                " - deleting $profileDst"
                Remove-Item $profileDst -Force -Confirm:$false
            }
        }
    } else {
        # in DFS share there is not profile.ps1
        if ((Test-Path $profileDst -ea SilentlyContinue) -and ($env:COMPUTERNAME -in (_flattenArray $_computerWithProfile -fqdnToHostname)) -and $isOurProfile) {
            # profile.ps1 is on this computer and was copied by this script == delete it
            " - deleting $profileDst"
            Remove-Item $profileDst -Force -Confirm:$false
        }
    }
}
#endregion sync of global PS profile



#
# SYNCHRONIZATION OF CUSTOM CONTENT
#

#region sync of custom content
# Repository Custom folder contains folders, that should be copied just to defined computers.
# What should happen is defined in variable $customConfig, which is stored in customConfig.ps1 where you also can find more information.
if ($synchronize -contains "custom") {
    "$(Get-Date -Format HH:mm:ss) - Synchronization of Custom Content"
    $customConfigScript = Join-Path $repository "Custom\customConfig.ps1"

    if (!(Test-Path $customConfigScript -ErrorAction SilentlyContinue)) {
        _sendEmailAndFail -subject "Custom" -body "script detected missing config file $customConfigScript. Event if you do not want to copy any Custom folders to any server, create empty $customConfigScript."
    }

    # import $customConfig
    " - dot sourcing customConfig.ps1"
    . $customConfigScript

    # objects from $customConfig, that represents folders from Custom, that should be copied to this computer
    $thisPCCustom = @()
    # name of Custom folders, that should be copied to %windir%\Scripts\
    $thisPCCustFolder = @()
    # name of Custom folders, that should be copied to system Modules
    $thisPCCustToModules = @()
    # name of Custom scheduled tasks, that should be created on this computer
    $thisPCCustSchedTask = @()

    foreach ($custom in $customConfig) {
        if ($hostname -in (_flattenArray $custom.computerName -fqdnToHostname)) {
            if ($customToSync -and $customToSync -notcontains $custom.folderName) {
                " - skipping custom folder {0} (not in customToSync argument)" -f $custom.folderName
                continue
            }

            $thisPCCustom += $custom

            if (!$custom.customLocalDestination) {
                # add only if folder should be copied to default (Scripts) folder
                $thisPCCustFolder += $custom.folderName
            }

            if ($custom.scheduledTask) {
                $thisPCCustSchedTask += $custom.scheduledTask
            }

            $normalizedModuleDstFolder = $moduleDstFolder -replace "\\$"
            $modulesFolderRegex = "^" + ([regex]::Escape($normalizedModuleDstFolder)) + "$"
            $normalizedCustomLocalDestination = $custom.customLocalDestination -replace "\\$"
            if ($custom.customLocalDestination -and $normalizedCustomLocalDestination -match $modulesFolderRegex -and (!$custom.copyJustContent -or ($custom.copyJustContent -and $custom.customDestinationNTFS))) {
                # in case copyJustContent is set but not customDestinationNTFS, NTFS rights for $read_user wont be set == folder won't be automatically deleted in case it isn't needed so it is useless to make exception for it
                $thisPCCustToModules += $custom.folderName
            }
        }
    }

    #
    # delete Custom folders, that shouldn't be on this computer
    if (!$omitDeletion -and !$customToSync -and $synchronize -contains "custom") {
        # skip if $customToSync is defined, because it modifies $thisPCCustFolder i.e. it would contain just subset of computers Custom folders (not all of them)
        Get-ChildItem $customDstFolder -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $folder = $_
            if ($folder.name -notin $thisPCCustFolder) {
                try {
                    " - deleting unnecessary $($folder.FullName)"
                    Remove-Item $folder.FullName -Recurse -Force -Confirm:$false -ErrorAction Stop
                    # content of folder can be in use == deletion will fail == email will be sent just in case delete was successfull
                    _sendEmailAndContinue -subject "Deletion of useless folder" -body "script deleted folder $($folder.FullName), because it is no more required here."
                } catch {
                    "There was an error when deleting $($folder.FullName), error was`n$_"
                }
            }
        }
    }


    #
    # process folders from Custom, that should be on this computer
    if ($thisPCCustom) {
        [Void][System.IO.Directory]::CreateDirectory("$customDstFolder")

        $thisPCCustom | ForEach-Object {
            $folderSrcPath = Join-Path $customSrcFolder $_.folderName
            $folderDstPath = Join-Path $customDstFolder $_.folderName

            $customName = Split-Path $folderSrcPath -Leaf
            " - processing folder $customName"

            if ($_.customLocalDestination) {
                if ($_.copyJustContent) {
                    $folderDstPath = $_.customLocalDestination
                } else {
                    $folderDstPath = Join-Path $_.customLocalDestination $_.folderName
                }

                [Void][System.IO.Directory]::CreateDirectory("$folderDstPath")
            }

            # check that source folder really exists in DFS share
            if (!(Test-Path $folderSrcPath -ErrorAction SilentlyContinue)) {
                _sendEmailAndFail -subject "Missing folder" -body "it is not possible to copy $folderSrcPath, because it does not exist.`nSynchronization will not work until you solve this problem."
            }

            # check that source folder doesn't contain subfolder named Log
            # subfolder with such a name is automatically created in root of clients folder copy so it would cause conflict or unexpected behaviour
            if (Test-Path (Join-Path $folderSrcPath "Log") -ErrorAction SilentlyContinue) {
                _sendEmailAndFail -subject "Sync of PS scripts: Existing Log folder" -body "in $folderSrcPath exist folder 'Log' which is not supported. Delete it.`nSynchronization will not work until you solve this problem."
            }

            # check that given account can be used on this computer
            $customNTFS = $_.customDestinationNTFS
            # $customNTFSWithoutDomain = ($customNTFS -split "\\")[-1]
            if ($customNTFS) {
                #TODO this check cannot be used for gMSA accounts, fix
                # if (!(Get-WmiObject -Class win32_userAccount -Filter "name=`'$customNTFSWithoutDomain`'")) {
                #     Import-Module Scripts -Function Send-Email
                #     Send-Email -subject "Sync of PS scripts: Missing account" -body "Hi,`non $env:COMPUTERNAME it is not possible to grant NTFS permission to $folderDstPath to account $customNTFS. Is `$customConfig configuration correct?`nSynchronization of $folderSrcPath will not work until you solve this problem."
                #     throw "Non existing account $customNTFS"
                # }
            }

            $change = 0
            $customLogFolder = Join-Path $folderDstPath "Log"

            #
            # copy Custom folder
            if ($_.copyJustContent) {
                # copy just content of the folder
                # cannot therefore use robocopy mirror, because it is likely, that destination folder will contain other files too
                "   - copying content of {0} to {1} (if necessary)" -f (Split-Path $folderSrcPath -Leaf), $folderDstPath
                $result = _copyFolder $folderSrcPath $folderDstPath
            } else {
                # copy folder as whole
                "   - copying {0} to {1} (if necessary)" -f (Split-Path $folderSrcPath -Leaf), (Split-Path $folderDstPath -Parent)
                $result = _copyFolder $folderSrcPath $folderDstPath -mirror -excludeFolder $customLogFolder

                # output deleted files
                if ($result.deleted) {
                    "      - deleted unnecessary files:`n$(($result.deleted) -join "`n")"
                }
            }

            if ($result.failures) {
                # just warn about error, it is likely, that it will end successfully next time (folder could be locked now etc)
                "       - there was an error when copying $folderSrcPath`n$($result.errMsg)"
            }

            if ($result.copied) {
                ++$change
            }

            #
            # create Log subfolder if that makes sense
            if (!$_.copyJustContent -or ($_.copyJustContent -and !$_.customLocalDestination)) {
                [Void][System.IO.Directory]::CreateDirectory("$customLogFolder")
            }

            #
            # set NTFS rights
            # do every tim because commit could have changed customDestinationNTFS value even though data stayed the same
            # if destination is customized, set NTFS only if customDestinationNTFS is set and whole folder is copied (otherwise it would be complicated/slow/contraproductive?!)
            if (!($_.customLocalDestination) -or ($_.customLocalDestination -and $_.customDestinationNTFS -and !($_.copyJustContent))) {
                $permParam = @{path = $folderDstPath; readUser = $readUser, "Administrators"; writeUser = $writeUser, "Administrators" }
                if ($customNTFS) {
                    $permParam.readUser = "Administrators", $customNTFS
                    $permParam.justGivenUser = $true
                }

                try {
                    "       - setting NTFS right on $folderDstPath"
                    _setPermissions @permParam
                } catch {
                    _sendEmailAndFail -subject "Set permission error" -body "there was failure:`n$_`n`n when set up permission (read: $readUser, write: $writeUser) on folder $folderDstPath"
                }

                # set NTFS permissions also on Log subfolder
                $permParam = @{ path = $customLogFolder; readUser = $readUser; writeUser = $writeUser }
                if ($customNTFS) {
                    $permParam.readUser = "Administrators"
                    $permParam.writeUser = "Administrators", $customNTFS
                    $permParam.justGivenUser = $true
                } else {
                    $permParam.writeUser = $permParam.writeUser, "Authenticated Users"
                }

                try {
                    "       - setting NTFS rights on $customLogFolder"
                    _setPermissions @permParam
                } catch {
                    _sendEmailAndFail -subject "Set permission error" -body "there was failure:`n$_`n`n when set up permission (read: $readUser, write: $writeUser) on folder $customLogFolder"
                }
            } elseif ($_.customLocalDestination -and !$_.customDestinationNTFS -and !$_.copyJustContent) {
                # no custom NTFS rights should be applied
                # reset NTFS just in case, there were some set earlier, but only read_user ACL is found == proof that NTFS was set by this script and therefore it is safe to reset them
                $folderhasCustomNTFS = Get-Acl -Path $folderDstPath | ? { $_.accessToString -like "*$readUser*" }
                if ($folderhasCustomNTFS) {
                    "      - folder $folderDstPath has custom NTFS rights even it shouldn't, resetting (also on Log subfolder)"
                    _setPermissions -path $folderDstPath -resetACL
                    _setPermissions -path $customLogFolder -resetACL
                }
            }

            #
            # create Scheduled tasks from XML definitions
            # or modify/delete existing one
            # sched. tasks are always created with same name as have XML that defines them and will be placed in Task Scheduler root
            # author will be set as name of this script for easy identification and manageability

            # scheduled tasks that should be created on this computer
            $scheduledTask = $_.scheduledTask

            if ($scheduledTask) {
                "       - creating scheduled task"
                foreach ($taskName in $scheduledTask) {
                    "           - $taskName"
                    $definitionPath = Join-Path $folderSrcPath "$taskName.xml"
                    # check that corresponding XML exists
                    if (!(Test-Path $definitionPath -ea SilentlyContinue)) {
                        _sendEmailAndFail -subject "Custom" -body "script detected missing XML definition $definitionPath for scheduled task $taskName."
                    }

                    [xml]$xmlDefinition = Get-Content $definitionPath
                    $runasAccountSID = $xmlDefinition.task.Principals.Principal.UserId
                    # check that runas account can be used on this computer
                    try {
                        $runasAccount = ((New-Object System.Security.Principal.SecurityIdentifier($runasAccountSID)).Translate([System.Security.Principal.NTAccount])).Value
                    } catch {
                        _sendEmailAndFail -subject "Custom" -body "script tried to create scheduled task $taskName, but runas account $runasAccountSID cannot be translated to account here."
                    }

                    #TODO?
                    # emailem upozornim, pokud vytvarim novy task:
                    # - ktery ma bezet pod gMSA uctem, ze je potreba povolit pro dany stroj
                    # - a Custom adresar obsahuje xml kredence (pravdepodobne jsou v ramci tasku pouzity), ze je potreba je znovu exportovat
                    # $taskExists = schtasks /tn "$taskName"
                    # if (!$taskExists) { }

                    # change author name to filename of this script
                    try {
                        $null = $xmlDefinition.task.RegistrationInfo.Author.GetType()
                    } catch {
                        # author node doesn't exist, I will create it
                        $xdNS = $xmlDefinition.DocumentElement.NamespaceURI
                        $authorElem = $xmlDefinition.CreateElement("Author", $xdNS)
                        [void]$xmlDefinition.task.RegistrationInfo.AppendChild($authorElem)
                    }
                    $xmlDefinition.task.RegistrationInfo.Author = $MyInvocation.MyCommand.Name
                    # create customized copy of XML definition
                    $xmlDefinitionCustomized = "$env:TEMP\22630001418512454850000.xml"
                    $xmlDefinition.Save($xmlDefinitionCustomized)

                    # create scheduled task from XML definition
                    $result = schtasks /CREATE /XML "$xmlDefinitionCustomized" /TN "$taskName" /F

                    if (!$?) {
                        Remove-Item $xmlDefinitionCustomized -Force -Confirm:$false
                        throw "Unable to create scheduled task $taskName"
                    } else {
                        # success
                        Remove-Item $xmlDefinitionCustomized -Force -Confirm:$false
                    }
                }
            } # end of sched. task section
        } # end of section that process objects from $customConfig that are targeted to this computer
    } # end of processing Custom folders that should be on this computer


    #
    # delete scheduled tasks that shouldn't be on this computer
    # and was created earlier by this script
    # check just tasks in root, because this script creates them in root
    if (!$omitDeletion -and $synchronize -contains "custom") {
        $taskInRoot = schtasks /QUERY /FO list | ? { $_ -match "^TaskName:\s+\\[^\\]+$" } | % { $_ -replace "^TaskName:\s+\\" }
        foreach ($taskName in $taskInRoot) {
            if ($taskName -notin $thisPCCustSchedTask) {
                # check that task was created by this script and only in that case delete it
                [xml]$xmlDefinitionExt = schtasks.exe /QUERY /XML /TN "$taskName"
                if ($xmlDefinitionExt.task.RegistrationInfo.Author -eq $MyInvocation.MyCommand.Name) {
                    "       - deleting scheduled task '$taskName'"
                    $null = schtasks /DELETE /TN "$taskName" /F

                    if (!$?) {
                        throw "Unable to delete scheduled task $taskName"
                    }
                }
            }
        } # end of deleting scheduled task section
    }
}
#endregion sync of custom content


#
# delete PowerShell modules that shouldn't be on this computer
# this section is after Custom, so I don't have to dot source customConfig.ps1 twice and to have $thisPCCustToModules prepared
if (!$omitDeletion -and $synchronize -contains "module" -and ($synchronize -contains "custom" -and !$customToSync)) {
    # Custom section has to be processed, because of getting $thisPCCustToModules and at the same time $customToSync cannot be defined, because it could modify it

    "$(Get-Date -Format HH:mm:ss) - Delete unnecessary PowerShell modules"

    if (Test-Path $moduleDstFolder -ea SilentlyContinue) {
        # get modules that was previously copied by this script
        $repoModuleInDestination = Get-ChildItem $moduleDstFolder -Directory | Get-Acl | Where-Object { $_.accessToString -like "*$readUser*" } | Select-Object -ExpandProperty PSChildName

        if ($repoModuleInDestination) {
            $sourceModuleName = @((Get-ChildItem $moduleSrcFolder -Directory).Name)

            $repoModuleInDestination | ForEach-Object {
                if ((($sourceModuleName -notcontains $_ -and $thisPCCustToModules -notcontains $_) -or ($customModules -contains $_ -and $thisPCModules -notcontains $_))) {
                    " - $_"
                    Remove-Item (Join-Path $moduleDstFolder $_) -Force -Confirm:$false -Recurse
                }
            }
        }
    }
}

if ($failedSync) {
    "`n`n!!!WARNING!!!`nSome content wasn't synchronized:`n$($failedSync | % {"`t- $_`n"})"
}

"$(Get-Date -Format HH:mm:ss) - END"

if ($failedSync) {
    # exit with custom code (10000), so CICD repository installation script and refresh function know this isn't serious
    $host.SetShouldExit(10000)
    exit
}