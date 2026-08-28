$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory

# --- ANONYMOUS LOGON in Pre-Windows 2000 Compatible Access (null-session enumeration) ---
# ANONYMOUS LOGON (S-1-5-7) isn't a resolvable AD object, so Add-ADGroupMember's
# identity validation rejects it outright. AD auto-creates a
# ForeignSecurityPrincipal object on the fly for a well-known SID referenced
# this way -- add it directly via the group's member attribute instead.
$groupDN = "CN=Pre-Windows 2000 Compatible Access,CN=Builtin,DC=cyberhawks,DC=lab"
$fspDN = "CN=S-1-5-7,CN=ForeignSecurityPrincipals,DC=cyberhawks,DC=lab"
$currentMembers = (Get-ADObject -Identity $groupDN -Properties member).member
if ($currentMembers -notcontains $fspDN) {
    # ANONYMOUS LOGON (S-1-5-7) isn't a resolvable AD object, so both
    # Add-ADGroupMember and New-ADObject('foreignSecurityPrincipal') reject
    # it (the module validates identities client-side; AD itself blocks
    # direct FSP creation as a DSA-internal special case normally only
    # triggered via ADUC's well-known-SID picker). Raw ADSI PutEx using the
    # "<SID=...>" distinguished-name-by-SID syntax goes around both and
    # lets AD auto-vivify the FSP object as a side effect of the write.
    $groupEntry = [ADSI]"LDAP://$groupDN"
    $groupEntry.PutEx(3, "member", @("<SID=S-1-5-7>")) # 3 = ADS_PROPERTY_APPEND
    $groupEntry.SetInfo()
    Write-Output "Added ANONYMOUS LOGON to Pre-Windows 2000 Compatible Access"
} else {
    Write-Output "ANONYMOUS LOGON already in Pre-Windows 2000 Compatible Access"
}

# --- computer4: stale, pre-2k default password (lowercase of its own name) ---
$c4Password = "computer4"
Set-ADAccountPassword -Identity "computer4$" -NewPassword (ConvertTo-SecureString $c4Password -AsPlainText -Force) -Reset
Write-Output "Set computer4's password to its pre-2k default (lowercase name)"

# --- computer5: stale, blank password ---
# Set-ADAccountPassword enforces a non-empty string; use the raw LDAP
# unicodePwd attribute (empty quoted UTF-16LE) plus PASSWD_NOTREQD to
# actually get a genuinely blank password, matching real legacy behavior.
$c5 = Get-ADComputer "computer5"
Set-ADObject -Identity $c5.DistinguishedName -Replace @{ userAccountControl = 4128 } # WORKSTATION_TRUST_ACCOUNT (4096) + PASSWD_NOTREQD (32)
$deObj = [ADSI]"LDAP://$($c5.DistinguishedName)"
$deObj.Invoke("SetPassword", "")
$deObj.CommitChanges()
Write-Output "Set computer5's password to blank"
