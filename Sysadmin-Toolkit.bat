@echo off
:: Sysadmin-Toolkit — double-click launcher for the menu (Start-SysadminToolkit.ps1).
:: Works from a local install, a USB stick, or a mounted ISO. Right-click > Run as
:: administrator for the tools that need it.
title Sysadmin-Toolkit
powershell.exe -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-SysadminToolkit.ps1"
