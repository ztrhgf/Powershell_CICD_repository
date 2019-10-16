<#
script automatically checks format of commit message
in case format is not "text: text", ends with error and commit will be aborted
#>

param ($commitPath)

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
    $commitMsg = Get-Content $commitPath -TotalCount 1

    if ($commitMsg -notmatch "[^:]+: [^:]+" -and $commitMsg -notmatch "Merge branch ") {
        _ErrorAndExit "Name of commit isn't in correct format: 'text: text'`n`nFor example:`n'Get-ComputerInfo: added force switch'"
    }
} catch {
    _ErrorAndExit "There was an error:`n$_"
}

"DONE"