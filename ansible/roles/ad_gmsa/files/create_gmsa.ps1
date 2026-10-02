$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory

# Finding: a group Managed Service Account (gMSA) whose managed password the
# low-priv starter account 'user' is allowed to retrieve
# (PrincipalsAllowedToRetrieveManagedPassword -> user). This is the classic
# ReadGMSAPassword abuse: user reads msDS-ManagedPassword over a sealed LDAP
# bind, derives the gMSA's NT hash from the blob, and authenticates as
# gmsa-backup$ -- which is a local admin on ca (granted separately in
# grant_local_admin.yml), making the retrieval worth something.
#
# Distinct, non-overlapping target per the design rules: the gMSA is a brand
# new account (never a starter), and ca is handed to nobody else (ca's own
# local admin is LAPS-only). It converges on ca compromise by a different path
# than ca's LAPS, the same intentional convergence pattern used elsewhere.

$gmsaName = 'gmsa-backup'
$gmsaDns  = 'gmsa-backup.cyberhawks.lab'

# 1. gMSAs require a KDS root key. Create one backdated 10 hours if none
#    exists, so it is immediately usable (the normal 10h propagation wait is
#    only to guarantee all DCs have replicated it; backdating is the standard
#    lab/single-forest shortcut).
if (-not (Get-KdsRootKey -ErrorAction SilentlyContinue)) {
    Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10)) | Out-Null
    Write-Output "Created backdated KDS root key"
} else {
    Write-Output "KDS root key already present"
}

$u = Get-ADUser user

$existing = Get-ADServiceAccount -Filter "Name -eq '$gmsaName'" -ErrorAction SilentlyContinue
if (-not $existing) {
    New-ADServiceAccount -Name $gmsaName `
        -DNSHostName $gmsaDns `
        -PrincipalsAllowedToRetrieveManagedPassword $u.DistinguishedName `
        -Description 'CyberHawks backup service account (group-managed)' `
        -ManagedPasswordIntervalInDays 30
    Write-Output "Created gMSA $gmsaName"
} else {
    # Idempotent: make sure 'user' is (still) allowed to retrieve the password.
    Set-ADServiceAccount -Identity $gmsaName `
        -PrincipalsAllowedToRetrieveManagedPassword $u.DistinguishedName
    Write-Output "gMSA $gmsaName already exists -- reasserted retrieve permission for user"
}

$g = Get-ADServiceAccount $gmsaName -Properties PrincipalsAllowedToRetrieveManagedPassword
Write-Output ("allowed-to-retrieve: " + (($g.PrincipalsAllowedToRetrieveManagedPassword) -join '; '))
