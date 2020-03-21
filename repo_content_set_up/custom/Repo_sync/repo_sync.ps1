<#
    script is processing GIT cloud repository content and distribute clients part to DFS share (read only share from which clients will download content to themselves)
    how it works:
    - pull/clone GIT cloud repository locally
    - process cloned content (generate PSM modules from scripts2module, copy Custom content to shares,..)
    - copy processed content which is intended for clients to shared folder (DFS)

    BEWARE, repo_puller account used to pull data from GIT repository has to have 'alternate credentials' created and these credentials has to be exported to login.xml (under account which is used to run this script ie SYSTEM)
        
    .NOTES
    Author: Ondřej Šebela - ztrhgf@seznam.cz
#>

# for debugging purposes
Start-Transcript -Path "$env:SystemRoot\temp\repo_sync.log" -Force

$ErrorActionPreference = "stop"

$logFolder = Join-Path $PSScriptRoot "Log"

# explicit import because sometimes it happened, that function autoload won't work
Import-Module Scripts -Function Send-Email -ErrorAction SilentlyContinue

# to avoid spamming, just one email per 30 minutes can be send
$lastSendEmail = Join-Path $logFolder "lastSendEmail"
$treshold = 30

# path to DFS share, where processed content will be copied
$destination = "__TODO__" # UNC path to DFS repository (ie.: \\myDomain\dfs\repository)

# AD group that has READ right on DFS share
[string] $readUser = "repo_reader"
# AD group that has MODIFY right on DFS share
[string] $writeUser = "repo_writer"

#__TODO__ configure and uncomment one of the rows that initialize variable $signingCert, if you want automatic code signing to happen (using specified certificate)

# certificate which will be used to sign ps1, psm1, psd1 and ps1xml files
# USE ONLY IF YOU KNOW, WHAT ARE YOU DOING
# tutorial how to create self signed certificate http://woshub.com/how-to-sign-powershell-script-with-a-code-signing-certificate/
# set correct path to signing certificate and uncomment to start signing
# $signingCert = Get-PfxCertificate -FilePath C:\Test\Mysign.pfx # something like this, if you want to use locally stored pfx certificate
# $signingCert = (Get-ChildItem cert:\LocalMachine\my –CodeSigningCert)[0] # something like this, if certificate is in store
if ($signingCert -and $signingCert.EnhancedKeyUsageList.friendlyName -ne "Code Signing") {
    throw "Certificate $($signingCert.DnsNameList) is not valid Code Signing certificate"
}

#
#region helper function
function _updateRepo {
    <#
    .SYNOPSIS
        Function used to process and copy local commited changes from local GIT repository to DFS share.
        Automatically skip modified but not commited or untracked files.

    .DESCRIPTION
        Function used to process and copy local commited changes from local GIT repository to DFS share.
        Automatically skip modified but not commited or untracked files.

        - from ps1 scripts in folders that are in scripts2module generates Powershell modules to \Modules\.
        - content of Modules folder is copied to Modules in DFS share
        - content of scripts2roor is copied to root of DFS share
        - content of Custom folder is copied to Custom in DFS share

        Function copies all files, not just changed one to replace possible modifications, that someone could have made in DFS share.

    .PARAMETER source
        Path to locally cloned GGIT repository.

    .PARAMETER destination
        Path to DFS share which should contain clients repository data.

    .PARAMETER force
        Force copy of all repository sections, not just changed one.
        Not commited and untracked files are still skipped.

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

    # quick check, that this PC is in domain
    $inDomain = (Get-WmiObject Win32_ComputerSystem).Domain -match "\."
    # local destination to which function should generate Powershell modules
    $modules = Join-Path $source "modules"
    # DFS share destination to which function should copy all Powershell modules
    $destModule = Join-Path $destination "modules"
    # local path to folder from which Powershell modules should be generated
    $scripts2module = Join-Path $source "scripts2module"
    # local path to folder shich content should be copied to root of DFS share
    $scripts2root = Join-Path $source "scripts2root"

    $somethingChanged = 0
    $moduleChanged = 0

    if (!$inDomain -or !(Test-Path $destination -ErrorAction SilentlyContinue)) {
        throw "Path $destination is not available"
    }


    #
    # get modified and deleted files
    #

    # variable will contain files, that cannot be copied to DFS share
    $unfinishedFile = @()
    $location = Get-Location
    Set-Location $source
    try {
        # locally cloned GIT repository state
        $repoStatus = git status -uno
        # unpushed commits
        $unpushedCommit = git log origin/master..HEAD
        # files in last commit
        $commitedFile = @(git show HEAD --pretty="" --name-only)
        # deleted files in last commit
        $commitedDeletedFile = @(git show HEAD --pretty="" --name-status | ? { $_ -match "^D\s+" } | % { $_ -replace "^D\s+" })
        # deleted files not in staging area
        $uncommitedDeletedFile = @(git ls-files -d)
        # modified and deleted files not in staging area
        $unfinishedFile += @(git ls-files -m)
        # untracked files
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
    # check that local repository contains most recent data
    if ($repoStatus -match "Your branch is behind") {
        throw "Repository doesn't contain actual data. Pull them using command 'git pull' (Sync in VSC editor) and run again"
    }

    $isForced = ($PSBoundParameters.GetEnumerator() | ? { $_.key -eq "force" }).value.isPresent

    if (!$unpushedCommit -and $isForced -ne "True") {
        Write-Warning "`nIn repository there is none unpushed commit. Function will copy just changes from last commit.`nIf you want to copy all, use -force switch`n`n"
    }

    # git command return path with /, replace to \
    $unfinishedFile = $unfinishedFile -replace "/", "\"
    $commitedFile = $commitedFile -replace "/", "\"
    $commitedDeletedFile = $commitedDeletedFile -replace "/", "\"
    $uncommitedDeletedFile = $uncommitedDeletedFile -replace "/", "\"

    # full path instead of relative
    $unfinishedFileAbsPath = $unfinishedFile | % { Join-Path $source $_ }

    #
    # preparation of string in format, that robocopy parameter /XF needs
    # it will contain file absolute paths, that robocopy will ignore
    # it has to be source path
    $excludeFile = ""
    if ($unfinishedFileAbsPath) {
        $unfinishedFileAbsPath | % {
            $excludeFile += " " + "`"$_`""
        }
    }
    # add deleted and uncommited files
    # it has to be destination path, so robocopy won't delete it
    $folderWithUncommitedDeletedFile = @()

    if ($uncommitedDeletedFile) {
        $uncommitedDeletedFile | % {
            $file = $_
            $destAbsPath = ""
            if ($file -match "scripts2root\\") {
                # file goes to root
                $file = Split-Path $file -Leaf
                $destAbsPath = Join-Path $destination $file
            } elseif ($file -match "scripts2module\\") {
                # files from scripts2module are not being copied to DFS share, ignoring
            } else {
                # path in GIT repository is same as in DFS share
                $destAbsPath = Join-Path $destination $_
            }

            if ($destAbsPath) {
                $excludeFile += " " + "`"$destAbsPath`""
                $folderWithUncommitedDeletedFile += Split-Path $destAbsPath -Parent
            }
        }
    }

    # also folders, where some files were deleted needs to be ignored
    # in case whole folder was deleted in source it's not enough to exclude all deleted files from it, robocopy would still delete it
    # so $excludeFolder will be used as value for /XD robocopy parameter
    $folderWithUncommitedDeletedFile = $folderWithUncommitedDeletedFile | Select-Object -Unique
    $excludeFolder = ""
    if ($folderWithUncommitedDeletedFile) {
        $folderWithUncommitedDeletedFile | % {
            $excludeFolder += " " + "`"$_`""
        }
    }

    # convert to arraylist to be able effectively add/remove items
    [System.Collections.ArrayList] $commitedFile = @($commitedFile)
    [System.Collections.ArrayList] $unfinishedFile = @($unfinishedFile)




    #
    # remove from commited files list files that was modified after addind to staging area
    #

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
    # SAVE COMMITS HISTORY TO FILE IN DFS SHARE ROOT
    # for clients to be able to determine how many commits behind is their running Powershell console behind client itself
    #
    if ($commitHistory) {
        $commitHistory | Out-File (Join-Path $destination commitHistory) -Force
    }




    #
    # GENERATE POWERSHELL MODULES FROM SCRIPTS2MODULE SUBFOLDERS CONTENT
    #

    # create special hashtable for function _exportScriptsToModule to know what modules it should generate
    $configHash = @{ }

    if ($force) {
        # generate all modules no matter they was changed
        Get-ChildItem $scripts2module -Directory | Select-Object -ExpandProperty FullName | % {
            $moduleName = Split-Path $_ -Leaf
            $absPath = $_
            $TextInfo = (Get-Culture).TextInfo
            $moduleName = $TextInfo.ToTitleCase($moduleName)
            $configHash[$absPath] = Join-Path $modules $moduleName
        }

        ++$moduleChanged
    } else {
        # generate just modules where some change in source script data was made
        $commitedFile | ? { $_ -match "^scripts2module\\" } | % { ($_ -split "\\")[-2] } | Select-Object -Unique | % {
            $moduleName = $_
            $absPath = Join-Path $scripts2module $moduleName
            $TextInfo = (Get-Culture).TextInfo
            $moduleName = $TextInfo.ToTitleCase($moduleName)
            $configHash[$absPath] = Join-Path $modules $moduleName
        }

        if ($commitedFile -match "^modules\\") {
            # take a note, that some module was changed
            Write-Output "Some modules changed, copying"
            ++$moduleChanged
        }
    }

    #
    # generate Powershell modules
    if ($configHash.Keys.count) {
        ++$somethingChanged

        _exportScriptsToModule -configHash $configHash -dontIncludeRequires
    }


    #
    # SYNCHRONIZE CONTENT OF LOCAL MODULES FOLDER TO DFS SHARE
    #

    #region
    if ($moduleChanged -or $configHash.Keys.count) {
        [Void][System.IO.Directory]::CreateDirectory("$destModule")
        if (!(Test-Path $destModule -ErrorAction SilentlyContinue)) {
            throw "Path $destModule isn't accessible"
        }

        ++$somethingChanged

        Write-Output "### Copying modules to $destModule"

        # exclude automatically generated modules from excluded files
        # they could get into list because of not being listed in .gitignore, therefore are considered as untracked
        if ($configHash.Keys.count) {
            $reg = ""

            $configHash.Values | % {
                Write-Verbose "Won't skip content of $_, it's automatically generated module"
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

        # sign Powershell scripts if requested
        if ($signingCert) {
            Get-ChildItem $modules -Recurse -Include *.ps1, *.psm1, *.psd1, *.ps1xml -File | % {
                Set-AuthenticodeSignature -Certificate $signingCert -FilePath $_.FullName
            }
        }

        # copy modules to DFS share
        # result variable will contain list of deleted files and/or errors
        $result = Invoke-Expression "Robocopy.exe `"$modules`" `"$destModule`" /MIR /S /NFL /NDL /NJH /NJS /R:4 /W:5 /XF $excludeFile2 /XD $excludeFolder"

        # output deleted files
        $deleted = $result | ? { $_ -match [regex]::Escape("*EXTRA File") } | % { ($_ -split "\s+")[-1] }
        if ($deleted) {
            Write-Output "Deletion of unnecessary files:`n$($deleted -join "`n")"
        }

        # filter from result all except errors
        # lines with *EXTRA File\Dir contains deleted files
        $result = $result | ? { $_ -notmatch [regex]::Escape("*EXTRA ") }
        if ($result) {
            Write-Error "There was an error when copying module $($_.name):`n`n$result`n`nRun again command: $($MyInvocation.Line) -force"
        }

        # limit NTFS rights on Modules in DFS share
        # so just computers listed in computerName key in modulesConfig variable can access it
        # in case computerName is not set NTFS permissions will be reset
        # do it on every synch cycle because of possibility, that computerName is defined by variable which value could have changed
        "### Setting NTFS rights on modules"
        foreach ($folder in (Get-ChildItem $destModule -Directory)) {
            $folder = $folder.FullName
            $folderName = Split-Path $folder -Leaf

            # $modulesConfig was loaded by dot sourcing modulesConfig.ps1 script file
            $configData = $modulesConfig | ? { $_.folderName -eq $folderName }
            if ($configData -and ($configData.computerName)) {
                # it is defined, where this module should be copied
                # limit NTFS rights accordingly
                [string[]] $readUserC = $configData.computerName
                # computer AD accounts end with $
                $readUserC = $readUserC | % { $_ + "$" }

                " - limiting NTFS rights on $folder (grant access just to: $($readUserC -join ', '))"
                _setPermissions $folder -readUser $readUserC -writeUser $writeUser
            } else {
                # it is not defined, where this module should be copied
                # reset NTFS rights to default
                " - resetting NTFS rights on $folder"
                _setPermissions $folder -resetACL
            }
        }
    }

    #
    # remove empty module folders from DFS share
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
    #endregion



    #
    # SYNCHRONIZE CONTENT OF LOCAL SCRIPTS2ROOT FOLDER TO DFS SHARE
    #

    #region
    if ($commitedFile -match "^scripts2root" -or $force) {
        Write-Output "### Copying root files from $scripts2root to $destination`n"

        # copy all files that can be copied
        $script2Copy = (Get-ChildItem $scripts2root -File).FullName | ? {
            if ($unfinishedFileAbsPath -match [regex]::Escape($_)) {
                return $false
            } else {
                return $true
            }
        }
        if ($script2Copy) {
            ++$somethingChanged

            $script2Copy | % {
                $item = $_
                Write-Output (" - " + ([System.IO.Path]::GetFileName("$item")))

                try {
                    # signing the script if requested
                    if ($signingCert -and $item -match "ps1$|psd1$|psm1$|ps1xml$") {
                        Set-AuthenticodeSignature -Certificate $signingCert -FilePath $item
                    }

                    Copy-Item $item $destination -Force -ErrorAction Stop

                    # in case of profile.ps1 limit NTFS rights just to computers which can download it
                    if ($item -match "\\profile\.ps1$") {
                        $destProfile = (Join-Path $destination "profile.ps1")
                        if ($computerWithProfile) {
                            # computer AD accounts end with $
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
        # DELETE UNNEEDED FILES FROM DFS SHARE ROOT
        #
        $DFSrootFile = Get-ChildItem $destination -File | ? { $_.extension }
        $GITrootFileName = Get-ChildItem $scripts2root -File | Select-Object -ExpandProperty Name
        $uncommitedDeletedRootFileName = $uncommitedDeletedFile | ? { $_ -match "scripts2root\\" } | % { ([System.IO.Path]::GetFileName($_)) }
        $DFSrootFile | % {
            if ($GITrootFileName -notcontains $_.Name -and $uncommitedDeletedRootFileName -notcontains $_.Name) {
                try {
                    Write-Verbose "Deleting $($_.FullName)"
                    Remove-Item $_.FullName -Force -Confirm:$false -ErrorAction Stop
                } catch {
                    Write-Error "There was an error when deleting file $item`:`n`n$_`n`nRun again command: $($MyInvocation.Line) -force"
                }
            }
        }
    }
    #endregion




    #
    # SYNCHRONIZE CONTENT OF CUSTOM FOLDER TO DFS SHARE
    #

    #region
    if ($commitedFile -match "^custom\\.+" -or $force) {
        $customSource = Join-Path $source "custom"
        $customDestination = Join-Path $destination "custom"

        if (!(Test-Path $customSource -ErrorAction SilentlyContinue)) {
            throw "Path $customSource isn't accessible"
        }

        Write-Output "### Copying Custom data from $customSource to $customDestination`n"

        # signing of scripts if requested
        if ($signingCert) {
            Get-ChildItem $customSource -Recurse -Include *.ps1, *.psm1, *.psd1, *.ps1xml -File | % {
                Set-AuthenticodeSignature -Certificate $signingCert -FilePath $_.FullName
            }
        }

        $result = Invoke-Expression "Robocopy.exe $customSource $customDestination /S /MIR /NFL /NDL /NJH /NJS /R:4 /W:5 /XF $excludeFile /XD $excludeFolder"

        # output deleted files
        $deleted = $result | ? { $_ -match [regex]::Escape("*EXTRA File") } | % { ($_ -split "\s+")[-1] }
        if ($deleted) {
            Write-Verbose "Unnecessary files was deleted:`n$($deleted -join "`n")"
        }

        # filter from result all except errors
        # lines with *EXTRA File\Dir contains deleted files
        $result = $result | ? { $_ -notmatch [regex]::Escape("*EXTRA ") }
        if ($result) {
            Write-Error "There was an error when copying Custom section`:`n`n$result`n`nRun again command: $($MyInvocation.Line) -force"
        }


        # limit NTFS rights on Custom folders in DFS share
        # so just computers listed in computerName or customSourceNTFS key in customConfig variable can access it
        # in case neither of this keys are set, NTFS permissions will be reset
        # do it on every synch cycle because of possibility, that computerName/customSourceNTFS is defined by variable which value could have changed
        "### Setting NTFS rights on Custom"
        foreach ($folder in (Get-ChildItem $customDestination -Directory)) {
            $folder = $folder.FullName
            $folderName = Split-Path $folder -Leaf

            # $customConfig was loaded by dot sourcing customConfig.ps1 script file
            $configData = $customConfig | ? { $_.folderName -eq $folderName }
            if ($configData -and ($configData.computerName -or $configData.customSourceNTFS)) {
                # it is defined, where this folder should be copied
                # limit NTFS rights accordingly

                # custom share NTFS rights defined in customSourceNTFS has precedence by design
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
                # it is not defined, where this folder should be copied
                # reset NTFS rights to default
                " - resetting NTFS rights on $folder"
                _setPermissions $folder -resetACL
            }
        }


        ++$somethingChanged
    }
    #endregion




    #
    # WARN IF NO CHANGE WAS DETECTED
    #

    # these files are not copied to DFS share but could be changed, take a note if this is the case to now show warning unnecessarily
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
        Function for generating Powershell module from ps1 scripts (that contains definition of functions) that are stored in given folder.
        Generated module will also contain function aliases (no matter if they are defined using Set-Alias or [Alias("Some-Alias")].
        Every script file has to have exactly same name as function that is defined inside it (ie Get-LoggedUsers.ps1 contains just function Get-LoggedUsers).
        In console where you call this function, font that can show UTF8 chars has to be set.

    .PARAMETER configHash
        Hash in specific format, where key is path to folder with scripts and value is path to which module should be generated.

        eg.: @{"C:\temp\scripts" = "C:\temp\Modules\Scripts"}

    .PARAMETER enc
        Which encoding should be used.

        Default is UTF8.

    .PARAMETER includeUncommitedUntracked
        Export also uncommited and untracked files.

    .PARAMETER dontCheckSyntax
        Switch that will disable syntax checking of created module.

    .PARAMETER dontIncludeRequires
        Switch that will lead to ignoring all #requires in scripts, so generated module won't contain them.
        Otherwise just module #requires will be added.

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
        $location = Get-Location
        Set-Location $scriptFolder
        $unfinishedFile = @()
        try {
            # uncommited changed files
            $unfinishedFile += @(git ls-files -m --full-name)
            # untracked files
            $unfinishedFile += @(git ls-files --others --exclude-standard --full-name)
        } catch {
            throw "It seems GIT isn't installed. I was unable to get list of changed files in repository $scriptFolder"
        }
        Set-Location $location

        #
        # there are untracked and/or uncommited files
        # instead just ignoring them try to get and use previous version from GIT
        if ($unfinishedFile) {
            [System.Collections.ArrayList] $unfinishedFile = @($unfinishedFile)

            # helper function to be able to catch errors and all outputs
            # dont wait for exit
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
                # $p.WaitForExit() # cannot be used otherwise if git show HEAD:$file returned something, process stuck
                $p.StandardOutput.ReadToEnd()
                if ($err = $p.StandardError.ReadToEnd()) {
                    Write-Error $err
                }
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
                    Write-Warning "$fName has uncommited changed. For module generating I will use its version from previous commit"
                    $lastCommitFileContent.$fName = $lastCommitContent
                    $unfinishedFile.Remove($file)
                }
            }
            Set-Location $location

            # unix / replace by \
            $unfinishedFile = $unfinishedFile -replace "/", "\"
            $unfinishedFileName = $unfinishedFile | % { [System.IO.Path]::GetFileName($_) }

            if ($includeUncommitedUntracked -and $unfinishedFileName) {
                Write-Warning "Exporting changed but uncommited/untracked functions: $($unfinishedFileName -join ', ')"
                $unfinishedFile = @()
            }
        }

        #
        # in ps1 files to export leave just these in consistent state
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

        if (Test-Path $modulePath -ErrorAction SilentlyContinue) {
            Remove-Item $moduleFolder -Recurse -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep 1
        }

        [Void][System.IO.Directory]::CreateDirectory($moduleFolder)

        Write-Verbose "To $modulePath`n"

        # to hash $lastCommitFileContent add  pair, where key is name of function and value is its text definition
        $script2Export | % {
            $script = $_
            $fName = [System.IO.Path]::GetFileNameWithoutExtension($script)
            if ($fName -match "\s+") {
                throw "File $script contains space in name which is nonsense. Name of file has to be same to the name of functions it defines and functions can't contain space in it's names."
            }

            # add function content only in case it isn't added already (to avoid overwrites)
            if (!$lastCommitFileContent.containsKey($fName)) {

                # check, that file contain just one function definition and nothing else
                $ast = [System.Management.Automation.Language.Parser]::ParseFile("$script", [ref] $null, [ref] $null)
                # just END block should exist
                if ($ast.BeginBlock -or $ast.ProcessBlock) {
                    throw "File $script isn't in correct format. It has to contain just function definition (+ alias definition, comment or requires)!"
                }

                # get funtion definition
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

                # use function definition obtained by AST to generating module
                # this way no possible dangerous content will be added
                $content = ""
                if (!$dontIncludeRequires) {
                    # adding module requires
                    $requiredModules = $ast.scriptRequirements.requiredModules.name
                    if ($requiredModules) {
                        $content += "#Requires -Modules $($requiredModules -join ',')`n`n"
                    }
                }
                # replace invalid chars for valid (en dash etc)
                $functionText = $functionDefinition.extent.text -replace [char]0x2013, "-" -replace [char]0x2014, "-"

                # add function text definition
                $content += $functionText

                # add aliases defined by Set-Alias
                $ast.EndBlock.Statements | ? { $_ -match "^\s*Set-Alias .+" } | % { $_.extent.text } | % {
                    $parts = $_ -split "\s+"

                    $content += "`n$_"

                    if ($_ -match "-na") {
                        # alias set by named parameter
                        # get parameter value
                        $i = 0
                        $parPosition
                        $parts | % {
                            if ($_ -match "-na") {
                                $parPosition = $i
                            }
                            ++$i
                        }

                        # save alias for later export
                        $alias2Export += $parts[$parPosition + 1]
                        Write-Verbose "- exporting alias: $($parts[$parPosition + 1])"
                    } else {
                        # alias set by positional parameter
                        # save alias for later export
                        $alias2Export += $parts[1]
                        Write-Verbose "- exporting alias: $($parts[1])"
                    }
                }

                # add aliases defined by [Alias("Some-Alias")]
                $innerAliasDefinition = $ast.FindAll( {
                        param([System.Management.Automation.Language.Ast] $ast)

                        $ast -is [System.Management.Automation.Language.AttributeAst]
                    }, $true) | ? { $_.parent.extent.text -match '^param' } | Select-Object -ExpandProperty PositionalArguments | Select-Object -ExpandProperty Value -ErrorAction SilentlyContinue # filter out aliases for function parameters

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
        # save all functions content to module file
        # store name of every funtion for later use in Export-ModuleMember
        $lastCommitFileContent.GetEnumerator() | % {
            $fName = $_.Key
            $content = $_.Value

            Write-Verbose "- exporting function: $fName"

            $function2Export += $fName

            $content | Out-File $modulePath -Append $enc
            "" | Out-File $modulePath -Append $enc
        }

        #
        # set what functions and aliases should be exported from module
        # explicit export is much faster than use *
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
    } # end of _generatePSModule

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
            # check generated module syntax
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

# helper function to be able to catch errors and all outputs
function _startProcess {
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

    # flattens input in case, that string and arrays are entered at the same time
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
        # it is folder

        $acl = New-Object System.Security.AccessControl.DirectorySecurity

        if ($resetACL) {
            # reset ACL, ie remove explicit ACL and enable inheritance
            $acl.SetAccessRuleProtection($false, $false)
        } else {
            # disable inheritance and remove inherited ACL
            $acl.SetAccessRuleProtection($true, $false)

            $readUser | % {
                $permissions += @(, ("$_", "ReadAndExecute", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            }

            $writeUser | % {
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

            $readUser | % {
                $permissions += @(, ("$_", "ReadAndExecute", 'Allow'))
            }

            $writeUser | % {
                $permissions += @(, ("$_", "FullControl", 'Allow'))
            }
        }
    }

    $permissions | % {
        $ace = New-Object System.Security.AccessControl.FileSystemAccessRule $_
        try {
            $acl.AddAccessRule($ace)
        } catch {
            Write-Warning "Setting of NTFS right wasn't successful. Does given user account exists?"
        }
    }

    try {
        # Set-Acl cannot be used because of bug https://stackoverflow.com/questions/31611103/setting-permissions-on-a-windows-fileshare
        (Get-Item $path).SetAccessControl($acl)
    } catch {
        throw "Setting of NTFS rights wasn't successful: $_"
    }
} # end of _setPermissions
#endregion

try {
    #
    # check that script has write permission to DFS share
    try {
        $rFile = Join-Path $destination Get-Random
        $null = New-Item -Path ($rFile) -ItemType File -Force -Confirm:$false
    } catch {
        _emailAndExit -body "Hi,`nscript doesn't have right to write in $destination. Changes in GIT repository can't be propagated.`nIs computer account $env:COMPUTERNAME in group repo_writer?"
    }
    Remove-Item $rFile -Force -Confirm:$false

    #
    # check that GIT is installed
    try {
        git --version
    } catch {
        _emailAndExit -body "Hi,`nGIT isn't installed on $env:COMPUTERNAME. Changes in GIT repository can't be propagated to $destination.`nInstall it."
    }



    #
    # GET CURRENT CONTENT OF CLOUD GIT REPOSITORY LOCALLY
    #

    #region
    $PS_repo = Join-Path $logFolder PS_repo

    if (Test-Path $PS_repo -ea SilentlyContinue) {
        # there is local copy of GIT repository
        # fetch recent data and replace old ones
        Set-Location $PS_repo
        try {
            # download the latest data from GIT repository without trying to merge or rebase anything
            _startProcess git -argumentList "fetch --all"

            # # ukoncim pokud nedoslo k zadne zmene
            # # ! pripadne manualni upravy v DFS repo se tim padem prepisi az po zmene v cloud repo, ne driv !
            # $status = _startProcess git -argumentList "status"
            # if ($status -match "Your branch is up to date with") {
            #     "nedoslo k zadnym zmenam, ukoncuji"
            #     exit
            # }

            # resets the master branch to what you just fetched. The --hard option changes all the files in your working tree to match the files in origin/master
            _startProcess git -argumentList "reset --hard origin/master"
            # delete untracked files and folders (generated modules etc)
            _startProcess git -argumentList "clean -fd"

            # save last 20 commits
            $commitHistory = _startProcess git -argumentList "log --pretty=format:%h -20"
            $commitHistory = $commitHistory -split "`n" | ? { $_ }
        } catch {
            Set-Location ..
            Remove-Item $PS_repo -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
            _emailAndExit -body "Hi,`nthere was an error when pulling changes from repository. Script deleted local copy of repository and will try git clone next time.`nError was:`n$_."
        }
    } else {
        # there isn't local copy of GIT repository
        # git clone it
        # login.xml should contain repo_puller credentials and should be placed in same folder as this script
        # !credentials are valid for one year, so need to be renewed regularly!
        #__TODO__ to login.xml export GIT credentials (alternate credentials or access token) of repo_puller account (read only account which is used to clone your repository) (details here https://docs.microsoft.com/cs-cz/azure/devops/repos/git/auth-overview?view=azure-devops)
        #__TODO__ how to export credentials https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20-%20INITIAL%20CONFIGURATION.md#on-server-which-will-be-used-for-cloning-and-processing-cloud-repository-data-and-copying-result-to-dfs-ie-mgm-server
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
    #endregion


    #
    # importing variables
    # to be able to limit NTFS rights on folders in Custom, Modules and profile.ps1 etc
    # need to be done before dot sourcing customConfig.ps1 and modulesConfig.ps1
    $repoModules = Join-Path $PS_repo "modules"
    try {
        # at first try to import Variables module pulled from cloud repo (so the newest version)
        Import-Module (Join-Path $repoModules "Variables") -ErrorAction Stop
    } catch {
        # if error, try to import Variables from system location
        # errors are ignored, because on fresh machine, module will be presented right after first run of PS_env_set_up.ps1 not sooner :)
        "importing Variables module from $((Join-Path $repoModules "Variables")) was unsuccessful"
        Import-Module Variables -ErrorAction "Continue"
    }



    #
    # SYNCHRONIZE DATA TO DFS SHARE
    #

    #region sync data to dfs share
    try {
        # import $customConfig
        $customSource = Join-Path $PS_repo "custom"
        $customConfigScript = Join-Path $customSource "customConfig.ps1"

        if (!(Test-Path $customConfigScript -ea SilentlyContinue)) {
            Write-Warning "$customConfigScript is missing, it is problem for 99,99%!"
        } else {
            . $customConfigScript
        }


        # import $modulesConfig
        $modulesSource = Join-Path $PS_repo "modules"
        $modulesConfigScript = Join-Path $modulesSource "modulesConfig.ps1"

        if (!(Test-Path $modulesConfigScript -ea SilentlyContinue)) {
            Write-Warning "$modulesConfigScript is missing"
        } else {
            . $modulesConfigScript
        }

        # synchronize data to DFS share
        _updateRepo -source $PS_repo -destination $destination -force
    } catch {
        _emailAndExit "There was an error when copying changes to DFS repository:`n$_"
    }
    #endregion



    #
    # COPY FOLDERS FROM CUSTOM DIRECTORY THAT HAVE DEFINED CUSTOMSHAREDESTINATION KEY
    # this isn't related to repository synchronization but I don't know here else to put it
    #

    #region copy Custom folders to UNC
    "### Synchronization of Custom data, which are supposed to be in specified shared folder"
    $folderToUnc = $customConfig | ? { $_.customShareDestination }

    foreach ($configData in $folderToUnc) {
        $folderName = $configData.folderName
        $copyJustContent = $configData.copyJustContent
        $customNTFS = $configData.customDestinationNTFS
        $customShareDestination = $configData.customShareDestination
        $folderSource = Join-Path $destination "Custom\$folderName"

        " - folder $folderName should be copied to $($configData.customShareDestination)"

        # check that $customShareDestination is UNC path
        if ($customShareDestination -notmatch "^\\\\") {
            Write-Warning "$customShareDestination isn't UNC path, skipping"
            continue
        }

        # check that source folder exists
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

            # create Log subfolder
            if (!(Test-Path $customLogFolder -ea SilentlyContinue)) {
                " - creation of Log folder $customLogFolder"

                New-Item $customLogFolder -ItemType Directory -Force -Confirm:$false
            }
        }

        if ($result.failures) {
            # just warn about error, it is likely, that it will end succesfully next time (shared folder could be locked now etc)
            Write-Warning "There was an error when copying $folderName`n$($result.errMsg)"
        }

        # limit access by NTFS rights
        # do it on every synch cycle because of possibility, that customDestinationNTFS is defined by variable which value could have changed
        if ($customNTFS -and !$copyJustContent) {
            " - set READ access to accounts in customDestinationNTFS to $folderDestination"
            _setPermissions $folderDestination -readUser $customNTFS -writeUser $writeUser

            " - set FULL CONTROL access to accounts in customDestinationNTFS to $customLogFolder"
            _setPermissions $customLogFolder -readUser $customNTFS -writeUser $writeUser, $customNTFS
        } elseif (!$customNTFS -and !$copyJustContent) {
            # no custom NTFS are set
            # just in case they were set previously reset them, but only in case ACL contains $readUser account ie this script have to set them in past
            $folderhasCustomNTFS = Get-Acl -path $folderDestination | ? { $_.accessToString -like "*$readUser*" }
            if ($folderhasCustomNTFS) {
                " - folder $folderDestination has some custom NTFS even it shouldn't have, resetting"
                _setPermissions -path $folderDestination -resetACL

                " - resetting also on Log subfolder"
                _setPermissions -path $customLogFolder -resetACL
            }
        }
    }
    #endregion
} catch {
    _emailAndExit -body "Hi,`nthere was an error when synchronizing GIT repository to DFS repository share:`n$_"
}