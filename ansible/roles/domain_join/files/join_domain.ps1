param(
    [Parameter(Mandatory = $true)][string]$DomainDnsName,
    [Parameter(Mandatory = $true)][string]$DomainAdminUser,
    [Parameter(Mandatory = $true)][string]$DomainAdminPassword
)

# Joins this host to the domain. Idempotent: no-ops if already joined to the
# target domain. Uses explicit domain credentials (NTLM double-hop, same
# reasoning as promote_dc.ps1).

$ErrorActionPreference = "Stop"

$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.PartOfDomain -and $cs.Domain -eq $DomainDnsName) {
    "RESULT=ok"
    return
}

$securePw = ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($DomainAdminUser, $securePw)

Add-Computer -DomainName $DomainDnsName -Credential $cred -Force | Out-Null
"RESULT=joined"
