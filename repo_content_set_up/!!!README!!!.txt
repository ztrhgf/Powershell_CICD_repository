NECESSARY INITIAL CONFIGURATION:

- in root of this repository run in CMD:
git config core.hooksPath ".\.githooks"
	- to set up automation of GIT through git hooks

git config --global user.name "myLogin"

git config --global user.email "myLogin@somedomain.com"



- in root or this repository run in ADMIN CMD:
mkdir %userprofile%\AppData\Roaming\Code\User\snippets
mklink %userprofile%\AppData\Roaming\Code\User\snippets\powershell.json %cd%\powershell.json
	- to set up TAB completition of Powershell snippets in VSC
	- (if you set this up for another account, use absolute path instead %userprofile%)