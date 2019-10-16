# script pushes commit to cloud repository

$ErrorActionPreference = "stop"

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
    # prepnu se do rootu repozitare
    Set-Location $PSScriptRoot
    Set-Location ..
    $root = Get-Location

    # _startProcess umi vypsat vystup (vcetne chyb) primo do konzole, takze se da pres Select-String poznat, jestli byla chyba
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
    # pushnuti zmen do remote repozitare
    "- push commit to cloud repository"
    $repoStatus = _startProcess git "push origin master"
    # kontrola, ze se push povedl
    if ($repoStatus -match "\[rejected\]") {
        _ErrorAndExit "There was an error when trying to push commit to cloud repository:`n$repoStatus"
    }

    # poznacim aktualni commit (duvod viz post-merge.ps1)
    $lastCommitPath = Join-Path $root ".githooks\lastCommit"
    # commit, ktery je aktualne posledni
    $actualLastCommit = git log -n 1 --pretty=format:"%H"
    $actualLastCommit | Out-File $lastCommitPath -Force

    # rozkopirovani do DFS se deje ze spesl serveru, ktery udela pull pod servisnim uctem + zavola Update-Repo a tim dostane zmeny do DFS
} catch {
    _ErrorAndExit "There ws an error:`n$_"
}

"DONE"