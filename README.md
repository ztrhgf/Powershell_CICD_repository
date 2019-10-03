# Powershell_CICD_repository
Repository contains necessary files to create your own company CI/CD-like Powershell repository, which will provide unified Powershell environment across whole company.

Just clone (don't use "Download ZIP"!) this repository and follow step by step tutorial in attached Powerpoint presentation.

In case you found any bug or have improvement suggestion, please contact me at ztrhgf'at'seznam.cz.


  
# Main features:
- unified Powershell environment across whole company
  - same modules, functions and variables across all Powershell sessions (local and remote)
  - one global Powershell profile to unify user experience
- fully automated (code validation, formatting and distribution)
  - using GIT hooks, Powershell scripts, GPO and VSC editor
  - automation is not applicable to code writing and making commits :)
  - after successful commit, content is automatically:
  pushed to GIT repository >> pulled to local server and processed >> distributed to DFS share >> and from it, downloaded to clients in your Active Directory
- possibility to synchronize chosen content to just specified computers
  - to specific folder
  - with specific NTFS permissions
- easy to use (fully managed from Visual Studio Code editor)
- idiot-proof
  - warn about modification of functions and variables used in other scripts in repository etc
- ...
  

# Changelog

## [Unreleased]
- support defining multiple object with same folderName key in $config
- support "\\" in folderName key in $config
- automatic script signing


## [2.0.3] - 2019-10-3
### Changed 
- $config variable defined in customConfig.ps1 renamed to $customConfig to honor name of the script file and be more unique
- repo_sync.ps1 now sync changes to DFS everytime, not just in case, some new data was pulled from cloud repo


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
- Granting access to global Powershell profile (scripts2root\profile.ps1) stored in DFS to just computers listed in $computerWithProfilefolders. Non other machines can access it.
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
