$ErrorActionPreference = "Stop"

# Certificate Services auditing -- off by default (Object Access category).
# Needed for the ADCS RPC/ICPR issuance detection (ESC1-4,6,7,9,10,13,15-17)
# in splunk-detections/detections/backlog.md, which keys off CA Security-log
# events 4886-4899. Confirmed live before this script existed: the
# "Certification Services" subcategory was "No Auditing" and CA\AuditFilter
# didn't exist at all. This lands in ca's own Security log -- no new
# forwarder config needed, defense-tooling's Windows forwarder already ships
# that log.

$auditState = (auditpol /get /subcategory:"Certification Services" /r | ConvertFrom-Csv).'Inclusion Setting'
if ($auditState -ne "Success and Failure") {
    auditpol /set /subcategory:"Certification Services" /success:enable /failure:enable | Out-Null
    Write-Output "Enabled Certification Services auditing (success+failure)"
} else {
    Write-Output "Certification Services auditing already enabled"
}

# CA\AuditFilter is a CertSvc-specific bitmask (not a normal audit-policy
# control), stored in CertSvc's own registry config:
# 1=start/stop service, 2=backup/restore, 4=issue/manage requests,
# 8=revoke certs/publish CRLs, 16=change CA security settings,
# 32=archive key operations, 64=change CA configuration. 127 = all of these.
$currentFilter = certutil -getreg "CA\AuditFilter" 2>&1 | Out-String
$filterChanged = $false
if ($currentFilter -notmatch "AuditFilter REG_DWORD = 7f \(127\)") {
    certutil -setreg "CA\AuditFilter" 127 | Out-Null
    Write-Output "Set CA\AuditFilter to 127 (audit everything)"
    $filterChanged = $true
} else {
    Write-Output "CA\AuditFilter already set to 127"
}

# Only AuditFilter needs a service restart to take effect -- the auditpol
# subcategory setting above is an LSA-wide policy that applies immediately.
if ($filterChanged) {
    Restart-Service CertSvc -Force
    Start-Sleep -Seconds 5
    Write-Output "Restarted CertSvc for the AuditFilter change to take effect"
}
