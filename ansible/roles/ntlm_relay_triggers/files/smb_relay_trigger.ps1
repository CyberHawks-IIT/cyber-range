# Simulates a scheduled backup job checking a legacy file server mount over
# SMB. The hostname is deliberately a bare, unqualified name with no DNS
# record -- cyberhawks.lab's own DC is authoritative for the full
# "*.cyberhawks.lab" zone, so an FQDN here would get a definitive
# authoritative NXDOMAIN and Windows would never fall back to broadcast
# resolution. A single-label name still fails DNS (via suffix search) but
# *does* fall through to LLMNR/NBT-NS/mDNS afterward -- whoever answers
# that broadcast gets a live NTLMv2 authentication attempt from this task's
# Run As identity, which is a local admin elsewhere in the range and so is
# worth relaying onward rather than just cracking offline.
try {
    Get-ChildItem -Path "\\backupsvc\sync\" -ErrorAction Stop | Out-Null
} catch {
    # Expected to fail every time -- the outbound NTLM auth attempt is the
    # point, not a successful directory listing.
}
