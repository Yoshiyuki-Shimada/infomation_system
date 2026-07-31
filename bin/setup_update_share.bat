@echo on
setlocal EnableExtensions

set "TARGET_PATH=C:\Users\Yukky\Desktop\infomation_system\_update\inbox"
set "SHARE_NAME=infomation_update_inbox"
set "USER_NAME=infoupdate"
set "USER_PASS=%INFO_UPDATE_PASS%"
set "LOG=%USERPROFILE%\Desktop\setup_update_share.log"

if "%USER_PASS%"=="" goto password_error

echo START %date% %time% > "%LOG%"
echo Log file: %LOG%
echo If this window closes, open the log file on Desktop.
echo.

net session >> "%LOG%" 2>&1
if errorlevel 1 goto admin_error

echo Create folder...
echo Create folder... >> "%LOG%"
mkdir "%TARGET_PATH%" >> "%LOG%" 2>&1

echo Create or update user...
echo Create or update user... >> "%LOG%"
net user "%USER_NAME%" >> "%LOG%" 2>&1
if errorlevel 1 (
    net user "%USER_NAME%" "%USER_PASS%" /add >> "%LOG%" 2>&1
) else (
    net user "%USER_NAME%" "%USER_PASS%" >> "%LOG%" 2>&1
)
if errorlevel 1 goto user_error

echo Disable password expiration...
echo Disable password expiration... >> "%LOG%"
wmic useraccount where "name='%USER_NAME%'" set PasswordExpires=false >> "%LOG%" 2>&1

echo Delete old share...
echo Delete old share... >> "%LOG%"
net share "%SHARE_NAME%" /delete /y >> "%LOG%" 2>&1

echo Create share...
echo Create share... >> "%LOG%"
net share "%SHARE_NAME%"="%TARGET_PATH%" /GRANT:%COMPUTERNAME%\%USER_NAME%,CHANGE /GRANT:Everyone,CHANGE >> "%LOG%" 2>&1
if errorlevel 1 goto share_error

echo Set folder permission...
echo Set folder permission... >> "%LOG%"
icacls "%TARGET_PATH%" /grant "%COMPUTERNAME%\%USER_NAME%:(OI)(CI)M" >> "%LOG%" 2>&1
if errorlevel 1 goto acl_error
icacls "%TARGET_PATH%" /grant "*S-1-1-0:(OI)(CI)M" >> "%LOG%" 2>&1

echo Enable firewall rules...
echo Enable firewall rules... >> "%LOG%"
netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes >> "%LOG%" 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' -ErrorAction SilentlyContinue | Enable-NetFirewallRule; Get-NetFirewallRule -DisplayGroup 'ファイルとプリンターの共有' -ErrorAction SilentlyContinue | Enable-NetFirewallRule" >> "%LOG%" 2>&1

echo Verify...
echo Verify... >> "%LOG%"
hostname >> "%LOG%" 2>&1
net share "%SHARE_NAME%" >> "%LOG%" 2>&1
net user "%USER_NAME%" >> "%LOG%" 2>&1
icacls "%TARGET_PATH%" >> "%LOG%" 2>&1

echo.
echo SETUP COMPLETE
echo Share path:
echo \\%COMPUTERNAME%\%SHARE_NAME%
echo.
echo Log file:
echo %LOG%
echo.
goto hold

:password_error
echo ERROR: INFO_UPDATE_PASS is not set.
echo Run this command first, then open a new administrator Command Prompt and run this BAT again:
echo setx INFO_UPDATE_PASS "your-password"
goto hold

:admin_error
echo ERROR: Run this file as administrator.
echo ERROR: Run this file as administrator. >> "%LOG%"
goto hold

:user_error
echo ERROR: Failed to create or update user.
echo ERROR: Failed to create or update user. >> "%LOG%"
goto hold

:share_error
echo ERROR: Failed to create share.
echo ERROR: Failed to create share. >> "%LOG%"
goto hold

:acl_error
echo ERROR: Failed to set folder permission.
echo ERROR: Failed to set folder permission. >> "%LOG%"
goto hold

:hold
echo.
echo This window will stay open. Close it with X after checking.
echo.
cmd /k