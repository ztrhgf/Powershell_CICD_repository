# FAQ

1. Is it possible to to disable automatic push of commit to cloud repository? So I can create more commits locally etc?
    - Yes, just comment line `exec powershell.exe -NoProfile -ExecutionPolicy Bypass -file ".\.githooks\post-commit.ps1"` in `.githook\post-commit`

2. Is it suitable for organizations with more than 1000 PC's?
    - Yes, just be sure to use DFS as location for clients repository data and have enough file servers for load balancing.

3. Can I store some sensitive information in this repository?
    - NEVER store plaintext password..even if you delete it, it will stay in git history
    - Content of repository is stored on several places, so make sure, that just trusted people have access
      - in GIT repository
      - on computers where this repository is cloned
      - on `MGM server`
      - in DFS share (but there is placed just content for clients)
        - by default just "Domain Computers" has (read only) access, but that means, that any administrator can read them too using psexec
        - according to scripts2root\profile.ps1
          - just computers where this profile should be copied has read access to this file
        - according to data in `Custom` section you can
          - customize DFS access rights by selecting `computerName` or `customSourceNTFS` key in `customConfig` which will limit access just for selected accounts
          - also limit NTFS rights on clients local copy using key `customDestinationNTFS` in `customConfig`
      - locally on clients
        - look at above `Custom` section information

4. How can I make updating of DFS share to be more/less often?
    - On `MGM server` edit how often is run scheduled task `Repo_sync` 

4. How can I make updating of clients data from DFS share to be more/less often?
    - In GPO `PS_env_set_up` which creates same named scheduled task on clients edit, how often this task should be run.
      - But don't run this more often than `Repo_sync` task on `MGM server`, because it wouldn't make sense..

5. How can I get new repository data to some computer ASAP?
    - Run function Refresh-Console with parameter computerName. This will lead to immediate update of data in DFS and on selected computer.

6. Synchronization of data to DFS isn't working, what should I do?
    - Look at "C:\Windows\Temp\Repo_sync.log" on `MGM server`
    
7. Synchronization of data from DFS to client isn't working, what should I do?
    - Look at "C:\Windows\Temp\PS_env_set_up.log" on client
    
8. I commited change, that will destroy whole world, how can I fix it ASAP?
    - In case, this bug is already in DFS share
      - disable GPO `PS_env_set_up` and invoke gpupdate on all affected clients (because this GPO should create scheduled task in replace mode, this should lead to deletion of that task)
      - fix the bug and wait for the propagation of change to DFS share, than enable GPO again
    - In case this bug isn't in DFS share yet
      - disable `Repo_sync` scheduled task on `MGM server`
      - fix the bug and than enable the task again
