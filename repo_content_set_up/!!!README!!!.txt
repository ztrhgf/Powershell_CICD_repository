###########
##### JAK ZACIT PRACOVAT S TIMTO REPO
- nainstalujte si Visual Studio Code
- nainstalujte si nejnovejsi GIT for Windows (pri instalaci zvolte vychozi hodnoty) HLAVNE komponentu "git credential manager"
- naklonujte repozitar (v GIT BASH konzoli prikazem "git clone httpsurlvasehorepo")
- nastavte repozitar viz nize!


###########
##### CO JE POTREBA PROVEST PO NAKLONOVANI TOHOTO REPOZITARE
v rootu tohoto repozitare spustte v konzoli:
git config core.hooksPath ".\.githooks"
- pro nastaveni git hooks (kvuli kontrole syntaxe, pushi comitu a kontrole auto-merge)

git config --global user.name "mujlogin"
git config --global user.email "mujlogin@kentico.com"
- pouzije se jako jmeno autora commitu
- oboje musi byt nastaveno, aby se zobrazovaly mnou definovane GIT chyby a ne "Make sure you configure your user.name ..."

- pro nastaveni git username (pouzije se jako jmeno autora commitu)

(v admin CMD otevrene v rootu repozitare!)
mkdir %userprofile%\AppData\Roaming\Code\User\snippets
mklink %userprofile%\AppData\Roaming\Code\User\snippets\powershell.json %cd%\powershell.json
- aby vam ve VSC fungovalo doplnovani powershell snippetu