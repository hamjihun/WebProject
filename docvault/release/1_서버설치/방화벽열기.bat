@echo off
chcp 65001 >nul
net session >nul 2>&1 || (echo 마우스 오른쪽 클릭 → [관리자 권한으로 실행] 으로 다시 실행하세요. & pause & exit /b 1)
netsh advfirewall firewall delete rule name="DocVault" >nul 2>&1
netsh advfirewall firewall add rule name="DocVault" dir=in action=allow protocol=TCP localport=8080
echo 8080 포트를 열었습니다. 다른 PC에서 http://이PC의IP:8080 으로 접속할 수 있습니다.
ipconfig | findstr /i "IPv4"
pause
