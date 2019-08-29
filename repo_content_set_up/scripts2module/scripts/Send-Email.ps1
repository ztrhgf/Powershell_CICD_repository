function Send-Email {
    <#
		.SYNOPSIS
			Fce pro poslání emailu.

        .DESCRIPTION
            Fce pro poslání emailu.
            Umožňuje poslat jak HTML, tak plain text email včetně přílohy.
            Standardně je replyto nastaveno na adresu it@TODONAHRADIT.cz.
            Standardne se pouziva SSL.

		.PARAMETER SmtpServer
			Adresa SMTP serveru, který se má použít pro odeslání emailu.
			Vychozi je "TODONAHRADIT".

		.PARAMETER From
			Adresa odesílatele.
			Vychozi je "monitoring@TODONAHRADIT.cz".

		.PARAMETER To
			Adresa příjemce/ů. Je možné zadat víc adres.
            Vychozi je "it@TODONAHRADIT.cz".
            Adresatum bez domeny, se automaticky doplni @TODONAHRADIT.cz (it >> it@TODONAHRADIT.cz).

		.PARAMETER Cc
			Komu poslat v kopii. Je možné zadat víc adres.
            Adresatum bez domeny, se automaticky doplni @TODONAHRADIT.cz (it >> it@TODONAHRADIT.cz).

		.PARAMETER ReplyTo
			Adresa, která se použije v případě odpovědi na email.
			Vychozi je "it@TODONAHRADIT.cz".

		.PARAMETER Subject
            Nepovinny parametr. Subjekt emailu.
            Pokud nezadan, nastavi se jmeno skriptu ci funkce, ktery/a tuto funkci zavolal/a.
            Jako vychozi pak je Send-Email tzn jmeno teto funkce.

		.PARAMETER Body
			Text, který se zobrazí v těle emailu. Pokud chci vypsat nějakou proměnnou tak takto: $($promenna | out-string).

		.PARAMETER Attachment
			Cesta k příloze/hám.

		.PARAMETER UseHTMLformat
            Switch pro kódování emailu jako HTML, jinak se odešle klasický plain text.

        .PARAMETER Critical
            Switch ktery zmeni odesilatele na monitoring_critical@TODONAHRADIT.cz a k subjektu prida prefix CRITICAL:
            Pouzivat pro zpravy, ktere by nemely zapadnout.

        .PARAMETER enableSSL
            Switch pro povoleni pouziti SSL. Tzn vychozi stav je, ze se SSL NEpouziva.

        .PARAMETER Credentials
            Pro predani credentials, ktere se pouziji pro autentizaci vuci SMTP serveru.

		.EXAMPLE
            Send-Email -to sebela@domain.cz,karel@domain.cz -subject pozdrav -body "Ahoj `njak se vede"

            Na zadane adresy odesle email.

		.EXAMPLE
            Send-Email -body "Ahoj `njak se vede" -attachment C:\temp\log.txt

            Na it@TODONAHRADIT.cz posle email, kde v subjektu bude jmeno skriptu ci funkce, ze ktere jsem inicioval poslani emailu. V priloze bude log.txt.

		.NOTES
			Author: Ondřej Šebela - ztrhgf@seznam.cz
	#>

    [CmdletBinding()]
    param (
        [string] $subject
        ,
        [string] $body = "Ahoj,`ntoto je vychozi zprava`nza minuly den... $($result | Out-String) `nKontrola probiha na..."
        ,
        [string[]]$to = "it@TODONAHRADIT.cz"
        ,
        [string[]]$cc
        ,
        [string] $smtpServer = "TODONAHRADIT"
        ,
        [ValidateScript( { $_ -match '@' })]
        [string] $from = "monitor@TODONAHRADIT.cz"
        ,
        [ValidateScript( { $_ -match '@' })]
        [string] $replyTo = "it@TODONAHRADIT.cz"
        ,
        [ValidateScript( { Test-Path $_ -PathType 'Leaf' })]
        [string[]] $attachment
        ,
        [switch] $useHTMLformat
        ,
        [switch] $critical
        ,
        [switch] $enableSSL
        ,
        [PSCredential] $credentials
    )

    # auto nastaveni subject
    # na nazev skriptu ci funkce, ze ktereho se tato funkce zavolala ci jmeno teto funkce
    if (!$subject) {
        $MyName = $MyInvocation.MyCommand.Name
        $lastCaller = Get-PSCallStack | Where-Object { $_.Command -ne $MyName -and $_.command -ne "<ScriptBlock>" } | Select-Object -Last 1 -Exp Command
        # zkusim ziskat cestu ke skriptu, ktery vola tuto funkci
        try {
            $subject = (Split-Path $MyInvocation.ScriptName -Leaf) -replace "\.\w+$"
        } catch { }
        # zkusim ziskat jmeno funkce, ktera vola tuto funkci
        if (!$subject) {
            $subject = $lastCaller
        }
        # nastavim jako subjekt jmeno teto funkce
        if (!$subject) {
            $subject = $MyName
        }
    }

    # prijemci bez domeny budou automaticky mit @TODONAHRADIT.cz
    [System.Collections.ArrayList] $to2 = @()
    foreach ($recipient in $to) {
        if ($recipient -notmatch '@') {
            $recipient = $recipient + '@TODONAHRADIT.cz'
        }
        $null = $to2.Add($recipient)
    }

    $to = $to2

    # prijemci bez domeny budou automaticky mit @TODONAHRADIT.cz
    [System.Collections.ArrayList] $cc2 = @()
    foreach ($recipient in $cc) {
        if ($recipient -notmatch '@') {
            $recipient = $recipient + '@TODONAHRADIT.cz'
        }
        $null = $cc2.Add($recipient)
    }

    $cc = $cc2

    try {
        if ($critical) {
            $Subject = "CRITICAL: $Subject"
        }

        # vytvorim si objekt se zpravou emailu
        $msg = New-Object System.Net.Mail.MailMessage
        # nastavim ruzne property
        $msg.From = $From
        foreach ($Recipient in $To) { $msg.To.Add($Recipient) }
        foreach ($Recipient in $Cc) { $msg.CC.Add($Recipient) }
        if ($ReplyTo) { $msg.ReplyTo = "$ReplyTo" }
        $msg.Subject = $Subject
        $msg.Body = $Body
        if ($Attachment) { $attachment.ForEach( { $msg.Attachments.Add( (New-Object Net.Mail.Attachment($_))) }) }
        if ($UseHTMLformat) { $msg.IsBodyHTML = $true } else { $msg.IsBodyHTML = $false }

        # vytvorim objekt pro odeslani emailu
        $smtpClient = New-Object Net.Mail.SmtpClient($smtpServer, 25252)

        if ($enableSSL) {
            # http://nicholasarmstrong.com/2009/12/sending-email-with-powershell-implicit-and-explicit-ssl/
            # zakaze pouziti SSL3
            $protocol = [System.Net.ServicePointManager]::SecurityProtocol
            [System.Net.ServicePointManager]::SecurityProtocol = 'TLS,TLS11,TLS12'
            [System.Net.ServicePointManager]::SecurityProtocol
            $smtpClient.EnableSsl = $true

            if ($credentials) {
                $smtpClient.UseDefaultCredentials = $false
                $smtpClient.Credentials = $credentials
            }
        }

        # odeslu zpravu na smtp server
        $smtpClient.Send($msg)

        if ($enableSSL) {
            # nastavim puvodni hodnoty
            [System.Net.ServicePointManager]::SecurityProtocol = $protocol
        }

        # zruseni objektu (aby nedrzel handle na soubory priloh atd)
        $msg.Dispose();
    } catch {
        throw $_
    }
}