$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory

$targetSpn = "cifs/dc1.cyberhawks.lab"

# sql1$: constrained delegation WITHOUT protocol transition.
$sql1 = Get-ADComputer sql1 -Properties "msDS-AllowedToDelegateTo", TrustedToAuthForDelegation
if ($sql1."msDS-AllowedToDelegateTo" -notcontains $targetSpn) {
    Set-ADComputer sql1 -Add @{ "msDS-AllowedToDelegateTo" = $targetSpn }
    Write-Output "Set msDS-AllowedToDelegateTo=$targetSpn on sql1$"
} else {
    Write-Output "sql1$ already has msDS-AllowedToDelegateTo=$targetSpn"
}
if ($sql1.TrustedToAuthForDelegation) {
    # Should stay OFF for sql1 -- this is the "no protocol transition" variant.
    Set-ADAccountControl -Identity "sql1$" -TrustedToAuthForDelegation $false
    Write-Output "Cleared TrustedToAuthForDelegation on sql1$ (must stay off for this variant)"
}

# sql2$: constrained delegation WITH protocol transition (T2A4D).
$sql2 = Get-ADComputer sql2 -Properties "msDS-AllowedToDelegateTo", TrustedToAuthForDelegation
if ($sql2."msDS-AllowedToDelegateTo" -notcontains $targetSpn) {
    Set-ADComputer sql2 -Add @{ "msDS-AllowedToDelegateTo" = $targetSpn }
    Write-Output "Set msDS-AllowedToDelegateTo=$targetSpn on sql2$"
} else {
    Write-Output "sql2$ already has msDS-AllowedToDelegateTo=$targetSpn"
}
if (-not $sql2.TrustedToAuthForDelegation) {
    Set-ADAccountControl -Identity "sql2$" -TrustedToAuthForDelegation $true
    Write-Output "Set TrustedToAuthForDelegation on sql2$ (T2A4D)"
} else {
    Write-Output "sql2$ already has TrustedToAuthForDelegation set"
}
