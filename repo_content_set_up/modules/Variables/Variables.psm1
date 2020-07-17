# this module should export just variables!
# is intended as central storage of "global" variables
# global variables means, that they will be available (after importing of this module) on ANY computer, where GPO PS_env_set_up is applied
# it's best practice to somehow distinguish variables defined here (for example prefix them with '_')

## REPOSITORY
# name of MGM server (used to pull and process GIT repository content and fill DFS with result)
$_repoSyncServer = "__TODO__"
# UNC path to share, where repository is stored (used in Refresh-Console)
$_repoShare = "__TODO__"
# name of computers, which should contain global Powershell profile (i.e. scripts2root\profile.ps1) and module with admin functions (i.e. scripts2module\adminFunctions)
$_computerWithProfile = "__TODO__"

## SMTP
# email address of your IT department, errors will be send to this address
$_adminEmail = "__TODO__" # for example it@contoso.com
# company SMTP server, Send-Email function will use it for sending emails
$_smtpServer = "__TODO__" # for example autodiscover.contoso.com
# address that will be used as sender in function Send-Email
$_from = "__TODO__" # for example monitoring@contoso.com

<# 
for inspiration:

$_dhcpServer = "server1"
$_mbamSQLServer = "server3"
$_computerAccountsOU = (New-Object System.DirectoryServices.DirectorySearcher((New-Object System.DirectoryServices.DirectoryEntry("LDAP://OU=Computer_Accounts,DC=contoso,DC=com")) , "objectCategory=computer")).FindAll() | ForEach-Object { $_.Properties.name }
#>

Export-ModuleMember -Variable *