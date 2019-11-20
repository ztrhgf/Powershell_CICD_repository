<#
Zde je mozne omezit, na jake klienty se budou moduly z Modules kopirovat. Mysli se tim Modules v DFS, tzn i moduly vznikle z scripts2module.
Pokud zde modul neni uveden, znamena to, ze se bude kopirovat na kazdeho klienta.

Standardne se obsah kopiruje do C:\Windows\System32\WindowsPowerShell\v1.0\Modules a dochazi automaticky k mazani toho, co tam jiz byt nema.
Tento skript se dot sourcuje v PS_env_set_up.ps1 a nesmi proto obsahovat nic krome promenne modulesConfig!

Jak ma vypadat $modulesConfig a co muze obsahovat:
$modulesConfig je pole objektu, kde kazdy objekt reprezentuje jednu slozku v Modules adresari.
Objekt pak obsahuje nasledujici klice:

    - folderName
        jmeno slozky (ktera se nachazi v Modules adresari)

    - computerName
        na jake stroje se ma slozka POUZE synchronizovat (je mozne pouzit i promennou (napr. z Variables modulu) obsahujici seznam stroju)
        !nikam jinam se kopirovat nebude a pokud jiz byla nekam drive nakopirovana, tak dojde k jejimu smazani!



PRIKLADY:

$modulesConfig = @(
    [PSCustomObject]@{
        folderName   = "ConfluencePS"
        computerName = "PC-1"
    },
    [PSCustomObject]@{
        folderName   = "Posh-SSH"
        computerName = $adminPC
    }
)

#>

#FIXME doresit, ze oddelovaci carka nesmi byt na novem radku jinak nefunguje AST kontrola
$modulesConfig = @(
    [PSCustomObject]@{
        folderName   = "adminFunctions"
        computerName = $computerWithProfile
    }
)