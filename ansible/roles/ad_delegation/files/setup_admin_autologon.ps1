$ErrorActionPreference = "Stop"

$adminPassword = $env:ADMIN_ACCOUNT_PASSWORD
if (-not $adminPassword) { throw "ADMIN_ACCOUNT_PASSWORD environment variable not set" }

$winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
New-ItemProperty -Path $winlogonPath -Name "AutoAdminLogon" -PropertyType String -Value "1" -Force | Out-Null
New-ItemProperty -Path $winlogonPath -Name "DefaultUserName" -PropertyType String -Value "admin" -Force | Out-Null
New-ItemProperty -Path $winlogonPath -Name "DefaultDomainName" -PropertyType String -Value "CYBERHAWKS" -Force | Out-Null
New-ItemProperty -Path $winlogonPath -Name "DefaultPassword" -PropertyType String -Value $adminPassword -Force | Out-Null
New-ItemProperty -Path $winlogonPath -Name "AutoLogonCount" -PropertyType DWord -Value 999999 -Force | Out-Null

Write-Output "Configured autologon for admin on web"
