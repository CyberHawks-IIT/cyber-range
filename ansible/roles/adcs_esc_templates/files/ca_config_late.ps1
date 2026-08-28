$ErrorActionPreference = "Stop"

# ESC6: EDITF_ATTRIBUTESUBJECTALTNAME2 -- CA-wide SAN injection via request
# attribute, independent of ENROLLEE_SUPPLIES_SUBJECT. Deliberately applied
# LAST (after ESC1 is independently verified) since this retroactively makes
# every other client-auth template on this CA SAN-injectable too.
$editFlags = certutil -getreg "policy\EditFlags" 2>&1 | Out-String
if ($editFlags -notmatch "EDITF_ATTRIBUTESUBJECTALTNAME2") {
    certutil -setreg "policy\EditFlags" +EDITF_ATTRIBUTESUBJECTALTNAME2 | Out-Null
    Restart-Service CertSvc -Force
    Start-Sleep -Seconds 5
    Write-Output "ESC6: enabled EDITF_ATTRIBUTESUBJECTALTNAME2 and restarted CertSvc"
} else {
    Write-Output "ESC6: EDITF_ATTRIBUTESUBJECTALTNAME2 already enabled"
}

# ESC16: disable the SID security extension CA-wide (szOID_NTDS_CA_SECURITY_EXT).
# Deliberately applied LAST of all -- this makes ESC9Template's own
# per-template flag redundant domain-wide, so ESC9 must be verified working
# off its own setting before this lands.
$disableExtList = certutil -getreg "policy\DisableExtensionList" 2>&1 | Out-String
if ($disableExtList -notmatch "1\.3\.6\.1\.4\.1\.311\.25\.2") {
    certutil -setreg "policy\DisableExtensionList" "1.3.6.1.4.1.311.25.2" | Out-Null
    Restart-Service CertSvc -Force
    Start-Sleep -Seconds 5
    Write-Output "ESC16: added szOID_NTDS_CA_SECURITY_EXT to DisableExtensionList and restarted CertSvc"
} else {
    Write-Output "ESC16: szOID_NTDS_CA_SECURITY_EXT already in DisableExtensionList"
}
