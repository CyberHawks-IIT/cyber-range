[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath
)

$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory

$domainDN = (Get-ADDomain).DistinguishedName
$schemaNC = (Get-ADRootDSE).schemaNamingContext

$rows = Import-Csv -Path $CsvPath
function Get-PoolUser {
    param([string]$Role)
    $row = $rows | Where-Object { $_.role -eq $Role }
    if (-not $row) { throw "No pool account found with role '$Role'" }
    return $row.username
}

$userSid = New-Object System.Security.Principal.SecurityIdentifier((Get-ADUser user).SID)

function Get-AttributeGuid {
    param([string]$LdapDisplayName)
    $obj = Get-ADObject -SearchBase $schemaNC -Filter "lDAPDisplayName -eq '$LdapDisplayName'" -Properties schemaIDGUID
    if (-not $obj) { throw "Schema attribute '$LdapDisplayName' not found" }
    return New-Object Guid(, $obj.schemaIDGUID)
}

function Add-Ace {
    param(
        [Parameter(Mandatory = $true)][string]$TargetDN,
        [Parameter(Mandatory = $true)][System.DirectoryServices.ActiveDirectoryRights]$Rights,
        [Guid]$ObjectType = [Guid]::Empty,
        [string]$Label
    )
    $path = "AD:\$TargetDN"
    $acl = Get-Acl -Path $path

    $alreadyPresent = $acl.Access | Where-Object {
        $_.IdentityReference -eq $userSid.Translate([System.Security.Principal.NTAccount]) -and
        $_.ActiveDirectoryRights -eq $Rights -and
        $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
        $_.ObjectType -eq $ObjectType
    }
    if ($alreadyPresent) {
        Write-Output "Already present: $Label on $TargetDN"
        return
    }

    if ($ObjectType -ne [Guid]::Empty) {
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $userSid, $Rights, [System.Security.AccessControl.AccessControlType]::Allow, $ObjectType)
    } else {
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $userSid, $Rights, [System.Security.AccessControl.AccessControlType]::Allow)
    }
    $acl.AddAccessRule($rule)
    Set-Acl -Path $path -AclObject $acl
    Write-Output "Granted $Label on $TargetDN"
}

# 1. WriteDacl -> writedacl-target user
$writeDaclTarget = Get-ADUser (Get-PoolUser "writedacl_target")
Add-Ace -TargetDN $writeDaclTarget.DistinguishedName -Rights WriteDacl -Label "WriteDacl"

# 2. GenericWrite -> genericwrite-target user
$genericWriteTarget = Get-ADUser (Get-PoolUser "genericwrite_target")
Add-Ace -TargetDN $genericWriteTarget.DistinguishedName -Rights GenericWrite -Label "GenericWrite"

# 3. WriteProperty(msDS-KeyCredentialLink) -> computer3
$kcl = Get-AttributeGuid "msDS-KeyCredentialLink"
$computer3 = Get-ADComputer computer3
Add-Ace -TargetDN $computer3.DistinguishedName -Rights WriteProperty -ObjectType $kcl -Label "WriteProperty(msDS-KeyCredentialLink)"

# 4. WriteProperty(msDS-AllowedToActOnBehalfOfOtherIdentity) -> computer2
$rbcd = Get-AttributeGuid "msDS-AllowedToActOnBehalfOfOtherIdentity"
$computer2 = Get-ADComputer computer2
Add-Ace -TargetDN $computer2.DistinguishedName -Rights WriteProperty -ObjectType $rbcd -Label "WriteProperty(msDS-AllowedToActOnBehalfOfOtherIdentity)"

# 5. GenericAll -> Default Domain Policy GPO
$gpo = Get-ADObject -Filter "objectClass -eq 'groupPolicyContainer' -and displayName -eq 'Default Domain Policy'"
Add-Ace -TargetDN $gpo.DistinguishedName -Rights GenericAll -Label "GenericAll (Default Domain Policy GPO)"

# 6. Self on Domain Admins (AddSelf / Self-Membership validated write).
# Domain Admins is AdminSDHolder-protected -- an ACE added directly to it
# gets silently stripped by the hourly SDPROP background process. The
# durable, standard technique (also a well-known real-world persistence
# primitive) is to add the ACE to the AdminSDHolder template itself, so
# SDPROP propagates and keeps re-propagating it instead of removing it.
# Side effect: this also reaches every other AdminSDHolder-protected
# principal (Enterprise Admins, Schema Admins, Administrators, DCs, etc.),
# not just Domain Admins -- an expected consequence of the technique, not
# a bug, and realistic (this is exactly how such backdoors work for real).
$selfMembershipGuid = [Guid]"bf9679c0-0de6-11d0-a285-00aa003049e2"
$adminSDHolderDN = "CN=AdminSDHolder,CN=System,$domainDN"
Add-Ace -TargetDN $adminSDHolderDN -Rights Self -ObjectType $selfMembershipGuid -Label "Self (Self-Membership, via AdminSDHolder template)"

# Force SDPROP to run now rather than waiting up to 60 minutes for the
# scheduled interval, so the ACE actually lands on Domain Admins immediately.
# RootDSE is a pseudo-object not addressable via Get/Set-ADObject -- ADSI
# is the standard way to write its operational attributes.
$rootDSEAdsi = [ADSI]"LDAP://RootDSE"
$rootDSEAdsi.Put("runProtectAdminGroupsTask", 1)
$rootDSEAdsi.SetInfo()
Start-Sleep -Seconds 5
Write-Output "Triggered SDPROP (AdminSDHolder propagation) to run immediately"

# 7. ForceChangePassword -> forcechangepw-target user
$forceChangePwGuid = [Guid]"00299570-246d-11d0-a768-00aa006e0529"
$forceChangePwTarget = Get-ADUser (Get-PoolUser "forcechangepw_target")
Add-Ace -TargetDN $forceChangePwTarget.DistinguishedName -Rights ExtendedRight -ObjectType $forceChangePwGuid -Label "ForceChangePassword"

# 8. DCSync (Replicating Directory Changes + Changes All) -> domain root
$dsReplGetChanges = [Guid]"1131f6aa-9c07-11d1-f79f-00c04fc2dcd2"
$dsReplGetChangesAll = [Guid]"1131f6ad-9c07-11d1-f79f-00c04fc2dcd2"
Add-Ace -TargetDN $domainDN -Rights ExtendedRight -ObjectType $dsReplGetChanges -Label "DS-Replication-Get-Changes (DCSync)"
Add-Ace -TargetDN $domainDN -Rights ExtendedRight -ObjectType $dsReplGetChangesAll -Label "DS-Replication-Get-Changes-All (DCSync)"

# 9. WriteOwner -> writeowner-target user
$writeOwnerTarget = Get-ADUser (Get-PoolUser "writeowner_target")
Add-Ace -TargetDN $writeOwnerTarget.DistinguishedName -Rights WriteOwner -Label "WriteOwner"

Write-Output "DONE"
