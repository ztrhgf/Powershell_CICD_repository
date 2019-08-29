# skript provede push commitu do remote repozitare

$ErrorActionPreference = "stop"

function _ErrorAndExit {
    param ($message)

    if ( !([appdomain]::currentdomain.getassemblies().fullname -like "*System.Windows.Forms*")) {
        Add-Type -AssemblyName System.Windows.Forms
    }

    Write-Host $message
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
    Write-Host "- pushnu zmeny do repozitare"
    $repoStatus = _startProcess git "push origin master"
    # kontrola, ze se push povedl
    if ($repoStatus -match "\[rejected\]") {
        _ErrorAndExit "Pri pushnuti zmen do remote repozitare se vyskytla chyba:`n$repoStatus"
    }

    # poznacim aktualni commit (duvod viz post-merge.ps1)
    $lastCommitPath = Join-Path $root ".githooks\lastCommit"
    # commit, ktery je aktualne posledni
    $actualLastCommit = git log -n 1 --pretty=format:"%H"
    $actualLastCommit | Out-File $lastCommitPath -Force

    # rozkopirovani do DFS se deje ze spesl serveru, ktery udela pull pod servisnim uctem + zavola Update-Kentico_repo a tim dostane zmeny do DFS
} catch {
    _ErrorAndExit "Doslo k chybe:`n$_"
}

Write-Host "HOTOVO"