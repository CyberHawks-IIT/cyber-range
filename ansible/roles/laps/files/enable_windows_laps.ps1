$ErrorActionPreference = "Stop"

$regPath = "HKLM:\Software\Microsoft\Policies\LAPS"
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}
New-ItemProperty -Path $regPath -Name "BackupDirectory" -PropertyType DWord -Value 2 -Force | Out-Null   # 2 = Active Directory (1 = Azure AD)
New-ItemProperty -Path $regPath -Name "PasswordComplexity" -PropertyType DWord -Value 4 -Force | Out-Null
New-ItemProperty -Path $regPath -Name "PasswordLength" -PropertyType DWord -Value 20 -Force | Out-Null
New-ItemProperty -Path $regPath -Name "PasswordAgeDays" -PropertyType DWord -Value 30 -Force | Out-Null

Import-Module LAPS
Invoke-LapsPolicyProcessing
Write-Output "LAPS policy applied and rotation triggered"
