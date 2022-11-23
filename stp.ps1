#Requires -Version 5.1

#FIXME predelat na auth pomoci PAT
<#
.SYNOPSIS
Installation script for PowerShell managing solution hosted at https://github.com/ztrhgf/Powershell_CICD_repository
Contains same steps as described at https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md

.DESCRIPTION
Installation script for PowerShell managing solution hosted at https://github.com/ztrhgf/Powershell_CICD_repository
Contains same steps as described at https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md

.PARAMETER noEnvModification
Switch to omit changes of your environment i.e. just customization of cloned folders content 'repo_content_set_up' will be made.

.PARAMETER iniFile
Path to text ini file that this script uses as storage for values the user entered during this scripts run.
So next time, they can be used to speed up whole installation process.

Default is "Powershell_CICD_repository.ini" in root of user profile, so it can't be replaced when user reset cloned repository etc.

.NOTES
Author: Ondřej Šebela - ztrhgf@seznam.cz
#>

[CmdletBinding()]
param (
    [switch] $noEnvModification
    ,
    [string] $iniFile = (Join-Path $env:USERPROFILE "Powershell_CICD_repository.ini")
)

Begin {
    $Host.UI.RawUI.WindowTitle = "Installer of PowerShell CI/CD solution"

    $transcript = Join-Path $env:USERPROFILE ((Split-Path $PSCommandPath -Leaf) + ".log")
    $null = Start-Transcript $transcript -Force

    $ErrorActionPreference = "Stop"

    #region Variables
    $isserver = $notadmin = $notadadmin = $noadmodule = $nogpomodule = $skipad = $skipgpo = $mgmserver = $accessdenied = $repositoryhostsession = $mgmserversession = 0

    # char that is between name of variable and its value in ini file
    $divider = "="
    # list of variables needed for installation, will be saved to iniFile
    $setupVariable = @{}
    # name of GPO that will be used for connecting computers to this solution
    $GPOname = 'PS_env_set_up'

    $userRepositoryWasntEmpty = $false

    # hardcoded PATHs for TEST installation
    $remoteRepository = "$env:SystemDrive\myCompanyRepository_remote"
    #endregion Variables

    # Detect if Server
    if ((Get-WmiObject -Class Win32_OperatingSystem).ProductType -in (2, 3)) {
        ++$isServer
    }

    #region helper functions
    function _pressKeyToContinue {
        Write-Host "`nPress any key to continue" -NoNewline
        $null = [Console]::ReadKey('?')
    }

    function _continue {
        param ($text, [switch] $passthru)

        $t = "Continue? (Y|N)"
        if ($text) {
            $t = "$text. $t"
        }

        $choice = ""
        while ($choice -notmatch "^[Y|N]$") {
            $choice = Read-Host $t
        }
        if ($choice -eq "N") {
            if ($passthru) {
                return $choice
            } else {
                break
            }
        }

        if ($passthru) {
            return $choice
        }
    }

    function _skip {
        param ($text)

        $t = "Skip? (Y|N)"
        if ($text) {
            $t = "$text. $t"
        }
        $t = "`n$t"

        $choice = ""
        while ($choice -notmatch "^[Y|N]$") {
            $choice = Read-Host $t
        }
        if ($choice -eq "N") {
            return $false
        } else {
            return $true
        }
    }

    function _getComputerMembership {
        # Pull the gpresult for the current server
        $Lines = & "$env:windir\system32\gpresult.exe" /s $env:COMPUTERNAME /v /SCOPE COMPUTER
        # Initialize arrays
        $cgroups = @()
        # Out equals false by default
        $Out = $False
        # Define start and end lines for the section we want
        $start = "The computer is a part of the following security groups"
        $end = "Resultant Set Of Policies for Computer"
        # Loop through the gpresult output looking for the computer security group section
        ForEach ($Line In $Lines) {
            If ($Line -match $start) { $Out = $True }
            If ($Out -eq $True) { $cgroups += $Line }
            If ($Line -match $end) { Break }
        }
        $cgroups | % { $_.trim() }
    }

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
    }

    function _setVariable {
        # function defines variable and fills it with value find in ini file or entered by the user
        param ([string] $variable, [string] $readHost, [switch] $YNQuestion, [switch] $optional, [switch] $passThru)

        $value = $setupVariable.GetEnumerator() | ? { $_.name -eq $variable -and $_.value } | select -ExpandProperty value
        if (!$value) {
            if ($YNQuestion) {
                $value = ""
                while ($value -notmatch "^[Y|N]$") {
                    $value = Read-Host "    - $readHost (Y|N)"
                }
            } else {
                if ($optional) {
                    $value = Read-Host "    - (OPTIONAL) Enter $readHost"
                } else {
                    while (!$value) {
                        $value = Read-Host "    - Enter $readHost"
                    }
                }
            }
        } else {
            # Write-Host "   - variable '$variable' will be: $value" -ForegroundColor Gray
        }
        if ($value) {
            # replace whitespaces so as quotes
            $value = $value -replace "^\s*|\s*$" -replace "^[`"']*|[`"']*$"
            $setupVariable.$variable = $value
            New-Variable $variable $value -Scope script -Force -Confirm:$false
        } else {
            if (!$optional) {
                throw "Variable $variable is mandatory!"
            }
        }

        if ($passThru) {
            return $value
        }
    }

    function _unsetVariable {
        # function defines variable and fills it with value find in ini file or entered by the user
        param ([string] $variable)

        $setupVariable.$variable = $null
    }


    function _setVariableValue {
        # function defines variable and fills it with given value
        param ([string] $variable, $value, [switch] $passThru)

        if (!$value) { throw "Undefined value" }

        # replace whitespaces so as quotes
        $value = $value -replace "^\s*|\s*$" -replace "^[`"']*|[`"']*$"
        $setupVariable.$variable = $value
        New-Variable $variable $value -Scope script -Force -Confirm:$false

        if ($passThru) {
            return $value
        }
    }


    function _saveInput {
        # call after each successfully ended section, so just correct inputs will be stored
        if (Test-Path $iniFile -ErrorAction SilentlyContinue) {
            Remove-Item $iniFile -Force -Confirm:$false
        }
        $setupVariable.GetEnumerator() | % {
            if ($_.name -and $_.value) {
                $_.name + "=" + $_.value | Out-File $iniFile -Append -Encoding utf8
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
            throw "Path isn't accessible"
        }

        $permissions = @()

        if (Test-Path $path -PathType Container) {
            # it is folder
            $acl = New-Object System.Security.AccessControl.DirectorySecurity

            if ($resetACL) {
                # reset ACL, i.e. remove explicit ACL and enable inheritance
                $acl.SetAccessRuleProtection($false, $false)
            } else {
                # disable inheritance and remove inherited ACL
                $acl.SetAccessRuleProtection($true, $false)

                if ($readUser) {
                    $readUser | ForEach-Object {
                        $permissions += @(, ("$_", 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                    }
                }
                if ($writeUser) {
                    $writeUser | ForEach-Object {
                        $permissions += @(, ("$_", 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                    }
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

                if ($readUser) {
                    $readUser | ForEach-Object {
                        $permissions += @(, ("$_", 'ReadAndExecute', 'Allow'))
                    }
                }

                if ($writeUser) {
                    $writeUser | ForEach-Object {
                        $permissions += @(, ("$_", 'FullControl', 'Allow'))
                    }
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

        Begin {
            [Void][System.IO.Directory]::CreateDirectory($destination)
        }

        Process {
            if ($mirror) {
                $result = & "$env:windir\system32\robocopy.exe" "$source" "$destination" /MIR /E /NFL /NDL /NJH /R:4 /W:5 /XD "$excludeFolder"
            } else {
                $result = & "$env:windir\system32\robocopy.exe" "$source" "$destination" /E /NFL /NDL /NJH /R:4 /W:5 /XD "$excludeFolder"
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
    }

    function _installGIT {
        $installedGITVersion = ( (Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*) + (Get-ItemProperty HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*) | ? { $_.DisplayName -and $_.Displayname -match '^Git' }) | select -ExpandProperty DisplayVersion

        if (!$installedGITVersion -or $installedGITVersion -as [version] -lt "2.27.0") {
            # get latest download url for git-for-windows 64-bit exe
            $url = "https://api.github.com/repos/git-for-windows/git/releases/latest"
            if ($asset = Invoke-RestMethod -Method Get -Uri $url | % { $_.assets } | ? { $_.name -like "*64-bit.exe" }) {
                # Download Git Installer File
                "      - downloading"
                $installer = "$env:temp\$($asset.name)"
                $ProgressPreference = 'SilentlyContinue'
                Invoke-WebRequest $asset.browser_download_url -OutFile $installer
                $ProgressPreference = 'Continue'

                # Install Git
                "      - installing"
                $install_args = "/SP- /VERYSILENT /SUPPRESSMSGBOXES /NOCANCEL /NORESTART /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS"
                Start-Process -FilePath $installer -ArgumentList $install_args -Wait

                Start-Sleep 3

                # update PATH
                $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

            } else {
                Write-Warning "Skipped!`nURL $url isn't accessible, install GIT manually"

                _continue
            }
        } else {
            "      - already installed"
        }
    }

    function _installGITCredManager {
        $ErrorActionPreference = "Stop"
        $url = "https://github.com/Microsoft/Git-Credential-Manager-for-Windows/releases/latest"
        $asset = Invoke-WebRequest $url -UseBasicParsing
        try {
            $durl = (($asset.RawContent -split "`n" | ? { $_ -match '<a href="/.+\.exe"' }) -split '"')[1]
        } catch {}
        if ($durl) {
            # Downloading Git Credential Manager
            $url = "github.com" + $durl
            $installer = "$env:temp\gitcredmanager.exe"
            "      - downloading"
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest $url -OutFile $installer
            $ProgressPreference = 'Continue'

            # Installing Git Credential Manager
            "      - installing"
            $install_args = "/VERYSILENT /SUPPRESSMSGBOXES /NOCANCEL /NORESTART /CLOSEAPPLICATIONS /RESTARTAPPLICATIONS"
            Start-Process -FilePath $installer -ArgumentList $install_args -Wait
        } else {
            Write-Warning "Skipped!`nURL $url isn't accessible, install GIT Credential Manager for Windows manually"

            _continue
        }
    }

    function _installVSC {
        # Test if Microsoft VS Code is already installed
        $codeCmdPath = "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd"
        if ((Test-Path "$env:ProgramFiles\Microsoft VS Code\Code.exe") -or (Test-Path "$env:USERPROFILE\AppData\Local\Programs\Microsoft VS Code\Code.exe")) {
            "      - already installed"
            return
        }
        # Downloading Microsoft VS Code
        $vscInstaller = "$env:TEMP\vscode-stable.exe"
        Remove-Item -Force $vscInstaller -ErrorAction SilentlyContinue
        "      - downloading"
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest "https://update.code.visualstudio.com/latest/win32-x64/stable" -OutFile $vscInstaller
        $ProgressPreference = 'Continue'

        # Installing Microsoft VS Code
        "      - installing"
        $loadInf = '@
[Setup]
Lang=english
Dir=C:\Program Files\Microsoft VS Code
Group=Visual Studio Code
NoIcons=0
Tasks=desktopicon,addcontextmenufiles,addcontextmenufolders,addtopath
@'
        $infPath = Join-Path $env:TEMP load.inf
        $loadInf | Out-File $infPath
        Start-Process $vscInstaller -ArgumentList "/VERYSILENT /LOADINF=${infPath} /mergetasks=!runcode" -Wait
    }

    function _createSchedTask {
        param ($xmlDefinition, $taskName)
        $result = schtasks /CREATE /XML "$xmlDefinition" /TN "$taskName" /F

        if (!$?) {
            throw "Unable to create scheduled task $taskName"
        }
    }

    function _startSchedTask {
        param ($taskName)
        $result = schtasks /RUN /I /TN "$taskName"

        if (!$?) {
            throw "Task $taskName finished with error. Check '$env:SystemRoot\temp\repo_sync.ps1.log'"
        }
    }

    function _exportCred {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [System.Management.Automation.PSCredential] $credential
            ,
            [string] $xmlPath = "$env:SystemDrive\temp\login.xml"
            ,
            [Parameter(Mandatory = $true)]
            [string] $runAs
        )

        begin {
            # transform relative path to absolute
            try {
                $null = Split-Path $xmlPath -Qualifier -ErrorAction Stop
            } catch {
                $xmlPath = Join-Path (Get-Location) $xmlPath
            }

            # remove existing xml
            Remove-Item $xmlPath -ErrorAction SilentlyContinue -Force

            # create destination folder
            [Void][System.IO.Directory]::CreateDirectory((Split-Path $xmlPath -Parent))
        }

        process {
            $login = $credential.UserName
            $pswd = $credential.GetNetworkCredential().password

            $command = @"
            # just in case auto-load of modules would be broken
            import-module `$env:windir\System32\WindowsPowerShell\v1.0\Modules\Microsoft.PowerShell.Security -ErrorAction Stop
            `$pswd = ConvertTo-SecureString `'$pswd`' -AsPlainText -Force
            `$credential = New-Object System.Management.Automation.PSCredential $login, `$pswd
            Export-Clixml -inputObject `$credential -Path $xmlPath -Encoding UTF8 -Force -ErrorAction Stop
"@

            # encode as base64
            $bytes = [System.Text.Encoding]::Unicode.GetBytes($command)
            $encodedString = [Convert]::ToBase64String($bytes)
            $A = New-ScheduledTaskAction -Argument "-executionpolicy bypass -noprofile -encodedcommand $encodedString" -Execute "$PSHome\powershell.exe"
            if ($runAs -match "\$") {
                # under gMSA account
                $P = New-ScheduledTaskPrincipal -UserId $runAs -LogonType Password
            } else {
                # under system account
                $P = New-ScheduledTaskPrincipal -UserId $runAs -LogonType ServiceAccount
            }
            $S = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            $taskName = "cred_export"
            try {
                $null = New-ScheduledTask -Action $A -Principal $P -Settings $S -ErrorAction Stop | Register-ScheduledTask -Force -TaskName $taskName -ErrorAction Stop
            } catch {
                if ($_ -match "No mapping between account names and security IDs was done") {
                    throw "Account $runAs doesn't exist or cannot be used on $env:COMPUTERNAME"
                } else {
                    throw "Unable to create scheduled task for exporting credentials.`nError was:`n$_"
                }
            }

            Start-Sleep -Seconds 1
            Start-ScheduledTask $taskName

            Start-Sleep -Seconds 5
            $result = (Get-ScheduledTaskInfo $taskName).LastTaskResult
            try {
                Unregister-ScheduledTask $taskName -Confirm:$false -ErrorAction Stop
            } catch {
                throw "Unable to remove scheduled task $taskName. Remove it manually, it contains the credentials!"
            }

            if ($result -ne 0) {
                throw "Export of the credentials end with error"
            }

            if ((Get-Item $xmlPath).Length -lt 500) {
                # sometimes sched. task doesn't end with error, but xml contained gibberish
                throw "Exported credentials are not valid"
            }
        }
    }

    function _isAdministrator {
        $currentUser = [Security.Principal.WindowsPrincipal]([Security.Principal.WindowsIdentity]::GetCurrent())
        Return $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    #endregion helper functions

    # store function definitions so I can recreate them in scriptblock
    $allFunctionDefs = "function _continue { ${function:_continue} };function _pressKeyToContinue { ${function:_pressKeyToContinue} }; function _skip { ${function:_skip} }; function _installGIT { ${function:_installGIT} }; function _installGITCredManager { ${function:_installGITCredManager} }; function _createSchedTask { ${function:_createSchedTask} }; function _exportCred { ${function:_exportCred} }; function _startSchedTask { ${function:_startSchedTask} }; function _setPermissions { ${function:_setPermissions} }; function _getComputerMembership { ${function:_getComputerMembership} }; function _startProcess { ${function:_startProcess} }"

}

Process {
    #region initial
    if (!$noEnvModification) {
        Clear-Host
        @"
####################################
#   INSTALL OPTIONS
####################################

1) TEST installation
    - PURPOSE:
        - Choose this option, if you want to make fast and safe (completely local) test of the features, this solution offers.
    - REQUIREMENTS:
        - Local Admin rights
        - (HIGHLY RECOMMENDED) Run this installer on (freshly installed) VM with internet connectivity. Like Windows Sandbox, VirtualBox, Hyper-V, etc.
    - WHAT IT DOES:
        To have this as simple as possible - Installer automatically:
        - Installs VSC, GIT.
        - Creates GIT repository in "$remoteRepository".
            - and clone it to "$env:SystemDrive\myCompanyRepository".
        - Creates folder "$env:SystemDrive\repositoryShare" and shares it as "\\$env:COMPUTERNAME\repositoryShare".
        - Creates local security groups repo_reader, repo_writer.
        - Creates required scheduled tasks.
        - Creates and sets global PowerShell profile.
        - Starts VSC editor with your new repository, so you can start your testing immediately. :)

2) ACTIVE DIRECTORY installation
    - PURPOSE:
        - Choose this option, if you want to create fully featured CI/CD central GIT repository for your Active Directory environment.
    - REQUIREMENTS:
        - Active Directory
            - Domain Admin rights
            - Enabled PSRemoting
        - Existing GIT Repository
    - WHAT IT DOES:
    - This script will set up your own GIT repository and your environment by:
        - Creating repo_reader, repo_writer AD groups.
        - Creates shared folder for serving repository data to the clients.
        - Customizes generic data from repo_content_set_up folder to match your environment.
            - Copies customized data to your repository.
        - Sets up your repository:
            - Activate custom git hooks.
            - Set git user name and email.
        - Commit & Push new content to your repository.
        - Sets up MGM server:
            - Copies the Repo_sync folder.
            - Creates Repo_sync scheduled task.
            - Exports repo_puller credentials.
        - Copies exported credentials from MGM to local repository, Commmit and Push it.
        - Creates a GPO '$GPOname' that will be used for connecting clients to this solution:
            - NOTE: Linking GPO has to be done manually.
    - NOTE: Every step has to be explicitly confirmed.

3) PERSONAL installation
    - PURPOSE:
        - Choose this option, if you want to leverage benefits of CI/CD for your personal PowerShell content or to share one GIT repository across multiple colleagues even without Active Directory.
    - REQUIREMENTS:
        - Local Admin rights
        - Existing GIT repository
    - WHAT IT DOES:
        Installer automatically:
        - Installs VSC, GIT (if necessary).
        - Creates local security groups repo_reader, repo_writer.
        - Let you decide what you want to synchronize from GIT:
            - Global PowerShell profile
            - Modules
            - Custom section
        - Creates required scheduled tasks.
            - Repo_sync
                - Pulls data from your GIT repository and process them
                - will be run under your account therefore use your credentials to access GIT repository
            - PS_env_set_up
                - Synchronizes client with already processed repository data
        - Starts VSC editor with your new repository, so you can start your testing immediately. :)
"@

        # TODO
        #     4) UPDATE of existing installation
        # ! NO MODIFICATION OF YOUR ENVIRONMENT WILL BE MADE !

        # - PURPOSE:
        #     - Choose this option if you want to deploy new version of this solution.
        #     - This option will just make customization of generic data in downloaded repo_content_set_up folder using data in your existing '$iniFile'.
        #         - Merging with your own repository etc has to be done manually.

        # - REQUIREMENTS:
        #     - This solution is already deployed

        $choice = ""
        while ($choice -notmatch "^[1|2|3]$") {
            $choice = Read-Host "Choose install option (1|2|3)"
        }

        # run again with admin rights if necessary
        if ($choice -in 1, 3) {
            if (!(_isAdministrator)) {
                # not running "as Administrator" - so relaunch as administrator

                # get command line arguments and reuse them
                $arguments = $myInvocation.line -replace [regex]::Escape($myInvocation.InvocationName), ""

                Start-Process powershell.exe -Verb RunAs -ArgumentList ('-noprofile -file "{0}" {1}' -f ($myinvocation.MyCommand.Definition), $arguments) # -noexit nebo -WindowStyle Hidden

                # exit from the current, unelevated, process
                exit
            }
        }

        switch ($choice) {
            1 {
                $testInstallation = 1
                $noEnvModification = $false
            }

            2 {
                $ADInstallation = 1
                $noEnvModification = $false
            }

            3 {
                $personalInstallation = 1
                $noEnvModification = $false
            }

            4 {
                $updateRootData = 1
                $noEnvModification = $true
            }

            default { throw "Undefined choice" }
        }
    }

    Clear-Host

    if ($personalInstallation -or $testInstallation) {
        @"
####################################
#   INSTALLING REQUIREMENTS
####################################
"@
        "   - installing 'GIT'"
        _installGIT

        "   - installing 'VSC'"
        _installVSC

        "   - installing 'Nuget'"
        if (Get-PackageProvider -Name nuget -ListAvailable -ErrorAction SilentlyContinue | ? Version -GT '2.8.5') {
            "      - already installed"
        } else {
            Install-PackageProvider -Name nuget -Force -ForceBootstrap -Scope allusers | Out-Null
        }

        # solves issue https://github.com/PowerShell/vscode-powershell/issues/2824
        "   - installing 'PackageManagement' PS module"
        if (Get-Module PackageManagement -ListAvailable | ? version -GT ([version]'1.4.8')) {
            "      - already installed"
        } else {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Install-Module -Name PackageManagement -Force -ErrorAction SilentlyContinue
        }

        if ((Get-ExecutionPolicy -Scope LocalMachine) -notmatch "Bypass|RemoteSigned") {
            # because of PS Global Profile loading
            "   - enabling running of PS scripts (because of PS Profile loading)"
            Try {
                Set-ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
            } Catch {
                # this script being run with Bypass, so it is ok, that this command ends with error "Windows PowerShell updated your execution policy successfully, but the setting is overridden by a policy defined at a more specific scope"
            }
        }
    }

    if (!$testInstallation) {
        _pressKeyToContinue
        Clear-Host
    } else {
        ""
    }

    if (!$noEnvModification -and !$testInstallation) {
        if ($personalInstallation) {
            @"
####################################
#   BEFORE YOU CONTINUE
####################################

- Create cloud or locally hosted GIT !private! repository (tested with Azure DevOps but probably will work also with GitHub etc).
- Clone this repository locally (git clone command).

- NOTE:
    - More details can be found at https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md
"@
        } else {
            @"
####################################
#   BEFORE YOU CONTINUE
####################################

- Create cloud or locally hosted GIT !private! repository (tested with Azure DevOps but probably will work also with GitHub etc).
- Create READ only account in that repository (repo_puller).
    - Create credentials for this account, that can be used in unattended way (i.e. alternate credentials in Azure DevOps).
- Clone this repository locally (git clone command).

- NOTE:
    - More details can be found at https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md
"@
        }

        _pressKeyToContinue
    }

    if (!$testInstallation) {
        Clear-Host
    } else {
        ""
    }

    if (!$noEnvModification -and !$testInstallation) {
        @"
############################
!!! ANYONE WHO CONTROL THIS SOLUTION IS DE FACTO ADMINISTRATOR ON EVERY COMPUTER CONNECTED TO IT !!!
So:
    - just approved users should have write access to GIT repository
    - for accessing cloud GIT repository, use MFA if possible
    $(if ($ADInstallation) {"- MGM server (processes repository data and uploads them to share) has to be protected so as the server that hosts that repository share"})
############################
"@

        _pressKeyToContinue
        Clear-Host

        @"
############################

Your input will be stored to '$iniFile'. So next time you start this script, its content will be automatically used.

############################
"@
    }

    if (!$testInstallation) {
        _pressKeyToContinue
        Clear-Host
    } else {
        ""
    }
    #endregion initial

    try {
        #region import variables
        # import variables from ini file
        # '#' can be used for comments, so skip such lines
        if ((Test-Path $iniFile) -and !$testInstallation) {
            Write-Host "- Importing variables from $iniFile" -ForegroundColor Green
            Get-Content $iniFile -ErrorAction SilentlyContinue | ? { $_ -and $_ -notmatch "^\s*#" } | % {
                $line = $_
                if (($line -split $divider).count -ge 2) {
                    $position = $line.IndexOf($divider)
                    $name = $line.Substring(0, $position) -replace "^\s*|\s*$"
                    $value = $line.Substring($position + 1) -replace "^\s*|\s*$"
                    "   - variable $name` will have value: $value"

                    # fill hash so I can later export (updated) variables back to file
                    $setupVariable.$name = $value
                }
            }

            _pressKeyToContinue
        }
        #endregion import variables

        if (!$testInstallation) {
            Clear-Host
        }

        #region checks
        if (!$updateRootData) {
            Write-Host "- Checking permissions etc" -ForegroundColor Green

            # # computer isn't in domain
            # if (!$noEnvModification -and !(Get-WmiObject -Class win32_computersystem).partOfDomain) {
            #     Write-Warning "This PC isn't joined to domain. AD related steps will have to be done manually."

            #     ++$skipAD

            #     _continue
            # }

            # is local administrator
            if (!(_isAdministrator)) {
                Write-Warning "Not running as administrator. Symlink for using repository PowerShell snippets file in VSC won't be created"
                ++$notAdmin

                _pressKeyToContinue
            }

            if ($ADInstallation) {
                # is domain admin
                if (!$noEnvModification -and !((& "$env:windir\system32\whoami.exe" /all) -match "Domain Admins|Enterprise Admins")) {
                    Write-Warning "You are not member of Domain nor Enterprise Admin group. AD related steps will have to be done manually."

                    ++$notADAdmin

                    _continue
                }

                # ActiveDirectory PS module is available
                if (!$noEnvModification -and !(Get-Module ActiveDirectory -ListAvailable)) {
                    Write-Warning "ActiveDirectory PowerShell module isn't installed (part of RSAT)."

                    if (!$notAdmin -and ((_continue "Proceed with installation" -passthru) -eq "Y")) {
                        if ($isServer) {
                            $null = Install-WindowsFeature -Name RSAT-AD-PowerShell -IncludeManagementTools
                        } else {
                            try {
                                $null = Get-WindowsCapability -Name "*activedirectory*" -Online -ErrorAction Stop | Add-WindowsCapability -Online -ErrorAction Stop
                            } catch {
                                Write-Warning "Unable to install RSAT AD tools.`nAD related steps will be skipped, so make them manually."
                                ++$noADmodule
                                _pressKeyToContinue
                            }
                        }
                    } else {
                        Write-Warning "AD related steps will be skipped, so make them manually."
                        ++$noADmodule
                        _pressKeyToContinue
                    }
                }

                # GroupPolicy PS module is available
                if (!$noEnvModification -and !(Get-Module GroupPolicy -ListAvailable)) {
                    Write-Warning "GroupPolicy PowerShell module isn't installed (part of RSAT)."

                    if (!$notAdmin -and ((_continue "Proceed with installation" -passthru) -eq "Y")) {
                        if ($isServer) {
                            $null = Add-WindowsFeature -Name GPMC -IncludeManagementTools
                        } else {
                            try {
                                $null = Get-WindowsCapability -Name "*grouppolicy*" -Online -ErrorAction Stop | Add-WindowsCapability -Online -ErrorAction Stop
                            } catch {
                                Write-Warning "Unable to install RSAT GroupPolicy tools.`nGPO related steps will be skipped, so make them manually."
                                ++$noGPOmodule
                                _pressKeyToContinue
                            }
                        }
                    } else {
                        Write-Warning "GPO related steps will be skipped, so make them manually."
                        ++$noGPOmodule
                        _pressKeyToContinue
                    }
                }

                if ($notADAdmin -or $noADmodule) {
                    ++$skipAD
                }

                if ($notADAdmin -or $noGPOmodule) {
                    ++$skipGPO
                }
            }

            if (!$testInstallation) {
                _pressKeyToContinue
                Clear-Host
            }
        }
        #endregion checks

        if ($ADInstallation -or $updateRootData) {
            _setVariable MGMServer "the name of the MGM server (will be used for pulling, processing and distributing of repository data to repository share)."
            if ($MGMServer -like "*.*") {
                $MGMServer = ($MGMServer -split "\.")[0]
                Write-Warning "$MGMServer was in FQDN format. Just hostname was used"
            }
            if ($ADInstallation -and !$noADmodule -and !(Get-ADComputer -Filter "name -eq '$MGMServer'")) {
                throw "$MGMServer doesn't exist in AD"
            }
        } else {
            if ($testInstallation) {
                "   - For testing purposes, this computer will host MGM server role too"
            } elseif ($personalInstallation) {
                "   - For local installation, this computer will host MGM server role too"
            }

            _setVariableValue -variable MGMServer -value $env:COMPUTERNAME
        }

        if (!$testInstallation) {
            _saveInput
            Clear-Host
        } else {
            ""
        }

        #region create repo_reader, repo_writer
        if ($ADInstallation) {
            Write-Host "- Creating repo_reader, repo_writer AD security groups" -ForegroundColor Green

            if (!$noEnvModification -and !$skipAD -and !(_skip)) {
                'repo_reader', 'repo_writer' | % {
                    if (Get-ADGroup -Filter "samaccountname -eq '$_'") {
                        "   - $_ already exists"
                    } else {
                        if ($_ -match 'repo_reader') {
                            $right = "read"
                        } else {
                            $right = "modify"
                        }
                        New-ADGroup -Name $_ -GroupCategory Security -GroupScope Universal -Description "Members have $right permission to repository share content."
                        " - created $_"
                    }
                }
            } else {
                Write-Warning "Skipped!`n`nCreate them manually"
            }
        } elseif ($personalInstallation -or $testInstallation) {
            Write-Host "- Creating repo_reader, repo_writer security groups" -ForegroundColor Green

            'repo_reader', 'repo_writer' | % {
                if (Get-LocalGroup $_ -ErrorAction SilentlyContinue) {
                    # already exists
                } else {
                    if ($_ -match 'repo_reader') {
                        $right = "read"
                    } else {
                        $right = "modify"
                    }

                    $null = New-LocalGroup -Name $_ -Description "Members have $right right to repository data." # max 48 chars!
                }
            }
        }
        #endregion create repo_reader, repo_writer

        if (!$testInstallation) {
            _pressKeyToContinue
            Clear-Host
        } else {
            ""
        }

        #region adding members to repo_reader, repo_writer
        if ($ADInstallation) {
            Write-Host "- Adding members to repo_reader, repo_writer AD groups" -ForegroundColor Green
            "   - add 'Domain Computers' to repo_reader group"
            "   - add 'Domain Admins' and $MGMServer to repo_writer group"

            if (!$noEnvModification -and !$skipAD -and !(_skip)) {
                "   - adding 'Domain Computers' to repo_reader group (DCs are not members of this group!)"
                Add-ADGroupMember -Identity 'repo_reader' -Members "Domain Computers"
                "   - adding 'Domain Admins' and $MGMServer to repo_writer group"
                Add-ADGroupMember -Identity 'repo_writer' -Members "Domain Admins", "$MGMServer$"
            } else {
                Write-Warning "Skipped! Fill them manually.`n`n - repo_reader should contains computers which you want to join to this solution i.e. 'Domain Computers' (if you choose just subset of computers, use repo_reader and repo_writer for security filtering on lately created GPO $GPOname)`n - repo_writer should contains 'Domain Admins' and $MGMServer server"
            }

            ""
            Write-Warning "RESTART $MGMServer (and rest of the computers) to apply new membership NOW!"
        } elseif ($personalInstallation -or $testInstallation) {
            Write-Host "- Adding members to repo_reader, repo_writer groups" -ForegroundColor Green
            # "   - adding SYSTEM to repo_reader group"
            # Add-LocalGroupMember -Name 'repo_reader' -Member "SYSTEM"
            "   - adding Administrators and SYSTEM to repo_writer group"
            "Administrators", "SYSTEM" | % {
                if ($_ -notin (Get-LocalGroupMember -Name 'repo_writer' | select @{n = "Name"; e = { ($_.Name -split "\\")[-1] } } | select -ExpandProperty Name)) {
                    Add-LocalGroupMember -Name 'repo_writer' -Member $_
                }
            }

        }
        #endregion adding members to repo_reader, repo_writer

        if (!$testInstallation) {
            _pressKeyToContinue
            Clear-Host
        } else {
            ""
        }

        #region set up shared folder for repository data
        if ($personalInstallation) {
            # for personal installation, no share is created, because there are no other clients to synchronize such data
            #TODO zrejme zbytecna duplicita, ale to bych musel ohackovat repo_sync.ps1 aby v podstate jen nageneroval moduly a done a taky ps_env_set_up
            $repositoryShare = "$env:windir\Scripts\Repo_sync\Log\PS_repo_Processed"
        } else {
            Write-Host "- Creating shared folder for hosting repository data" -ForegroundColor Green
            if ($ADInstallation -or $updateRootData) {
                _setVariable repositoryShare "UNC path to folder, where the repository data should be stored (i.e. \\mydomain\dfs\repository)"
            } elseif ($testInstallation) {
                $repositoryShare = "\\$env:COMPUTERNAME\repositoryShare"
                "   - For testing purposes $repositoryShare will be used"
            }
            if ($repositoryShare -notmatch "^\\\\[^\\]+\\[^\\]+") {
                throw "$repositoryShare isn't valid UNC path"
            }

            $permissions = "`n`t`t- SHARE`n`t`t`t- Everyone - FULL CONTROL`n`t`t- NTFS`n`t`t`t- SYSTEM, repo_writer - FULL CONTROL`n`t`t`t- repo_reader - READ"
            if ($testInstallation -or $ADInstallation -or (!$noEnvModification -and !(_skip))) {
                "   - Testing, whether '$repositoryShare' already exists"
                try {
                    $repositoryShareExists = Test-Path $repositoryShare
                } catch {
                    # in case this script already created that share but this user isn't yet in repo_writer, he will receive access denied error when accessing it
                    if ($_ -match "access denied") {
                        ++$accessDenied
                    }
                }
                if ($repositoryShareExists -or $accessDenied) {
                    if (!$testInstallation) {
                        Write-Warning "Share '$repositoryShare' already exists.`n`tMake sure, that ONLY following permissions are set:$permissions`n`nNOTE: it's content will be replaced by repository data eventually!"
                    }
                } else {
                    # share or some part of its path doesn't exist
                    $isDFS = ""
                    if (!$testInstallation) {
                        # for testing installation I will use common UNC share
                        while ($isDFS -notmatch "^[Y|N]$") {
                            ""
                            $isDFS = Read-Host "   - Is '$repositoryShare' DFS share? (Y|N)"
                        }
                    }
                    if ($isDFS -eq "Y") {
                        #TODO pridat podporu pro tvorbu DFS share
                        Write-Warning "Skipped! Currently this installer doesn't support creation of DFS share.`nMake share manually with ONLY following permissions:$permissions"
                    } else {
                        # creation of non-DFS shared folder
                        $repositoryHost = ($repositoryShare -split "\\")[2]
                        if (!$testInstallation -and !$noADmodule -and !(Get-ADComputer -Filter "name -eq '$repositoryHost'")) {
                            throw "$repositoryHost doesn't exist in AD"
                        }

                        $parentPath = "\\" + [string]::join("\", $repositoryShare.Split("\")[2..3])

                        if (($parentPath -eq $repositoryShare) -or ($parentPath -ne $repositoryShare -and !(Test-Path $parentPath -ErrorAction SilentlyContinue))) {
                            # shared folder doesn't exist, can't deduce local path from it, so get it from the user
                            ""
                            if (!$testInstallation) {
                                _setVariable repositoryShareLocPath "local path to folder, which will be than shared as '$parentPath' (on $repositoryHost)"
                            } else {
                                $repositoryShareLocPath = "$env:SystemDrive\repositoryShare"
                                "   - For testing purposes, repository share will be stored locally in '$repositoryShareLocPath'"
                            }
                        } else {
                            ""
                            "   - Share $parentPath already exists. Folder for repository data will be created (if necessary) and JUST NTFS permissions will be set."
                            Write-Warning "So make sure, that SHARE permissions are set to: Everyone - FULL CONTROL!"

                            _pressKeyToContinue
                        }

                        $invokeParam = @{}
                        if (!$testInstallation) {
                            if ($notADAdmin) {
                                while (!$repositoryHostSession) {
                                    $repositoryHostSession = New-PSSession -ComputerName $repositoryHost -Credential (Get-Credential -Message "Enter admin credentials for connecting to $repositoryHost through psremoting") -ErrorAction SilentlyContinue
                                }
                            } else {
                                $repositoryHostSession = New-PSSession -ComputerName $repositoryHost
                            }
                            $invokeParam.Session = $repositoryHostSession
                        } else {
                            # testing installation i.e. locally
                        }

                        $invokeParam.argumentList = $repositoryShareLocPath, $repositoryShare, $allFunctionDefs
                        $invokeParam.ScriptBlock = {
                            param ($repositoryShareLocPath, $repositoryShare, $allFunctionDefs)

                            # recreate function from it's definition
                            foreach ($functionDef in $allFunctionDefs) {
                                . ([ScriptBlock]::Create($functionDef))
                            }

                            $shareName = ($repositoryShare -split "\\")[3]

                            if ($repositoryShareLocPath) {
                                # share doesn't exist yet
                                # create folder (and subfolders) and share it
                                if (Test-Path $repositoryShareLocPath) {
                                    Write-Warning "$repositoryShareLocPath already exists on $env:COMPUTERNAME!"
                                    _continue "Content will be eventually overwritten"
                                } else {
                                    [Void][System.IO.Directory]::CreateDirectory($repositoryShareLocPath)

                                    # create subfolder structure if UNC path contains them as well
                                    $subfolder = [string]::join("\", $repositoryShare.split("\")[4..1000])
                                    $subfolder = Join-Path $repositoryShareLocPath $subfolder
                                    [Void][System.IO.Directory]::CreateDirectory($subfolder)

                                    # share the folder
                                    "       - share $repositoryShareLocPath as $shareName"
                                    $null = Remove-SmbShare -Name $shareName -Force -Confirm:$false -ErrorAction SilentlyContinue
                                    $null = New-SmbShare -Name $shareName -Path $repositoryShareLocPath -FullAccess Everyone

                                    # set NTFS permission
                                    "       - setting NTFS permissions on $repositoryShareLocPath"
                                    _setPermissions -path $repositoryShareLocPath -writeUser SYSTEM, repo_writer -readUser repo_reader
                                }
                            } else {
                                # share already exists
                                # create folder for storing repository, set NTFS permissions and check SHARE permissions
                                $share = Get-SmbShare $shareName
                                $repositoryShareLocPath = $share.path

                                # create subfolder structure if UNC path contains them as well
                                $subfolder = [string]::join("\", $repositoryShare.split("\")[4..1000])
                                $subfolder = Join-Path $repositoryShareLocPath $subfolder
                                [Void][System.IO.Directory]::CreateDirectory($subfolder)

                                # set NTFS permission
                                "`n   - setting NTFS permissions on $repositoryShareLocPath"
                                _setPermissions -path $repositoryShareLocPath -writeUser SYSTEM, repo_writer -readUser repo_reader

                                # check/set SHARE permission
                                $sharePermission = Get-SmbShareAccess $shareName
                                if (!($sharePermission | ? { $_.accountName -eq "Everyone" -and $_.AccessControlType -eq "Allow" -and $_.AccessRight -eq "Full" })) {
                                    "      - share $shareName doesn't contain valid SHARE permissions, EVERYONE should have FULL CONTROL access (access to repository data is driven by NTFS permissions)."

                                    _pressKeyToContinue "Current share $repositoryShare will be un-shared and re-shared with correct SHARE permissions"

                                    Remove-SmbShare -Name $shareName -Force -Confirm:$false
                                    New-SmbShare -Name $shareName -Path $repositoryShareLocPath -FullAccess EVERYONE
                                } else {
                                    "      - share $shareName already has correct SHARE permission, no action needed"
                                }
                            }
                        }

                        Invoke-Command @invokeParam

                        if ($repositoryHostSession) {
                            Remove-PSSession $repositoryHostSession -ErrorAction SilentlyContinue
                        }
                    }
                }
            } else {
                Write-Warning "Skipped!`n`n - Create shared folder '$repositoryShare' manually and set there following permissions:$permissions"
            }
        }
        #endregion set up shared folder for repository data

        if ($personalInstallation) {
            _saveInput
            Clear-Host
        } elseif (!$testInstallation) {
            _saveInput
            _pressKeyToContinue
            Clear-Host
        } else {
            ""
        }

        #region customize generalized cloned data
        $repo_content_set_up = Join-Path $PSScriptRoot "repo_content_set_up"
        $_other = Join-Path $PSScriptRoot "_other"
        Write-Host "- Customizing generic data to match your environment by replacing '__REPLACEME__<number>'" -ForegroundColor Green
        if (!(Test-Path $repo_content_set_up -ErrorAction SilentlyContinue)) {
            throw "Unable to find '$repo_content_set_up'. Clone repository https://github.com/ztrhgf/Powershell_CICD_repository again"
        }
        if (!(Test-Path $_other -ErrorAction SilentlyContinue)) {
            throw "Unable to find '$_other'. Clone repository https://github.com/ztrhgf/Powershell_CICD_repository again"
        }

        #region create copy of generalized data
        "       - create copy of the folders with generalized data`n"

        $date = Get-Date -Format ddMMHHmmss

        # create copy of the repo_content_set_up folder
        $repo_content_set_up_Customized = "$repo_content_set_up`_$date"
        $result = _copyFolder $repo_content_set_up $repo_content_set_up_Customized
        if ($err = $result.errMsg) {
            throw "Copy failed:`n$err"
        }
        # customize copy instead of original
        "           - '$repo_content_set_up_Customized' will be used instead of '$repo_content_set_up'`n"
        $repo_content_set_up = $repo_content_set_up_Customized

        # create copy of the _other folder
        $_other_Customized = "$_other`_$date"
        $result = _copyFolder $_other $_other_Customized
        if ($err = $result.errMsg) {
            throw "Copy failed:`n$err"
        }
        "           - '$_other_Customized' will be used instead of '$_other'`n"
        $_other = $_other_Customized
        # customize copy instead of original
        #endregion create copy of generalized data

        if ($ADInstallation) {
            Write-Host "`n   - Gathering values for replacing __REPLACEME__<number> string:" -ForegroundColor DarkGreen
            "       - in case, you will need to update some of these values in future, clone again this repository, edit content of $iniFile and run this wizard again`n"

            $replacemeVariable = @{
                1 = $repositoryShare
                2 = _setVariable repositoryURL "Cloning URL of your own GIT repository. Will be used on MGM server" -passThru
                3 = $MGMServer
                4 = _setVariable computerWithProfile "name of computer(s) (without ending $, divided by comma) that should get:`n       - global Powershell profile (shows number of commits this console is behind in Title etc)`n" -passThru
                5 = _setVariable smtpServer "IP or hostname of your SMTP server. Will be used for sending error notifications (recipient will be specified later)" -optional -passThru
                6 = _setVariable adminEmail "recipient(s) email address (divided by comma), that should receive error notifications. Use format it@contoso.com" -optional -passThru
                7 = _setVariable 'from' "sender email address, that should be used for sending error notifications. Use format robot@contoso.com" -optional -passThru
            }
        } elseif ($personalInstallation) {
            Write-Host "`n   - Gathering values for replacing __REPLACEME__<number> string:" -ForegroundColor DarkGreen
            "       - in case, you will need to update some of these values in future, clone again this repository, edit content of $iniFile and run this wizard again`n"

            $replacemeVariable = @{
                1 = $repositoryShare
                2 = _setVariable repositoryURL "Cloning URL of your own GIT repository." -passThru
                3 = '"$env:COMPUTERNAME"' # there can be more than one computer that will behave like MGM server, therefore sync on them all
                4 = "##DONOTSYNCPROFILEANYWHERE##" # will be replaced with real computer name, if user decides to have synchronized PS profile
            }

            _setVariable syncPSProfile "Do you want to synchronize Global PowerShell Profile (shows number of commits this console is behind in Title etc) to this computer?" -YNQuestion

            if ($syncPSProfile -eq "Y") {
                $replacemeVariable.4 = $env:COMPUTERNAME
            }
        } elseif ($testInstallation) {
            # there will be created GIT repository for test installation

            $repositoryURL = $remoteRepository
            $computerWithProfile = $env:COMPUTERNAME
            Write-Warning "So this computer will get:`n - global Powershell profile (shows number of commits this console is behind in Title etc)`n"

            $replacemeVariable = @{
                1 = $repositoryShare
                2 = $repositoryURL
                3 = $MGMServer
                4 = $computerWithProfile
            }
        } elseif ($updateRootData) {
            #TODO problem je ze to zalezi na typu instalace..
        }

        # replace __REPLACEME__<number> for entered values in cloned files
        $replacemeVariable.GetEnumerator() | Sort-Object | % {
            # in files, __REPLACEME__<number> format is used where user input should be placed
            $name = "__REPLACEME__" + $_.name
            $value = $_.value

            # variables that support array convert to "a", "b", "c" format
            if ($_.name -in (4, 6) -and $value -match ",") {
                $value = $value -split "," -replace "\s*$|^\s*"
                $value = $value | % { "`"$_`"" }
                $value = $value -join ", "
            }

            # variable is repository URL, convert it to correct format
            if ($_.name -eq 2) {
                # remove leading http(s):// because it is already mentioned in repo_sync.ps1
                $value = $value -replace "^http(s)?://"
                # remove login i.e. part before @
                $value = $value.Split("@")[-1]
            }

            # remove quotation, replace string is already quoted in files
            $value = $value -replace "^\s*[`"']" -replace "[`"']\s*$"

            if (!$testInstallation) {
                "   - replacing: $name for: $value"
            } else {
                Write-Verbose "   - replacing: $name for: $value"
            }

            Get-ChildItem $repo_content_set_up, $_other -Include *.ps1, *.psm1, *.xml -Recurse | % {
                (Get-Content $_.fullname) -replace $name, $value | Set-Content $_.fullname
            }

            #TODO zkontrolovat/upozornit na soubory kde jsou replaceme (exclude takovych kde nezadal uzivatel zadnou hodnotu)
        }
        #endregion customize generalized cloned data

        if (!$testInstallation) {
            _saveInput
            _pressKeyToContinue
            Clear-Host
        } else {
            ""
        }

        #region warn about __CHECKME__
        Write-Host "- Searching for __CHECKME__ in $repo_content_set_up" -ForegroundColor Green
        $fileWithCheckMe = Get-ChildItem $repo_content_set_up -Recurse | % { if ((Get-Content $_.fullname -ErrorAction SilentlyContinue -Raw) -match "__CHECKME__") { $_.fullname } }
        # remove this script from the list
        $fileWithCheckMe = $fileWithCheckMe | ? { $_ -ne $PSCommandPath }
        if ($fileWithCheckMe) {
            Write-Warning "(OPTIONAL CUSTOMIZATIONS) Search for __CHECKME__ string in the following files and decide what to do according to information that follows there (save any changes before continue):"
            $fileWithCheckMe | % { "   - $_" }
        }
        #endregion warn about __CHECKME__

        if (!$testInstallation) {
            _pressKeyToContinue
            Clear-Host
        } else {
            ""
        }

        #region copy customized repository data to the users own repository
        if (!$testInstallation) {
            _setVariable userRepository "path to ROOT of your locally cloned repository '$repositoryURL'"

            while (!(Test-Path (Join-Path $userRepository ".git") -ErrorAction SilentlyContinue)) {
                Write-Warning "'$userRepository' isn't cloned GIT repository (hidden '.git' folder is missing)"
                _unsetVariable userRepository
                _setVariable userRepository "path to ROOT of your locally cloned repository '$repositoryURL'"
            }

            # make a note whether cloned repository is brand new or was already set up
            $userRepositoryWasntEmpty = Test-Path "$userRepository\Custom\Repo_Sync\Repo_Sync.ps1" -ErrorAction SilentlyContinue
        } else {
            $userRepository = "$env:SystemDrive\myCompanyRepository"

            Write-Host " - Creating new GIT repository '$remoteRepository'. It will be used instead of your own cloud repository like GitHub or Azure DevOps. DON'T MAKE ANY CHANGES HERE." -ForegroundColor Green
            [Void][System.IO.Directory]::CreateDirectory($remoteRepository)
            Set-Location $remoteRepository
            $result = _startProcess git init
            #FIXME https://stackoverflow.com/questions/3221859/cannot-push-into-git-repository
            $result = _startProcess git "config receive.denyCurrentBranch updateInstead"

            ""

            Write-Host " - Cloning '$remoteRepository' to '$userRepository'. So in '$userRepository' MAKE YOUR CHANGES." -ForegroundColor Green
            Set-Location (Split-Path $userRepository -Parent)
            $result = _startProcess git "clone --local $remoteRepository $(Split-Path $userRepository -Leaf)" -outputErr2Std
        }

        Write-Host "- Copying customized repository data ($repo_content_set_up) to your own repository ($userRepository)" -ForegroundColor Green

        if ($testInstallation -or (!$noEnvModification -and !(_skip))) {
            $result = _copyFolder $repo_content_set_up $userRepository
            if ($err = $result.errMsg) {
                throw "Copy failed:`n$err"
            }
        } else {
            Write-Warning "Skipped!`n`n - Copy CONTENT of $repo_content_set_up to ROOT of your locally cloned repository. Review the changes to prevent loss of any of your customization (preferably merge content of customConfig.ps1 and Variables.psm1 instead of replacing them completely) and COMMIT them"
        }
        #endregion copy customized repository data to the users own repository

        if (!$testInstallation) {
            _pressKeyToContinue
            _saveInput
            Clear-Host
        } else {
            ""
        }

        #region configure user repository
        if ($env:USERDNSDOMAIN) {
            $userDomain = $env:USERDNSDOMAIN
        } else {
            $userDomain = "$env:COMPUTERNAME.com"
        }
        Write-Host "- Configuring repository '$userRepository'" -ForegroundColor Green
        "   - activating GIT Hooks, creating symlink for PowerShell snippets, commiting&pushing changes (if new repository), etc"

        if ($testInstallation -or (!$noEnvModification -and !(_skip))) {
            $currPath = Get-Location
            Set-Location $userRepository

            # just in case user installed GIT after launch of this console, update PATH
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

            "   - setting GIT user name to '$env:USERNAME'"
            git config user.name $env:USERNAME

            "   - setting GIT user email to '$env:USERNAME@$userDomain'"
            git config user.email "$env:USERNAME@$userDomain"

            $VSCprofile = Join-Path $env:APPDATA "Code\User"
            $profileSnippets = Join-Path $VSCprofile "snippets"
            [Void][System.IO.Directory]::CreateDirectory($profileSnippets)
            $profilePSsnippet = Join-Path $profileSnippets "powershell.json"
            $repositoryPSsnippet = Join-Path $userRepository "powershell.json"
            "   - creating symlink '$profilePSsnippet' for '$repositoryPSsnippet', so VSC can offer these PowerShell snippets"
            if (!$notAdmin -and (Test-Path $VSCprofile -ErrorAction SilentlyContinue) -and !(Test-Path $profilePSsnippet -ErrorAction SilentlyContinue)) {
                [Void][System.IO.Directory]::CreateDirectory($profileSnippets)
                $null = New-Item -ItemType symboliclink -Path $profileSnippets -Name "powershell.json" -Value $repositoryPSsnippet
            } else {
                Write-Warning "Skipped.`n`nYou are not running this script with admin privileges or VSC isn't installed or '$profilePSsnippet' already exists"
            }

            # to avoid message 'warning: LF will be replaced by CRLF'
            $null = _startProcess git "config core.autocrlf false" -outputErr2Std -dontWait

            # commit without using hooks, to avoid possible problem with checks (because of wrong encoding, missing PSScriptAnalyzer etc), that could stop it
            "   - commiting & pushing changes to repository $repositoryURL"
            if ($testInstallation -or !$userRepositoryWasntEmpty) {
                # user repo was empty before my customized content was copied to it or this is TEST installation
                # it is safe to automatically do commit&push
                $null = git add .
                $null = _startProcess git "commit --no-verify -m initial" -outputErr2Std -dontWait
                $null = _startProcess git "push --no-verify" -outputErr2Std
            } else {
                Write-Warning "Skipped.`n`nYour repository wasn't empty before customized content was copied a.k.a. some of your content could be lost. Check manually changed files (in VSC 'Source Control' tab) and commit&push just safe changes before continue!"
                _pressKeyToContinue
            }

            "   - activating GIT hooks for automation of checks, git push etc"
            $null = _startProcess git 'config core.hooksPath ".\.githooks"'

            # to set default value again
            $null = _startProcess git "config core.autocrlf true" -outputErr2Std -dontWait

            Set-Location $currPath
        } else {
            Write-Warning "Skipped!`n`nFollow instructions in $(Join-Path $repo_content_set_up '!!!README!!!.txt') file"
        }
        #endregion configure user repository

        if (!$testInstallation) {
            _pressKeyToContinue
            Clear-Host
        } else {
            ""
        }

        #region preparation of MGM server
        if ($personalInstallation -or $testInstallation) {
            $MGMRepoSync = "$env:windir\Scripts\Repo_sync"
        } else {
            $MGMRepoSync = "\\$MGMServer\C$\Windows\Scripts\Repo_sync"
        }
        $userRepoSync = Join-Path $userRepository "custom\Repo_sync"
        Write-Host "- Setting MGM server ($MGMServer)" -ForegroundColor Green
        if (!$testInstallation) {
            if ($personalInstallation) {
                @"
   - copy Repo_sync folder to '$MGMRepoSync'
   - install 'GIT'
   - create scheduled task 'Repo_sync' from 'Repo_sync.xml'

"@
            } else {
                @"
   - copy Repo_sync folder to '$MGMRepoSync'
   - install 'GIT'
   - create scheduled task 'Repo_sync' from 'Repo_sync.xml'
   - export 'repo_puller' account alternate credentials to '$MGMRepoSync\login.xml' (only SYSTEM account on $MGMServer will be able to read them!)
   - copy exported credentials from $MGMServer to $userRepoSync
   - commit&push exported credentials (so they won't be automatically deleted from $MGMServer, after this solution starts working)

"@
            }
        }

        if ($testInstallation -or (!$noEnvModification -and !(_skip))) {
            #region copy Repo_sync folder to MGM server
            "   - copying Repo_sync folder to '$MGMRepoSync'"
            if ($ADInstallation) {
                if ($notADAdmin) {
                    while (!$MGMServerSession) {
                        $MGMServerSession = New-PSSession -ComputerName $MGMServer -Credential (Get-Credential -Message "Enter admin credentials for connecting to $MGMServer through psremoting") -ErrorAction SilentlyContinue
                    }
                } else {
                    $MGMServerSession = New-PSSession -ComputerName $MGMServer
                }

                if ($notADAdmin) {
                    $destination = "C:\Windows\Scripts\Repo_sync"

                    # remove existing folder, otherwise Copy-Item creates eponymous subfolder and copies the content to it
                    Invoke-Command -Session $MGMServerSession {
                        param ($destination)
                        if (Test-Path $destination -ErrorAction SilentlyContinue) {
                            Remove-Item $destination -Recurse -Force
                        }
                    } -ArgumentList $destination

                    Copy-Item -ToSession $MGMServerSession $userRepoSync -Destination $destination -Force -Recurse
                } else {
                    # copy using admin share
                    $result = _copyFolder $userRepoSync $MGMRepoSync
                    if ($err = $result.errMsg) {
                        throw "Copy failed:`n$err"
                    }
                }
            } elseif ($personalInstallation -or $testInstallation) {
                # local copy
                $result = _copyFolder $userRepoSync $MGMRepoSync
                if ($err = $result.errMsg) {
                    throw "Copy failed:`n$err"
                }
            }
            #endregion copy Repo_sync folder to MGM server

            #region configure MGM server
            $invokeParam = @{
                ArgumentList = $repositoryShare, $allFunctionDefs, $testInstallation, $personalInstallation, $ADInstallation
            }
            if ($MGMServerSession) {
                $invokeParam.session = $MGMServerSession
            }
            $invokeParam.ScriptBlock = {
                param ($repositoryShare, $allFunctionDefs, $testInstallation, $personalInstallation, $ADInstallation)

                # recreate function from it's definition
                foreach ($functionDef in $allFunctionDefs) {
                    . ([ScriptBlock]::Create($functionDef))
                }

                $MGMRepoSync = "C:\Windows\Scripts\Repo_sync"
                $taskName = 'Repo_sync'

                if ($ADInstallation) {
                    "   - checking that $env:COMPUTERNAME is in AD group repo_writer"
                    if (!(_getComputerMembership -match "repo_writer")) {
                        throw "Check failed. Make sure, that $env:COMPUTERNAME is in repo_writer group and restart it to apply new membership. Than run this script again"
                    }
                }

                "   - installing newest 'GIT'"
                _installGIT

                # "   - downloading & installing 'GIT Credential Manager'"
                # _installGITCredManager

                $Repo_syncXML = "$MGMRepoSync\Repo_sync.xml"
                "   - creating scheduled task '$taskName' from $Repo_syncXML"

                if ($personalInstallation) {
                    [xml]$Repo_syncXMLContent = Get-Content $Repo_syncXML
                    # replace SID for the current user ones a.k.a. the sched. task will be run as current user a.k.a. his credentials will be used to clone GIT repository instead of separate repo_puller account
                    $Repo_syncXMLContent.Task.Principals.Principal.UserId = ([System.Security.Principal.WindowsIdentity]::GetCurrent()).User.Value
                    $LogonTypeChild = $Repo_syncXMLContent.CreateElement('LogonType', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
                    $null = $Repo_syncXMLContent.Task.Principals.Principal.AppendChild($LogonTypeChild)
                    if ((whoami.exe) -like "azuread\*") {
                        # AAD user
                        # sched. task run under AAD user cannot be set with 'run whether user is logged on or not' option (which I use)
                        # instead 'run only when user is logged on' has to be used, which is interactive, therefore ps1 script is being run via vbs script to make it hidden
                        Write-Warning "You are AzureAD user, synchronization will be run only when you will be logged on"
                        $Repo_syncXMLContent.Task.Actions.Exec.Command = 'wscript.exe'
                        $Repo_syncXMLContent.Task.Actions.Exec.Arguments = "$MGMRepoSync\run_hidden.vbs $MGMRepoSync\Repo_Sync.ps1 -force"
                        $Repo_syncXMLContent.Task.Principals.Principal.LogonType = 'InteractiveToken'
                    } else {
                        # not an AAD user
                        $Repo_syncXMLContent.Task.Principals.Principal.LogonType = 'S4U'
                    }
                    $Repo_syncXMLContent.save($Repo_syncXML)
                }

                _createSchedTask -xmlDefinition $Repo_syncXML -taskName $taskName

                if ($personalInstallation) {
                    # this task definition is customized for every repository user, therefore it doesn't make sense to save it into the repository, because no one else can use it
                    "   - removing scheduled task '$taskName' definition $Repo_syncXML"
                    Remove-Item $Repo_syncXML -Force
                }

                if ($ADInstallation) {
                    "   - exporting repo_puller account alternate credentials to '$MGMRepoSync\login.xml' (only SYSTEM account on $env:COMPUTERNAME will be able to read them!)"
                    _exportCred -credential (Get-Credential -Message 'Enter credentials (that can be used in unattended way) for GIT "repo_puller" account, you created earlier') -runAs "NT AUTHORITY\SYSTEM" -xmlPath "$MGMRepoSync\login.xml"
                }

                "   - starting scheduled task '$taskName' to fill $repositoryShare immediately"
                _startSchedTask $taskName

                "      - checking, that the task ends up succesfully"
                while (($result = ((schtasks /query /tn "$taskName" /v /fo csv /nh) -split ",")[6]) -eq '"267009"') {
                    # task is running
                    Start-Sleep 1
                }
                if ($result -ne '"0"') {
                    throw "Task '$taskName' ends up with error ($($result -replace '"')). Check C:\Windows\Temp\Repo_sync.ps1.log on $env:COMPUTERNAME for more information"
                }
            }

            Invoke-Command @invokeParam
            #endregion configure MGM server

            #region copy exported GIT credentials from MGM server to cloned GIT repo & commit them
            if ($ADInstallation) {
                "   - copying exported credentials from $MGMServer to $userRepoSync"
                if ($notADAdmin) {
                    # copy using previously created PSSession
                    Copy-Item -FromSession $MGMServerSession "C:\Windows\Scripts\Repo_sync\login.xml" -Destination "$userRepoSync\login.xml" -Force
                } else {
                    # copy using admin share
                    Copy-Item "$MGMRepoSync\login.xml" "$userRepoSync\login.xml" -Force
                }

                if ($MGMServerSession) {
                    Remove-PSSession $MGMServerSession -ErrorAction SilentlyContinue
                }

                "   - committing exported credentials (so they won't be automatically deleted from MGM server, after this solution starts)"
                $currPath = Get-Location
                Set-Location $userRepository
                $null = git add .
                $null = _startProcess git 'commit --no-verify -m "repo_puller creds for $MGMServer"' -outputErr2Std -dontWait
                $null = _startProcess git "push --no-verify" -outputErr2Std
                # git push # push should be done automatically thanks to git hooks
                Set-Location $currPath
            }
            #endregion copy exported GIT credentials from MGM server to cloned GIT repo & commit them
        } else {
            Write-Warning "Skipped!`n`nFollow instruction in configuring MGM server section https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md#on-server-which-will-be-used-for-cloning-and-processing-cloud-repository-data-and-copying-result-to-dfs-ie-mgm-server"
        }
        #endregion preparation of MGM server

        if (!$testInstallation) {
            _pressKeyToContinue
            Clear-Host
        } else {
            ""
        }

        #region create GPO that creates PS_env_set_up scheduled task or just the sched. task
        if ($ADInstallation) {
            $GPObackup = Join-Path $_other "PS_env_set_up GPO"
            Write-Host "- Creating GPO $GPOname for creating sched. task, that will synchronize repository data from share to clients" -ForegroundColor Green
            if (!$noEnvModification -and !$skipGPO -and !(_skip)) {
                if (Get-GPO $GPOname -ErrorAction SilentlyContinue) {
                    $choice = ""
                    while ($choice -notmatch "^[Y|N]$") {
                        $choice = Read-Host "GPO $GPOname already exists. Replace it? (Y|N)"
                    }
                    if ($choice -eq "Y") {
                        $null = Import-GPO -BackupGpoName $GPOname -Path $GPObackup -TargetName $GPOname
                    } else {
                        Write-Warning "Skipped creation of $GPOname"
                    }
                } else {
                    $null = Import-GPO -BackupGpoName $GPOname -Path $GPObackup -TargetName $GPOname -CreateIfNeeded
                }
            } else {
                Write-Warning "Skipped!`n`nCreate GPO by following https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md#in-active-directory-1 or using 'Import settings...' wizard in GPMC. GPO backup is stored in '$GPObackup'"
            }
        } elseif ($personalInstallation -or $testInstallation) {
            # sched. task has to be created manually (instead of GPO)
            $taskName = "PS_env_set_up"

            Write-Host "- Creating $taskName scheduled task, that will synchronize repository data from $repositoryShare to this client" -ForegroundColor Green

            #region PS_env_set_up scheduled task properties preparation
            #region customize parameters of PS_env_set_up.ps1 script that is being run in PS_env_set_up scheduled task
            if ($personalInstallation) {
                "1 - All (PS profile, modules, custom folders) - RECOMMENDED"
                "2 - Just PowerShell modules"
                "3 - Just Custom folders"
                ""

                $whatToSync = ""
                while (!($whatToSync -match "^(1|2|3)$")) {
                    [string[]] $whatToSync = Read-Host "Choose what you want to allow to be synchronized to this computer"
                }

                if ($whatToSync -ne 1) {
                    # not all data from repository will be synchronized

                    "   - you have chosen to synchronize just subset of repository data"

                    $PS_env_set_up_Param = " -synchronize "
                    $PS_env_set_up_ParamArg = ""

                    if ($syncPSProfile -eq "Y") {
                        # 4 stands for synchronyzing PS Profile
                        $whatToSync = @($whatToSync) + 4
                    }

                    switch ($whatToSync) {
                        2 {
                            if ($PS_env_set_up_ParamArg) {
                                $PS_env_set_up_ParamArg += ", "
                            }
                            $PS_env_set_up_ParamArg += "module"
                        }

                        3 {
                            if ($PS_env_set_up_ParamArg) {
                                $PS_env_set_up_ParamArg += ", "
                            }
                            $PS_env_set_up_ParamArg += "custom"
                        }

                        4 {
                            if ($PS_env_set_up_ParamArg) {
                                $PS_env_set_up_ParamArg += ", "
                            }
                            $PS_env_set_up_ParamArg += "profile"
                        }

                        default {
                            throw "Undefined synchronize option"
                        }
                    }

                    if ($PS_env_set_up_Param) {
                        # Repo_sync from Custom section has to be synchronized in any way, because this computer is also MGM server
                        if ($whatToSync -notcontains 3) {
                            if ($PS_env_set_up_ParamArg) {
                                $PS_env_set_up_ParamArg += ", "
                            }
                            $PS_env_set_up_Param = "-customToSync Repo_sync $PS_env_set_up_Param"
                            $PS_env_set_up_ParamArg += "custom"
                        }

                        $PS_env_set_up_Param = "$PS_env_set_up_Param $PS_env_set_up_ParamArg"

                        "   - synchronization PS_env_set_up.ps1 script called in same named scheduled task, will be run with following parameters: $PS_env_set_up_Param"

                        Write-Warning "Be very careful when using Refresh-Console function with 'synchronize' parameter. So you don't accidentaly synchronize more than you wanted."
                    }
                } else {
                    # option 1 was selected, i.e. synchronize all, i.e. default behaviour
                }
            }
            #endregion customize parameters of PS_env_set_up.ps1 script that is being run in PS_env_set_up scheduled task

            # define how often should synchronization occur
            if ($testInstallation) {
                # for test installation synchronization will be made once per 10 minutes
                $startInterval = "10M"
            } else {
                # for personal installation, synchronization will be made once per hour
                # all modules will be regenerated, so its not desirable to make this too often
                $startInterval = "1H"
            }

            # XML definition of the PS_env_set_up scheduled task
            $PS_env_set_up_schedTaskDefinition = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
    <RegistrationInfo>
    <Author>CONTOSO\adminek</Author>
    <URI>\PS_env_set_up</URI>
    </RegistrationInfo>
    <Triggers>
    <TimeTrigger>
        <Repetition>
        <Interval>PT$startInterval</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
        </Repetition>
        <StartBoundary>2019-04-10T14:31:23</StartBoundary>
        <Enabled>true</Enabled>
    </TimeTrigger>
    </Triggers>
    <Principals>
    <Principal id="Author">
        <UserId>S-1-5-18</UserId>
        <RunLevel>HighestAvailable</RunLevel>
    </Principal>
    </Principals>
    <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
        <Duration>PT5M</Duration>
        <WaitTimeout>PT1H</WaitTimeout>
        <StopOnIdleEnd>false</StopOnIdleEnd>
        <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>7</Priority>
    <RestartOnFailure>
        <Interval>PT1M</Interval>
        <Count>3</Count>
    </RestartOnFailure>
    </Settings>
    <Actions Context="Author">
    <Exec>
        <Command>powershell.exe</Command>
        <Arguments>-ExecutionPolicy ByPass -NoProfile `"$repositoryShare\PS_env_set_up.ps1 $PS_env_set_up_Param`"</Arguments>
    </Exec>
    </Actions>
</Task>
"@
            #endregion PS_env_set_up scheduled task properties preparation

            $PS_env_set_up_schedTaskDefinitionFile = "$env:TEMP\432432432.xml"
            $PS_env_set_up_schedTaskDefinition | Out-File $PS_env_set_up_schedTaskDefinitionFile -Encoding ascii -Force
            _createSchedTask $PS_env_set_up_schedTaskDefinitionFile $taskName
            "   - starting scheduled task '$taskName' to synchronize repository data from '$repositoryShare' to this client"
            _startSchedTask $taskName

            "      - checking, that the task ends up succesfully"
            while (($result = ((schtasks /query /tn "$taskName" /v /fo csv /nh) -split ",")[6] -replace '"') -eq '267009') {
                # task is running
                Start-Sleep 1
            }
            if ($result -ne '0' -and $result -ne '10000') {
                # custom error code 10000 means something wasn't synchronized (because in use etc), but for installation purposes it can be ignored
                Write-Error "Task '$taskName' ends up with error $result. Check C:\Windows\Temp\PS_env_set_up.ps1.log on $env:COMPUTERNAME for more information"
            }
        }
        #endregion create GPO that creates PS_env_set_up scheduled task or just the sched. task

        if (!$testInstallation) {
            _pressKeyToContinue
            Clear-Host
        } else {
            ""
        }

        #region finalize installation
        Write-Host "FINALIZING INSTALLATION" -ForegroundColor Green

        if ($personalInstallation -or $testInstallation -or ($ADInstallation -and !$skipAD -and !$skipGPO -and !$notAdmin)) {
            # enought rights to process all steps
        } else {
            "- DO NOT FORGET TO DO ALL SKIPPED TASKS MANUALLY"
        }

        if ($ADInstallation) {
            Write-Warning "- Link GPO $GPOname to OU(s) with computers, that should be driven by this tool.`n    - don't forget, that also $MGMServer server has to be in such OU!"
            @"
    - for ASAP test that synchronization is working:
        - run on client command 'gpupdate /force' to create scheduled task $GPOname
        - run that sched. task and check the result in C:\Windows\Temp\$GPOname.ps1.log
"@
        } elseif ($testInstallation) {
            "- check this console output, to get better idea what was done"
        }
        #endregion finalize installation

        if (!$testInstallation) {
            _pressKeyToContinue
            Clear-Host
        } else {
            ""
        }

        if ($testInstallation) {
            @"
SUMMARY ABOUT THIS !TEST! INSTALLATION:
 - Simulated Central Repository Share $repositoryShareLocPath is locally saved in $repositoryShareLocPath.
    - It would be used by clients as a source for synchronyzing repository data to them.
 - Simulated (Cloud) GIT Repository is hosted locally at $remoteRepository
    - In reality, this would be hosted in Azure DevOps, GitHub, etc private repository.
 - $userRepository is git clone of the (Cloud) Repository
    - This is the only part of this solution, that would be stored on your computer
    - Here you should make changes to repository data (creates new functions, modules, ...) and commit them to (Cloud) Repository.
 - Scheduled Tasks:
    - Repo_sync
        - Pulls data from (Cloud) GIT repository, processes them, and synchronizes the results to $repositoryShare.
            - In reality, this is being run on separated so called MGM Server
        - Processing is done in C:\Windows\Scripts\Repo_sync
        - Log file in C:\Windows\Temp\Repo_sync.ps1.log
    - PS_env_set_up
        - Synchronizes content from $repositoryShare to the client.
        - Log file in C:\Windows\Temp\PS_env_set_up.ps1.log
"@
            _pressKeyToContinue
            Clear-Host
        }

        Write-Host "GOOD TO KNOW" -ForegroundColor green
        @"
- It is highly recommended to use 'Visual Studio Code (VSC)' editor to work with the repository content because it provides:
    - Unified admin experience through repository thanks to included VSC workspace settings
        - Auto-Formatting of the code, encoding, addons, etc..
    - Integration & control of GIT
- Do NOT place your GIT repository inside Dropbox, Onedrive or other similar synchronization tool, it would cause problems!
- To understand, what is purpose of this repository content, check https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/3.%20SIMPLIFIED%20EXPLANATION%20OF%20HOW%20IT%20WORKS.md
- For immediate refresh of clients data (and console itself) use function Refresh-Console
    - NOTE: Available only on computers defined in Variables module in variable `$computerWithProfile
- For examples check https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/2.%20HOW%20TO%20USE%20-%20EXAMPLES.md
- For brief video introduction check https://youtu.be/-xSJXbmOgyk and other videos at https://youtube.com/playlist?list=PLcNLAABGhY_GqrWfOZGjpgFv3fiaL0ciM
- For mastering Modules deployment check \modules\modulesConfig.ps1
- For mastering Custom section features check \custom\customConfig.ps1
- To see what is happening in the background check logs
    - In VSC Output terminal (CTRL + SHIFT + U, there switch output to GIT) (pre-commit.ps1 checks etc)
    - C:\Windows\Temp\Repo_sync.ps1.log on MGM server (synchronization from GIT repository to share)
    - C:\Windows\Temp\PS_env_set_up.ps1.log on client (synchronization from share to client)

ENJOY :)

"@

        # start VSC and open there GIT repository
        $codeCmdPath = "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd"
        if (Test-Path $codeCmdPath) {
            Start-Sleep 10
            "- Opening your repository in VSC"
            & $codeCmdPath "$userRepository"
        }

        # open examples web page
        Start-Sleep 3
        Start-Process "https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/2.%20HOW%20TO%20USE%20-%20EXAMPLES.md"
    } catch {
        $e = $_.Exception
        $line = $_.InvocationInfo.ScriptLineNumber
        Write-Host "$e (file: $PSCommandPath line: $line)" -ForegroundColor Red
        break
    } finally {
        Set-Location $PSScriptRoot

        $null = Stop-Transcript -ErrorAction SilentlyContinue

        try {
            Remove-PSSession -Session $repositoryHostSession
            Remove-PSSession -Session $MGMServerSession
        } catch {}
    }
}