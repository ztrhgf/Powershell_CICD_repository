# Fully automated CI/CD solution for (not just) PowerShell content management in your Active Directory environment
Repository contains necessary files + installer that will create your own fully automated company CD/CD like repository, which can be used to manage the whole lifecycle of the (primarily) PowerShell content. So the only thing you will have to worry about now on, is code writing :-)
Everything else, like code backups, validations, auditing, signing, modules generation, content distribution etc will be automated.

- To get some quick insight, watch this [short introduction video](https://youtu.be/-xSJXbmOgyk) or super short examples of [new function creation](https://youtu.be/XvTe6ppsHgI), [new 'global' variable creation](https://youtu.be/Cb981bQ5SV4), [script validations](https://youtu.be/myxzPZZ8gEk). For more examples and explanation of how this works watch [quite long but detailed video](https://youtu.be/R3wjRT0zuOk) (examples starts at 10:12). Případně [českou verzi videa](https://youtu.be/Jylfq7lYzG4).

[<img src="https://media.giphy.com/media/hAfuEpFUrP2Nn79v7c/giphy.gif" width="30%">](https://youtu.be/037Ki_Hx0kY4)

- **!!! To test this solution in safe manner in under 5 minutes, check this out !!!** [<img src="https://media.giphy.com/media/27URm9VNtXQyaKqmvf/giphy.gif" width="30%">](https://youtu.be/o_QlF5YCMGU)

- To set this up in your environment please follow these [installation instructions](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md).

- In case you like this solution, found any bug or have improvement suggestion, please contact me at **ondrejsebela'at'gmail.com**.


# Main features:
- **unifies PowerShell environment across whole Active Directory**
  - same PowerShell modules, functions and variables everywhere (but can be customized by editing modulesConfig.ps1)
  - (optional) global Powershell profile to unify repository administrators experience
    - shows how many commits is this console behind, simplifies prompt, omits commands with plaintext password from history etc
- literally **all scripting content from whole Active Directory environment can be stored and managed from one place**
  - thanks to possibility to distribute any content to any location
- **based on GIT**
  - version control system
  - auditing (who changed what and when)
  - ...
- **extremely simplifies PowerShell content management by automating**
  - **code validation**
  - **code formatting**
  - **content distribution**
      - using: GIT hooks, PowerShell scripts, GPO and VSC editor Workspace settings
- adheres to the principles of **configuration as a code**
- written by Windows administrator for Windows administrators i.e. 
  - **easy to use**
    - fully managed from Visual Studio Code editor
    - GIT knowledge not needed
    - Refresh-Console function for forcing synchronization of repository data on any client and importing such data to running Powershell console
  - **boost PowerShell adoption between admins**, because of easy know-how/functions sharing
  - **customizable**
    - everything is written in Powershell so you can easily add/remove features
  - **idiot-proof :)**
    - won't let you commit change, that would break your environment 
      - script contain syntax errors
    - warns against commiting change, that could break your environment (if changed object is used elsewhere)
      - modification of parameters of the function (applies just for functions in scripts2module folder)
      - modification of variable value (applies just for variables in Variables PS module)
      - deletion of function or variable
     - etc
- **no paid tools needed**
- last but not least
  - automatic **scheduled task creation** (from XML definition), so ps1 script (modules that it depend on) and sched. task, that should run it, can be distributed together
  - automatic **script signing** (if enabled)

- check [examples](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/2.%20HOW%20TO%20USE%20-%20EXAMPLES.md) or [watch short introduction video](https://youtu.be/-xSJXbmOgyk) for getting better insight

# Table of contents
## [Installation](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md)
## [Examples](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/2.%20HOW%20TO%20USE%20-%20EXAMPLES.md)
## [Repository logic & content explanation](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/3.%20SIMPLIFIED%20EXPLANATION%20OF%20HOW%20IT%20WORKS.md)
## [FAQ](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/FAQ.md)
## [Changelog](https://github.com/ztrhgf/Powershell_CICD_repository/releases)
