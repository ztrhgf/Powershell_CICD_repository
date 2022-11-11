<#
Purpose of this file is to give you option to limit only on which computers should be selected modules from this repository copied.
Both modules from modules and scripts2module (automatically generated) folders can be set.

- modules not defined here will be copied to every computer joined to this CI/CD solution
- modules are copied on clients to C:\Windows\System32\WindowsPowerShell\v1.0\Modules, so are globally available
- any copied module, that shouldn't be on client anymore is deleted
    - copied modules are recognized by their NTFS ACL
- synchronization of modules is invoked from clients themself
    - through PS_env_set_up scheduled task (ie ps1 script) under SYSTEM account
    - by dot sourcing this file and behave accordingly to content of modulesConfig variable
        - so IT SHOULD'N CONTAIN ANYTHING ELSE BESIDES variable modulesConfig


## WHAT MODULESCONFIG VARIABLE IS AND WHAT IT SHOULD CONTAINS:
- modulesConfig is defined as array of objects, where every object represents one folder (module) in root of Modules or scripts2module directory
- object keys define, what should be done with this folder


## POSSIBLE OBJECT KEYS:
    - folderName
        (mandatory) [string] key
        - name of folder in modules or scripts2module directory, that this object represents

    - computerName
        (mandatory) [string[]] key
        - name of servers to which should be this folder copied (and nowhere else!)
            - in case it was already copied to some computers, it will be automatically deleted there!
        - variable (from module Variables) can be used also


## EXAMPLES:

    !!! BEWARE because of AST analyze, comma between objects always need to be on same line as the objects closing brace ie.

    $modulesConfig = @(
        [PSCustomObject]@{
            folderName   = "ConfluencePS"
            computerName = "PC-1"
        },
        [PSCustomObject]@{
            folderName   = "Posh-SSH"
            computerName = $adminPC
        },
        [PSCustomObject]@{
            folderName   = "adminFunctions"
            computerName = $adminPC
        }
    )
#>

$modulesConfig = @(
)