<#
Purpose of this file is to define, what should happen with folders in Custom directory.
So to what computers or shares, to what location and with what permissions should they be copied.

- everything is defined in CustomConfig variable (details below)
- synchronization of Custom directory is invoked from clients themself
    - through PS_env_set_up scheduled task (ie ps1 script) under SYSTEM account
    - by dot sourcing this file and behave accordingly to content of CustomConfig variable
        - so IT SHOULD'N CONTAIN ANYTHING ELSE BESIDES variable CustomCOnfig
- folder are copied using robocopy in mirror mode
    - modified data are therefore automatically replaced
    - no more needed files are automatically deleted
    - so save any scripts output to 'Log' subfolder which is automatically created in root of each copied folder from Custom directory (otherwise it will be automatically deleted by robocopy mirror)
- folders that are not mentioned here in customConfig variable are just copied to DFS share and nothing else


## WHAT CUSTOMTONFIG VARIABLE IS AND WHAT IT SHOULD CONTAINS:
- customConfig is defined as array of objects, where every object represents one folder in root of Custom directory
- object keys define, what should be done with this folder


## POSSIBLE OBJECT KEYS:
    - folderName
        (mandatory) [string] key
        - name of folder in Custom directory, that this object represents
            - don't forget to delete this object from CustomConfig in case, corresponding folder is also deleted, otherwise sync script PS_env_set_up will end with error!

        eg.: folderName = "MonitoringScripts"

    - computerName
        (optional) [string[]] key
        - name of servers to which should be this folder copied
            - default destination location is C:\Windows\Scripts
        - variable (from module Variables) can be used also
        - moreover, for security reasons just these computers will have access to this folder in DFS share
            - access is limited by customizing NTFS rights

        eg.: computerName = "PC1", "PC2", "SERVER-01", $SQLServers (the last one is variable from Variables module)

    - customDestinationNTFS
        (optional) [string[]] key
        - used to limit NTFS access rights on copied folder
        - just given accounts/groups will have READ access instead of all 'Authenticated Users'
            BEWARE that
                - in case, that folder is copied to local destination on some server, SYSTEM and members of groups repo_reader, repo_writer, Administrators will have also READ access (this is by design)
                - members of group repo_writer have always FULL CONTROL access (this is by design)
        - just given account/group will have MODIFY access on (automatically created) Log subfolder (otherwise 'Authenticated Users')

        eg.: customDestinationNTFS = "SYSTEM", "Local Service", "contoso\JohnD", "contoso\o365sync$" (the last one is gMSA domain account)

    - customSourceNTFS
        (optional) [string[]] key
        - used to limit NTFS rights to this folder right in DFS share
        - just given accounts/groups will have READ access instead of 'Domain computers'
        - BEWARE, that in case this key and computerName key are both set, this setting will replace NTFS settings that would otherwise be set for computers listed in computerName key

        eg.: customSourceNTFS = "APP-15$", "SQL-01$", "contoso\sqlAdmins"

    - customLocalDestination
        (optional) [string] key
        - used to change destination path, where should be this folder copied
        - default path is %WINDIR%\Scripts (so for example folder MonitoringScripts will be copied to C:\Windows\Scripts\MonitoringScripts)
        - it has to be local path and SYSTEM account needs to have Full Control permissions
        - BEWARE, if you define this key
            - copied folder won't be deleted in case value of this key changes
            - NTFS permissions won't be set unless you explicitly define key customDestinationNTFS (to minimize risk for break something), same goes for Log subfolder

        eg.: customLocalDestination = "C:\Program Files\PowerShell\7-preview\Modules"

    - customShareDestination
        (optional) [string] key
        - used to copy folder to shared folder
            - in case you also define computerName key, folder will be copied also to this computers
        - path has to be in UNC format and repo_writer group members has to have Full Control access to it
        - BEWARE, if you define this key
            - copied folder won't be deleted in case value of this key changes
            - NTFS permissions won't be set unless you explicitly define key customDestinationNTFS (to minimize risk for break something), same goes for Log subfolder

        eg.: customShareDestination = "C:\Program Files\PowerShell\7-preview\Modules"

    - copyJustContent
        (optional) [switch] key
        - used to copy just folder content not folder itself
        - typical use case would be to copy config files, ini etc
        - can be used only with customLocalDestination and customShareDestination
        - BEWARE, if you define this key
            - copied content won't be deleted in case value of this key changes
            - NTFS permissions won't be set (nor customDestinationNTFS)
            - Log subfolder won't be created

        eg.: copyJustContent = $true

    - scheduledTask
        (optional) [string[]] key
        - used to automatically create scheduled task from given xml definition
            - for getting xml definition easiest approach is to create task in Task Scheduler and Export it
        - value has to be the name of the existing xml file (without extension)
            - name is case sensitive
            - xml file has to be placed in folder root
        - created Scheduled task will
            - be named as xml file itself no matter what is defined in it
            - be created in Task Scheduled root
            - have as author name of synchronization script (PS_env_set_up)
                - because of easy identification and manageability
            - be replaced in case, the base xml will be modified
            - be deleted in case, it should'n be on client anymore

        eg.: scheduledTask = "performanceMonitoring", "auditMonitoring"


## EXAMPLES:

    !!! BEWARE because of AST analyze, comma between objects always need to be on same line as the objects closing brace ie.
    $customConfig = @(
        [PSCustomObject]@{
            folderName   = "SomeTools"
            computerName = "APP-1", $servers_app
        },
        [PSCustomObject]@{
            folderName   = "SomeOtherTools"
            computerName = "APP-1"
        }
    )

    # copy folder "SomeTools" to APP-1 and computers in variable $servers_app to C:\Windows\Scripts\SomeTools and moreover just o365sync$ gmsa account will have READ rights to this folder
    [PSCustomObject]@{
        folderName   = "SomeTools"
        computerName = "APP-1", $servers_app
        customDestinationNTFS   = "contoso\o365sync$"
    }

    # copy folder "Monitoring_Scripts" which contains some monitoring scripts and xml sch. task definitions to server defined in $monitoringServer to C:\Windows\Scripts\Monitoring_Scripts
    # and create scheduled tasks from XML definitions monitor_AD_Admins.xml, monitor_backup.xml (which can call these monitoring scripts) on that server
    [PSCustomObject]@{
        folderName   = "Monitoring_Scripts"
        scheduledTask = "monitor_AD_Admins", "monitor_backup"
        computerName = $monitoringServer
    }

    # example of dynamically defined computerName (by computers in OU Notebooks)
    [PSCustomObject]@{
        folderName   = "notebookScripts"
        computerName = (New-Object System.DirectoryServices.DirectorySearcher((New-Object System.DirectoryServices.DirectoryEntry("LDAP://OU=Notebooks,OU=Computer_Accounts,DC=contoso,DC=com")) , "objectCategory=computer")).FindAll() | ForEach-Object { $_.Properties.name }
    }

    # copy content of IISConfig (for example web.config) to "C:\inetpub\wwwroot\" on web server
    [PSCustomObject]@{
        folderName   = "IISConfig"
        computerName = $webServer
        customLocalDestination = "C:\inetpub\wwwroot\"
        copyJustContent   = 1
    }

    # copy folder "Scripts" to shared folder "\\DFS\root\privateScrips" moreover just comptuers "APP-1$", "APP-2$" and group "Domain Admins" will have rights to read its content
    [PSCustomObject]@{
        folderName   = "Scripts"
        customShareDestination = "\\DFS\root\privateScrips"
        customDestinationNTFS   = "APP-1$", "APP-2$", "Domain Admins"
    }

    # leave "Admin_Secrets" just in your DFS share and limit access just to "Domain Admins"
    [PSCustomObject]@{
        folderName   = "Admin_Secrets"
        customSourceNTFS = "Domain Admins"
    }
#>

$customConfig = @(
    [PSCustomObject]@{
        folderName   = "Repo_sync"
        computerName = $_repoSyncServer
    }
)