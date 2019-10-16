# this module should export just variables!
# is intended as central storage of "global" variables
# global variables means, that they will be available (after importing of this module) on ANY computer, where GPO PS_env_set_up is applied

# name of MGM server (used to pull and process GIT repository content and fill DFS with result)
$repoSyncServer = "__TODO__"
# name of computers, which should contain global Powershell profile (ie. scripts2root\profile.ps1)
$computerWithProfile = "__TODO__"

# some examples of global variables...
$dhcpServer = "server1"
$smtpServer = "server2"
# $computerAccountsOU = (New-Object System.DirectoryServices.DirectorySearcher((New-Object System.DirectoryServices.DirectoryEntry("LDAP://OU=Computer_Accounts,DC=contoso,DC=com")) , "objectCategory=computer")).FindAll() | ForEach-Object { $_.Properties.name }


Export-ModuleMember -Variable *