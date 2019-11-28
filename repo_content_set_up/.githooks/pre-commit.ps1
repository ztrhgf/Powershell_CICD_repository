<#
script is automatically run (thanks to git pre commit hook) when new commit is created
check:
    if git pull is needed
    syntax, format, name convention, fulfill of best practices, problematic character
    encoding of text files
    etc
notify user about:
    deleted functions if used somewhere
    deleted/modified variables from Variables module if used somewhere
    modified function parameter if used somewhere
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

    $message = $message + "`n`nAre you sure you want to continue in commit?"

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
            if ($filesToCommitStatus -match ("(A|M|R)\s+[`"]?" + [Regex]::Escape($item))) {
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
            _ErrorAndExit "Recency of repository can't be checked. Is GIT installed? Error was:`n$err"
        } else {
            _ErrorAndExit $err
        }
    }


    #
    # kontrola, ze repo obsahuje aktualni data
    # automaticky provest git pull v pre-commit nelze, protoze commit pak konci chybou fatal: cannot lock ref 'HEAD': is at cfd4a815a.. but expected 37936..
    "- check, that repository contains actual data"
    if ($repoStatus -match "Your branch is behind") {
        _ErrorAndExit "Repository doesn't contain actual data. Pull them (git pull or sync icon in VSC) and try again."
    }


    #
    # kontrola, ze commitovany soubor neni zaroven zmodifikovany mimo staging area
    # dost se tim zjednodusuje prace s repo (kontroly, ziskavani predchozi verze souboru atp)
    "- check, that commited file isn't modified outside staging area"
    if ($modifiedNonstagedFile -and $filesToCommit) {
        $modifiedNonstagedFile | ForEach-Object {
            if ($filesToCommit -contains $_) {
                _ErrorAndExit "It is not allowed to commit file which contains another non staged modifications ($_).`nAdd this file to staging area (+ icon) or remove these modifications."
            }
        }
    }


    #
    # chyba, pokud commit maze dulezite soubory
    "- exit if commit deletes important files"
    if ($commitedDeletedFile | Where-Object { $_ -match "custom/customConfig\.ps1" }) {
        _ErrorAndExit "You are deleting customConfig, which is needed for Custom section to work. On 99,99% you don't want do this!"
    }

    if ($commitedDeletedFile | Where-Object { $_ -match "scripts2root/PS_env_set_up\.ps1" }) {
        _ErrorAndExit "You are deleting PS_env_set_up, which is needed for deploy of repository content to clients. On 99,99% you don't want do this!"
    }

    if ($commitedDeletedFile | Where-Object { $_ -match "modules/Variables/Variables\.psm1" }) {
        _ErrorAndExit "You are deleting module Variables, which contains important variables like RepoSyncServer, computerWithProfile etc. On 99,99% you don't want do this!"
    }


    #
    # kontrola, ze commit neobsahuje modul, ktery se zaroven generuje automaticky z scripts2module
    # do DFS by se nakopiroval pouze jeden z nich
    "- check that commit doesn't contain module which is in the same time generated from content of scripts2module"
    if ($module2commit = $filesToCommit -match "^modules/") {
        # ulozim pouze jmeno modulu
        $module2commit = ($module2commit -split "/")[1]
        # jmena modulu, ktere jsou generovany z ps1
        $generatedModule = Get-ChildItem "scripts2module" -Directory -Name

        if ($conflictedModule = $module2commit | Where-Object { $_ -in $generatedModule }) {
            _ErrorAndExit "It's not possible to commit module ($($conflictedModule -join ', ')), which is in the same time generated from content of scripts2module."
        }
    }


    #
    # kontrola obsahu promenne $customConfig z customConfig.ps1
    # pozn.: zamerne nedotsourcuji customConfig.ps1 ale kontroluji pres AST, protoze pokud by plnil nejake promenne z AD, tak pri editaci na nedomenovem stroji, by hazelo chyby
    "- check of content of variable `$customConfig in customConfig.ps1"
    if ($filesToCommitNoDEL | Where-Object { $_ -match "custom\\customConfig\.ps1" }) {
        $customConfigScript = Join-Path $rootFolder "Custom\customConfig.ps1"
        $AST = [System.Management.Automation.Language.Parser]::ParseFile($customConfigScript, [ref]$null, [ref]$null)
        $variables = $AST.FindAll( { $args[0] -is [System.Management.Automation.Language.VariableExpressionAst ] }, $true)
        $configVar = $variables | ? { $_.variablepath.userpath -eq "customConfig" }
        if (!$configVar) {
            _ErrorAndExit "customConfig.ps1 is not defining variable `$customConfig. It has to, at least empty one."
        }

        # prava strana promenne $customConfig resp. prvky pole
        $configValueItem = $configVar.parent.right.expression.subexpression.statements.pipelineelements.expression.elements
        if (!$configValueItem) {
            # pokud obsahuje pouze jeden objekt, musim vycist primo expression
            $configValueItem = $configVar.parent.right.expression.subexpression.statements.pipelineelements.expression
        }

        # kontrola, ze obsahuje pouze prvky typu psobject
        if ($configValueItem | ? { $_.type.typename.name -ne "PSCustomObject" }) {
            _ErrorAndExit "In customConfig.ps1 script variable `$customConfig has to contain array of PSCustomObject items, which it hasn't."
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
                _ErrorAndExit "In customConfig.ps1 script variable `$customConfig defines folderName '$folderName'. FolderName can't contain \ in it's name."
            }

            $item.child.keyvaluepairs | % {
                $key = $_.item1.value
                $value = $_.item2.pipelineelements.extent.text -replace '"' -replace "'"

                # kontrola, ze jsou pouzity pouze validni klice
                $validKey = "computerName", "folderName", "customDestinationNTFS", "customSourceNTFS", "customLocalDestination", "customShareDestination", "copyJustContent", "scheduledTask"
                if ($key -and ($nonvalidKey = Compare-Object $key $validKey | ? { $_.sideIndicator -match "<=" } | Select-Object -ExpandProperty inputObject)) {
                    _ErrorAndExit "In customConfig.ps1 script variable `$customConfig contains unnaproved keys: ($($nonvalidKey -join ', ')). Approved are only: $($validKey -join ', ')"
                }

                # kontrola, ze folderName, customLocalDestination, customShareDestination obsahuji max jednu hodnotu)
                if ($key -in ("folderName", "customLocalDestination", "customShareDestination") -and ($value -split ',').count -ne 1) {
                    _ErrorAndExit "In customConfig.ps1 script variable `$customConfig contains in object that defines '$folderName' in key $key more than one values. Values in key are: $($value -join ', ')"
                }

                # kontrola, ze customShareDestination je v UNC tvaru
                if ($key -match "customShareDestination" -and $value -notmatch "^\\\\") {
                    _ErrorAndExit "In customConfig.ps1 script variable `$customConfig doesn't contain in object that defines '$folderName' in key $key UNC path. Value of key is '$value'"
                }

                # kontrola, ze customLocalDestination je lokalni cesta
                # pozn.: regulak zamerne extremne jednoduchy aby slo pouzit promenne v ceste
                if ($key -match "customLocalDestination" -and $value -match "^\\\\") {
                    _ErrorAndExit "In customConfig.ps1 script variable `$customConfig doesn't contain in object that defines '$folderName' in key $key local path. Value of key is '$value'"
                }

                # kontrola, ze k sched. taskum definovanym v scheduledTask klici existuji odpovidajici XML soubory s nastavenimi tasku (v rootu Custom adresare)
                if ($key -match "scheduledTask" -and $value) {
                    ($value -split ",").trim() | % {
                        $taskName = $_

                        $unixPath = 'custom/{0}/{1}.xml' -f ($folderName -replace "\\", "/"), $taskName
                        $alreadyInRepo = _startProcess git "show `"HEAD:$unixPath`""
                        if ($alreadyInRepo -match "^fatal: ") {
                            # hledany XML v GITu neni
                            $alreadyInRepo = ""
                        }
                        $windowsPath = $unixPath -replace "/", "\"
                        $inActualCommit = $filesToCommitNoDEL | Where-Object { $_ -cmatch [regex]::Escape($windowsPath) }
                        if (!$alreadyInRepo -and !$inActualCommit) {
                            _ErrorAndExit "In customConfig.ps1 object that defines '$folderName' in key $key, defines scheduled task '$taskName', but associated config file $windowsPath is neither in remote GIT repository\Custom\$folderName nor in actual commit (name is case sensitive!). It would cause error on clients."
                        }

                        # kontrola, ze XML skutecne obsahuje nastaveni scheduled tasku
                        $XMLPath = Join-Path $rootFolder "Custom\$folderName\$taskName.xml"
                        [xml]$xmlDefinition = Get-Content $XMLPath
                        if (!$xmlDefinition.Task.RegistrationInfo.URI) {
                            _ErrorAndExit "In customConfig.ps1 object that defines '$folderName' in key $key, defines scheduled task '$taskName', but associated config file $windowsPath doesn't contain valid data. It would cause error on clients."
                        }

                        # upozorneni pokud se jmeno XML lisi od sched. tasku, ktery definuje
                        $taskNameInXML = $xmlDefinition.task.RegistrationInfo.URI -replace "^\\"
                        if ($taskName -ne $taskNameInXML) {
                            _WarningAndExit "In customConfig.ps1 object that defines '$folderName' in key $key, defines scheduled task '$taskName', but associated config file $windowsPath defines task '$taskNameInXML'.`nBeware, that this task will be created with name '$taskName'."
                        }
                    }
                }
            }

            $keys = $item.child.keyvaluepairs.item1.value
            # objekt neobsahuje povinny klic folderName
            if ($keys -notcontains "folderName") {
                _ErrorAndExit "In customConfig.ps1 script variable `$customConfig doesn't contain mandatory key folderName at some of objects."
            }

            $folderNames += $folderName

            # upozornim na potencialni problem s nastavenim share prav
            if ($keys -contains "computerName" -and $keys -contains "customSourceNTFS") {
                _WarningAndExit "In customConfig.ps1 script variable `$customConfig contains in object that defines '$folderName' keys: computerName, customSourceNTFS at the same time. This is safe only in case, when customSourceNTFS contains all computers from computerName (and more)."
            }

            # kontrola, ze neni pouzita nepodporovana kombinace klicu
            if ($keys -contains "copyJustContent" -and $keys -contains "computerName" -and $keys -notcontains "customLocalDestination") {
                _ErrorAndExit "In customConfig.ps1 script variable `$customConfig contains in object that defines '$folderName' copyJustContent and computerName, but no customLocalDestination. To destination folder (Scripts) are always copied whole folders."
            }

            # kontrola, ze neni pouzita nepodporovana kombinace klicu
            if ($keys -contains "copyJustContent" -and $keys -contains "customDestinationNTFS" -and ($keys -contains "customLocalDestination" -or $keys -contains "customShareDestination")) {
                # kdyz se kopiruje do Scripts, tak se copyJustContent ignoruje tzn se custom prava pouziji
                _ErrorAndExit "In customConfig.ps1 script variable `$customConfig contains in object that defines '$folderName' customDestinationNTFS, but that's not possible, because copyJustContent is also used and therefore NTFS rights are not configuring."
            }

            # kontrola, ze folderName odpovida realne existujicimu adresari v Custom
            $unixFolderPath = 'custom/{0}' -f ($folderName -replace "\\", "/") # folderName muze obsahovat i zanoreny adresar tzn modules\pokusny
            $folderAlreadyInRepo = _startProcess git "show `"HEAD:$unixFolderPath`""
            if ($folderAlreadyInRepo -match "^fatal: ") {
                # hledany adresar v GITu neni
                $folderAlreadyInRepo = ""
            }
            $windowsFolderPath = $unixFolderPath -replace "/", "\"
            $folderInActualCommit = $filesToCommitNoDEL | Where-Object { $_ -cmatch [regex]::Escape($windowsFolderPath) }
            if (!$folderAlreadyInRepo -and !$folderInActualCommit) {
                _ErrorAndExit "In customConfig.ps1 script variable `$customConfig contains object that defines '$folderName', but given folder is neither in remote GIT repository\Custom nor in actual commit (name is case sensitive!). It would cause error on clients."
            }
        }

        if ($folderNames -notcontains "Repo_sync") {
            _ErrorAndExit "In customConfig.ps1 script variable `$customConfig has to contain PSCustomObject that defines Repo_sync. It is necesarry for transfer data from MGM server to DFS share works."
        }

        # upozornim na slozky, ktere jsou definovane vickrat
        $ht = @{ }
        $folderNames | % { $ht["$_"] += 1 }
        $duplicatesFolder = $ht.keys | ? { $ht["$_"] -gt 1 } | % { $_ }
        if ($duplicatesFolder) {
            #TODO dodelat podporu pro definovani jedne slozky vickrat
            # chyba pokud definuji computerName (prepsaly by se DFS permissn), leda ze bych do repo_sync dodelal merge tech prav ;)
            # chyba pokud definuji u jednoho computerName a druheho customSourceNTFS (prepsaly by se DFS permissn)
            _ErrorAndExit "In customConfig.ps1 script variable `$customConfig defines folderName multiple times '$($duplicatesFolder -join ', ')'."
            # _WarningAndExit "In customConfig.ps1 script variable `$customConfig definuje vickrat folderName '$($duplicatesFolder -join ', ')'. Budte si 100% jisti, ze nedojde ke konfliktu kvuli prekryvajicim nastavenim.`n`nPokracovat?"
        }
    }



    #
    # kontrola obsahu promenne $modulesConfig z modulesConfig.ps1
    # pozn.: zamerne nedotsourcuji modulesConfig.ps1 ale kontroluji pres AST, protoze pokud by plnil nejake promenne z AD, tak pri editaci na nedomenovem stroji, by hazelo chyby
    "- check content of variable `$modulesConfig in modulesConfig.ps1"
    if ($filesToCommitNoDEL | Where-Object { $_ -match "modules\\modulesConfig\.ps1" }) {
        $modulesConfigScript = Join-Path $rootFolder "modules\modulesConfig.ps1"
        $AST = [System.Management.Automation.Language.Parser]::ParseFile($modulesConfigScript, [ref]$null, [ref]$null)
        $variables = $AST.FindAll( { $args[0] -is [System.Management.Automation.Language.VariableExpressionAst ] }, $true)
        $configVar = $variables | ? { $_.variablepath.userpath -eq "modulesConfig" }
        if (!$configVar) {
            _ErrorAndExit "modulesConfig.ps1 doesn't define variable `$modulesConfig."
        }

        # prava strana promenne $modulesConfig resp. prvky pole
        $configValueItem = $configVar.parent.right.expression.subexpression.statements.pipelineelements.expression.elements
        if (!$configValueItem) {
            # pokud obsahuje pouze jeden objekt, musim vycist primo expression
            $configValueItem = $configVar.parent.right.expression.subexpression.statements.pipelineelements.expression
        }

        if ($configValueItem) {
            # kontrola, ze obsahuje pouze prvky typu psobject
            if ($configValueItem | ? { $_.type.typename.name -ne "PSCustomObject" }) {
                _ErrorAndExit "In modulesConfig.ps1 script variable `$modulesConfig has to contain array of PSCustomObject items."
            }

            # sem poznacim vsechny adresare, ktere $modulesConfig nastavuje
            $folderNames = @()

            # zkontroluji jednotlive objekty pole (kazdy objekt by mel definovat nastaveni pro jednu Custom slozku)
            $configValueItem | % {
                $item = $_
                $folderName = ($item.child.keyvaluepairs | ? { $_.item1.value -eq "folderName" }).item2.pipelineelements.extent.text -replace '"' -replace "'"

                # kontrola, ze folderName neobsahuje zanorenou slozku
                if ($folderName -match "\\") {
                    _ErrorAndExit "In modulesConfig.ps1 script variable `$modulesConfig key folderName '$folderName' contains '\', but that's not allowed."
                }

                $item.child.keyvaluepairs | % {
                    $key = $_.item1.value
                    $value = $_.item2.pipelineelements.extent.text -replace '"' -replace "'"

                    # kontrola, ze jsou pouzity pouze validni klice
                    $validKey = "computerName", "folderName"
                    if ($key -and ($nonvalidKey = Compare-Object $key $validKey | ? { $_.sideIndicator -match "<=" } | Select-Object -ExpandProperty inputObject)) {
                        _ErrorAndExit "In modulesConfig.ps1 script variable `$modulesConfig contains unnaproved keys ($($nonvalidKey -join ', ')). Approved are just: $($validKey -join ', ')"
                    }

                    # kontrola, ze folderName obsahuje max jednu hodnotu
                    if ($key -in ("folderName") -and ($value -split ',').count -ne 1) {
                        _ErrorAndExit "In modulesConfig.ps1 script variable `$modulesConfig contains in object that defines '$folderName' in key $key more than one value. Value of key is $($value -join ', ')"
                    }
                }

                $keys = $item.child.keyvaluepairs.item1.value
                # objekt neobsahuje povinny klic folderName
                if ($keys -notcontains "folderName") {
                    _ErrorAndExit "In modulesConfig.ps1 script variable `$modulesConfig doesn't contain mandatory key folderName at some object."
                }

                $folderNames += $folderName

                # zkontroluji, ze folderName odpovida realne existujicimu adresari v modules ci scripts2module
                # a to bud v aktualnim commitu nebo v GIT repo
                $unixFolderPath = ('modules/{0}' -f ($folderName -replace "\\", "/")), ('scripts2module/{0}' -f ($folderName -replace "\\", "/"))
                $folderAlreadyInRepo = ''
                $folderInActualCommit = ''
                $unixFolderPath | % {
                    if (!$folderAlreadyInRepo) {
                        $folderAlreadyInRepo = _startProcess git "show `"HEAD:$_`""
                        if ($folderAlreadyInRepo -match "^fatal: ") {
                            # hledany adresar v GITu neni
                            $folderAlreadyInRepo = ''
                        }
                    }

                    $windowsFolderPath = $_ -replace "/", "\"
                    if (!$folderInActualCommit) {
                        $folderInActualCommit = $filesToCommitNoDEL | Where-Object { $_ -cmatch [regex]::Escape($windowsFolderPath) }
                    }
                }

                if (!$folderAlreadyInRepo -and !$folderInActualCommit) {
                    _WarningAndExit "In modulesConfig.ps1 script variable `$modulesConfig contains object that defines '$folderName', but given folder is neither in GIT repository\Modules or repository\scripts2module nor in actual commit (name is case sensitive!)."
                }
            }

            # upozornim na slozky, ktere jsou definovane vickrat
            $ht = @{ }
            $folderNames | % { $ht["$_"] += 1 }
            $duplicatesFolder = $ht.keys | ? { $ht["$_"] -gt 1 } | % { $_ }
            if ($duplicatesFolder) {
                _ErrorAndExit "In modulesConfig.ps1 script variable `$modulesConfig defines folderName multiple times '$($duplicatesFolder -join ', ')'."
            }
        } else {
            "   - `$modulesConfig contains nothing"
        }
    }


    #
    # kontrola kodovani u textovych souboru urcenych ke commitu
    "- check encoding ..."
    # textove soubory ke commitu
    $textFilesToCommit = $filesToCommitNoDEL | Where-Object { $_ -match '\.ps1$|\.psm1$|\.psd1$|\.txt$' }
    if ($textFilesToCommit) {
        # zkontroluji ze textove soubory nepouzivaji UTF16/32 kodovani
        # GIT pak neukazuje historii protoze je nebere jako texove soubory
        $textFilesToCommit | ForEach-Object {
            $fileEnc = (_GetFileEncoding $_).bodyName
            if ($fileEnc -notin "US-ASCII", "ASCII", "UTF-8" ) {
                _WarningAndExit "File $_ is encoded in '$fileEnc', so git diff wont work.`nIdeal is to save it using UTF-8 with BOM, or UTF-8."
            }
        }
    }


    #
    # kontroly ps1 a psm1 souboru
    "- check syntax, problematic characters, FIXME, best practices, format, name , changes in function parameters,..."
    $psFilesToCommit = $filesToCommitNoDEL | Where-Object { $_ -match '\.ps1$|\.psm1$' }
    if ($psFilesToCommit) {
        try {
            $null = Get-Command Invoke-ScriptAnalyzer
        } catch {
            _ErrorAndExit "Module PSScriptAnalyzer isn't available (respective command Invoke-ScriptAnalyzer). It's not possible to check syntax of ps1 scripts."
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
                _ErrorAndExit "File $([System.IO.Path]::GetFileName($script)) contains problematic character (en dash instead of dash?).`nOn row:`n`n$($problematicLine -join "`n`n")"
            }

            #
            # kontrola
            # - syntaxe a dodrzovani best practices
            # - a pripadna dalsi nastaveni viz PSScriptAnalyzerSettings
            Invoke-ScriptAnalyzer $script -Settings .\PSScriptAnalyzerSettings.psd1 | % {
                if ($_.RuleName -in "PSUseCompatibleCommands", "PSUseCompatibleSyntax", "PSAvoidUsingComputerNameHardcoded" -and $_.Severity -in "Warning", "Error", "ParseError") {
                    $ps1CompatWarning += $_
                } elseif ($_.Severity -in "Error", "ParseError") {
                    $ps1Error += $_
                }
            }


            #
            # upozorneni pokud skript obsahuje FIXME komentar (krizek udelan pres [char] aby nehlasilo samo sebe)
            if ($fixme = Get-Content $script | ? { $_ -match ("\s*" + [char]0x023 + "\s*" + "FIXME\b") }) {
                _WarningAndExit "File $script contains FIXME:`n$($fixme.trim() -join "`n")."
            }

            #
            # kontrola skriptu ze kterych se generuji moduly
            if ($script -match "\\$rootFolderName\\scripts2module\\") {
                # prevedu na AST objekt pro snadnou analyzu obsahu
                $ast = [System.Management.Automation.Language.Parser]::ParseFile("$script", [ref] $null, [ref] $null)

                $wrgMessage = "File $script is not in correct format. It has to contain just definition of one function (with the same name). Beside that, script can also contains: Set-Alias, comments or requires statement!"

                #
                # kontrola, ze existuje pouze end block
                if ($ast.BeginBlock -or $ast.ProcessBlock) {
                    _ErrorAndExit $wrgMessage
                }

                #
                # kontrola, ze neobsahuje kus kodu, ktery by se stejne pri generovani modulu zahodil (protoze tam nema co delat)
                $ast.EndBlock.Statements | ForEach-Object {
                    if ($_.gettype().name -ne "FunctionDefinitionAst" -and !($_ -match "^\s*Set-Alias .+")) {
                        _ErrorAndExit $wrgMessage
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
                    _ErrorAndExit "File $script either doesn't contain any function definition or contain more than one."
                }

                #
                # kontrola, ze se ps1 jmenuje stejne jako funkce v nem obsazena
                $fileName = [System.IO.Path]::GetFileNameWithoutExtension($script)
                $functionName = $functionDefinition.name
                if ($fileName -ne $functionName) {
                    _ErrorAndExit "File $script has to be named exactly the same as function that it defines ($functionName)."
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
                    Write-Warning "Previous version of $scriptUnixPath cannot be found (to check modified parameters)."
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

                        _WarningAndExit "Function $functionName which has changed parameters is used in following scripts:`n$($fileUsed -join "`n")"
                    }
                }
            }
        }

        if ($ps1Error) {
            # ps1 v commitu obsahuji nejake chyby
            if (!($ps1Error | Where-Object { $_.ruleName -ne "PSAvoidUsingConvertToSecureStringWithPlainText" })) {
                # ps1 v commitu obsahuji pouze chyby ohledne pouziti plaintext hesla
                $ps1Error = $ps1Error | Select-Object -ExpandProperty ScriptName -Unique
                _WarningAndExit "Following scripts are using ConvertTo-SecureString, which is unsafe:`n$($ps1Error -join "`n")"
            } else {
                # ps1 v commitu obsahuji zavazne poruseni pravidel psani PS skriptu
                $ps1Error = $ps1Error | Select-Object Scriptname, Line, Column, Message | Format-List | Out-String -Width 1200
                _ErrorAndExit "Following serious misdemeanors agains best practices were found:`n$ps1Error`n`nFix and commit again."
            }
        }

        if ($ps1CompatWarning) {
            # ps1 v commitu obsahuji nekompatibilni prikazy se zadanou verzi PS (dle nastaveni v .vscode\PSScriptAnalyzerSettings.psd1)
            $ps1CompatWarning = $ps1CompatWarning | Select-Object Scriptname, Line, Column, Message | Format-List | Out-String -Width 1200
            _WarningAndExit "Compatibility issues were found:`n$ps1CompatWarning"
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

                _WarningAndExit "Deleted function $funcName is used in following scripts:`n$($fileFuncUsed -join "`n")"
            }
        }
        #TODO kontrola funkci v profile.ps1? viz AST sekce https://devblogs.microsoft.com/scripting/learn-how-it-pros-can-use-the-powershell-ast/
    }


    #
    # kontrola modulu Variables
    if ([string]$variablesModule = $filesToCommit -match "Variables\.psm1") {
        "- check module Variables ..."

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
            Write-Warning "Previous version of module Variables cannot be found (to check changed variables)."
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
            _ErrorAndExit "In module Variables are following variables defined more than once: $($duplicateVariable -join ', ')`n`nFix and commit again."
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

                    _WarningAndExit "Deleted variable $varName is used in following scripts:`n$($fileUsed -join "`n")"
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

                    _WarningAndExit "Modified variable $varName is used in following scripts:`n$($fileUsed -join "`n")"
                }
            }
        }


        #
        # chyba, pokud modul Variables neobsahuje prikaz pro export promennych
        # pozn.: pokud bych umoznoval commitovat soubory modifikovane mimo staging area, musel bych misto obsahu lok. souboru vzit obsah z repo (git show :cestakmodulu)
        $AST = [System.Management.Automation.Language.Parser]::ParseFile($variablesModule, [ref]$null, [ref]$null)
        $commands = $AST.FindAll( { $args[0] -is [System.Management.Automation.Language.CommandAst ] }, $true)
        if (!($commands.extent.text -match "Export-ModuleMember")) {
            _ErrorAndExit "Module Variables doesn't export any variables using Export-ModuleMember.`n`nFix and commit again."
        }
    } # konec kontrol modulu Variables


    #
    # znovu provedu kontrolu, ze repo ma aktualni data
    # kontroly trvaji nekolik vterin, behem nichz mohl teoreticky nekdo jiny udelat push do repozitare
    $repoStatus = git.exe status -uno
    if ($repoStatus -match "Your branch is behind") {
        _ErrorAndExit "Repository doesn't contain actual data. Pull them (git pull or sync icon in VSC) and try again."
    }
} catch {
    $err = $_
    # vypisi i do git konzole kdyby se GUI okno s chybou nezobrazilo
    $err
    if ($err -match "##_user_cancelled_##") {
        # uzivatelem iniciovane preruseni commitu
        exit 1
    } else {
        _ErrorAndExit "There was an error:`n$err`n`nFix and commit again."
    }
}

"DONE"