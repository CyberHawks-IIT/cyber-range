$ErrorActionPreference = "Stop"

# "1644" is Directory-Service diagnostic logging for expensive/inefficient
# LDAP searches. With Field Engineering at 5 and all three thresholds at 1,
# every LDAP search that touches the directory -- plain LDAP, LDAPS, and ADWS
# (which runs its searches over loopback, so it logs client [::1] plus the
# real remote user) -- logs its full filter, base DN, requested attributes,
# bind user, and client IP:port. This is the log-everything layer the LDAP
# Query detection in splunk-detections correlates back to Zeek conn.log.
#
# The thresholds MUST be 1, not 0: 0 means "use the default" (Search Time
# 30000 ms, Expensive 10000 visited, Inefficient 1000 visited), which
# silently limits logging to slow/unindexed searches -- confirmed live
# 2026-09-29, when indexed filters like (sAMAccountName=x) and
# (servicePrincipalName=*) produced no 1644 at all. At 1, a single-object
# indexed lookup (1 entry visited) logs. No NTDS restart is needed; the
# thresholds are read live. The anonymous RootDSE read (base scope, empty
# base DN) never logs -- it isn't a directory search.
# New-Item -Force on an EXISTING key deletes and recreates the whole subtree
# rather than updating in place (confirmed live -- see configure_audit_policy.ps1's
# comment on the same gotcha). NTDS\Diagnostics always exists once AD DS is
# installed, so guard with Test-Path instead of ever calling -Force on it.
if (-not (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Diagnostics")) {
    New-Item -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Diagnostics" | Out-Null
}
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Diagnostics" -Name "15 Field Engineering" -Value 5 -Type DWord

Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" -Name "Search Time Threshold (msecs)" -Value 1 -Type DWord
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" -Name "Expensive Search Results Threshold" -Value 1 -Type DWord
Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters" -Name "Inefficient Search Results Threshold" -Value 1 -Type DWord

# With every search logging, the Directory Service log fills fast on a DC
# with any real traffic. Cap it and let it overwrite the oldest events rather
# than fill and stop; the local copy only needs to survive long enough for
# the forwarder to ship 1644 events off-box.
wevtutil sl "Directory Service" /ms:104857600 /rt:false

Write-Output "DONE"
