<#

GLOBALNI POWERSHELL PROFILE

- slouzi k nastaveni PS konzole
    tzn importu pouzivanych skriptu, modulu, promennych, definovani per user funkci, ...

- kopiruje se na klientech do %WINDIR%\System32\WindowsPowershell\v1.0 tzn jde o globalni PS profil
- kopiruje se pouze na klienty uvedene v promenne $computerWithProfile definovane v modulu Variables
    a to pomoci GPO "PS_env_set_up"

! tento profil ovlivnuje pouze lokalni session, ne remote !

!!! piste jej tak, aby nic nespoustel ci needitoval !!!

#>


# nema smysl spoustet pro startup skripty, sched. task skripty atd, ktere bezi pod systemovymi ucty
$whoami = whoami.exe
if ($whoami -in "NT AUTHORITY\SYSTEM", "NT AUTHORITY\NETWORK SERVICE", "NT AUTHORITY\LOCAL SERVICE") { return }
$local_user = $env:USERDOMAIN -eq $env:COMPUTERNAME

#
# aby jako pracovni adresar byla cesta do profilu uzivatele, pod kterym konzole bezi
Set-Location $env:USERPROFILE



#
# customizace chovani psreadline rozsireni
#

try {
    # aby TAB doplnoval i jmena souboru v adresari
    Set-PSReadLineKeyHandler -Key Tab -Function MenuComplete -ErrorAction Stop # nebo Complete
    # identicke prikazy spustene vickrat po sobe se budou zobrazovat v historii pouze jednou
    Set-PSReadLineOption -HistoryNoDuplicates:$True -ErrorAction Stop
    # co se smi ulozit do historie prikazu
    # obecne ignoruji veci kolem hesel
    Set-PSReadLineOption -AddToHistoryHandler {
        Param([string]$line)
        if ($line -notmatch "runas|admpwd|-pswd ") {
            return $True
        } else {
            return $False
        }
    } -ErrorAction Stop
} catch {
    "nepodarilo se nastavit PSReadline"
}




#
# customizace vychozich parametru fci
#

$PSDefaultParameterValues = @{
    # ulozeni vystupu posledniho prikazu do $__
    'Out-Default:OutVariable' = '__'
}
# $PSDefaultParameterValues.Clear() # komplet zruseni
# $PSDefaultParameterValues.Add('Disabled', $true) # docasne zakazani obsahu $PSDefaultParameterValues
# $PSDefaultParameterValues.Remove('Disabled') # opetovne povoleni obsahu $PSDefaultParameterValues




#
# TAB completition
#

# doplneni dynamicky ziskane hodnoty ve vybranych parametrech vybranych funkci stiskem TAB
#__TODO__ replace used LDAP:// paths according to your organization, otherwise TAB completition wont work

$computerSB = {
    param ($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameter)

    $searcher = New-Object System.DirectoryServices.DirectorySearcher (([adsi]"LDAP://DC=kontoso,DC=com"), '(objectCategory=computer)', ('name', 'description'))
    ($searcher.findall() | ? { $_.properties.name -match $wordToComplete -or $_.properties.description -match $wordToComplete }).properties.name  | Sort-Object | % { "'$_'" }
    $searcher.Dispose()
}
# TAB doplneni jmena domenoveho stroje do computerName parametru v jakemkoli prikazu z modulu Scripts
# zadany string hleda jak v name, tak description
Register-ArgumentCompleter -CommandName ((Get-Command -Module Scripts).name) -ParameterName computerName -ScriptBlock $computerSB
# TAB doplneni jmena domenoveho stroje do identity parametru v prikazech z modulu ActiveDirectory, ktere pracuji s computer objekty
Register-ArgumentCompleter -CommandName ((Get-Command -Module ActiveDirectory -Noun *computer*).name) -ParameterName identity -ScriptBlock $computerSB

$serverSB = {
    param ($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameter)

    $searcher = New-Object System.DirectoryServices.DirectorySearcher (([adsi]"LDAP://OU=Servers,DC=kontoso,DC=com"), '(objectCategory=computer)', ('name', 'description'))
    ($searcher.findall() | ? { $_.properties.name -match $wordToComplete -or $_.properties.description -match $wordToComplete }).properties.name  | Sort-Object | % { "'$_'" }
    $searcher.Dispose()
}
# ukazka omezeni TAB doplneni computerName parametru na jmena serveru (ve vybranych funkcich)
# zadany string hleda jak v name, tak description
Register-ArgumentCompleter -CommandName Invoke-MSTSC -ParameterName computerName -ScriptBlock $serverSB

$clientSB = {
    param ($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameter)

    $searcher = New-Object System.DirectoryServices.DirectorySearcher (([adsi]"LDAP://OU=Clients,DC=kontoso,DC=com"), '(objectCategory=computer)', ('name'))
    ($searcher.findall()).properties.name | ? { $_ -match $wordToComplete } | Sort-Object | % { "'$_'" }
    $searcher.Dispose()
}
# ukazka omezeni automatickeho doplneni computerName parametru na jmena klientskych stroju (ve vybranych funkcich)
Register-ArgumentCompleter -CommandName Assign-Computer -ParameterName computerName -ScriptBlock $clientSB

$userSB = {
    param ($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameter)

    $searcher = New-Object System.DirectoryServices.DirectorySearcher (([adsi]"LDAP://OU=User,DC=kontoso,DC=com"), '(objectCategory=user)', ('name', 'samaccountname'))
    ($searcher.findall() | ? { $_.properties.name -match $wordToComplete }).properties.samaccountname | Sort-Object | % { "'$_'" }
    $searcher.Dispose()
}
# TAB doplneni userName parametru na user login v jakemkoli prikazu z modulu Scripts
Register-ArgumentCompleter -CommandName ((Get-Command -Module Scripts).name) -ParameterName userName -ScriptBlock $userSB
# TAB doplneni identity parametru na user login v prikazech z modulu ActiveDirectory, ktere pracuji s user objekty
Register-ArgumentCompleter -CommandName ((Get-Command -Module ActiveDirectory -Noun *user*).name) -ParameterName identity -ScriptBlock $userSB

$groupSB = {
    param ($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameter)

    $searcher = New-Object System.DirectoryServices.DirectorySearcher (([adsi]"LDAP://OU=Groups,DC=kontoso,DC=com"), '(objectCategory=group)', ('name', 'description'))
    ($searcher.findall() | ? { $_.properties.name -match $wordToComplete -or $_.properties.description -match $wordToComplete }).properties.name | Sort-Object | % { "'$_'" }
    $searcher.Dispose()
}
# TAB doplneni identity parametru na group name v prikazech z modulu ActiveDirectory, ktere pracuji s group objekty
Register-ArgumentCompleter -CommandName ((Get-Command -Module ActiveDirectory -Noun *group*).name) -ParameterName identity -ScriptBlock $groupSB




#
# import modulu
#

if (!$local_user) {
    #
    # nactu promenne z Variables modulu
    Import-Module Variables
}




#
# customizace vzhledu konzole
#

# uprava Title konzole
$title = ''
$identity = [Security.Principal.WindowsIdentity]::GetCurrent() ; $principal = [Security.Principal.WindowsPrincipal] $identity
if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) { $title = "[ELEVATED] " }
$title += ($env:USERNAME).toupper()
$title += "            " + (Get-Location).path
$Host.UI.RawUI.Windowtitle = $title
# uprava promptu, barevne odliseni podle toho jak privilegovany ucet konzoli spustil
function prompt {
    # aktualizace cesty v title
    $titleItems = $Host.UI.RawUI.Windowtitle -split "\s+"
    $Host.UI.RawUI.Windowtitle = (($titleItems | Select-Object -First ($titleItems.count - 1)) -join " ") + "            " + (Get-Location).path

    # uprava promptu
    $color = "white"
    if ($env:USERNAME -match "^adm_") {
        $color = "red"
    }

    Write-Host "PS" -noNewLine -ForegroundColor $color
    return "> "
}




#
# aliasy
#

Set-Alias es Enter-PSSession




#
# per user nastaveni
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