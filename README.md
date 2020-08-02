# CI/CD solution for (not just) PowerShell content management in your Active Directory environment
Repository contains necessary files and instructions to create your own company fully automated CI/CD-like repository for managing whole lifecycle of (primarly) PowerShell content. So the only thing you will have to worry about is code writing :)

- To see some of the features this solution offers, watch this [short introduction video](https://youtu.be/-xSJXbmOgyk). For more examples and explanation of how this works watch [quite long but detailed video](https://youtu.be/R3wjRT0zuOk) (examples starts at 10:12). Případně [českou verzi videa](https://youtu.be/Jylfq7lYzG4).

- To set this up in your environment please follow these [installation instructions](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md).

- In case you like this solution, found any bug or have improvement suggestion, please contact me at **ondrejsebela'at'gmail.com**.


# Main features:
- **based on GIT**
- **unified Powershell environment across whole Active Directory**
  - same PowerShell modules, functions and variables everywhere
    - can be customized using modulesConfig.ps1
  - (optional) global Powershell profile to unify repository administrators experience
- **extremely simplifies PowerShell content management by automating**
  - **code validation**
  - **code formatting**
  - **content distribution**
      - using: GIT hooks, PowerShell scripts, GPO and VSC editor workspace settings
- adheres to the principles of **configuration as code**
- written by Windows administrator for Windows administrators i.e. 
  - **easy to use**
    - fully managed from Visual Studio Code editor
    - GIT knowledge not needed
    - Refresh-Console function for forcing synchronization of repository data on any client and importing such data to running Powershell console
  - **customizable**
    - everything is written in Powershell
  - **idiot-proof :)**
    - warns against commiting changes, that could break your environment (if changed thing is used elsewhere) 
      - script contain syntax errors
      - modification of functions parameters
      - modification of variable value (applies just for variables in Variables PS module)
      - deletion of function or variable
      - etc
- **no paid tools needed**
- last but not least
  - **distribute any kind of content** (ps1, exe, ini, whatever) **to any local/remote location**
    - driven by customConfig.ps1
  - automatic **scheduled task creation** (from XML definition), so ps1 script (modules that it depend on) and sched. task, that should run it, can be distributed together
  - automatic **script signing** (if enabled)

- check [examples](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/2.%20HOW%20TO%20USE%20-%20EXAMPLES.md) or [watch short introduction video](https://youtu.be/-xSJXbmOgyk) for getting better insight
  
# How code validation works
- after you commit your changes, pre-commit git hook automatically initiate checks defined in pre-commit.ps1
- only if all checks are passed, commit will be created and content distributed
  - checks can stop creation of commit completely, or warn you about possible problems and let you decide, whether to continue

## What is validated before commit is created
- that you are not trying to delete important repository files
- that Powershell files 
  - are encoded as UTF-8 or UTF-8 with BOM
  - have valid syntax
  - doesn't contain EN DASH, EM DASH instead of dash (it would lead to strange errors)
  - doesn't contain #FIXME comment, otherwise warn about it
  - from which modules are generated are in correct form
- warn about changed function parameters (in case, the functions is used elsewhere)
- warn about changed function aliases (in case, the alias is used elsewhere)
- warn about deleted function (in case, the function is used elsewhere)
- warn about changed variable value from module Variables (in case, the variable is used elsewhere)
- warn about deleted variable from module Variables (in case, the variable is used elsewhere)
- ...


# How distribution of content works
- after successful commit, content is automatically:
  - pushed to GIT repository
    - by post-commit GIT hook (post-commit.ps1)
  - pulled to local server, processed and (clients part) distributed to shared folder
    - by repo_sync.ps1 which is regularly run every 15 minutes by scheduled task
  - from shared folder the content is being downloaded by clients in your Active Directory
    - by PS_env_set_up.ps1 which is regularly run on client every 30 minutes by automatically created scheduled task (created via GPO PS_env_set_up)
  

# [Installation](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20INSTALL.md)
# [Examples](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/2.%20HOW%20TO%20USE%20-%20EXAMPLES.md)
# [FAQ](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/FAQ.md)
# [Repository content explanation](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/3.%20SIMPLIFIED%20EXPLANATION%20OF%20HOW%20IT%20WORKS.md)
# [Changelog](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/CHANGELOG.md)
