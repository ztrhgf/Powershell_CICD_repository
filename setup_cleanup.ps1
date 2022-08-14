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

    throw "work in progress"

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
                    $permissions += @(, ("$_", "ReadAndExecute", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                }
            }
            if ($writeUser) {
                $writeUser | ForEach-Object {
                    $permissions += @(, ("$_", "FullControl", 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
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
                    $permissions += @(, ("$_", "ReadAndExecute", 'Allow'))
                }
            }

            if ($writeUser) {
                $writeUser | ForEach-Object {
                    $permissions += @(, ("$_", "FullControl", 'Allow'))
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

"C:\Windows\System32\WindowsPowerShell\v1.0\profile.ps1", "C:\Windows\System32\WindowsPowerShell\v1.0\Modules\Adminfunctions", "C:\Windows\System32\WindowsPowerShell\v1.0\Modules\Scripts", "C:\Windows\System32\WindowsPowerShell\v1.0\Modules\Scripts2" | % {
    if (Test-Path $_ -ea SilentlyContinue) {
        $_
        takeown /F $_
        _setPermissions -path $_ -writeUser somedomain\administrator
        Remove-Item $_ -Recurse -Force
    }
}


SCHTASKS /Delete /TN "repo_sync" /F
SCHTASKS /Delete /TN "ps_env_set_up" /F

Remove-Item C:\Windows\Scripts -Recurse -Force -ea SilentlyContinue
Remove-Item "$env:userprofile\AppData\Roaming\Code\User\snippets\powershell.json" -ea SilentlyContinue -Force
Remove-Item "$env:userprofile\setup.ps1.log" -ea SilentlyContinue -Force
Remove-Item "$env:userprofile\Powershell_CICD_repository.ini" -ea SilentlyContinue -Force
Remove-Item "C:\Windows\Temp\Repo_Sync.ps1.log" -ea SilentlyContinue -Force
Remove-Item "C:\Windows\Temp\PS_env_set_up.ps1.log" -ea SilentlyContinue -Force

Remove-ADGroup repo_reader -Confirm:$false
Remove-ADGroup repo_writer -Confirm:$false