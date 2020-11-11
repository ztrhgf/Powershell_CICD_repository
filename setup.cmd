@echo off
cd /d %~dp0

%WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe -executionPolicy bypass -noprofile -noexit -file stp.ps1