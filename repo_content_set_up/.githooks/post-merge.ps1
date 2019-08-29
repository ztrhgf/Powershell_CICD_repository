# skript se automaticky spousti po provedeni git pull
# upozorni na soubory, ktere mam aktualne rozdelane/modifikovane, a ktere byly zaroven modifikovany nejakym commitem
# ktery byl stazen v ramci aktualne probehleho git pull == tzn doslo u nich k automerge
# pozn.: je potreba kvuli pouziti VSC, pokud bych delal git pull v konzoli, tak tam se zmeny vypisi

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

    # do tohoto souboru budu ukladat hash POSLEDNIHO commitu, ktery jsem z remote repo pull-nul ci do nej push-nul
    # tzn posledniho commitu, nez jsem musel udelat git pull, protoze remote repo obsahovalo novejsi data
    # chci totiz pouze zmenene soubory v CIZICH commitech
    # pozn.: hash pushnuteho commitu ukladam v ramci post-commit.ps1 (push nemohu udelat bez aktualnich dat, tzn melo by byt ok)
    $lastCommitPath = Join-Path $root ".githooks\lastCommit"

    # posledni commit, ktery se stahl pri predchozim git pull
    # do souboru musim znacit, protoze tento hook se spousti az po provedeni pull, tzn nevim jaky commit byl jako posledni pred provedenim pull :)
    $previousLastCommit = Get-Content $lastCommitPath -ea SilentlyContinue
    Write-Host "prechodzi commit $previousLastCommit"
    # commit, ktery je aktualne posledni (na ktery jsem se dostal po provedeni pull)
    $actualLastCommit = git log -n 1 --pretty=format:"%H"
    Write-Host "aktualne pullnuty commit $actualLastCommit"
    # poznacim jej, abych pri dalsim pull vedel, kde jsem skoncil
    $actualLastCommit | Out-File $lastCommitPath -Force

    if ($previousLastCommit) {
        # jake soubory se zmenily od posledniho stazeni zmen, tzn. posledniho git pull
        $changedFileBetweenCommits = @(git diff --name-only $previousLastCommit $actualLastCommit)
        $prevCommitSubject = git log -1 $previousLastCommit --format="%s"
        Write-Host "soubory zmenene od posledniho commitu (`"$prevCommitSubject`"):`n$($changedFileBetweenCommits -join "`n")"

        # jake mam aktualne rozdelane soubory
        # soubory ve staging area, tzn. urcene ke commitu
        $stagedFile = @(git diff --name-only --cached)
        # modifikovane, ale ne v staging area soubory
        $modifiedNonstagedFile = @(git ls-files -m)
        # soubory ve stashi
        if (git stash list) {
            $stashedFile = @(((git stash show) -split "`n" | ? { $_ -match "\|" } | % { ($_ -split "\|")[0] }).trim())
        }

        $modifiedFile = $stagedFile + $modifiedNonstagedFile + $stashedFile
        Write-Host "modifikovane soubory:`n$($modifiedFile -join "`n")"
        # poznacim si soubory, ktere se stahly v ramci git pull a zaroven je mam rozdelane
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
            $message = "U nasledujicich souboru doslo k automergi zmen. Zkontrolujte, ze je ok.`n`n$($possibleConflictingFile -join "`n")`n`n`npozn.: zmeny probehly po commitu `"$prevCommitSubject`""

            if ( !([appdomain]::currentdomain.getassemblies().fullname -like "*System.Windows.Forms*")) {
                Add-Type -AssemblyName System.Windows.Forms
            }

            Write-Host $message
            $null = [System.Windows.Forms.MessageBox]::Show($this, $message, 'ERROR', 'ok', 'Error')
        }
    }
} catch {
    _ErrorAndExit "Doslo k chybe:`n$_"
}

Write-Host "HOTOVO"