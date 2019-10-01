# Settings for PSScriptAnalyzer invocation.
# https://devblogs.microsoft.com/powershell/using-psscriptanalyzer-to-check-powershell-version-compatibility/
@{
    Rules = @{
        PSUseCompatibleCommands = @{
            # Turns the rule on
            Enable         = $true

            # Lists the PowerShell platforms we want to check compatibility with
            TargetProfiles = @(
                # PowerShell 6.1 Core on Windows Server 2019
                # 'win-8_x64_10.0.17763.0_6.1.3_x64_4.0.30319.42000_core',

                # PowerShell 5.1 on Windows Server 2019
                # 'win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework',

                # PowerShell 3.0 on Windows Server 2012
                'win-8_x64_6.2.9200.0_3.0_x64_4.0.30319.42000_framework'
            )
        }
        PSUseCompatibleSyntax   = @{
            # This turns the rule on (setting it to false will turn it off)
            Enable         = $true

            # Simply list the targeted versions of PowerShell here
            TargetVersions = @(
                # Powershell Core
                # '6.2',
                # '5.1',
                '3.0'
            )
        }
    }
}