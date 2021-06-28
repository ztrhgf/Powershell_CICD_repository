<#
    .SYNOPSIS
    script is processing GIT cloud repository content and distribute "client" part to DFS share (read only share from which clients will download content to themselves)
    how it works:
    - pull/clone GIT cloud repository locally
    - process cloned content (generate PSM modules from scripts2module, copy Custom content to shares,..)
    - copy processed content which is intended for clients to shared folder (DFS)

    BEWARE, repo_puller account used to pull data from GIT repository has to have 'alternate credentials' created and these credentials has to be exported to login.xml (under account which is used to run this script i.e. SYSTEM)

    .PARAMETER force
    Switch for forcing synchronization of all content, even not changed one.
    If not used, just changes from unprocessed commit will be processed.

    ! USE IT FOR REGULAR SYNCHRONIZATION BY DEFAULT! in other case changes in NTFS permission defined by AD membership will be set only after processing of new commit

    .PARAMETER omitDeletion
    Switch for omitting deletion of needless files.
    Usable for making synchronization as fast as possible.

    .NOTES
    Author: Ondřej Šebela - ztrhgf@seznam.cz
#>

param (
    [switch] $force
    ,
    [switch] $omitDeletion
)

# just in case auto-loading of modules doesn't work
Import-Module Microsoft.PowerShell.Host
Import-Module Microsoft.PowerShell.Security

# for debugging purposes
Start-Transcript (Join-Path "$env:SystemRoot\temp" ((Split-Path $PSCommandPath -Leaf) + ".log"))

$ErrorActionPreference = "stop"

$logFolder = Join-Path $PSScriptRoot "Log"

# explicit import because sometimes it happened, that function autoload won't work
Import-Module Scripts -Function Send-Email -ErrorAction SilentlyContinue

# to avoid spamming, just one email per 30 minutes can be send
$lastSendEmail = Join-Path $logFolder "lastSendEmail"
$treshold = 30

# UNC path to (DFS) share, where repository data for clients are stored and therefore processed content will be copied
$repository = "__REPLACEME__1" # UNC path to DFS repository (ie.: \\myDomain\dfs\repository)

$clonedRepository = Join-Path $logFolder "PS_repo"

$modulesSrc = Join-Path $clonedRepository "modules"
$modulesDst = Join-Path $repository "modules"
$scripts2moduleSrc = Join-Path $clonedRepository "scripts2module"
$scripts2rootSrc = Join-Path $clonedRepository "scripts2root"
$customSrc = Join-Path $clonedRepository "custom"
$customDst = Join-Path $repository "custom"

$somethingChanged = 0

# AD group that has READ right on DFS share
[string] $readUser = "repo_reader"
# AD group that has MODIFY right on DFS share
[string] $writeUser = "repo_writer"

"$(Get-Date -Format HH:mm:ss) - START synchronizing data to $repository"

# path to file that contains hashes of last 20 processed commits
$processedCommitPath = Join-Path $repository commitHistory
# list of hashes of already processed commits
$processedCommit = Get-Content $processedCommitPath -ErrorAction SilentlyContinue | ? { $_ }
# hash of last processed commit
$lastProcessedCommit = $processedCommit | Select-Object -First 1

#__CHECKME__ configure and uncomment one of the rows that initialize variable $signingCert, if you want automatic code signing to happen (using specified certificate)
# certificate which will be used to sign ps1, psm1, psd1 and ps1xml files
# USE ONLY IF YOU KNOW, WHAT ARE YOU DOING
# tutorial how to create self signed certificate http://woshub.com/how-to-sign-powershell-script-with-a-code-signing-certificate/
# set correct path to signing certificate and uncomment to start signing
# $signingCert = Get-PfxCertificate -FilePath C:\Test\Mysign.pfx # something like this, if you want to use locally stored pfx certificate
# $signingCert = (Get-ChildItem cert:\LocalMachine\my –CodeSigningCert)[0] # something like this, if certificate is in store
# certTimeStampServer - Specifies the trusted timestamp server that adds a timestamp to your script's digital signature. Adding a timestamp ensures that your code will not expire when the signing certificate expires.
$certTimeStampServer = "http://timestamp.digicert.com"
if ($signingCert -and $signingCert.EnhancedKeyUsageList.friendlyName -ne "Code Signing") {
    throw "Certificate $($signingCert.DnsNameList) is not valid Code Signing certificate"
}

#
#region helper function
function _exportScripts2Module {
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

    .PARAMETER markAutoGenerated
        Switch will add comment '# _AUTO_GENERATED_' on first line of each module, that was created by this function.
        For internal use, so I can distinguish which modules was created from functions stored in scripts2module and therefore easily generate various reports.

    .EXAMPLE
        _exportScripts2Module @{"C:\DATA\POWERSHELL\repo\scripts" = "c:\DATA\POWERSHELL\repo\modules\Scripts"}
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
        ,
        [switch] $markAutoGenerated
    )

    function _checkSyntax {
        param ($file)
        $syntaxError = @()
        [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$syntaxError)
        return $syntaxError
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

            Set-Location $scriptFolder

            $unfinishedFile2 = $unfinishedFile.Clone()
            $unfinishedFile2 | % {
                $file = $_
                $lastCommitContent = _startProcess git "show HEAD:$file" -dontWait # don't wait because if git show HEAD:$file returned anything, process stuck
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

        # to hash $lastCommitFileContent add pair, where key is name of the function and value is its text definition
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
                $ast.EndBlock.Statements | ? { $_ -match "^\s*Set-Alias .+" -and $_ -match [regex]::Escape($functionDefinition.name) } | % { $_.extent.text } | % {
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

        if ($markAutoGenerated) {
            "# _AUTO_GENERATED_" | Out-File $modulePath $enc
            "" | Out-File $modulePath -Append $enc
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
                Remove-Item $modulePath -Recurse -Force -Confirm:$false
                throw "Exported function contains unnaproved character # in it's name. Module was removed."
            }

            $function2Export = $function2Export | Select-Object -Unique | Sort-Object

            "Export-ModuleMember -function $($function2Export -join ', ')" | Out-File $modulePath -Append $enc
        }

        if ($alias2Export) {
            if ($alias2Export -match "#") {
                Remove-Item $modulePath -Recurse -Force -Confirm:$false
                throw "Exported alias contains unnaproved character # in it's name. Module was removed."
            }

            $alias2Export = $alias2Export | Select-Object -Unique | Sort-Object

            "Export-ModuleMember -alias $($alias2Export -join ', ')" | Out-File $modulePath -Append $enc
        }
    } # end of _generatePSModule

    $scripts2ModuleConfig.GetEnumerator() | % {
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

        Write-Output "      - $(Split-Path $moduleFolder -Leaf)"
        _generatePSModule @param

        if (!$dontCheckSyntax) {
            # check generated module syntax
            Get-ChildItem $moduleFolder -File -Recurse | % {
                $file = $_.FullName
                $syntaxError = _checkSyntax $file
                if ($syntaxError) {
                    throw "In module file $file were found these syntax problems:`n$syntaxError"
                }
            }
        }
    }
} # end of _exportScripts2Module

function _emailAndExit {
    param ($body)

    $body

    if (Get-Command Send-Email -ErrorAction SilentlyContinue) {
        ++$sendEmail
    }

    if ($sendEmail -and (Test-Path $lastSendEmail -ea SilentlyContinue) -and (Get-Item $lastSendEmail).LastWriteTime -gt [datetime]::Now.AddMinutes(-$treshold)) {
        "Last error email was sent less than $treshold minutes...just end"
    } elseif ($sendEmail) {
        $body = $body + "`n`n`nNext failure will be emailed at first after $treshold minutes"
        Send-Email -body $body
        New-Item $lastSendEmail -Force
    }

    throw 1
} # end of _emailAndExit

# helper function to be able to catch errors and all outputs
function _startProcess {
    [CmdletBinding()]
    param (
        [string] $filePath = ''
        ,
        [string] $argumentList = ''
        ,
        [string] $workingDirectory = (Get-Location)
        ,
        [switch] $dontWait
        ,
        # lot of git commands output verbose output to error stream
        [switch] $outputErr2Std
    )

    $p = New-Object System.Diagnostics.Process
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError = $true
    $p.StartInfo.WorkingDirectory = $workingDirectory
    $p.StartInfo.FileName = $filePath
    $p.StartInfo.Arguments = $argumentList
    [void]$p.Start()
    if (!$dontWait) {
        $p.WaitForExit()
    }
    $p.StandardOutput.ReadToEnd()
    if ($outputErr2Std) {
        $p.StandardError.ReadToEnd()
    } else {
        if ($err = $p.StandardError.ReadToEnd()) {
            Write-Error $err
        }
    }
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
            # captures errors like: 2020/04/27 09:01:27 ERROR 2 (0x00000002) Accessing Source Directory C:\temp
            if ($match = ([regex]"^[0-9 /]+ [0-9:]+ ERROR \d+ \([0-9x]+\) (.+)").Match($_).captures.groups) {
                $errMsg += $match[1].value
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

function _flattenArray {
    # flattens input in case, that string and arrays are entered at the same time
    param (
        [array] $inputArray
    )

    foreach ($item in $inputArray) {
        if ($item -ne $null) {
            # recurse for arrays
            if ($item.gettype().BaseType -eq [System.Array]) {
                _flattenArray $item
            } else {
                # output non-arrays
                $item
            }
        }
    }
} # end of _flattenArray

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
        throw "path doesn't exist"
    }

    $readUser = _flattenArray $readUser
    $writeUser = _flattenArray $writeUser

    # adding SYSTEM account
    # for case when data should be copied to server X (so NTFS will be limited to just his account) and that server at the same time hosts shared folder with this repository data. Therefore he uses SYSTEM account for accessing that (in fact locally stored) data, so granting access just for it's computer account wouldn't suffice and lead to access denied
    # write rights because of TEST installation type on Sandbox VM (cannot be restarted, so computer will never be member of repo_writer i.e. cannot update share content once it is copied)
    if (!($writeUser -match 'SYSTEM')) {
        $writeUser = @($writeUser) + 'SYSTEM'
    }

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
        throw "Setting of NTFS permissions wasn't successful: $_"
    }
} # end of _setPermissions
#endregion helper function

try {
    #
    # check that script has write permission to DFS share
    try {
        $rFile = Join-Path $repository Get-Random
        $null = New-Item -Path ($rFile) -ItemType File -Force -Confirm:$false
    } catch {
        _emailAndExit -body "Hi,`nscript doesn't have write permission for $repository. Changes in GIT repository can't be propagated.`nIs computer account $env:COMPUTERNAME in group repo_writer?"
    }
    Remove-Item $rFile -Force -Confirm:$false

    #
    # check that GIT is installed
    try {
        $null = git.exe --version
    } catch {
        _emailAndExit -body "Hi,`nGIT isn't installed on $env:COMPUTERNAME. Changes in GIT repository can't be propagated to $repository.`nInstall it."
    }



    #
    #region PULL NEWEST CONTENT OF CLOUD GIT REPOSITORY LOCALLY
    #

    if (Test-Path $clonedRepository -ea SilentlyContinue) {
        # there is already local copy of GIT repository
        # fetch recent data and replace the old ones
        Set-Location $clonedRepository
        try {
            "$(Get-Date -Format HH:mm:ss) - Pulling newest repository data to $clonedRepository"
            # download the latest data from GIT repository without trying to merge or rebase anything
            $result = _startProcess git -argumentList "fetch --all" -outputErr2Std
            if ($result -match "fatal: ") { throw $result }
            # resets the master branch to what you just fetched. The --hard option changes all the files in your working tree to match the files in origin/master
            "$(Get-Date -Format HH:mm:ss) - Discarding local changes"
            $null = _startProcess git -argumentList "reset --hard origin/master"
            # delete untracked files and folders (generated modules etc)
            _startProcess git -argumentList "clean -fd"

            # last 20 commits
            $commitHistory = _startProcess git -argumentList "log --pretty=format:%h -20"
            $commitHistory = $commitHistory -split "`n" | ? { $_ }
            # latest commit
            $newestCommit = $commitHistory | Select-Object -First 1
            $status = _startProcess git -argumentList "status"
            # end if there are no changes to process
            if (!$force -and $status -match "Your branch is up to date with" -and $lastProcessedCommit -eq $newestCommit) {
                "No changes detected, exiting"
                exit
            }

            "$(Get-Date -Format HH:mm:ss) - Last processed commit: $lastProcessedCommit, newest commit: $newestCommit"
        } catch {
            Set-Location ..
            Remove-Item $clonedRepository -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
            _emailAndExit -body "Hi,`nthere was an error when pulling changes from repository. Script deleted local copy of repository and will try git clone next time.`nError was:`n$_."
        }
    } else {
        # there isn't local copy of GIT repository yet
        # clone it
        # login.xml should contain repo_puller credentials
        #__CHECKME__ to login.xml export GIT credentials (access token in case of Azure DevOps) of repo_puller account (read only account which is used to clone your repository) (what is access token https://docs.microsoft.com/cs-cz/azure/devops/organizations/accounts/use-personal-access-tokens-to-authenticate?view=azure-devops&tabs=preview-page)
        # tutorial how to export credentials safely to xml file https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20-%20INITIAL%20CONFIGURATION.md#on-server-which-will-be-used-for-cloning-and-processing-cloud-repository-data-and-copying-result-to-dfs-ie-mgm-server
        # !credentials are valid for one year, so need to be renewed regularly!
        "$(Get-Date -Format HH:mm:ss) - Cloning repository data to $clonedRepository"
        $force = $true
        try {
            if ("__REPLACEME__2" -match "^[a-z]{1}:") {
                # its local path (hack because of TEST installation)
                $result = _startProcess git -argumentList "clone --local `"__REPLACEME__2`" `"$clonedRepository`"" -outputErr2Std
            } else {
                # its URL
                $acc = Import-Clixml "$PSScriptRoot\login.xml"
                $l = $acc.UserName
                $p = $acc.GetNetworkCredential().Password
                # instead __REPLACEME__ use URL of your company repository (i.e. something like: dev.azure.com/ztrhgf/WUG_show/_git/WUG_show). Final URL will than be something like this: https://altLogin:altPassword@dev.azure.com/ztrhgf/WUG_show/_git/WUG_show)
                $result = _startProcess git -argumentList "clone `"https://$l`:$p@__REPLACEME__2`" `"$clonedRepository`"" -outputErr2Std
            }
            if ($result -match "fatal: ") { throw $result }
        } catch {
            Remove-Item $clonedRepository -Recurse -Force -Confirm:$false -ErrorAction SilentlyContinue
            _emailAndExit -body "Hi,`nthere was an error when cloning repository.`nError was: $_."
        }
    }
    #endregion PULL NEWEST CONTENT OF CLOUD GIT REPOSITORY LOCALLY



    #
    #region SYNCHRONIZE DATA TO DFS SHARE
    #
    try {
        # import Variables module
        # to be able to limit NTFS rights on folders in Custom, Modules and profile.ps1 etc
        # need to be done before dot sourcing customConfig.ps1 and modulesConfig.ps1
        "$(Get-Date -Format HH:mm:ss) - Importing module Variables"
        try {
            # at first try to import Variables module pulled from cloud repo (so the newest version)
            Import-Module (Join-Path $modulesSrc "Variables") -ErrorAction Stop
        } catch {
            # if error, try to import Variables from system location
            # errors are ignored, because on fresh machine, module will be presented right after first run of PS_env_set_up.ps1 not sooner :)
            "importing Variables module from $((Join-Path $modulesSrc "Variables")) was unsuccessful"
            Import-Module Variables -ErrorAction "Continue"
        }

        # import $customConfig
        "$(Get-Date -Format HH:mm:ss) - Dot sourcing customConfig.ps1"
        $customConfigScript = Join-Path $customSrc "customConfig.ps1"

        if (!(Test-Path $customConfigScript -ea SilentlyContinue)) {
            Write-Warning "$customConfigScript is missing, it is problem for 99,99%!"
        } else {
            . $customConfigScript
        }

        # import $modulesConfig
        "$(Get-Date -Format HH:mm:ss) - Dot sourcing modulesConfig.ps1"
        $modulesConfigScript = Join-Path $modulesSrc "modulesConfig.ps1"

        if (!(Test-Path $modulesConfigScript -ea SilentlyContinue)) {
            Write-Warning "$modulesConfigScript is missing"
        } else {
            . $modulesConfigScript
        }

        # get changed files from last processed commit to the most recent one
        if ($lastProcessedCommit) {
            $changedFile = @(git diff --name-only $lastProcessedCommit HEAD)
        } else {
            # probably the first run
            $force = $true
        }

        # variable will contain files, that cannot be copied to DFS share
        $location = Get-Location
        Set-Location $clonedRepository
        try {
            # locally cloned GIT repository state
            $repoStatus = git status -uno
        } catch {
            $err = $_
            if ($err -match "is not recognized as the name of a cmdlet") {
                Set-Location $location
                throw "git command failed. Is GIT installed? Error was:`n$err"
            } else {
                Set-Location $location
                throw $err
            }
        }
        Set-Location $location

        if (!$changedFile -and !$force) {
            Write-Warning "`nIn repository there are no changes detected.`nIf you want to copy data anyway, use -force switch`n`n"
        }

        # git command return path with /, replace to \
        $changedFile = $changedFile -replace "/", "\"

        $changedVariables = $changedFile | ? { $_ -match "^modules\\Variables\\" }



        #
        #region SYNCHRONIZE MODULES
        #

        #
        #region generate powershell module from scripts2module
        # special hashtable for function _exportScripts2Module to define, what modules it should generate
        $scripts2ModuleConfig = @{ }

        if ($force) {
            # generate all modules no matter if there was any change
            Get-ChildItem $scripts2moduleSrc -Directory | Select-Object -ExpandProperty FullName | % {
                $moduleName = Split-Path $_ -Leaf
                $absPath = $_
                $moduleName = (Get-Culture).TextInfo.ToTitleCase($moduleName)
                $scripts2ModuleConfig[$absPath] = Join-Path $modulesSrc $moduleName
            }
        } else {
            # generate just modules where some change in source script data was made
            $changedFile | ? { $_ -match "^scripts2module\\" } | % { ($_ -split "\\")[-2] } | Select-Object -Unique | % {
                if ((Get-ChildItem $scripts2moduleSrc -Directory | select -exp Name) -contains $_) {
                    $moduleName = $_
                    $absPath = Join-Path $scripts2moduleSrc $moduleName
                    $moduleName = (Get-Culture).TextInfo.ToTitleCase($moduleName)
                    $scripts2ModuleConfig[$absPath] = Join-Path $modulesSrc $moduleName
                } else {
                    # module was deleted
                    "   - $_ was deleted"
                }
            }
        }

        # generate Powershell modules from scripts2module content
        if ($scripts2ModuleConfig.Keys.count) {
            "$(Get-Date -Format HH:mm:ss) - Generating modules from $scripts2moduleSrc"
            ++$somethingChanged

            _exportScripts2Module -configHash $scripts2ModuleConfig -dontIncludeRequires -markAutoGenerated
            "$(Get-Date -Format HH:mm:ss) - Finished generating modules"
        }
        #endregion generate powershell module from scripts2module

        # name of modules changed from last processed commit
        $changedModule = $changedFile | ? { $_ -match "^scripts2module\\" -or $_ -match "^modules\\" } | % { ($_ -split "\\")[-2] } | Select-Object -Unique
        $changedModulesConfig = $changedFile | ? { $_ -match "^modules\\modulesConfig.ps1$" }

        #region copy content of modules to DFS share
        if ($changedModule -or $force) {
            [Void][System.IO.Directory]::CreateDirectory($modulesDst)
            if (!(Test-Path $modulesDst -ErrorAction SilentlyContinue)) {
                throw "Path $modulesDst isn't accessible"
            }

            ++$somethingChanged

            "$(Get-Date -Format HH:mm:ss) - Copying Modules data to $modulesDst"

            foreach ($item in (Get-ChildItem $modulesSrc)) {
                $itemName = $item.Name
                $itemPath = $item.FullName

                if (!$force -and $itemName -notin $changedModule) { continue }

                "       - $itemName"

                if ((Get-Item $itemPath).attributes -ne "Directory") { $isFile = 1 } else { $isFile = 0 }

                # sign Powershell files if requested
                if ($signingCert) {
                    if ($isFile) {
                        $sign = $item.FullName
                    } else {
                        $sign = Get-ChildItem $itemPath -Recurse -Include *.ps1, *.psm1, *.psd1, *.ps1xml -File | select -exp FullName
                    }

                    $sign | % {
                        $notSigned = Get-AuthenticodeSignature $_ | ? { $_.status -eq "NotSigned" }
                        if ($notSigned) {
                            Set-AuthenticodeSignature -Certificate $signingCert -FilePath $_ -TimestampServer $certTimeStampServer
                        } else {
                            Write-Verbose "File $_ is already signed, skipping"
                        }
                    }
                }

                # copy content to DFS share
                if ($isFile) {
                    Copy-Item $itemPath $modulesDst -Force
                } else {
                    $result = _copyFolder -source $itemPath -destination (Join-Path $modulesDst $itemName) -mirror

                    if ($result.deleted) {
                        "               - deleted unnecessary files:`n$(($result.deleted) -join "`n")"
                    }

                    if ($result.failures) {
                        # just warn about error, it is likely, that it will end successfully next time (folder could be locked now etc)
                        Write-Error "There was an error when copying $itemName`:`n$($result.errMsg)"
                    }
                }
            }
        }
        #endregion copy content of modules to DFS share

        #region set NTFS permission on Modules in DFS share
        # so just computers listed in computerName key in modulesConfig variable can access it
        # in case computerName is not set NTFS permissions will be reset
        # set only if files that defined permissions have changed (modulesConfig.ps1, Variables module)
        # BEWARE, that if you use variable which is filled dynamically (by AD membership etc) to limit computerName or permissions, change will be made only after new commit occurs or force switch will be used!
        if ($changedModulesConfig -or $changedVariables -or $force) {
            "$(Get-Date -Format HH:mm:ss) - Setting NTFS permission on Modules"
            foreach ($folder in (Get-ChildItem $modulesDst -Directory)) {
                $folder = $folder.FullName
                $folderName = Split-Path $folder -Leaf

                # $modulesConfig was loaded by dot sourcing modulesConfig.ps1 script file
                $configData = $modulesConfig | ? { $_.folderName -eq $folderName }
                if ($configData -and ($configData.computerName)) {
                    # it is defined, where this module should be copied
                    # limit NTFS rights accordingly
                    $readUserC = $configData.computerName
                    # computer AD accounts end with $
                    $readUserC = (_flattenArray $readUserC) | % { $_ + "$" }
                    "       - limiting NTFS permissions on $folderName`n            - access just for: $($readUserC -join ', ')"
                    _setPermissions $folder -readUser $readUserC -writeUser $writeUser
                } else {
                    # it is not defined, where this module should be copied
                    # reset NTFS rights to default
                    "       - resetting NTFS permissions on $folderName"
                    _setPermissions $folder -resetACL
                }
            }
        }
        #endregion set NTFS permission on Modules in DFS share

        #
        #region remove empty and needless Module folders from DFS share
        if (!$omitDeletion -or $force) {
            "$(Get-Date -Format HH:mm:ss) - Deleting needless Module folders"
            $allModule = (Get-ChildItem $scripts2moduleSrc -Directory | select -exp Name) + (Get-ChildItem $modulesSrc -Directory | select -exp Name)
            Get-ChildItem $modulesDst -Directory | % {
                $item = $_.FullName
                $itemName = $_.Name
                if ($itemName -notin $allModule -or (!(Get-ChildItem $item -Recurse -File))) {
                    try {
                        "       - $itemName"
                        Remove-Item $item -Force -Recurse -Confirm:$false
                    } catch {
                        Write-Error "There was an error when deleting $item`:`n`n$_"
                    }
                }
            }
        }
        #endregion remove empty and needless Module folders from DFS share

        #endregion SYNCHRONIZE MODULES



        #
        #region SYNCHRONIZE SCRIPTS2ROOT
        #

        # name of scripts2root files changed from last processed commit
        $changedSripts2root = $changedFile | ? { $_ -match "^scripts2root\\" } | % { Split-Path $_ -Leaf }

        if ($changedSripts2root -or $force) {
            "$(Get-Date -Format HH:mm:ss) - Copying root files from $scripts2rootSrc to $repository"
            # copy all files that can be copied
            foreach ($item in (Get-ChildItem $scripts2rootSrc -File)) {
                $itemName = $item.Name
                $itemPath = $item.FullName

                if (!$force -and $itemName -notin $changedSripts2root) { continue }

                ++$somethingChanged

                "       - $itemName"

                try {
                    # signing the script if requested
                    if ($signingCert -and $itemName -match "ps1$|psd1$|psm1$|ps1xml$") {
                        $notSigned = Get-AuthenticodeSignature $itemPath | ? { $_.status -eq "NotSigned" }
                        if ($notSigned) {
                            Set-AuthenticodeSignature -Certificate $signingCert -FilePath $itemPath -TimestampServer $certTimeStampServer
                        } else {
                            Write-Verbose "File $itemPath is already signed, skipping"
                        }
                    }

                    Copy-Item $itemPath $repository -Force -ErrorAction Stop

                    # in case of profile.ps1 limit NTFS permissions just to computers which should download it
                    if ($itemName -match "\\profile\.ps1$") {
                        $destProfile = (Join-Path $repository "profile.ps1")
                        if ($_computerWithProfile) {
                            # computer AD accounts end with $
                            $readUserP = (_flattenArray $_computerWithProfile) | % { $_ + "$" }

                            "       - limiting NTFS permissions on $destProfile`n            - access just for: $($readUserP -join ', ')"
                            _setPermissions $destProfile -readUser $readUserP -writeUser $writeUser
                        } else {
                            "       - resetting NTFS permissions on $destProfile"
                            _setPermissions $destProfile -resetACL
                        }
                    }
                } catch {
                    Write-Error "There was an error when copying root file $itemName`:`n`n$_"
                }
            }
        }



        #
        # DELETE NEEDLESS FILES FROM DFS SHARE ROOT
        #
        if (!$omitDeletion -or $force) {
            "$(Get-Date -Format HH:mm:ss) - Deleting needless files from root of $repository"
            $destinationRootFile = Get-ChildItem $repository -File | ? { $_.extension } # don't want to delete 'commitHistory'
            $sourceScripts2Root = Get-ChildItem $scripts2rootSrc -File | Select-Object -ExpandProperty Name
            $destinationRootFile | % {
                $item = $_
                $itemName = $item.Name
                $itemPath = $item.FullName
                if ($sourceScripts2Root -notcontains $itemName) {
                    try {
                        Write-Verbose "     - $itemName"
                        Remove-Item $itemPath -Force -Confirm:$false -ErrorAction Stop
                    } catch {
                        Write-Error "There was an error when deleting file $itemName`:`n`n$_"
                    }
                }
            }
        }
        #endregion SYNCHRONIZE SCRIPTS2ROOT



        #
        #region SYNCHRONIZE CUSTOM
        #

        # name of Custom folders changed from last processed commit
        $changedCustom = $changedFile | ? { $_ -match "^custom\\.+" } | % { ($_ -split "\\")[1] } | Select-Object -Unique
        $changedCustomConfig = $changedFile | ? { $_ -match "^custom\\customConfig.ps1$" }

        if ($changedCustom -or $force) {
            [Void][System.IO.Directory]::CreateDirectory($customDst)
            if (!(Test-Path $customSrc -ErrorAction SilentlyContinue)) {
                throw "Path $customSrc isn't accessible"
            }

            ++$somethingChanged

            "$(Get-Date -Format HH:mm:ss) - Copying Custom data to $customDst"

            foreach ($item in (Get-ChildItem $customSrc)) {
                $itemName = $item.Name
                $itemPath = $item.FullName

                if (!$force -and $itemName -notin $changedCustom) { continue }

                "       - $itemName"

                if ((Get-Item $itemPath).attributes -ne "Directory") { $isFile = 1 } else { $isFile = 0 }

                # signing Powershell files if requested
                if ($signingCert) {
                    if ($isFile) {
                        $sign = $item.FullName
                    } else {
                        $sign = Get-ChildItem $itemPath -Recurse -Include *.ps1, *.psm1, *.psd1, *.ps1xml -File | select -exp FullName
                    }

                    $sign | % {
                        $notSigned = Get-AuthenticodeSignature $_ | ? { $_.status -eq "NotSigned" }
                        if ($notSigned) {
                            Set-AuthenticodeSignature -Certificate $signingCert -FilePath $_ -TimestampServer $certTimeStampServer
                        } else {
                            Write-Verbose "File $_ is already signed, skipping"
                        }
                    }
                }

                # copy content to DFS share
                if ($isFile) {
                    Copy-Item $itemPath $customDst -Force
                } else {
                    $result = _copyFolder -source $itemPath -destination (Join-Path $customDst $itemName) -mirror

                    if ($result.deleted) {
                        "           - deleted unnecessary files:`n$(($result.deleted) -join "`n")"
                    }

                    if ($result.failures) {
                        # just warn about error, it is likely, that it will end successfully next time (folder could be locked now etc)
                        Write-Error "There was an error when copying $itemName`:`n$($result.errMsg)"
                    }
                }
            }
        }

        #region set NTFS permission on Custom folders in DFS share
        # so just computers listed in computerName or customSourceNTFS key in customConfig variable can access it
        # in case neither of this keys are set, NTFS permissions will be reset
        # set only if files that defined permissions have changed (customConfig.ps1, Variables module)
        # BEWARE, that if you use variable which is filled dynamically (by AD membership etc) to limit computerName or permissions, change will be made only after new commit occurs or force switch will be used!
        if ($changedCustomConfig -or $changedVariables -or $force) {
            "$(Get-Date -Format HH:mm:ss) - Setting NTFS permission on Custom"
            foreach ($folder in (Get-ChildItem $customDst -Directory)) {
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
                        $readUserC = $configData.computerName
                        # computer AD ucty maji $ za svym jmenem, pridam
                        $readUserC = (_flattenArray $readUserC) | % { $_ + "$" }
                    }

                    "       - limiting NTFS permissions on $folderName`n            - access just for: $($readUserC -join ', ')"
                    _setPermissions $folder -readUser $readUserC -writeUser $writeUser
                } else {
                    # it is not defined, where this folder should be copied
                    # reset NTFS rights to default
                    "       - resetting NTFS permissions on $folderName"
                    _setPermissions $folder -resetACL
                }
            }
        }
        #endregion set NTFS permission on Custom folders in DFS share

        #
        #region remove empty and needless Custom folders from DFS share
        if (!$omitDeletion -or $force) {
            "$(Get-Date -Format HH:mm:ss) - Deleting needless Custom folders"
            Get-ChildItem $customDst -Directory | % {
                $item = $_.FullName
                $itemName = $_.Name
                if ($itemName -notin (Get-ChildItem $customSrc -Directory | select -exp Name) -or (!(Get-ChildItem $item -Recurse -File))) {
                    try {
                        "           - $itemName"
                        Remove-Item $item -Force -Recurse -Confirm:$false
                    } catch {
                        Write-Error "There was an error when deleting $item`:`n`n$_"
                    }
                }
            }
        }
        #endregion remove empty and needless Custom folders from DFS share

        #endregion SYNCHRONIZE CUSTOM



        #
        #region WARN IF NO CHANGE WAS DETECTED
        #

        # these files are not copied to DFS share but could be changed, take a note if this is the case to now show warning unnecessarily
        if ($changedFile -match "\.githooks\\|\.vscode\\|\.gitignore|!!!README!!!|powershell\.json") {
            ++$somethingChanged
        }

        if (!$somethingChanged) {
            Write-Warning "In $clonedRepository nothing has changed. Use force switch if you want to copy content anyway."
        }
        #endregion WARN IF NO CHANGE WAS DETECTED
    } catch {
        _emailAndExit "There was an error when copying changes to DFS repository:`n$_"
    }
    #endregion SYNCHRONIZE DATA TO DFS SHARE



    #
    #region COPY FOLDERS FROM CUSTOM DIRECTORY THAT HAVE DEFINED CUSTOMSHAREDESTINATION KEY
    # this isn't related to repository synchronization but I don't know where else to put it
    #
    $customToUNC = $customConfig | ? { $_.customShareDestination }
    $changedCustomToUNC = $customToUNC | ? { $_.folderName -in $changedCustom }

    if ($changedCustomToUNC -or $force) {
        "$(Get-Date -Format HH:mm:ss) - Synchronizing Custom data, that should be copied to UNC"
        foreach ($configData in $customToUNC) {
            $folderName = $configData.folderName
            $copyJustContent = $configData.copyJustContent
            $customNTFS = $configData.customDestinationNTFS
            $customShareDestination = $configData.customShareDestination
            $folderSource = Join-Path $repository "Custom\$folderName"

            if (!$force -and $folderName -notin $changedCustomToUNC.folderName) { continue }

            "       - $folderName"

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

                "           - copying to $folderDestination (in merge mode)"

                $result = _copyFolder -source $folderSource -destination $folderDestination
            } else {
                $folderDestination = Join-Path $customShareDestination $folderName
                $customLogFolder = Join-Path $folderDestination "Log"

                "           - copying to $folderDestination (in replace mode)"

                $result = _copyFolder -source $folderSource -destination $folderDestination -excludeFolder $customLogFolder -mirror

                # create Log subfolder
                if (!(Test-Path $customLogFolder -ea SilentlyContinue)) {
                    "           - creating Log subfolder"

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
                "           - setting READ access to accounts in customDestinationNTFS"
                _setPermissions $folderDestination -readUser $customNTFS -writeUser $writeUser

                "           - setting FULL CONTROL access to accounts in customDestinationNTFS to Log subfolder"
                _setPermissions $customLogFolder -readUser $customNTFS -writeUser $writeUser, $customNTFS
            } elseif (!$customNTFS -and !$copyJustContent) {
                # no custom NTFS are set
                # just in case they were set previously reset them, but only in case ACL contains $readUser account ie this script have to set them in past
                $folderhasCustomNTFS = Get-Acl -Path $folderDestination | ? { $_.accessToString -like "*$readUser*" }
                if ($folderhasCustomNTFS) {
                    "           - resetting NTFS permissions"
                    _setPermissions -path $folderDestination -resetACL

                    "           - resetting NTFS permission on Log subfolder"
                    _setPermissions -path $customLogFolder -resetACL
                }
            }
        }
    }
    #endregion COPY FOLDERS FROM CUSTOM DIRECTORY THAT HAVE DEFINED CUSTOMSHAREDESTINATION KEY



    #
    # SAVE COMMITS HISTORY TO FILE IN DFS SHARE ROOT
    # for clients to be able to determine how many commits is their running Powershell console behind the client itself
    # and for this script to determine whether commits were processed succefully i.e. can exit if doesn't detect any new commit
    #

    if ($commitHistory) {
        "$(Get-Date -Format HH:mm:ss) - Saving processed commit history to $processedCommitPath"
        $commitHistory | Out-File $processedCommitPath -Force
    }

    "$(Get-Date -Format HH:mm:ss) - END"
} catch {
    _emailAndExit -body "Hi,`nthere was an error (line $($_.InvocationInfo.ScriptLineNumber)) when synchronizing GIT repository to DFS repository share:`n$($_.Exception)"
}

# TODO doresit ze po cerstve instalaci GITu se mi stalo ze nedetekoval GIT v path (az po restartu) tzn zkusit pouzit cestu do program files?
