<#
script
    - is automatically run after new commit is succesfully created (because of git post-commit hook)
    - pushes commit to cloud repository
#>

$ErrorActionPreference = "stop"

# Write-Host is used to display output in GIT console

function _ErrorAndExit {
    param ($message)

    if ( !([appdomain]::currentdomain.getassemblies().fullname -like "*System.Windows.Forms*")) {
        Add-Type -AssemblyName System.Windows.Forms
    }

    # to GIT console output whole message
    Write-Host $message

    # in case message is too long, trim
    $messagePerLine = $message -split "`n"
    $lineLimit = 40
    if ($messagePerLine.count -gt $lineLimit) {
        $message = (($messagePerLine | select -First $lineLimit) -join "`n") + "`n..."
    }

    $null = [System.Windows.Forms.MessageBox]::Show($this, $message, 'ERROR', 'ok', 'Error')
    exit 1
}

try {
    # switch to repository root
    Set-Location $PSScriptRoot
    Set-Location ..
    $root = Get-Location

    function _startProcess {
        [CmdletBinding()]
        param (
            [string] $filePath = '',
            [string] $argumentList = '',
            [string] $workingDirectory = (Get-Location)
        )

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo.UseShellExecute = $false
        $p.StartInfo.RedirectStandardOutput = $true
        $p.StartInfo.RedirectStandardError = $true
        $p.StartInfo.WorkingDirectory = $workingDirectory
        $p.StartInfo.FileName = $filePath
        $p.StartInfo.Arguments = $argumentList
        [void]$p.Start()
        $p.WaitForExit()
        $p.StandardOutput.ReadToEnd()
        $p.StandardError.ReadToEnd()
    }


    #
    # push commit to cloud GIT repository
    "- push commit to cloud repository"
    $defaultBranch = ((git symbolic-ref refs/remotes/origin/HEAD) -split "/")[-1]
    $repoStatus = _startProcess git "push origin $defaultBranch"
    # check that push was succesfull
    if ($repoStatus -match "\[rejected\]") {
        _ErrorAndExit "There was an error when trying to push commit to cloud repository:`n$repoStatus"
    }

    #
    # save actual commit hash to file (reason to this is explained in post-merge.ps1)
    $lastCommitPath = Join-Path $root ".githooks\lastCommit"
    $actualLastCommit = git log -n 1 --pretty=format:"%H"
    $actualLastCommit | Out-File $lastCommitPath -Force
} catch {
    _ErrorAndExit "There was an error:`n$_"
}

"DONE"