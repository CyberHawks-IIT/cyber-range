$ErrorActionPreference = "Stop"

# Same SYSTEM-scheduled-task pattern as configure_sacls_common.ps1 -- NTDS.dit
# is locked to SYSTEM only, and running as SYSTEM on a domain controller
# carries the domain's own authority for AD operations (the ActiveDirectory
# module works here the same as it would for a Domain Admin, no separate
# credential needed).
$innerScript = @'
$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory
$resultPath = "C:\Windows\Temp\sacl_dc_result.txt"
try {
    $everyone = New-Object System.Security.Principal.SecurityIdentifier("S-1-1-0")
    $lines = @()

    # NTDS.dit extraction detection (IFM / shadow-copy reads land here as
    # 4663, alongside the separate WMI-Activity VSS-creation signal that
    # catches the shadow-copy step itself).
    $ntdsPath = Join-Path $env:SystemRoot "NTDS\ntds.dit"
    if (Test-Path $ntdsPath) {
        $acl = Get-Acl -Path $ntdsPath -Audit
        $rule = New-Object System.Security.AccessControl.FileSystemAuditRule(
            $everyone, "FullControl", "None", "None", "Success,Failure")
        $acl.AddAuditRule($rule)
        Set-Acl -Path $ntdsPath -AclObject $acl
        $lines += "SACL set on $ntdsPath"
    } else {
        $lines += "WARNING: $ntdsPath not found (not an AD DS-holding DC?)"
    }

    # NETLOGON scripts folder -- feeds both the NETLOGON-creds-exposure
    # detection and the logon-script/ScriptPath-tampering detection (4663
    # write to the physical script file).
    $scriptsPath = Join-Path $env:SystemRoot "SYSVOL\domain\scripts"
    if (Test-Path $scriptsPath) {
        $acl = Get-Acl -Path $scriptsPath -Audit
        $rule = New-Object System.Security.AccessControl.FileSystemAuditRule(
            $everyone, "FullControl", "ContainerInherit,ObjectInherit", "None", "Success,Failure")
        $acl.AddAuditRule($rule)
        Set-Acl -Path $scriptsPath -AclObject $acl
        $lines += "SACL set on $scriptsPath"
    } else {
        $lines += "WARNING: $scriptsPath not found"
    }

    # Default Domain Policy GPO -- feeds the ACL/delegation-abuse detection
    # (5136 on nTSecurityDescriptor). "Directory Service Changes" auditing
    # requires an object-level SACL to actually fire, not just the
    # subcategory being on -- scoped to this one object rather than the
    # domain root, matching the range design's own minimalism (this is the
    # one GPO user already holds GenericAll on by design).
    $gpo = Get-ADObject -Filter "objectClass -eq 'groupPolicyContainer' -and displayName -eq 'Default Domain Policy'"
    if ($gpo) {
        $path = "AD:\$($gpo.DistinguishedName)"
        $acl = Get-Acl -Path $path
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAuditRule(
            $everyone,
            [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,
            [System.Security.AccessControl.AuditFlags]"Success,Failure")
        $acl.AddAuditRule($rule)
        Set-Acl -Path $path -AclObject $acl
        $lines += "SACL set on Default Domain Policy GPO ($($gpo.DistinguishedName))"
    } else {
        $lines += "WARNING: Default Domain Policy GPO object not found"
    }

    # DNS zone partition -- feeds the Attacker-added DNS record detection
    # (5137 directory service object created, under the zone). Confirmed
    # live 2026-09-27: "Directory Service Changes" auditing being on is not
    # enough by itself -- without ANY object SACL anywhere in the domain,
    # 5136/5137 never fire at all, not even for the Default Domain Policy
    # GPO change above (that SACL is what makes 5136 fire for it
    # specifically). Same principle applies here: scoped to the zone
    # object itself with ContainerInherit so every dnsNode record created
    # under it gets audited, not the domain root.
    $zone = Get-ADObject -Filter "objectClass -eq 'dnsZone' -and Name -eq 'cyberhawks.lab'" -SearchBase "DC=DomainDnsZones,DC=cyberhawks,DC=lab" -ErrorAction SilentlyContinue
    if ($zone) {
        $path = "AD:\$($zone.DistinguishedName)"
        $acl = Get-Acl -Path $path
        $rule = New-Object System.DirectoryServices.ActiveDirectoryAuditRule(
            $everyone,
            [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,
            [System.Security.AccessControl.AuditFlags]"Success,Failure",
            [System.DirectoryServices.ActiveDirectorySecurityInheritance]::All)
        $acl.AddAuditRule($rule)
        Set-Acl -Path $path -AclObject $acl
        $lines += "SACL set on DNS zone partition ($($zone.DistinguishedName))"
    } else {
        $lines += "WARNING: cyberhawks.lab DNS zone object not found under DomainDnsZones"
    }

    $lines | Out-File -FilePath $resultPath
} catch {
    "ERROR: $($_.Exception.Message)" | Out-File -FilePath $resultPath -Append
}
'@

$taskName = "SaclDc_$(Get-Random)"
$scriptPath = "C:\Windows\Temp\sacl_dc_task_script.ps1"
$resultPath = "C:\Windows\Temp\sacl_dc_result.txt"

Remove-Item -Path $resultPath -Force -ErrorAction SilentlyContinue
Set-Content -Path $scriptPath -Value $innerScript

schtasks /Create /TN $taskName /TR "powershell.exe -ExecutionPolicy Bypass -File $scriptPath" /SC ONCE /ST 00:00 /RU "SYSTEM" /RL HIGHEST /F | Out-Null
schtasks /Run /TN $taskName | Out-Null

$maxWait = 60
$waited = 0
while (-not (Test-Path $resultPath) -and $waited -lt $maxWait) {
    Start-Sleep -Seconds 2
    $waited += 2
}

schtasks /Delete /TN $taskName /F | Out-Null
Remove-Item -Path $scriptPath -Force -ErrorAction SilentlyContinue

if (-not (Test-Path $resultPath)) {
    throw "Scheduled task did not complete within $maxWait seconds"
}

$output = Get-Content $resultPath
Remove-Item -Path $resultPath -Force -ErrorAction SilentlyContinue
$output | Write-Output
if ($output -match "^ERROR:") {
    throw "DC SACL configuration task reported an error (see output above)"
}
