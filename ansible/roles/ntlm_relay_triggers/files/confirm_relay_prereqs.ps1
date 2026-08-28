$ErrorActionPreference = "Stop"

# --- LDAP relay path: make sure the DC's own LDAP service doesn't block a
# relayed NTLM authentication with signing/channel-binding requirements. ---
$ntdsParams = "HKLM:\SYSTEM\CurrentControlSet\Services\NTDS\Parameters"
$integrity = (Get-ItemProperty -Path $ntdsParams -Name LDAPServerIntegrity -ErrorAction SilentlyContinue).LDAPServerIntegrity
$channelBinding = (Get-ItemProperty -Path $ntdsParams -Name LdapEnforceChannelBinding -ErrorAction SilentlyContinue).LdapEnforceChannelBinding
if ($integrity -ne 1 -or $channelBinding -ne 0) {
    New-ItemProperty -Path $ntdsParams -Name "LDAPServerIntegrity" -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $ntdsParams -Name "LdapEnforceChannelBinding" -PropertyType DWord -Value 0 -Force | Out-Null
    Write-Output "LDAP signing not required, channel binding not enforced (changed, restart needed)"
} else {
    Write-Output "LDAP signing/channel-binding already permissive"
}

# --- LLMNR: "Turn off Multicast Name Resolution" policy. Default is Not
# Configured (LLMNR enabled); confirm nothing has switched it off. ---
$llmnrPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"
if (Test-Path $llmnrPath) {
    $val = (Get-ItemProperty -Path $llmnrPath -Name EnableMulticast -ErrorAction SilentlyContinue).EnableMulticast
    if ($null -ne $val -and $val -eq 0) {
        Set-ItemProperty -Path $llmnrPath -Name EnableMulticast -Value 1
        Write-Output "LLMNR was disabled via policy -- re-enabled"
    } else {
        Write-Output "LLMNR already enabled"
    }
} else {
    Write-Output "LLMNR policy not configured (enabled by default)"
}

# --- mDNS: confirm the DNS client's multicast DNS responder isn't disabled. ---
$mdnsPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters"
$mdnsVal = (Get-ItemProperty -Path $mdnsPath -Name EnableMDNS -ErrorAction SilentlyContinue).EnableMDNS
if ($null -ne $mdnsVal -and $mdnsVal -eq 0) {
    Set-ItemProperty -Path $mdnsPath -Name EnableMDNS -Value 1
    Write-Output "mDNS was disabled -- re-enabled"
} else {
    Write-Output "mDNS already enabled"
}

# --- NBT-NS: confirm no adapter has NetBIOS explicitly disabled (2). ---
$disabledAdapters = Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" |
    Where-Object { $_.TcpipNetbiosOptions -eq 2 }
if ($disabledAdapters) {
    foreach ($a in $disabledAdapters) {
        Set-CimInstance -InputObject $a -Property @{ TcpipNetbiosOptions = 0 }
    }
    Write-Output "NBT-NS was disabled on one or more adapters -- reset to default (enabled)"
} else {
    Write-Output "NBT-NS already enabled (or default) on every adapter"
}

Write-Output "DONE"
