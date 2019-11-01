# CI/CD solution for (not just) PowerShell content management in your Active Directory environment
Repository contains necessary files to create your own company CI/CD-like Powershell repository.

To set up please follow [instructions](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20-%20INITIAL%20CONFIGURATION.md)

In case you found any bug or have improvement suggestion, please contact me at ztrhgf'at'seznam.cz.


  
# Main features:
- **unified Powershell environment across whole Active Directory**
  - same modules, functions and variables everywhere
  - one global Powershell profile to unify user experience
- **fully automated code validation, formatting and content distribution**
  - using GIT hooks, Powershell scripts, GPO and VSC editor
  - automation is not applicable to code writing and making commits :)
- possibility to **distribute selected content to selected computers** (to specified folder (with specified NTFS permissions))
- can be used to **distribute any kind of content** (ps1, exe, ini, whatever) across company
- **easy to use** (fully managed from Visual Studio Code editor)
- **no paid tools needed**
- GIT knowledge not needed
- **idiot-proof**
  - warn about modification of functions and variables used in other scripts in repository etc
- **customizable** (everything is written in Powershell)
- automatic script signing (if enabled)
- check [examples](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/2.%20HOW%20TO%20USE%20-%20EXAMPLES.md) for getting better insight
  
# How code validation works
- after you commit your changes, pre-commit git hook initiate checks defined in pre-commit.ps1
- only if all checks are passed, commit will be created

# How distribution of content works
- after successful commit, content is automatically:
  - pushed to GIT repository
  - pulled to local server, processed and distributed to DFS share
  - from DFS share the content is downloaded to clients in your Active Directory
  
  
# Changelog

## [Unreleased]
- support defining multiple object with same folderName key in $customConfig
- support nesting of folders in Custom folder
- support for Pester testing


## [2.0.9] - 2019-11-01
### Added
- automatic scheduled task creation from xml saved in Custom section
  - so now you can automatically distribute as scripts as scheduled task itself (that should run them). No GPO preferences needed
  - check [examples](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/2.%20HOW%20TO%20USE%20-%20EXAMPLES.md) for getting better insight


## [2.0.8] - 2019-10-31
### Bug fixes
- fixed bug in PS_env_set_up that caused error in synchronization on computers, that should obtain global PS profile


## [2.0.7] - 2019-10-24
### Bug fixes
- fixed check for modules existence (now check also scripts2module path) in pre-commit


## [2.0.6] - 2019-10-24
### Bug fixes
- fixed not working limiting access to Custom folder stored in DFS share when used variables (from module Variables) 
### Added
- limiting access to modules stored in DFS share to just computers listed in $modulesConfig computerName key. No other machines can access them
### Changed
- better log output for repo_sync.ps1 script


## [2.0.5] - 2019-10-16
### Changed
- important comments and error messages changed to english


## [2.0.4] - 2019-10-4
### Added
- possibility to automatically sign Powershell code
  - just set up and uncomment definition of $signingCert variable in repo_sync.ps1 


## [2.0.3] - 2019-10-3
### Added
- possibility to sync modules just to chosen computers (defined in modulesConfig.ps1)
### Changed 
- $config variable defined in customConfig.ps1 renamed to $customConfig to honor name of the script file and be more unique
- repo_sync.ps1 now sync changes to DFS everytime, not just in case, some new data was pulled from cloud repo
### Bug fixes
- minor fixes


## [2.0.2] - 2019-10-1
### Added
- check, that commited scripts are compatible with Powershell 3.0 (defined in PSScriptAnalyzerSettings.psd1, so edit it, if you wish to check PS Core compatibility etc)


## [2.0.1] - 2019-9-27
### Bug fixes
- minor fixes


## [2.0.0] - 2019-9-22
### Breaking change
- $config key customNTFS was renamed to customDestinationNTFS
- $config key customShareNTFS was renamed to customSourceNTFS

### Bug fixes
- Repo_sync newly works with most actual data (loads Variables module and customConfig.ps1 right from local cloned repo, prior to loading from DFS share, which could lead to problems in some situations)

### Added
- Granting access to global Powershell profile (scripts2root\profile.ps1) stored in DFS to just computers listed in $computerWithProfilefolders. No other machines can access it.
- Possibility to copy Custom folder to any given local or shared path
- Possibility to copy just content of Custom folder
- Validation of $config variable stored in customConfig.ps1
- Multiple accounts could be defined in customDestinationNTFS (customNTFS)
- Warn about commited files, that contain #FIXME comment
- TAB completition of computerName parametr in any command defined in Scripts module through using Register-ArgumentCompleter in profile.ps1

### Changed 
- Update-Repo and Export-ScriptsToModule functions was moved to Repo_sync.ps1 


## [1.0.3] - 2019-9-2
### Added
- Possibility to define custom share NTFS rights for folders in Custom. Intended for limiting read access to folders stored in share/DFS, in case the folder doesn't have computerName attribute in customConfig, etc access isn't limited already.


## [1.0.2] - 2019-8-30
### Changed
- Later import of the Variables module in PS_env_set_up.ps1 script. To work with current data when synchronyzing profile and Custom section.


## [1.0.1] - 2019-8-30
### Added
- Granting access to folders in DFS repository "Custom" to just computers, which should download this content. Non other machines can access it.


## [1.0.0] - 2019-8-29
### Added
- Initial commit
