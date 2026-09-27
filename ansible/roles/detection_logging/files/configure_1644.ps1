$ErrorActionPreference = "Stop"

# "1644" is Directory-Service diagnostic logging for expensive/inefficient
# LDAP searches. With Field Engineering enabled and both thresholds forced to
# 0, every LDAP search -- not just genuinely expensive ones -- logs its full
# filter, base DN, requested attributes, and client IP. This is the
# log-everything layer the LDAP/LDAPS/ADWS enumeration detections in
# splunk-detections/detections/backlog.md correlate back to once Zeek's
# ldap.log or conn.log flags a suspicious source.
# New-Item -Force on an EXISTING key deletes and recreates the whole subtree
# rather than updating in place (confirmed live -- see configure_audit_policy.ps1's
# comment on the same gotcha). NTDS\Diagnostics always exists once AD DS is
# installed, so guard with Test-Path instead of ever calling -Force on it.
if (-not (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Diagnostics")) {
    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Diagnostics" | Out-Null
}
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Diagnostics" -Name "15 Field Engineering" -Value 5 -Type DWord

Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" -Name "Search Time Threshold (msecs)" -Value 0 -Type DWord
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" -Name "Expensive Search Results Threshold" -Value 0 -Type DWord

# At threshold 0, every query logs -- on a DC with any real traffic that
# fills the Directory Service log fast. Cap it and let it overwrite the
# oldest events rather than fill and stop, per the backlog's own
# volume-management note; the local copy only needs to survive long enough
# for a forwarder to ship 1644 events off-box (that forwarding is step 3 of
# the rollout plan, not yet built).
wevtutil sl "Directory Service" /ms:104857600 /rt:false

Write-Output "DONE"
