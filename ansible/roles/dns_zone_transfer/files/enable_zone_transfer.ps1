$ErrorActionPreference = "Stop"
Import-Module DnsServer

$zoneName = "cyberhawks.lab"
$zone = Get-DnsServerZone -Name $zoneName

if ($zone.SecureSecondaries -ne "TransferAnyServer") {
    Set-DnsServerPrimaryZone -Name $zoneName -SecureSecondaries "TransferAnyServer"
    Write-Output "Enabled unrestricted zone transfer (AXFR) on $zoneName"
} else {
    Write-Output "Zone transfer already unrestricted on $zoneName"
}

Write-Output "DONE"
