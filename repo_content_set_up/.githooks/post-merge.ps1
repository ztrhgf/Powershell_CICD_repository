<#
script
    - is automatically run when 'git pull' is called (because of git post-merge hook)
    - notify user about files, that are currently modified and were automerged with changes downloaded through git pull

It is needed in case you are using VSC for managing repository. If you make git pull in console, merged files would be outputed to console automatically.
#>

$ErrorActionPreference = "stop"

# Write-Host is used to display output in GIT console

function _ErrorAndExit {
    param ($message)

    if ( !([appdomain]::currentdomain.getassemblies().fullname -like "*System.Windows.Forms*")) {
        Add-Type -AssemblyName System.Windows.Forms
    }

    $message
    $null = [System.Windows.Forms.MessageBox]::Show($this, $message, 'ERROR', 'ok', 'Error')
    exit 1
}

try {
    # switch to repository root
    Set-Location $PSScriptRoot
    Set-Location ..
    $root = Get-Location

    # this file contains hash of LAST commit, that was pulled from or pushed to repository
    # ie last commit before user was forced to made pull new data from repository (because someonw else made some changes)
    # it is used to show files that was changed by other users ie in commits that made other users
    # hash of last pushed commit is automatically saved when post-commit.ps1 is called (push cannot be done without most recent data ie it should be ok)
    $lastCommitPath = Join-Path $root ".githooks\lastCommit"

    # last commit that was downloaded when previous git pull was done
    # it has to be saved to file because this git hook is run after git pull is made
    $previousLastCommit = Get-Content $lastCommitPath -ea SilentlyContinue
    "previous commit $previousLastCommit"
    # commit that was actual when git pull was done
    $actualLastCommit = git log -n 1 --pretty=format:"%H"
    "now pulled commit $actualLastCommit"
    $actualLastCommit | Out-File $lastCommitPath -Force

    if ($previousLastCommit) {
        # what files were changed from last git pull
        $changedFileBetweenCommits = @(git diff --name-only $previousLastCommit $actualLastCommit)
        $prevCommitSubject = git log -1 $previousLastCommit --format="%s"
        "files changed since last commit (`"$prevCommitSubject`"):`n$($changedFileBetweenCommits -join "`n")"

        # what files are modified right now
        # files in staging area ie commited files
        $stagedFile = @(git diff --name-only --cached)
        # modified files but not in staging area
        $modifiedNonstagedFile = @(git ls-files -m)
        # files in stash
        if (git stash list) {
            $stashedFile = @(((git stash show) -split "`n" | ? { $_ -match "\|" } | % { ($_ -split "\|")[0] }).trim())
        }

        $modifiedFile = $stagedFile + $modifiedNonstagedFile + $stashedFile
        "modified files:`n$($modifiedFile -join "`n")"
        # files that was downloaded using git pull and are modified at the same time
        $possibleConflictingFile = @()

        if ($modifiedFile -and $changedFileBetweenCommits) {
            $modifiedFile | % {
                if ($changedFileBetweenCommits -contains $_) {
                    $possibleConflictingFile += $_
                }
            }
        }

        $possibleConflictingFile = $possibleConflictingFile | Select-Object -Unique

        if ($possibleConflictingFile) {
            $message = "Following files were automerged with changes pulled from cloud repository. Check, that it is ok.`n`n$($possibleConflictingFile -join "`n")`n`n`nChanges happened after commit `"$prevCommitSubject`""

            if ( !([appdomain]::currentdomain.getassemblies().fullname -like "*System.Windows.Forms*")) {
                Add-Type -AssemblyName System.Windows.Forms
            }

            $message
            $null = [System.Windows.Forms.MessageBox]::Show($this, $message, 'ERROR', 'ok', 'Error')
        }
    }
} catch {
    _ErrorAndExit "There was an error:`n$_"
}

"DONE"