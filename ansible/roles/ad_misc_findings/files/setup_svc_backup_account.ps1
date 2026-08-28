$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory

$svcPassword = $env:SVC_BACKUP_PASSWORD
if (-not $svcPassword) { throw "SVC_BACKUP_PASSWORD environment variable not set" }

if (-not (Get-ADUser -Filter "SamAccountName -eq 'svc-backup'" -ErrorAction SilentlyContinue)) {
    $secure = ConvertTo-SecureString $svcPassword -AsPlainText -Force
    New-ADUser -Name "svc-backup" -SamAccountName "svc-backup" -UserPrincipalName "svc-backup@cyberhawks.lab" `
        -AccountPassword $secure -Enabled $true -PasswordNeverExpires $true -ChangePasswordAtLogon $false
    Write-Output "Created svc-backup account"
} else {
    Set-ADAccountPassword -Identity "svc-backup" -NewPassword (ConvertTo-SecureString $svcPassword -AsPlainText -Force) -Reset
    Write-Output "Converged existing svc-backup account"
}
