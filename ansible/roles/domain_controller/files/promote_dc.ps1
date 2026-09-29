param(
    [Parameter(Mandatory = $true)][string]$DomainDnsName,
    [Parameter(Mandatory = $true)][string]$DomainAdminUser,
    [Parameter(Mandatory = $true)][string]$DomainAdminPassword,
    [Parameter(Mandatory = $true)][string]$SafeModePassword
)

# Promotes this host as an ADDITIONAL domain controller in an existing forest.
# Idempotent: no-ops if already a DC. Passes explicit domain credentials to
# Install-ADDSDomainController so its AD writes to the existing forest use
# those creds directly (this control node is not domain-joined, so the WinRM
# logon token is NTLM and cannot be delegated for that second hop -- see
# CLAUDE.md's "WinRM double-hop" note).

$ErrorActionPreference = "Stop"

$role = (Get-CimInstance Win32_ComputerSystem).DomainRole
if ($role -ge 4) {
    "RESULT=ok"
    return
}

Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null

$secureSafe = ConvertTo-SecureString $SafeModePassword -AsPlainText -Force
$securePw = ConvertTo-SecureString $DomainAdminPassword -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential($DomainAdminUser, $securePw)

Import-Module ADDSDeployment
Install-ADDSDomainController `
    -DomainName $DomainDnsName `
    -Credential $cred `
    -InstallDns `
    -SafeModeAdministratorPassword $secureSafe `
    -NoRebootOnCompletion `
    -Force | Out-Null

"RESULT=promoted"
