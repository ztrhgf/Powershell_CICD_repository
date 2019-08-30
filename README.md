# Powershell_CICD_repository
Repository contains necessary files to create your own company CI/CD-like Powershell repository.

Just clone (don't use "Download ZIP"!) this repository and follow step by step tutorial in attached Powerpoint presentation.


# Changelog

## [Unreleased]
- Possibility to define custom NTFS rights for folders in Custom (independent on NTFS based on value of property computerName). It could be useful to private content which is not intended for downloading on any clients
- limit access to global powershell profile.ps1 stored in DFS according to value of $computerWithProfile

## [1.0.2] - 2019-30-8
### Changed
- Later import of the Variables module in PS_env_set_up.ps1 script. To work with current data when synchronyzing profile and Custom section.

## [1.0.1] - 2019-30-8
### Added
- Granting access to folders in DFS repository "Custom" to just computers, which should download this content. Non other machines can access it.

## [1.0.0] - 2019-29-8
### Added
- Initial commit
