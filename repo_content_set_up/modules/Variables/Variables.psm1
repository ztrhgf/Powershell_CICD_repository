# modul obsahuje promenne, ktere budou dostupne vsude kde se aplikuje GPO PS_env_set_up

# jmeno serveru, ze ktereho se plni DFS repo (MGM server)
$repoSyncServer = "TODONAHRADIT"
# jmena stroju, na ktere se ma kopirovat globalni Powershell profil (tzn. scripts2root\profile.ps1)
$computerWithProfile = "TODONAHRADIT"

# co dalsiho tu muze byt...
$dhcpServer = "server1"
$smtpServer = "server2"
# $computerAccountsOU = (New-Object System.DirectoryServices.DirectorySearcher((New-Object System.DirectoryServices.DirectoryEntry("LDAP://OU=Computer_Accounts,DC=contoso,DC=com")) , "objectCategory=computer")).FindAll() | ForEach-Object { $_.Properties.name }


Export-ModuleMember -Variable *