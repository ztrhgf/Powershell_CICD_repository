set WshShell = WScript.CreateObject("WScript.Shell")

' regex to distinguish ps1 scripts
Set runPs1 = New RegExp
With runPs1
.Pattern    = "\.ps1$"
.IgnoreCase = True
.Global     = False
End With
' regex to distinguish base64
set runBase64 = New RegExp
With runBase64
.Pattern    = "^psbase64:"
.IgnoreCase = True
.Global     = False
End With

If Wscript.Arguments.Count < 1 Or Wscript.Arguments.Count > 2 Then
wscript.echo "ERROR, you have to enter one or two argument(s)! First has to be the path to cmd file to run and voluntarily second one as CMDs file argument"
ElseIf Wscript.Arguments.Count = 1 Then
If runPs1.Test( WScript.Arguments(0) ) Then
' it is ps1 script
        WshShell.Run "cmd /c powershell.exe -ExecutionPolicy Bypass -NoLogo -NonInteractive -NoProfile -WindowStyle Hidden -File" & " " & """" & WScript.Arguments(0) & """", 0, True
    ElseIf runBase64.Test( WScript.Arguments(0) ) Then
        ' It is base64 string
'remove part before : from passed string to get just base64
        base64 = WScript.Arguments(0)
        base64 = Mid(base64,instr(base64,":")+1)
        WshShell.Run "cmd /c powershell.exe -ExecutionPolicy Bypass -NoLogo -NonInteractive -NoProfile -WindowStyle Hidden -EncodedCommand" & " " & """" & base64 & """", 0, True
    Else
        ' It is something else
WshShell.Run """" & WScript.Arguments(0) & """", 0, True
End If
ElseIf Wscript.Arguments.Count = 2 Then
'wscript.echo WScript.Arguments(0)
'wscript.echo WScript.Arguments(1)
If runPs1.Test( WScript.Arguments(0) ) Then
' it is ps1 script
        WshShell.Run "cmd /c powershell.exe -ExecutionPolicy Bypass -NoLogo -NonInteractive -NoProfile -WindowStyle Hidden -File" & " " & """" & WScript.Arguments(0) & """" & " " & """" & WScript.Arguments(1) & """", 0, True
    Else
        ' It isn't ps1 script
        WshShell.Run """" & WScript.Arguments(0) & """" & """" & WScript.Arguments(1) & """", 0, True
    End If
End If

Set WshShell = Nothing