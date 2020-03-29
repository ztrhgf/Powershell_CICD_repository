<#

GLOBAL POWERSHELL PROFILE

- intended for unifying company admins Powershell experience
    - setting console GUI, importing Variables module, defining per-user functions etc
- is automatically copied to computers listed in $computerWithProfile variable (defined in Variables module)
    - to %WINDIR%\System32\WindowsPowershell\v1.0 ie its gloval powershell profile
- is applied only in local session, no remote
- when editing, BE VERY CAREFUL, because it is basically script, that will be run on every console start!

#>

# don't apply to system accounts
$whoami = whoami
if ($whoami -in "NT AUTHORITY\SYSTEM", "NT AUTHORITY\NETWORK SERVICE", "NT AUTHORITY\LOCAL SERVICE") { return }

$local_user = $env:USERDOMAIN -eq $env:COMPUTERNAME

# set working directory to user profile
Set-Location $env:USERPROFILE



#
# customization of PSReadline
#

try {
    # enable TAB completion of files in actual working directory
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete -ErrorAction Stop # nebo Complete
    # no duplicity in command history
    Set-PSReadLineOption -HistoryNoDuplicates:$True -ErrorAction Stop
    # limit what can be saved in command history
    # becauase of security prohibit command with parameters, that can contain plaintext passwords
    Set-PSReadLineOption -AddToHistoryHandler {
        Param([string]$line)
        if ($line -notmatch "runas|admpwd|-pswd ") {
            return $True
        } else {
            return $False
        }
    } -ErrorAction Stop
} catch {
    "unable to configure PSReadline"
}




#
# customization of default function parameters
#

$PSDefaultParameterValues = @{
    # save output of last command to variable $__
    'Out-Default:OutVariable' = '__'
}



#
# dynamic TAB completion of parameter values
#
#__TODO__ replace used LDAP:// paths according to your organization or you can delete this section completely :)

$computerSB = {
    param ($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameter)

    $searcher = New-Object System.DirectoryServices.DirectorySearcher (([adsi]"LDAP://DC=kontoso,DC=com"), '(objectCategory=computer)', ('name', 'description'))
    ($searcher.findall() | ? { $_.properties.name -match $wordToComplete -or $_.properties.description -match $wordToComplete }).properties.name  | Sort-Object | % { "'$_'" }
    $searcher.Dispose()
}
# TAB completion of AD computer names in computerName parameter of any command from module Scripts, ..
# given string (on which TAB was used) is searched in name and description of AD computer accounts
Register-ArgumentCompleter -CommandName ((Get-Command -Module Scripts).name) -ParameterName computerName -ScriptBlock $computerSB
# TAB completion of AD computer names in identity parameter of commands with "computer" in their name from module ActiveDirectory
#__TODO__ uncomment only in case you have RSAT installed on your admin computers 
#Register-ArgumentCompleter -CommandName ((Get-Command -Module ActiveDirectory -Noun *computer*).name) -ParameterName identity -ScriptBlock $computerSB




#
# import Variables module
#
if (!$local_user) {
    Import-Module Variables
}


#
# customization console Title and prompt
#

# save commit identifier which was actual when this console started to user registry
# to be able later compare it with actual system commit
$commitHistoryPath = "$env:SystemRoot\Scripts\commitHistory"
$keyName = "consoleCommit_$PID"
$keyPath = "HKCU:\Software"
if ($consoleCommit = Get-Content $commitHistoryPath -First 1 -ErrorAction SilentlyContinue) {
    $null = New-ItemProperty $keyPath -Name $keyName -PropertyType string -Value $consoleCommit -Force
}
# cleanup of registry records, for not existing console processes (identified by PID)
$pssId = Get-Process powershell, powershell_ise -ErrorAction SilentlyContinue | select -exp id
Get-Item $keyPath | select -exp property | % {
    $id = ($_ -split "_")[-1]
    if ($id -notin $pssId) {
        Remove-ItemProperty $keyPath $_
    }
}

# function for showing, how many commits is this console behind the system state
function _commitDelay {
    $space = "   "
    try {
        $consoleCommit = Get-ItemPropertyValue $keyPath -Name $keyName -ea Stop
    } catch { }
    if (!$consoleCommit -or !(Test-Path $commitHistoryPath -ea SilentlyContinue)) {
        return "$space(*unknown*)"
    }

    $i = 0
    $commitHistory = @(Get-Content $commitHistoryPath)
    foreach ($commit in $commitHistory) {
        if ($commit -eq $consoleCommit) {
            return "$space($i)"
        }

        ++$i
    }

    # commit jsem nenasel
    return ($space + "(>" + $commitHistory.count + ")")
}

# Title customization
$title = ''
$space = "      "
$identity = [Security.Principal.WindowsIdentity]::GetCurrent() ; $principal = [Security.Principal.WindowsPrincipal] $identity
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) { $title = "[ELEVATED] " }
$title += ($env:USERNAME).toupper()
$title += $space + (_commitDelay) + $space + (Get-Location).path
$Host.UI.RawUI.Windowtitle = $title
# Prompt customization
function prompt {
    $titleItems = $Host.UI.RawUI.Windowtitle -split "\s+"
    $Host.UI.RawUI.Windowtitle = (($titleItems | Select-Object -First ($titleItems.count - 2)) -join " ") + $space + (_commitDelay) + $space + (Get-Location).path

    $color = "white"
    if ($env:USERNAME -match "^adm_") {
        $color = "red"
    }

    Write-Host "PS" -noNewLine -ForegroundColor $color
    return "> "
}




#
# aliases
#

Set-Alias es Enter-PSSession


#
# per user settings
#

# just examples, how you can make per user changes
switch ($env:USERNAME) {
    { $_ -in 'karel', 'admKarel' } {
        function ttcmd { & "C:\DATA\totalcmd(x64)\TOTALCMD64.EXE" }
    }

    { $_ -in 'pepa' } {
        function ttcmd { & "C:\Program Files\totalcmd(x64)\TOTALCMD64.EXE" }
    }
}