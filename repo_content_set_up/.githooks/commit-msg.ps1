# skript kontroluje tvar commit message
# pokud neodpovida tvaru "text: text", skonci chybou a ke commitu nedojde

param ($commitPath)

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
    $commitMsg = Get-Content $commitPath -TotalCount 1

    if ($commitMsg -notmatch "[^:]+: [^:]+" -and $commitMsg -notmatch "Merge branch ") {
        _ErrorAndExit "Nazev commitu neni ve tvaru: 'text: text'`n`nPresneji 'jmenoZmenenehoSouboru: co jsem v nem zmenil'`n napr.:`n'Get-ComputerInfo: pridan vypis diskovych chyb'`n`nPS:`nmisto jmenoZmenenehoSouboru muze byt jmeno modulu ci oblasti, ktere se zmena tyka"
    }
} catch {
    _ErrorAndExit "Doslo k chybe:`n$_"
}

Write-Host "HOTOVO"