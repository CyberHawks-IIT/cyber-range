$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory

$configNC = (Get-ADRootDSE).configurationNamingContext
$templatesContainer = "CN=Certificate Templates,CN=Public Key Services,CN=Services,$configNC"
$oidContainer = "CN=OID,CN=Public Key Services,CN=Services,$configNC"
$domainDN = (Get-ADDomain).DistinguishedName
$domainUsersSid = New-Object System.Security.Principal.SecurityIdentifier((Get-ADGroup "Domain Users").SID)

$ENROLL_GUID = [Guid]"0e10c968-78fb-11d2-90d4-00c04f79dc55"
$AUTOENROLL_GUID = [Guid]"a05b8cc2-17bc-4802-a710-e7c15ab866a2"
$CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT = 1
$CT_FLAG_NO_SECURITY_EXTENSION = 0x80000

$EKU_CLIENT_AUTH = "1.3.6.1.5.5.7.3.2"
$EKU_SERVER_AUTH = "1.3.6.1.5.5.7.3.1"
$EKU_CERT_REQUEST_AGENT = "1.3.6.1.4.1.311.20.2.1"
$EKU_ANY_PURPOSE = "2.5.29.37.0"

# Base OID arc discovered on this CA -- new template OIDs just need to be
# unique, not derived via Microsoft's exact internal algorithm.
$baseTemplate = Get-ADObject -SearchBase $templatesContainer -Filter "Name -eq 'User'" -Properties *
$oidPrefix = ($baseTemplate."msPKI-Cert-Template-OID" -replace '\.\d+$', '')

function New-VulnTemplate {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$OidSuffix,
        [int]$NameFlag = 0,
        [int]$EnrollmentFlagAdd = 0,
        [string[]]$Ekus = @($EKU_CLIENT_AUTH),
        [string]$EnrollGroup = "Domain Users"
    )

    $existing = Get-ADObject -SearchBase $templatesContainer -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Output "$Name already exists, skipping creation"
        return
    }

    $newDN = "CN=$Name,$templatesContainer"
    $newOid = "$oidPrefix.$OidSuffix"

    # Copy only the known pKICertificateTemplate schema attributes (not
    # every returned property -- many are read-only/computed and New-ADObject
    # will reject them). This preserves tricky byte-array fields like
    # pKIExpirationPeriod/pKIOverlapPeriod exactly rather than hand-rolling
    # them, per the known gotcha with those FILETIME-interval fields.
    $copyableAttrs = @(
        "flags", "pKIDefaultKeySpec", "pKIKeyUsage", "pKIMaxIssuingDepth",
        "pKICriticalExtensions", "pKIExpirationPeriod", "pKIOverlapPeriod",
        "pKIDefaultCSPs", "msPKI-Minimal-Key-Size", "msPKI-Template-Schema-Version",
        "msPKI-Template-Minor-Revision", "msPKI-Private-Key-Flag",
        "msPKI-Certificate-Application-Policy", "msPKI-RA-Application-Policies",
        "msPKI-Enrollment-Flag", "msPKI-Certificate-Name-Flag"
    )
    $srcProps = @{}
    foreach ($p in $copyableAttrs) {
        if ($null -ne $baseTemplate.$p) { $srcProps[$p] = $baseTemplate.$p }
    }

    $newObj = New-ADObject -Name $Name -Type "pKICertificateTemplate" -Path $templatesContainer -OtherAttributes $srcProps -PassThru

    $enrollmentFlag = [int]$srcProps["msPKI-Enrollment-Flag"] -bor $EnrollmentFlagAdd
    Set-ADObject -Identity $newObj -Replace @{
        "displayName"                  = $Name
        "msPKI-Cert-Template-OID"      = $newOid
        "msPKI-Certificate-Name-Flag"  = $NameFlag
        "msPKI-Enrollment-Flag"        = $enrollmentFlag
        "msPKI-RA-Signature"           = 0
        "pKIExtendedKeyUsage"          = $Ekus
        "revision"                     = 100
    }

    # Grant Enroll to the given low-priv group.
    $acl = Get-Acl -Path "AD:\$newDN"
    $groupSid = New-Object System.Security.Principal.SecurityIdentifier((Get-ADGroup $EnrollGroup).SID)
    $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $groupSid, "ExtendedRight", "Allow", $ENROLL_GUID)
    $acl.AddAccessRule($rule)
    Set-Acl -Path "AD:\$newDN" -AclObject $acl

    Write-Output "Created $Name (OID $newOid, Enroll granted to $EnrollGroup)"
}

# ESC1: enrollee supplies subject + client auth EKU -> impersonate anyone.
New-VulnTemplate -Name "ESC1Template" -OidSuffix 101 -NameFlag $CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT -Ekus @($EKU_CLIENT_AUTH)

# ESC2: Any Purpose EKU.
New-VulnTemplate -Name "ESC2Template" -OidSuffix 102 -Ekus @($EKU_ANY_PURPOSE)

# ESC3: Certificate Request Agent EKU, no RA signature required to enroll.
New-VulnTemplate -Name "ESC3Template" -OidSuffix 103 -Ekus @($EKU_CERT_REQUEST_AGENT)

# ESC4: cert-issuance settings stay benign (same as User); the vulnerability
# is an ACE on the template's OWN ACL, added separately below.
New-VulnTemplate -Name "ESC4Template" -OidSuffix 104 -Ekus @($EKU_CLIENT_AUTH)

# ESC9: NO_SECURITY_EXTENSION, Enroll to Domain Computers (see MAQ note in
# the plan -- any domain user can self-create a computer account to reach
# this without a dedicated ACL grant).
New-VulnTemplate -Name "ESC9Template" -OidSuffix 109 -EnrollmentFlagAdd $CT_FLAG_NO_SECURITY_EXTENSION -Ekus @($EKU_CLIENT_AUTH) -EnrollGroup "Domain Computers"

# ESC13: cert-issuance settings benign; msPKI-Certificate-Policy + the OID
# group-link object are added separately below.
New-VulnTemplate -Name "ESC13Template" -OidSuffix 113 -Ekus @($EKU_CLIENT_AUTH)

# ESC15 ("EKUwu"): schema v1 (inherited from the User base, no
# msPKI-Certificate-Application-Policy attribute) + enrollee supplies
# subject. The template's own EKU barely matters since the whole technique
# lets the requester override it at request time.
New-VulnTemplate -Name "ESC15Template" -OidSuffix 115 -NameFlag $CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT -Ekus @($EKU_CLIENT_AUTH)

# ESC17: server-auth EKU + enrollee supplies subject (SAN injection for
# server certs instead of client-auth certs).
New-VulnTemplate -Name "ESC17Template" -OidSuffix 117 -NameFlag $CT_FLAG_ENROLLEE_SUPPLIES_SUBJECT -Ekus @($EKU_SERVER_AUTH)

# --- ESC4: WriteOwner/WriteDacl/GenericWrite on the template's own ACL ---
$esc4DN = "CN=ESC4Template,$templatesContainer"
$acl = Get-Acl -Path "AD:\$esc4DN"
$domainUsersSid = New-Object System.Security.Principal.SecurityIdentifier((Get-ADGroup "Domain Users").SID)
foreach ($right in @("WriteOwner", "WriteDacl", "GenericWrite")) {
    $already = $acl.Access | Where-Object { $_.IdentityReference -eq $domainUsersSid.Translate([System.Security.Principal.NTAccount]) -and $_.ActiveDirectoryRights -eq $right }
    if (-not $already) {
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($domainUsersSid, $right, "Allow")
        $acl.AddAccessRule($rule)
    }
}
Set-Acl -Path "AD:\$esc4DN" -AclObject $acl
Write-Output "Granted WriteOwner/WriteDacl/GenericWrite on ESC4Template to Domain Users"

# --- ESC13: OID object linked to Domain Admins ---
# Leaf OID object names follow AD's own convention:
# "<oid-last-component>.<32-hex-uppercase-GUID-no-dashes>".
$esc13OidSuffix = 213
$esc13OidGuidPart = ([Guid]::NewGuid().ToString("N")).ToUpper()
$esc13OidCn = "$esc13OidSuffix.$esc13OidGuidPart"
$esc13OidValue = "$oidPrefix.$esc13OidSuffix"
# msDS-OIDToGroupLink requires (a) a Universal-scope group -- Domain Admins
# is Global scope, rejected with a misleading "specified group type is
# invalid" error -- and (b) that group must have NO members, since
# membership is conferred purely via the certificate/OID, not both at once
# ("OID mapped groups cannot have members"). Enterprise Admins already has
# Administrator as a member by default, so it can't be linked directly
# either. Standard fix: a new, empty, Universal-scope group holds the link,
# and is itself nested inside Enterprise Admins (Universal-in-Universal
# nesting is valid) for the actual forest-wide privilege.
$linkGroupName = "ESC13-Escalation"
$linkGroup = Get-ADGroup -Filter "Name -eq '$linkGroupName'" -ErrorAction SilentlyContinue
if (-not $linkGroup) {
    $linkGroup = New-ADGroup -Name $linkGroupName -GroupScope Universal -GroupCategory Security -PassThru
    Write-Output "Created empty Universal group $linkGroupName"
}
$entAdmins = Get-ADGroup "Enterprise Admins"
if (-not (Get-ADGroupMember -Identity $entAdmins | Where-Object { $_.SID -eq $linkGroup.SID })) {
    Add-ADGroupMember -Identity $entAdmins -Members $linkGroup
    Write-Output "Nested $linkGroupName inside Enterprise Admins"
}

$existingOid = Get-ADObject -SearchBase $oidContainer -Filter "Name -eq '$esc13OidCn'" -ErrorAction SilentlyContinue
if (-not $existingOid) {
    $oidObj = New-ADObject -Name $esc13OidCn -Type "msPKI-Enterprise-Oid" -Path $oidContainer -OtherAttributes @{
        "displayName"              = "ESC13 Issuance Policy"
        "msPKI-Cert-Template-OID"  = $esc13OidValue
        "flags"                    = 2
        "msDS-OIDToGroupLink"      = $linkGroup.DistinguishedName
    } -PassThru
    Set-ADObject -Identity "CN=ESC13Template,$templatesContainer" -Replace @{ "msPKI-Certificate-Policy" = $esc13OidValue }
    Write-Output "Created ESC13 issuance-policy OID $esc13OidValue linked to $linkGroupName (nested in Enterprise Admins)"
} else {
    Write-Output "ESC13 OID object already exists"
}

# --- ESC5: excess rights (WriteDacl/GenericWrite) on NTAuthCertificates ---
# Run from dc1 rather than ca: cross-machine ADWS calls from ca to the DCs
# were unreliable (TCP/firewall/service all checked out fine, but the
# ADWS application-layer exchange itself failed) -- this is a pure AD
# object edit anyway, no reason it needs to run on ca specifically.
$ntAuthDN = "CN=NTAuthCertificates,CN=Public Key Services,CN=Services,$configNC"
$ntAuthAcl = Get-Acl -Path "AD:\$ntAuthDN"
foreach ($right in @("WriteDacl", "GenericWrite")) {
    $already = $ntAuthAcl.Access | Where-Object { $_.IdentityReference -eq $domainUsersSid.Translate([System.Security.Principal.NTAccount]) -and $_.ActiveDirectoryRights -eq $right }
    if (-not $already) {
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($domainUsersSid, $right, "Allow")
        $ntAuthAcl.AddAccessRule($rule)
    }
}
Set-Acl -Path "AD:\$ntAuthDN" -AclObject $ntAuthAcl
Write-Output "ESC5: granted WriteDacl/GenericWrite on NTAuthCertificates to Domain Users"

Write-Output "DOMAIN_USERS_SID=$($domainUsersSid.Value)"
Write-Output "DONE"
