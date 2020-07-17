function Send-Email {
    <#
    .SYNOPSIS
    Function for sending emails through company SMTP server.

    .DESCRIPTION
    Function for sending emails through company SMTP server.
    Function is much more smarter than default Send-MailMessage.

    .PARAMETER SmtpServer
    Address of the SMTP server.
    Default is $_smtpServer.

    .PARAMETER From
    Address of the sender.
    Default is $_from.

    .PARAMETER To
    Address of the recipient(s).
    Default is $_adminEmail.
    If you omit domain (part after @), it will be automatically set to same domain as has sender.

    .PARAMETER Cc
    Address of the cc recipient(s).
    If you omit domain (part after @), it will be automatically set to same domain as has sender.

    .PARAMETER ReplyTo
    Address of reply-to.
    Default is $_adminEmail.

    .PARAMETER Subject
    Subject of the email.
    It is optional, if omitted, name of the script/functions which call this Send-Email function will be used. Otherwise Send-Email will be used.

    .PARAMETER Body
    Body of the email.

    .PARAMETER Attachment
    Path to file attachment.

    .PARAMETER UseHTMLformat
    Switch for send email as HTML, otherwise it will be send as plaintext.

    .PARAMETER Critical
    Switch for adding CRITICAL: prefix to subject.

    .PARAMETER enableSSL
    Switch for enabling SSL.

    .PARAMETER Credentials
    Credentials for authentication to SMTP server.

    .EXAMPLE
    Send-Email -to sebela@domain.cz, karel@domain.cz -subject "hi buddy" -body "Hi`nhow are you?"
	#>

    [CmdletBinding()]
    param (
        [string] $subject
        ,
        [string] $body = "Ahoj,`ntoto je vychozi zprava`nza minuly den... $($result | Out-String) `nKontrola probiha na..."
        ,
        [ValidateNotNullOrEmpty()]
        [string[]]$to = $_adminEmail
        ,
        [string[]]$cc
        ,
        [ValidateNotNullOrEmpty()]
        [string] $smtpServer = $_smtpServer
        ,
        [ValidateScript( { $_ -match '@' })]
        [string] $from = $_from
        ,
        [ValidateScript( { $_ -match '@' })]
        [string] $replyTo = $_adminEmail
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
        ,
        [int] $smtpServerPort = 25
    )

    if (!$subject) {
        $thisFunctionName = $MyInvocation.MyCommand.Name
        $lastCaller = Get-PSCallStack | Where-Object { $_.Command -ne $thisFunctionName -and $_.command -ne "<ScriptBlock>" } | Select-Object -Last 1 -Exp Command
        # trying to get path to script that called this function
        try {
            $subject = (Split-Path $MyInvocation.ScriptName -Leaf) -replace "\.\w+$"
        }
        catch { }
        # trying to get name of function that called this function
        if (!$subject) {
            $subject = $lastCaller
        }
        # nastavim jako subjekt jmeno teto funkce
        if (!$subject) {
            $subject = $thisFunctionName
        }
    }

    
    $position = $from.IndexOf("@")
    $defaultDomain = $from.Substring($position + 1)

    # fill default domain for recipients without any
    [System.Collections.ArrayList] $to2 = @()
    foreach ($recipient in $to) {
        if ($recipient -notmatch '@') {
            $recipient = $recipient + "@" + $defaultDomain
        }
        $null = $to2.Add($recipient)
    }

    $to = $to2

    # fill default domain for recipients without any
    [System.Collections.ArrayList] $cc2 = @()
    foreach ($recipient in $cc) {
        if ($recipient -notmatch '@') {
            $recipient = $recipient + "@" + $defaultDomain
        }
        $null = $cc2.Add($recipient)
    }

    $cc = $cc2

    try {
        if ($critical) {
            $Subject = "CRITICAL: $Subject"
        }

        $msg = New-Object System.Net.Mail.MailMessage
        $msg.From = $From
        foreach ($Recipient in $To) { $msg.To.Add($Recipient) }
        foreach ($Recipient in $Cc) { $msg.CC.Add($Recipient) }
        if ($ReplyTo) { $msg.ReplyTo = "$ReplyTo" }
        $msg.Subject = $Subject
        $msg.Body = $Body
        if ($Attachment) { $attachment.ForEach( { $msg.Attachments.Add( (New-Object Net.Mail.Attachment($_))) }) }
        if ($UseHTMLformat) { $msg.IsBodyHTML = $true } else { $msg.IsBodyHTML = $false }

        $smtpClient = New-Object Net.Mail.SmtpClient($smtpServer, $smtpServerPort)

        if ($enableSSL) {
            # http://nicholasarmstrong.com/2009/12/sending-email-with-powershell-implicit-and-explicit-ssl/
            # disable SSL3
            $protocol = [System.Net.ServicePointManager]::SecurityProtocol
            [System.Net.ServicePointManager]::SecurityProtocol = 'TLS,TLS11,TLS12'
            $smtpClient.EnableSsl = $true

            if ($credentials) {
                $smtpClient.UseDefaultCredentials = $false
                $smtpClient.Credentials = $credentials
            }
        }

        Write-Verbose "
        subject: $subject
        to: $to
        cc: $cc
        smtpServer: $smtpServer
        from: $from
        replyTo: $replyTo
        attachment: $attachment
        useHTMLformat: $useHTMLformat
        critical: $critical
        enableSSL: $enableSSl
        smtpServerPort: $smtpServerPort
        "

        $smtpClient.Send($msg)

        if ($enableSSL) {
            # set original values
            [System.Net.ServicePointManager]::SecurityProtocol = $protocol
        }

        $msg.Dispose()
    }
    catch {
        throw $_
    }
}