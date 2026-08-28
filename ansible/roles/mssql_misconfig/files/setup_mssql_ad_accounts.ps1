$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory

$svcPassword = $env:SVC_MSSQL_PASSWORD
$crackmePassword = "iloveyou"
if (-not $svcPassword) { throw "SVC_MSSQL_PASSWORD environment variable not set" }

# svc-mssql: shared domain service account for both sql1 and sql2 instances.
if (-not (Get-ADUser -Filter "SamAccountName -eq 'svc-mssql'" -ErrorAction SilentlyContinue)) {
    $secure = ConvertTo-SecureString $svcPassword -AsPlainText -Force
    New-ADUser -Name "svc-mssql" -SamAccountName "svc-mssql" -UserPrincipalName "svc-mssql@cyberhawks.lab" `
        -AccountPassword $secure -Enabled $true -PasswordNeverExpires $true -ChangePasswordAtLogon $false
    Write-Output "Created svc-mssql account"
} else {
    Set-ADAccountPassword -Identity "svc-mssql" -NewPassword (ConvertTo-SecureString $svcPassword -AsPlainText -Force) -Reset
    Set-ADUser -Identity "svc-mssql" -Enabled $true -PasswordNeverExpires $true
    Write-Output "Converged existing svc-mssql account"
}

# SQL Server running under a domain USER account (unlike a computer account)
# can't self-register its own SPN -- without this, Kerberos auth for the
# service fails and OLE DB linked-server calls silently fall back to
# NT AUTHORITY\ANONYMOUS LOGON instead of the intended shared-identity
# escalation. Register both instances' SPNs explicitly.
$svcSpns = (Get-ADUser svc-mssql -Properties ServicePrincipalNames).ServicePrincipalNames
foreach ($spn in @("MSSQLSvc/sql1.cyberhawks.lab:1433", "MSSQLSvc/sql2.cyberhawks.lab:1433")) {
    if ($svcSpns -notcontains $spn) {
        Set-ADUser -Identity "svc-mssql" -ServicePrincipalNames @{Add = $spn }
        Write-Output "Added SPN $spn to svc-mssql"
    } else {
        Write-Output "svc-mssql already has SPN $spn"
    }
}

# crackme: standalone Kerberoastable account, RC4 allowed, password iloveyou.
if (-not (Get-ADUser -Filter "SamAccountName -eq 'crackme'" -ErrorAction SilentlyContinue)) {
    $secure = ConvertTo-SecureString $crackmePassword -AsPlainText -Force
    New-ADUser -Name "crackme" -SamAccountName "crackme" -UserPrincipalName "crackme@cyberhawks.lab" `
        -AccountPassword $secure -Enabled $true -PasswordNeverExpires $true -ChangePasswordAtLogon $false
    Write-Output "Created crackme account"
} else {
    Write-Output "crackme account already exists"
}
$targetSpn = "MSSQLSvc/crackme.cyberhawks.lab:1433"
$existingSpns = (Get-ADUser crackme -Properties ServicePrincipalNames).ServicePrincipalNames
if ($existingSpns -notcontains $targetSpn) {
    Set-ADUser -Identity "crackme" -ServicePrincipalNames @{Add = $targetSpn }
    Write-Output "Added SPN $targetSpn to crackme"
} else {
    Write-Output "crackme already has SPN $targetSpn"
}
Set-ADUser -Identity "crackme" -Replace @{"msDS-SupportedEncryptionTypes" = 4 }  # RC4-HMAC only, guarantees crackability
Write-Output "Set crackme's supported encryption types to RC4-only"
