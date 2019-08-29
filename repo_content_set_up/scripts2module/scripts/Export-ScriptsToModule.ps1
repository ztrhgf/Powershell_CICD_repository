function Export-ScriptsToModule {
    <#
    .SYNOPSIS
        Funkce pro vytvoreni PS modulu z PS funkci ulozenych v ps1 souborech v zadanem adresari.
        Krome funkci exportuje take jejich aliasy at uz zadane skrze Set-Alias ci [Alias("Some-Alias")]
        !!! Aby se v generovanych modulech korektne exportovaly funkce je potreba,
        mit funkce ulozene v ps1 souboru se shodnym nazvem (Invoke-Command2 funkci v Invoke-Command2.ps1 souboru)

        !!! POZOR v PS konzoli musi byt vybran font, ktery nekazi UTF8 znaky, jinak zpusobuje problemy!!!

    .PARAMETER configHash
        Hash obsahujici dvojice, kde klicem je cesta k adresari se skripty a hodnotou cesta k adresari, do ktereho se vygeneruje modul.
        napr.: @{"C:\temp\scripts" = "C:\temp\Modules\Scripts"}

    .PARAMETER enc
        Jake kodovani se ma pouzit pro vytvareni modulu a cteni skriptu

        Vychozi je UTF8.

    .PARAMETER includeUncommitedUntracked
        Vyexportuje i necomitnute a untracked funkce z repozitare

    .PARAMETER dontCheckSyntax
        Prepinac rikajici, ze se u vytvoreneho modulu nema kontrolovat syntax.
        Kontrola muze byt velmi pomala, pripadne mohla byt uz provedena v ramci kontroly samotnych skriptu

    .PARAMETER dontIncludeRequires
        Prepinac rikajici, ze se do modulu nepridaji pripadne #requires modulu skriptu.

    .EXAMPLE
        Export-ScriptsToModule @{"C:\DATA\POWERSHELL\repo\scripts" = "c:\DATA\POWERSHELL\repo\modules\Scripts"}

    .NOTES
        Author: Ondřej Šebela - ztrhgf@seznam.cz
    #>

    [CmdletBinding()]
    param (
        [ValidateNotNullOrEmpty()]
        $configHash
        ,
        $enc = 'utf8'
        ,
        [switch] $includeUncommitedUntracked
        ,
        [switch] $dontCheckSyntax
        ,
        [switch] $dontIncludeRequires
    )

    if (!(Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue) -and !$dontCheckSyntax) {
        Write-Warning "Syntaxe se nezkontroluje, protoze neni dostupna funkce Invoke-ScriptAnalyzer (soucast modulu PSScriptAnalyzer)"
    }
    function _generatePSModule {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            $scriptFolder
            ,
            [Parameter(Mandatory = $true)]
            [ValidateNotNullOrEmpty()]
            $moduleFolder
            ,
            [switch] $includeUncommitedUntracked
        )

        if (!(Test-Path $scriptFolder)) {
            throw "Cesta $scriptFolder neexistuje"
        }

        $modulePath = Join-Path $moduleFolder ((Split-Path $moduleFolder -Leaf) + ".psm1")
        $function2Export = @()
        $alias2Export = @()
        $lastCommitFileContent = @{ }
        # necomitnute zmenene skripty a untracked do modulu nepridam, protoze nejsou hotove
        $location = Get-Location
        Set-Location $scriptFolder
        $unfinishedFile = @()
        try {
            # necomitnute zmenene soubory
            $unfinishedFile += @(git.exe ls-files -m --full-name)
            # untracked
            $unfinishedFile += @(git.exe ls-files --others --exclude-standard --full-name)
        } catch {
            throw "Zrejme neni nainstalovan GIT, nepodarilo se ziskat seznam zmenenych souboru v repozitari $scriptFolder"
        }
        Set-Location $location

        #
        # existuji modifikovane necomitnute/untracked soubory
        # abych je jen tak nepreskocil pri generovani modulu, zkusim dohledat verzi z posledniho commitu a tu pouzit
        if ($unfinishedFile) {
            [System.Collections.ArrayList] $unfinishedFile = @($unfinishedFile)

            # _startProcess umi vypsat vystup (vcetne chyb) primo do konzole, takze se da pres Select-String poznat, jestli byla chyba
            function _startProcess {
                [CmdletBinding()]
                param (
                    [string] $filePath = 'notepad.exe',
                    [string] $argumentList = '/c dir',
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

            Set-Location $scriptFolder
            $unfinishedFile2 = $unfinishedFile.Clone()
            $unfinishedFile2 | ForEach-Object {
                $file = $_
                $lastCommitContent = _startProcess git "show HEAD:$file"
                if (!$lastCommitContent -or $lastCommitContent -match "^fatal: ") {
                    Write-Warning "Preskakuji zmeneny ale necomitnuty/untracked soubor: $file"
                } else {
                    $fName = [System.IO.Path]::GetFileNameWithoutExtension($file)
                    # upozornim, ze pouziji verzi z posledniho commitu, protoze aktualni je nejak upravena
                    Write-Warning "$fName ma necommitnute zmeny. Pro vygenerovani modulu pouziji jeho verzi z posledniho commitu"
                    # ulozim obsah souboru tak jak vypadal pri poslednim commitu
                    $lastCommitFileContent.$fName = $lastCommitContent
                    # z $unfinishedFile odeberu, protoze obsah souboru pridam, i kdyz z posledniho commitu
                    $unfinishedFile.Remove($file)
                }
            }
            Set-Location $location

            # unix / nahradim za \
            $unfinishedFile = $unfinishedFile -replace "/", "\"
            $unfinishedFileName = $unfinishedFile | ForEach-Object { [System.IO.Path]::GetFileName($_) }

            if ($includeUncommitedUntracked -and $unfinishedFileName) {
                Write-Warning "Vyexportuji i tyto zmenene, ale necomitnute/untracked funkce: $($unfinishedFileName -join ', ')"
                $unfinishedFile = @()
            }
        }

        #
        # v seznamu ps1 k exportu do modulu ponecham pouze ty, ktere jsou v konzistentnim stavu
        $script2Export = (Get-ChildItem (Join-Path $scriptFolder "*.ps1") -File).FullName | Where-Object {
            $partName = ($_ -split "\\")[-2..-1] -join "\"
            if ($unfinishedFile -and $unfinishedFile -match [regex]::Escape($partName)) {
                return $false
            } else {
                return $true
            }
        }

        if (!$script2Export -and $lastCommitFileContent.Keys.Count -eq 0) {
            Write-Warning "V $scriptFolder neni zadna vyhovujici funkce k exportu do $moduleFolder. Ukoncuji"
            return
        }

        # smazu existujici modul
        if (Test-Path $modulePath -ErrorAction SilentlyContinue) {
            Remove-Item $moduleFolder -Recurse -Confirm:$false -ErrorAction SilentlyContinue
            Start-Sleep 1
        }

        # vytvorim slozku modulu
        [Void][System.IO.Directory]::CreateDirectory($moduleFolder)

        Write-Verbose "Do $modulePath`n"

        # do hashe $lastCommitFileContent pridam dvojice, kde klic je jmeno funkce a hodnotou jeji textova definice
        $script2Export | ForEach-Object {
            $script = $_
            $fName = [System.IO.Path]::GetFileNameWithoutExtension($script)
            if ($fName -match "\s+") {
                throw "Soubor $script obsahuje v nazvu mezeru coz je nesmysl. Jmeno souboru musi odpovidat funkci v nem ulozene a funkce nemohou v nazvu obsahovat mezery"
            }
            if (!$lastCommitFileContent.containsKey($fName)) {
                # obsah skriptu (funkci) pridam pouze pokud jiz neni pridan, abych si neprepsal fce vytazene z posledniho commitu

                #
                # provedu nejdriv kontrolu, ze je ve skriptu definovana pouze jedna funkce a nic jineho
                $ast = [System.Management.Automation.Language.Parser]::ParseFile("$script", [ref] $null, [ref] $null)
                # mel by existovat pouze end block
                if ($ast.BeginBlock -or $ast.ProcessBlock) {
                    throw "Soubor $script neni ve spravnem tvaru. Musi obsahovat pouze definici jedne funkce (pripadne nastaveni aliasu pomoci Set-Alias, komentar ci requires)!"
                }

                # ziskam definovane funkce (v rootu skriptu)
                $functionDefinition = $ast.FindAll( {
                        param([System.Management.Automation.Language.Ast] $ast)

                        $ast -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                        # Class methods have a FunctionDefinitionAst under them as well, but we don't want them.
                        ($PSVersionTable.PSVersion.Major -lt 5 -or
                            $ast.Parent -isnot [System.Management.Automation.Language.FunctionMemberAst])
                    }, $false)

                if ($functionDefinition.count -ne 1) {
                    throw "Soubor $script bud neobsahuje zadnou funkci ci obsahuje vic nez jednu. To neni povoleno."
                }

                #TODO pouzivat pro jmeno funkce jeji skutecne jmeno misto nazvu souboru?.
                # $fName = $functionDefinition.name

                #
                # nadefinuji znovu obsah funkce z AST a ten teprve dam do modulu (takto mam jistotu, ze tam nebude zadny bordel navic)
                $content = ""
                if (!$dontIncludeRequires) {
                    # pridam puvodne definovane requires, ale pouze pro moduly
                    $requiredModules = $ast.scriptRequirements.requiredModules.name
                    if ($requiredModules) {
                        $content += "#Requires -Modules $($requiredModules -join ',')`n`n"
                    }
                }
                # nahradim zavadne znaky za legitimni
                $functionText = $functionDefinition.extent.text -replace [char]0x2013, "-" -replace [char]0x2014, "-"

                # pridam i text funkce :)
                $content += $functionText

                # pridam aliasy definovane skrze Set-Alias
                # $ast.EndBlock.Statements obsahuje bloky kodu
                # zajimaji mne pouze ty, ktere definuji alias
                $ast.EndBlock.Statements | Where-Object { $_ -match "^\s*Set-Alias .+" } | ForEach-Object { $_.extent.text } | ForEach-Object {
                    $parts = $_ -split "\s+"
                    # pridam text aliasu
                    $content += "`n$_"

                    if ($_ -match "-na") {
                        # alias nastaven jmennym parametrem
                        # ziskam hodnotu parametru
                        $i = 0
                        $parPosition
                        $parts | ForEach-Object {
                            if ($_ -match "-na") {
                                $parPosition = $i
                            }
                            ++$i
                        }

                        # poznacim alias pro pozdejsi export z modulu
                        $alias2Export += $parts[$parPosition + 1]
                        Write-Verbose "- exportuji alias: $($parts[$parPosition + 1])"
                    } else {
                        # alias nastaven pozicnim parametrem
                        # poznacim alias pro pozdejsi export z modulu
                        $alias2Export += $parts[1]
                        Write-Verbose "- exportuji alias: $($parts[1])"
                    }
                }

                # pridam aliasy definovane skrze [Alias("Some-Alias")]
                $innerAliasDefinition = $ast.FindAll( {
                        param([System.Management.Automation.Language.Ast] $ast)

                        $ast -is [System.Management.Automation.Language.AttributeAst]
                    }, $true) | Where-Object { $_.parent.extent.text -match '^param' } | Select-Object -ExpandProperty PositionalArguments | Select-Object -ExpandProperty Value -ErrorAction SilentlyContinue # odfitrluji aliasy definovane pro parametry funkce

                if ($innerAliasDefinition) {
                    $innerAliasDefinition | ForEach-Object {
                        $alias2Export += $_
                        Write-Verbose "- exportuji inner alias: $_"
                    }
                }

                $lastCommitFileContent.$fName = $content
            }
        }

        #
        # z hodnot v hashi (jmeno funkce a jeji textovy obsah) vygeneruji psm modul
        # poznacim jmeno funkce a pripadne aliasy pro Export-ModuleMember
        $lastCommitFileContent.GetEnumerator() | ForEach-Object {
            $fName = $_.Key
            $content = $_.Value

            Write-Verbose "- exportuji funkci: $fName"

            $function2Export += $fName


            $content | Out-File $modulePath -Append $enc
            "" | Out-File $modulePath -Append $enc
        }

        # nastavim, co se ma z modulu exportovat
        # rychlejsi (pri naslednem importu modulu) je, pokud se exportuji jen explicitne vyjmenovane funkce/aliasy nez pouziti *
        # 300ms vs 15ms :)

        if (!$function2Export) {
            throw "Neexistuji zadne funkce k exportu! Spatne zadana cesta??"
        } else {
            if ($function2Export -match "#") {
                Remove-Item $modulePath -recurse -force -confirm:$false
                throw "Exportovane funkce obsahuji v nazvu nepovoleny znak #. Modul jsem smazal."
            }

            $function2Export = $function2Export | Select-Object -Unique | Sort-Object

            "Export-ModuleMember -function $($function2Export -join ', ')" | Out-File $modulePath -Append $enc
        }

        if ($alias2Export) {
            if ($alias2Export -match "#") {
                Remove-Item $modulePath -recurse -force -confirm:$false
                throw "Exportovane aliasy obsahuji v nazvu nepovoleny znak #. Modul jsem smazal."
            }

            $alias2Export = $alias2Export | Select-Object -Unique | Sort-Object

            "Export-ModuleMember -alias $($alias2Export -join ', ')" | Out-File $modulePath -Append $enc
        }
    } # konec funkce _generatePSModule

    # ze skriptu vygeneruji modul
    $configHash.GetEnumerator() | ForEach-Object {
        $scriptFolder = $_.key
        $moduleFolder = $_.value

        $param = @{
            scriptFolder = $scriptFolder
            moduleFolder = $moduleFolder
            verbose      = $VerbosePreference
        }
        if ($includeUncommitedUntracked) {
            $param["includeUncommitedUntracked"] = $true
        }

        Write-Output "Generuji modul $moduleFolder ze skriptu v $scriptFolder"
        _generatePSModule @param

        if (!$dontCheckSyntax -and (Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue)) {
            # zkontroluji syntax vytvoreneho modulu
            $syntaxError = Invoke-ScriptAnalyzer $moduleFolder -Severity Error
            if ($syntaxError) {
                Write-Warning "V modulu $moduleFolder byly nalezeny tyto problemy:"
                $syntaxError
            }
        }
    }
}