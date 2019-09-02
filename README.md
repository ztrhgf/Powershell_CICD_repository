# Powershell_CICD_repository
Repository contains necessary files to create your own company CI/CD-like Powershell repository.

Just clone (don't use "Download ZIP"!) this repository and follow step by step tutorial in attached Powerpoint presentation.


# Changelog

## [Unreleased]
- Limit access to global powershell profile.ps1 stored in DFS according to value of $computerWithProfile
- Use alternate data stream to detect my modules instead of ACL

## [1.0.3] - 2019-2-9
### Added
- Possibility to define custom share NTFS rights for folders in Custom. Intended for limiting read access to folders stored in share/DFS in case, the folder doesn't have computerName attribute in customConfig etc access isn't limited already.

## [1.0.2] - 2019-30-8
### Changed
- Later import of the Variables module in PS_env_set_up.ps1 script. To work with current data when synchronyzing profile and Custom section.

## [1.0.1] - 2019-30-8
### Added
- Granting access to folders in DFS repository "Custom" to just computers, which should download this content. Non other machines can access it.

## [1.0.0] - 2019-29-8
### Added
- Initial commit
