# CI/CD solution for (not just) PowerShell content management in your Active Directory environment
Repository contains necessary files and instructions to create your own company fully automated CI/CD-like repository for managing whole lifecycle of (primarly) Powershell content. So the only thing you will have to worry about is code writing :)

- To see some of the features this solution offers, watch this [short introduction video](https://youtu.be/-xSJXbmOgyk). For more examples and explanation of how this works watch [quite long but detailed video](https://youtu.be/R3wjRT0zuOk) (examples starts at 10:12).

- To set this up in your environment please follow these [instructions](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20-%20INITIAL%20CONFIGURATION.md).

- In case you like this solution, found any bug or have improvement suggestion, please contact me at **ondrejsebela'at'gmail.com**.


# Main features:
- **unified Powershell environment across whole Active Directory**
  - same modules, functions and variables everywhere
  - one global Powershell profile to unify repository administrators experience
- **fully automated code validation, formatting and content distribution**
  - using GIT hooks, Powershell scripts, GPO and VSC editor
- Written by Windows administrator for Windows administrators i.e. 
  - **easy to use**
    - fully managed from Visual Studio Code editor
    - GIT knowledge not needed
  - **customizable**
    - everything is written in Powershell
  - **idiot-proof :)**
    - warn about modification of functions and variables used elsewhere in repository, so chance that you break your environment is less than ever :)
- can be used also to 
  - **distribute any kind of content** (ps1, exe, ini, whatever) to any local/remote location
  - automatic script signing (if enabled)
  - automatic scheduled task creation (from XML definition), so ps1 script and sched. task that should run it can be distributed together
- **no paid tools needed**

- check [examples](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/2.%20HOW%20TO%20USE%20-%20EXAMPLES.md) or [watch video](https://youtu.be/R3wjRT0zuOk?t=612) for getting better insight
  
# How code validation works
- after you commit your changes, pre-commit git hook initiate checks defined in pre-commit.ps1
- only if all checks are passed, commit will be created and content distributed

## What is validated before commit is created
- that you are trying to delete important repository files
- that Powershell files 
  - are encoded as UTF-8 or UTF-8 with BOM
  - have correct syntax
  - doesn't contain EN DASH, EM DASH instead of dash (it would lead to strange errors)
  - doesn't contain #FIXME comment, otherwise warn about it
  - from which modules are generated are in correct form
- warn about changed function parameters (in case, the functions is used elsewhere)
- warn about deleted function (in case, the function is used elsewhere)
- warn about changed variable value from module Variables (in case, the variable is used elsewhere)
- warn about deleted variable from module Variables (in case, the variable is used elsewhere)
- ...


# How distribution of content works
- after successful commit, content is automatically:
  - pushed to GIT repository
    - by post-commit GIT hook (post-commit.ps1)
  - pulled to local server, processed and distributed to DFS share
    - by repo_sync.ps1 which is regularly run every 15 minutes by scheduled task
  - from DFS share the content is being downloaded by clients in your Active Directory
    - by PS_env_set_up.ps1 which is regularly run on client every 30 minutes by automatically created scheduled task (created via GPO PS_env_set_up)
  

# [Installation](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/1.%20HOW%20TO%20-%20INITIAL%20CONFIGURATION.md)
# [Examples](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/2.%20HOW%20TO%20USE%20-%20EXAMPLES.md)
# [FAQ](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/FAQ.md)
# [Repository content explanation](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/3.%20SIMPLIFIED%20EXPLANATION%20OF%20HOW%20IT%20WORKS.md)
# [Changelog](https://github.com/ztrhgf/Powershell_CICD_repository/blob/master/CHANGELOG.md)
