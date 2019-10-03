<#
skript se automaticky spousti pri vytvoreni commmitu
zkontroluje:
    jestli neni potreba provest git pull a upozorni
    syntaxi, format, pojmenovani, dodrzovani best practices, absenci zavadnnych znaku ps1 souboru
    kodovani textovych souboru
    ze commit neobsahuje modul, ktery se zaroven automaticky generuje
upozorni na:
    mazane funkce, pokud jsou nekde pouzity
    mazane/modifikovane promenne z Variables modulu, pokud jsou nekde pouzity
    menene parametry funkci, pokud jsou nekde pouzity
#>

$ErrorActionPreference = "stop"

# pozn. Write-Host pouzivat, aby se vypis zobrazil v git konzoli

function _ErrorAndExit {
    param ($message)

    if ( !([appdomain]::currentdomain.getassemblies().fullname -like "*System.Windows.Forms*")) {
        Add-Type -AssemblyName System.Windows.Forms
    }

    Write-Host $message
    $null = [System.Windows.Forms.MessageBox]::Show($this, $message, 'ERROR', 'ok', 'Error')
    exit 1
}

function _WarningAndExit {
    param ($message)

    if ( !([appdomain]::currentdomain.getassemblies().fullname -like "*System.Windows.Forms*")) {
        Add-Type -AssemblyName System.Windows.Forms
    }

    Write-Host $message
    $msgBoxInput = [System.Windows.Forms.MessageBox]::Show($this, $message, 'Continue?', 'YesNo', 'Warning')
    switch ($msgBoxInput) {
        'No' {
            throw "##_user_cancelled_##"
        }
    }
}

function _GetFileEncoding {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $True, ValueFromPipelineByPropertyName = $True)]
        [String] $path
        ,
        [Parameter(Mandatory = $False)]
        [System.Text.Encoding] $defaultEncoding = [System.Text.Encoding]::ASCII
    )

    process {
        [Byte[]]$bom = Get-Content -Encoding Byte -ReadCount 4 -TotalCount 4 -Path $path

        $encodingFound = $false

        if ($bom) {
            foreach ($encoding in [System.Text.Encoding]::GetEncodings().GetEncoding()) {
                $preamble = $encoding.GetPreamble()

                if ($preamble) {
                    # obsahuje BOM
                    foreach ($i in 0..($preamble.Length - 1)) {
                        if ($preamble[$i] -ne $bom[$i]) {
                            break
                        } elseif ($i -eq ($preamble.Length - 1)) {
                            $encodingFound = $encoding
                        }
                    }
                }
            }
        }

        if (!$encodingFound) {
            $encodingFound = $defaultEncoding
        }

        $encodingFound
    }
}

function _startProcess {
    [CmdletBinding()]
    param (
        [string] $filePath,
        [string] $argumentList,
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
    # $p.WaitForExit() # s timto pokud git show HEAD:$file neco vratilo, se proces nikdy neukoncil..
    $p.StandardOutput.ReadToEnd()
    $p.StandardError.ReadToEnd()
}

try {
    # prepnu se do rootu repozitare
    Set-Location $PSScriptRoot
    Set-Location ..
    $rootFolder = Get-Location
    $rootFolderName = ((Get-Location) -split "\\")[-1]


    #
    # kontrola, ze repo obsahuje aktualni data
    # tzn nejsem pozadu za remote repozitarem
    try {
        $repoStatus = git.exe status -uno
        # soubory urcene ke commitu
        $filesToCommit = @(git.exe diff --name-only --cached)
        # soubory urcene ke commitu vcetne typu akce
        $filesToCommitStatus = @(git.exe status --porcelain)
        # modifikovane, ale ne v staging area soubory
        $modifiedNonstagedFile = @(git.exe ls-files -m)
        # ziskam pridane|modifikovane|prejmenovane soubory z commitu (ale ne smazane)
        $filesToCommitNoDEL = $filesToCommit | ForEach-Object {
            $item = $_
            if ($filesToCommitStatus -match ("(A|M|R)\s+" + [Regex]::Escape($item))) {
                # z relativni cesty udelam absolutni a unix lomitka zaroven nahradim za windowsi
                Join-Path (Get-Location) $item
            }
        }
        # smazane, commitnute soubory
        $commitedDeletedFile = @(git.exe diff --name-status --cached --diff-filter=D | ForEach-Object { $_ -replace "^D\s+" })
        # smazane, commitnute ps1 skripty, ktere mohou obsahovat funkce, ktere budou nekde pouzity
        $commitedDeletedPs1 = @($commitedDeletedFile | Where-Object { $_ -match "\.ps1$" } | Where-Object { $_ -match "scripts2module/|scripts2root/profile\.ps1" })
    } catch {
        $err = $_
        if ($err -match "is not recognized as the name of a cmdlet") {
            _ErrorAndExit "Nepodarilo se zjistit aktualnost repozitare. Zrejme GIT neni nainstalovan. Chyba byla:`n$err"
        } else {
            _ErrorAndExit $err
        }
    }


    #
    # kontrola, ze repo obsahuje aktualni data
    # automaticky provest git pull v pre-commit nelze, protoze commit pak konci chybou fatal: cannot lock ref 'HEAD': is at cfd4a815a.. but expected 37936..
    "- kontrola, ze repo obsahuje aktualni data"
    if ($repoStatus -match "Your branch is behind") {
        _ErrorAndExit "Repozitar neobsahuje aktualni data. Stahnete je (git pull ci ikona sipek v VSC) a zkuste znovu."
    }


    #
    # kontrola, ze commitovany soubor neni zaroven zmodifikovany mimo staging area
    # dost se tim zjednodusuje prace s repo (kontroly, ziskavani predchozi verze souboru atp)
    "- kontrola, ze commitovany soubor neni zaroven zmodifikovany mimo staging area"
    if ($modifiedNonstagedFile -and $filesToCommit) {
        $modifiedNonstagedFile | ForEach-Object {
            if ($filesToCommit -contains $_) { _ErrorAndExit "Neni povoleno commitovat soubor ($_), ktery obsahuje dalsi nestagovane upravy.`nBud dalsi upravy pridejte do staging area nebo je zruste." }
        }
    }


    #
    # chyba, pokud commit maze dulezite soubory
    "- chyba, pokud commit maze dulezite soubory"
    if ($commitedDeletedFile | Where-Object { $_ -match "custom/customConfig\.ps1" }) {
        _ErrorAndExit "Mazete customConfig, ktery je nutny pro fungovani Custom sekce repozitare. To na 99,99% nechcete udelat!"
    }

    if ($commitedDeletedFile | Where-Object { $_ -match "scripts2root/PS_env_set_up\.ps1" }) {
        _ErrorAndExit "Mazete PS_env_set_up, ktery je nutny pro deploy obsahu na klienty. To na 99,99% nechcete udelat!"
    }

    if ($commitedDeletedFile | Where-Object { $_ -match "modules/Variables/Variables\.psm1" }) {
        _ErrorAndExit "Mazete modul Variables, to na 99,99% nechcete udelat!"
    }


    #
    # kontrola, ze commit neobsahuje modul, ktery se zaroven generuje automaticky z scripts2module
    # do DFS by se nakopiroval pouze jeden z nich
    "- kontrola, ze commit neobsahuje modul, ktery se zaroven generuje automaticky z scripts2module"
    if ($module2commit = $filesToCommit -match "^modules/") {
        # ulozim pouze jmeno modulu
        $module2commit = ($module2commit -split "/")[1]
        # jmena modulu, ktere jsou generovany z ps1
        $generatedModule = Get-ChildItem "scripts2module" -Directory -Name

        if ($conflictedModule = $module2commit | Where-Object { $_ -in $generatedModule }) {
            _ErrorAndExit "Neni mozne commitovat modul ($($conflictedModule -join ', ')), ktery se zaroven generuje z obsahu scripts2module."
        }
    }


    #
    # kontrola obsahu promenne $customConfig z customConfig.ps1
    # pozn.: zamerne nedotsourcuji customConfig.ps1 ale kontroluji pres AST, protoze pokud by plnil nejake promenne z AD, tak pri editaci na nedomenovem stroji, by hazelo chyby
    "- kontrola obsahu promenne `$customConfig z customConfig.ps1"
    if ($filesToCommitNoDEL | Where-Object { $_ -match "custom\\customConfig\.ps1" }) {
        $customConfigScript = Join-Path $rootFolder "Custom\customConfig.ps1"
        $AST = [System.Management.Automation.Language.Parser]::ParseFile($customConfigScript, [ref]$null, [ref]$null)
        $variables = $AST.FindAll( { $args[0] -is [System.Management.Automation.Language.VariableExpressionAst ] }, $true)
        $configVar = $variables | ? { $_.variablepath.userpath -eq "customConfig" }
        if (!$configVar) {
            _ErrorAndExit "customConfig.ps1 nedefinuje promennou `$customConfig. To musi i kdyby mela byt prazdna."
        }

        # prava strana promenne $customConfig resp. prvky pole
        $configValueItem = $configVar.parent.right.expression.subexpression.statements.pipelineelements.expression.elements
        if (!$configValueItem) {
            # pokud obsahuje pouze jeden objekt, musim vycist primo expression
            $configValueItem = $configVar.parent.right.expression.subexpression.statements.pipelineelements.expression
        }

        # kontrola, ze obsahuje pouze prvky typu psobject
        if ($configValueItem | ? { $_.type.typename.name -ne "PSCustomObject" }) {
            _ErrorAndExit "V customConfig.ps1 skriptu promenna `$customConfig musi obsahovat pole PSCustomObject prvku, coz aktualne neplati."
        }

        # sem poznacim vsechny adresare, ktere $customConfig nastavuje
        $folderNames = @()

        # zkontroluji jednotlive objekty pole (kazdy objekt by mel definovat nastaveni pro jednu Custom slozku)
        $configValueItem | % {
            $item = $_
            $folderName = ($item.child.keyvaluepairs | ? { $_.item1.value -eq "folderName" }).item2.pipelineelements.extent.text -replace '"' -replace "'"

            # kontrola, ze folderName neobsahuje zanorenou slozku
            #TODO dodelat podporu, aby to slo
            if ($folderName -match "\\") {
                _ErrorAndExit "V customConfig.ps1 skriptu promenna `$customConfig definuje folderName '$folderName'. To ale nesmi obsahovat zanorene slozky tzn. '\'"
            }

            $item.child.keyvaluepairs | % {
                $key = $_.item1.value
                $value = $_.item2.pipelineelements.extent.text -replace '"' -replace "'"

                # kontrola, ze jsou pouzity pouze validni klice
                $validKey = "computerName", "folderName", "customDestinationNTFS", "customSourceNTFS", "customLocalDestination", "customShareDestination", "copyJustContent"
                if ($nonvalidKey = Compare-Object $key $validKey | ? { $_.sideIndicator -match "<=" } | Select-Object -ExpandProperty inputObject) {
                    _ErrorAndExit "V customConfig.ps1 skriptu promenna `$customConfig obsahuje nepovolene klice ($($nonvalidKey -join ', ')). Povolene jsou pouze $($validKey -join ', ')"
                }

                # kontrola, ze folderName, customLocalDestination, customShareDestination obsahuji max jednu hodnotu)
                if ($key -in ("folderName", "customLocalDestination", "customShareDestination") -and ($value -split ',').count -ne 1) {
                    _ErrorAndExit "V customConfig.ps1 skriptu promenna `$customConfig obsahuje v objektu pro nastaveni '$folderName' v klici $key vic hodnot. Hodnota klice je '$value'"
                }

                # kontrola, ze customShareDestination je v UNC tvaru
                if ($key -match "customShareDestination" -and $value -notmatch "^\\\\") {
                    _ErrorAndExit "V customConfig.ps1 skriptu promenna `$customConfig neobsahuje v objektu pro nastaveni '$folderName' v klici $key UNC cestu. Hodnota klice je '$value'"
                }

                # kontrola, ze customLocalDestination je lokalni cesta
                # pozn.: regulak zamerne extremne jednoduchy aby slo pouzit promenne v ceste
                if ($key -match "customLocalDestination" -and $value -match "^\\\\") {
                    _ErrorAndExit "V customConfig.ps1 skriptu promenna `$customConfig neobsahuje v objektu pro nastaveni '$folderName' v klici $key lokalni cestu. Hodnota klice je '$value'"
                }
            }

            $keys = $item.child.keyvaluepairs.item1.value
            # objekt neobsahuje povinny klic folderName
            if ($keys -notcontains "folderName") {
                _ErrorAndExit "V customConfig.ps1 skriptu promenna `$customConfig neobsahuje u nejakeho objektu povinny klic folderName."
            }

            $folderNames += $folderName

            # upozornim na potencialni problem s nastavenim share prav
            if ($keys -contains "computerName" -and $keys -contains "customSourceNTFS") {
                _WarningAndExit "V customConfig.ps1 skriptu promenna `$customConfig obsahuje v objektu pro nastaveni '$folderName' jak computerName, tak customSourceNTFS. To je bezpecne pouze pokud customSourceNTFS obsahuje vsechny stroje z computerName (plus neco navic).`n`nSkutecne pokracovat v commitu?"
            }

            # kontrola, ze neni pouzita nepodporovana kombinace klicu
            if ($keys -contains "copyJustContent" -and $keys -contains "computerName" -and $keys -notcontains "customLocalDestination") {
                _ErrorAndExit "V customConfig.ps1 skriptu promenna `$customConfig obsahuje v objektu pro nastaveni '$folderName' copyJustContent a computerName, ale ne customLocalDestination. Do vychozi slozky (Scripts) se vzdy kopiruji cele slozky."
            }

            # kontrola, ze neni pouzita nepodporovana kombinace klicu
            if ($keys -contains "copyJustContent" -and $keys -contains "customDestinationNTFS" -and ($keys -contains "customLocalDestination" -or $keys -contains "customShareDestination")) {
                # kdyz se kopiruje do Scripts, tak se copyJustContent ignoruje tzn se custom prava pouziji
                _ErrorAndExit "V customConfig.ps1 skriptu promenna `$customConfig obsahuje v objektu pro nastaveni '$folderName' customDestinationNTFS, ale to nelze, protoze je zaroven nastaveno copyJustContent a proto se prava nenastavuji."
            }

            # zkontroluji, ze folderName odpovida realne existujicimu adresari v Custom
            $unixFolderPath = 'custom/{0}' -f ($folderName -replace "\\", "/") # folderName muze obsahovat i zanoreny adresar tzn modules\pokusny
            $folderAlreadyInRepo = _startProcess git "show `"HEAD:$unixFolderPath`""
            if ($folderAlreadyInRepo -match "^fatal: ") {
                # hledany adresar v GITu neni
                $folderAlreadyInRepo = ""
            }
            $windowsFolderPath = $unixFolderPath -replace "/", "\"
            $folderInActualCommit = $filesToCommitNoDEL | Where-Object { $_ -cmatch [regex]::Escape($windowsFolderPath) }
            if (!$folderAlreadyInRepo -and !$folderInActualCommit) {
                _ErrorAndExit "V customConfig.ps1 skriptu promenna `$customConfig obsahuje objekt pro nastaveni '$folderName', ale dany adresar neni v remote GIT repo\Custom ani v aktualnim commitu (nazev je case sensitive!). Zpusobilo by chybu na klientech."
            }
        }

        if ($folderNames -notcontains "Repo_sync") {
            _ErrorAndExit "V customConfig.ps1 skriptu promenna `$customConfig musi obsahovat PSCustomObject pro definici Repo_sync. To je potreba, aby fungovalo plneni MGM >> share."
        }

        # upozornim na slozky, ktere jsou definovane vickrat
        $ht = @{ }
        $folderNames | % { $ht["$_"] += 1 }
        $duplicatesFolder = $ht.keys | ? { $ht["$_"] -gt 1 } | % { $_ }
        if ($duplicatesFolder) {
            #TODO dodelat podporu pro definovani jedne slozky vickrat
            # chyba pokud definuji computerName (prepsaly by se DFS permissn), leda ze bych do repo_sync dodelal merge tech prav ;)
            # chyba pokud definuji u jednoho computerName a druheho customSourceNTFS (prepsaly by se DFS permissn)
            _ErrorAndExit "V customConfig.ps1 skriptu promenna `$customConfig definuje vickrat folderName '$($duplicatesFolder -join ', ')'."
            # _WarningAndExit "V customConfig.ps1 skriptu promenna `$customConfig definuje vickrat folderName '$($duplicatesFolder -join ', ')'. Budte si 100% jisti, ze nedojde ke konfliktu kvuli prekryvajicim nastavenim.`n`nPokracovat?"
        }
    }


    #
    # kontrola kodovani u textovych souboru urcenych ke commitu
    "- kontrola kodovani ..."
    # textove soubory ke commitu
    $textFilesToCommit = $filesToCommitNoDEL | Where-Object { $_ -match '\.ps1$|\.psm1$|\.psd1$|\.txt$' }
    if ($textFilesToCommit) {
        # zkontroluji ze textove soubory nepouzivaji UTF16/32 kodovani
        # GIT pak neukazuje historii protoze je nebere jako texove soubory
        $textFilesToCommit | ForEach-Object {
            $fileEnc = (_GetFileEncoding $_).bodyName
            if ($fileEnc -notin "US-ASCII", "ASCII", "UTF-8" ) {
                _WarningAndExit "Soubor $_ je kodovany v '$fileEnc', takze nebude fungovat git diff.`nIdealne jej ulozte s kodovanim UTF-8 with BOM, pripadne UTF-8.`n`nSkutecne pokracovat v commitu?"
            }
        }
    }


    #
    # kontroly ps1 a psm1 souboru
    "- kontrola syntaxe, zavadnych znaku, FIXME, dodrzovani best practices, formatu, jmena, zmen v parametrech,..."
    $psFilesToCommit = $filesToCommitNoDEL | Where-Object { $_ -match '\.ps1$|\.psm1$' }
    if ($psFilesToCommit) {
        try {
            $null = Get-Command Invoke-ScriptAnalyzer
        } catch {
            _ErrorAndExit "Neni dostupny modul PSScriptAnalyzer (respektive prikaz Invoke-ScriptAnalyzer). Neni mozne zkontrolovat syntax ps1 skriptu."
        }

        $ps1Error = @()
        $ps1CompatWarning = @()

        $psFilesToCommit | ForEach-Object {
            $script = $_

            #
            # kontrola ze skript neobsahuje non ASCII znaky, ktere by vedly k rozbiti parseru
            # typicky jde o EN DASH ci EM DASH misto klasicke pomlcky atp
            # ty v kombinaci s UTF8 kodovanim skriptu pusobi nesmyslne chyby typu, ze nemate uzavrene zavorky atd
            $problematicChar = [char]0x2013, [char]0x2014 # en dash, em dash
            $regex = $problematicChar -join '|'
            $problematicLine = (Get-Content $script) -match $regex
            if ($problematicLine) {
                $problematicLine = $problematicLine.Trim()
                _ErrorAndExit "Skript $([System.IO.Path]::GetFileName($script)) obsahuje problematicke znaky (en dash misto klasicke pomlcky?).`nNa radcich:`n`n$($problematicLine -join "`n`n")"
            }

            #
            # kontrola
            # - syntaxe a dodrzovani best practices
            # - kompatibility s Powershell 3.0
            #   - viz https://devblogs.microsoft.com/powershell/using-psscriptanalyzer-to-check-powershell-version-compatibility/
            $scriptAnalyzerResult = Invoke-ScriptAnalyzer $script -Settings .\PSScriptAnalyzerSettings.psd1
            $ps1CompatWarning += $scriptAnalyzerResult | ? { $_.RuleName -in "PSUseCompatibleCommands", "PSUseCompatibleSyntax" -and $_.Severity -in "Warning", "Error", "ParseError" }
            $ps1Error += $scriptAnalyzerResult | ? { $_.Severity -in "Error", "ParseError" }


            #
            # upozorneni pokud skript obsahuje FIXME komentar (krizek udelan pres [char] aby nehlasilo samo sebe)
            if ($fixme = Get-Content $script | ? { $_ -match ("\s*" + [char]0x023 + "\s*" + "FIXME\b") }) {
                _WarningAndExit "Soubor $script obsahuje FIXME:`n$($fixme.trim() -join "`n").`n`nSkutecne pokracovat v commitu?"
            }

            #
            # kontrola skriptu ze kterych se generuji moduly
            if ($script -match "\\$rootFolderName\\scripts2module\\") {
                # prevedu na AST objekt pro snadnou analyzu obsahu
                $ast = [System.Management.Automation.Language.Parser]::ParseFile("$script", [ref] $null, [ref] $null)

                #
                # kontrola, ze existuje pouze end block
                if ($ast.BeginBlock -or $ast.ProcessBlock) {
                    _ErrorAndExit "Soubor $script neni ve spravnem tvaru. Musi obsahovat pouze definici jedne funkce (pripadne Set-Alias, komentar ci requires)!"
                }

                #
                # kontrola, ze neobsahuje kus kodu, ktery by se stejne pri generovani modulu zahodil (protoze tam nema co delat)
                $ast.EndBlock.Statements | ForEach-Object {
                    if ($_.gettype().name -ne "FunctionDefinitionAst" -and !($_ -match "^\s*Set-Alias .+")) {
                        _ErrorAndExit "Soubor $script neni ve spravnem tvaru. Musi obsahovat pouze definici jedne funkce (pripadne Set-Alias, komentar ci requires)!"
                    }
                }

                # ziskam definovane funkce (v rootu skriptu)
                $functionDefinition = $ast.FindAll( {
                        param([System.Management.Automation.Language.Ast] $ast)

                        $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        # Class methods have a FunctionDefinitionAst under them as well, but we don't want them.
                        ($PSVersionTable.PSVersion.Major -lt 5 -or
                            $ast.Parent -isnot [System.Management.Automation.Language.FunctionMemberAst])
                    }, $false)

                #
                # kontrola, ze definuje pouze jednu funkci
                if ($functionDefinition.count -ne 1) {
                    _ErrorAndExit "Soubor $script bud neobsahuje zadnou funkci ci obsahuje vic nez jednu. To neni povoleno."
                }

                #
                # kontrola, ze se ps1 jmenuje stejne jako funkce v nem obsazena
                $fileName = [System.IO.Path]::GetFileNameWithoutExtension($script)
                $functionName = $functionDefinition.name
                if ($fileName -ne $functionName) {
                    _ErrorAndExit "Soubor $script se musi jmenovat stejne, jako funkce v nem obsazena ($functionName)."
                }

                #
                # upozornim na funkci u ktere se zmenily parametry, pokud je funkce nekde v repo pouzita
                $actParameter = $AST.FindAll( { $args[0] -is [System.Management.Automation.Language.ParamBlockAst] }, $true) | Where-Object { $_.parent.parent.name -eq $functionName }
                $actParameter = $actParameter.parameters | Select-Object @{n = 'name'; e = { $_.name.variablepath.userpath } }, @{n = 'value'; e = { $_.defaultvalue.extent.text } }, @{ n = 'type'; e = { $_.staticType.name } }
                # pomoci AST ziskam vsechny parametry definovane v predchozi verzi modulu Variables
                # absolutni cestu s windows lomitky prevedu na relativni s unix lomitky
                $scriptUnixPath = $script -replace ([regex]::Escape((Get-Location))) -replace "\\", "/" -replace "^/"
                $lastCommitContent = _startProcess git "show HEAD:$scriptUnixPath"
                if (!$lastCommitContent -or $lastCommitContent -match "^fatal: ") {
                    Write-Warning "Nepovedlo se dohledat predchozi verzi $scriptUnixPath kvuli kontrole zmenenych parametru"
                } else {
                    $AST = [System.Management.Automation.Language.Parser]::ParseInput(($lastCommitContent -join "`n"), [ref]$null, [ref]$null)
                    $prevParameter = $AST.FindAll( { $args[0] -is [System.Management.Automation.Language.ParamBlockAst] }, $true) | Where-Object { $_.parent.parent.name -eq $functionName }
                    $prevParameter = $prevParameter.parameters | Select-Object @{n = 'name'; e = { $_.name.variablepath.userpath } }, @{n = 'value'; e = { $_.defaultvalue.extent.text } }, @{ n = 'type'; e = { $_.staticType.name } }
                }

                if ($actParameter -and $prevParameter -and (Compare-Object $actParameter $prevParameter -Property name, value, type)) {
                    $escFuncName = [regex]::Escape($functionName)
                    # ziskani vsech souboru, kde je menena funkce pouzita (ale i v komentarich, proto zobrazim vyzvu a kazdy si musi zkontrolovat sam)
                    $fileUsed = git.exe grep --ignore-case -l "\b$escFuncName\b"
                    # odfiltruji z nalezu skript, kde je tato funkce definovana, protoze tam ke zmene doslo zamerne
                    $fileUsed = $fileUsed | Where-Object { $_ -notmatch "/$functionName\.ps1" }

                    if ($fileUsed) {
                        # git vraci s unix lomitky, zmenim na zpetna
                        $fileUsed = $fileUsed -replace "/", "\"

                        _WarningAndExit "Funkce $functionName u niz jste zmenili vstupni parametry je pouzita v nasledujicich skriptech:`n$($fileUsed -join "`n")`n`nSkutecne pokracovat v commitu?"
                    }
                }
            }
        }

        if ($ps1Error) {
            # ps1 v commitu obsahuji nejake chyby
            if (!($ps1Error | Where-Object { $_.ruleName -ne "PSAvoidUsingConvertToSecureStringWithPlainText" })) {
                # ps1 v commitu obsahuji pouze chyby ohledne pouziti plaintext hesla
                $ps1Error = $ps1Error | Select-Object -ExpandProperty ScriptName -Unique
                _WarningAndExit "Nasledujici skripty pouzivaji ConvertTo-SecureString, coz neni bezpecne:`n$($ps1Error -join "`n")`n`nSkutecne pokracovat v commitu?"
            } else {
                # ps1 v commitu obsahuji zavazne poruseni pravidel psani PS skriptu
                $ps1Error = $ps1Error | Select-Object Scriptname, Line, Column, Message | Format-List | Out-String -Width 1200
                _ErrorAndExit "Byly nalezeny nasledujici vazne prohresky proti psani PS skriptu:`n$ps1Error`n`nVyres a znovu comitni"
            }
        }

        if ($ps1CompatWarning) {
            # ps1 v commitu obsahuji nekompatibilni prikazy se zadanou verzi PS (dle nastaveni v .vscode\PSScriptAnalyzerSettings.psd1)
            $ps1CompatWarning = $ps1CompatWarning | Select-Object Scriptname, Line, Column, Message | Format-List | Out-String -Width 1200
            _WarningAndExit "Byly nalezeny problemy s kompatibilitou vuci PS 3.0:`n$ps1CompatWarning`n`nSkutecne pokracovat v commitu?"
        }
    } # konec kontrol ps1 a psm1 souboru


    #
    # upozornim na mazane ps1 definujici funkce, ktere jsou nekde v repo pouzity
    if ($commitedDeletedPs1) {
        # git vraci s unix lomitky, zmenim na zpetna
        $commitedDeletedPs1 = $commitedDeletedPs1 -replace "/", "\"

        # kontrola ps1 ze kterych se generuji moduly
        $commitedDeletedPs1 | Where-Object { $_ -match "scripts2module\\" } | ForEach-Object {
            $funcName = [System.IO.Path]::GetFileNameWithoutExtension($_)
            #$fileFuncUsed = git grep --ignore-case -l "^\s*[^#]*\b$funcName\b" # v komentari mi nevadi, na viceradkove ale upozorni :( HROZNE POMALE!
            # ziskani vsech souboru, kde je mazana funkce pouzita (ale i v komentarich, proto zobrazim vyzvu a kazdy si musi zkontrolovat sam)
            $escFuncName = [regex]::Escape($funcName)
            $fileFuncUsed = git.exe grep --ignore-case -l "\b$escFuncName\b"
            if ($fileFuncUsed) {
                # git vraci s unix lomitky, zmenim na zpetna
                $fileFuncUsed = $fileFuncUsed -replace "/", "\"

                _WarningAndExit "Mazana funkce $funcName je pouzita v nasledujicich skriptech:`n$($fileFuncUsed -join "`n")`n`nSkutecne pokracovat v commitu?"
            }
        }
        #TODO kontrola funkci v profile.ps1? viz AST sekce https://devblogs.microsoft.com/scripting/learn-how-it-pros-can-use-the-powershell-ast/
    }


    #
    # kontrola modulu Variables
    if ([string]$variablesModule = $filesToCommit -match "Variables\.psm1") {
        Write-Host "- kontroly modulu Variables ..."

        #
        # pomoci AST ziskam vsechny promenne definovane v commitovanem modulu Variables
        # pozn.: pokud bych umoznoval commitovat soubory modifikovane mimo staging area, musel bych misto obsahu lok. souboru vzit obsah z repo (git show :cestakmodulu)
        $varToExclude = 'env:|ErrorActionPreference|WarningPreference|VerbosePreference|^\$_$'
        $variablesModuleUnixPath = $variablesModule
        $variablesModule = Join-Path $rootFolder $variablesModule
        $AST = [System.Management.Automation.Language.Parser]::ParseFile($variablesModule, [ref]$null, [ref]$null)
        $actVariables = $AST.FindAll( { $args[0] -is [System.Management.Automation.Language.VariableExpressionAst ] }, $true)
        # aktualne definovane promenne (vcetne otypovanych)
        $actVariables = $actVariables | Where-Object { $_.parent.left -or $_.parent.type } | Select-Object @{n = "name"; e = { $_.variablepath.userPath } }, @{n = "value"; e = {
                if ($value = $_.parent.right.extent.text) {
                    $value
                } else {
                    # u otypovanych je zanoreno v dalsim parent
                    $_.parent.parent.right.extent.text
                }
            }
        }
        # kvuli pozdejsimu compare sjednotim newline symbol (CRLF vs LF)
        $actVariables = $actVariables | Select-Object name, @{n = "value"; e = { $_.value.Replace("`r`n", "`n") } }
        if ($varToExclude) {
            $actVariables = $actVariables | Where-Object { $_.name -notmatch $varToExclude }
        }

        # pomoci AST ziskam vsechny promenne definovane v predchozi verzi modulu Variables
        $lastCommitContent = _startProcess git "show HEAD:$variablesModuleUnixPath"
        if (!$lastCommitContent -or $lastCommitContent -match "^fatal: ") {
            Write-Warning "Nepovedlo se dohledat predchozi verzi modulu Variables kvuli kontrole zmenenych promennych"
        } else {
            $AST = [System.Management.Automation.Language.Parser]::ParseInput(($lastCommitContent -join "`n"), [ref]$null, [ref]$null)
            $prevVariables = $AST.FindAll( { $args[0] -is [System.Management.Automation.Language.VariableExpressionAst ] }, $true)
            # promenne definovane v predchozi verzi modulu Variables (vcetne otypovanych)
            $prevVariables = $prevVariables | Where-Object { $_.parent.left -or $_.parent.type } | Select-Object @{n = "name"; e = { $_.variablepath.userPath } }, @{n = "value"; e = {
                    if ($value = $_.parent.right.extent.text) {
                        $value
                    } else {
                        # u otypovanych je zanoreno v dalsim parent
                        $_.parent.parent.right.extent.text
                    }
                }
            }
            # kvuli pozdejsimu compare sjednotim newline symbol (CRLF vs LF)
            $prevVariables = $prevVariables | Select-Object name, @{n = "value"; e = { $_.value.Replace("`r`n", "`n") } }
            if ($varToExclude) {
                $prevVariables = $prevVariables | Where-Object { $_.name -notmatch $varToExclude }
            }
        }


        #
        # kontrola, ze modul nedefinuje jednu promennou vickrat
        $duplicateVariable = $actVariables | Group-Object name | Where-Object { $_.count -gt 1 } | Select-Object -ExpandProperty name
        if ($duplicateVariable) {
            _ErrorAndExit "V modulu Variables jsou nasledujici promenne definovany vic nez jednou: $($duplicateVariable -join ', ')`n`nVyres a znovu comitni"
        }


        #
        # upozornim na mazane promenne, pokud jsou nekde v repo pouzity
        if ($actVariables -and $prevVariables -and ($removedVariable = $prevVariables.name | Where-Object { $_ -notin $actVariables.name })) {
            $removedVariable | ForEach-Object {
                $varName = "$" + $_
                $escVarName = [regex]::Escape($varName)
                # ziskani vsech souboru, kde je mazana promenna pouzita (ale i v komentarich, proto zobrazim vyzvu a kazdy si musi zkontrolovat sam)
                $fileUsed = git.exe grep --ignore-case -l "$escVarName\b"
                # odfiltruji z nalezu modul Variables, protoze tam ke zmene doslo zamerne
                $fileUsed = $fileUsed | Where-Object { $_ -notmatch "/Variables\.psm1" }
                if ($fileUsed) {
                    # git vraci s unix lomitky, zmenim na zpetna
                    $fileUsed = $fileUsed -replace "/", "\"

                    _WarningAndExit "Mazana promenna $varName je pouzita v nasledujicich skriptech:`n$($fileUsed -join "`n")`n`nSkutecne pokracovat v commitu?"
                }
            }
        }


        #
        # upozornim na modifikovane promenne, pokud jsou nekde v repo pouzity
        # abych mohl pouzit Compare-Object, ponecham pouze promenne, ktere je s cim porovnat
        if ($actVariables -and $prevVariables -and ($modifiedVariable = Compare-Object $actVariables ($prevVariables | Where-Object { $_.name -notin $removedVariable } ) -Property value -PassThru | Select-Object -ExpandProperty name -Unique)) {
            $modifiedVariable | ForEach-Object {
                $varName = "$" + $_
                $escVarName = [regex]::Escape($varName)
                # ziskani vsech souboru, kde je mazana promenna pouzita (ale i v komentarich, proto zobrazim vyzvu a kazdy si musi zkontrolovat sam)
                $fileUsed = git.exe grep --ignore-case -l "$escVarName\b"
                # odfiltruji z nalezu modul Variables, protoze tam ke zmene doslo zamerne
                $fileUsed = $fileUsed | Where-Object { $_ -notmatch "/Variables\.psm1" }

                if ($fileUsed) {
                    # git vraci s unix lomitky, zmenim na zpetna
                    $fileUsed = $fileUsed -replace "/", "\"

                    _WarningAndExit "Modifikovana promenna $varName je pouzita v nasledujicich skriptech:`n$($fileUsed -join "`n")`n`nSkutecne pokracovat v commitu?"
                }
            }
        }


        #
        # chyba, pokud modul Variables neobsahuje prikaz pro export promennych
        # pozn.: pokud bych umoznoval commitovat soubory modifikovane mimo staging area, musel bych misto obsahu lok. souboru vzit obsah z repo (git show :cestakmodulu)
        $AST = [System.Management.Automation.Language.Parser]::ParseFile($variablesModule, [ref]$null, [ref]$null)
        $commands = $AST.FindAll( { $args[0] -is [System.Management.Automation.Language.CommandAst ] }, $true)
        if (!($commands.extent.text -match "Export-ModuleMember")) {
            _ErrorAndExit "Modul Variables neexportuje zadne promenne skrze Export-ModuleMember.`n`nVyres a znovu comitni"
        }
    } # konec kontrol modulu Variables


    #
    # znovu provedu kontrolu, ze repo ma aktualni data
    # kontroly trvaji nekolik vterin, behem nichz mohl teoreticky nekdo jiny udelat push do repozitare
    $repoStatus = git.exe status -uno
    if ($repoStatus -match "Your branch is behind") {
        _ErrorAndExit "Repozitar neobsahuje aktualni data. Stahnete je (git pull ci ikona sipek v VSC) a zkuste znovu."
    }
} catch {
    $err = $_
    # vypisi i do git konzole kdyby se GUI okno s chybou nezobrazilo
    Write-Host $err
    if ($err -match "##_user_cancelled_##") {
        # uzivatelem iniciovane preruseni commitu
        exit 1
    } else {
        _ErrorAndExit "Doslo k chybe:`n$err`n`nVyres a znovu comitni"
    }
}

Write-Host "HOTOVO"