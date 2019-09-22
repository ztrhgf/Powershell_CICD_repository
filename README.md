# Powershell_CICD_repository
Repository contains necessary files to create your own company CI/CD-like Powershell repository.

Just clone (don't use "Download ZIP"!) this repository and follow step by step tutorial in attached Powerpoint presentation.


# Changelog

## [Unreleased]
- support defining multiple object with same folderName key in $config
- support "\" in folderName key in $config
- add automatic script signing



## [2.0.0] - 2019-22-9
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


## [1.0.3] - 2019-2-9
### Added
- Possibility to define custom share NTFS rights for folders in Custom. Intended for limiting read access to folders stored in share/DFS, in case the folder doesn't have computerName attribute in customConfig, etc access isn't limited already.


## [1.0.2] - 2019-30-8
### Changed
- Later import of the Variables module in PS_env_set_up.ps1 script. To work with current data when synchronyzing profile and Custom section.


## [1.0.1] - 2019-30-8
### Added
- Granting access to folders in DFS repository "Custom" to just computers, which should download this content. Non other machines can access it.


## [1.0.0] - 2019-29-8
### Added
- Initial commit
