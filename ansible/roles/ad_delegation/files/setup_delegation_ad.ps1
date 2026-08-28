$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory

$adminPassword = $env:ADMIN_ACCOUNT_PASSWORD
if (-not $adminPassword) { throw "ADMIN_ACCOUNT_PASSWORD environment variable not set" }

# "admin" -- the Domain Admin whose session/TGT gets captured via web's
# Unconstrained Delegation below. Not a starter account; its password is
# never meant to be known/guessed, only reached via LSASS capture.
if (-not (Get-ADUser -Filter "SamAccountName -eq 'admin'" -ErrorAction SilentlyContinue)) {
    $securePw = ConvertTo-SecureString $adminPassword -AsPlainText -Force
    New-ADUser -Name "admin" -SamAccountName "admin" -UserPrincipalName "admin@cyberhawks.lab" `
        -AccountPassword $securePw -Enabled $true -PasswordNeverExpires $true -ChangePasswordAtLogon $false
    Add-ADGroupMember -Identity "Domain Admins" -Members "admin"
    Write-Output "Created admin account and added to Domain Admins"
} else {
    Set-ADAccountPassword -Identity "admin" -NewPassword (ConvertTo-SecureString $adminPassword -AsPlainText -Force) -Reset
    Set-ADUser -Identity "admin" -Enabled $true -PasswordNeverExpires $true
    if (-not (Get-ADGroupMember -Identity "Domain Admins" | Where-Object { $_.SamAccountName -eq "admin" })) {
        Add-ADGroupMember -Identity "Domain Admins" -Members "admin"
    }
    Write-Output "Converged existing admin account to documented state"
}

# web's computer account: Unconstrained Delegation.
$web = Get-ADComputer web -Properties TrustedForDelegation
if (-not $web.TrustedForDelegation) {
    Set-ADAccountControl -Identity "web$" -TrustedForDelegation $true
    Write-Output "Enabled Unconstrained Delegation on web$"
} else {
    Write-Output "Unconstrained Delegation already enabled on web$"
}
