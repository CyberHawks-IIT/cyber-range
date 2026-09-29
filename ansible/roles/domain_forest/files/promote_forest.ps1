param(
    [Parameter(Mandatory = $true)][string]$DomainDnsName,
    [Parameter(Mandatory = $true)][string]$DomainNetbiosName,
    [Parameter(Mandatory = $true)][string]$FunctionalLevel,
    [Parameter(Mandatory = $true)][string]$SafeModePassword
)

# Promotes this host to the forest-root domain controller of a new forest.
# Idempotent: if the machine is already a DC (DomainRole 4/5) it exits
# "unchanged" and does nothing. On a real promotion it emits RESULT=promoted
# and the Ansible task then reboots the host.

$ErrorActionPreference = "Stop"

$role = (Get-CimInstance Win32_ComputerSystem).DomainRole
if ($role -ge 4) {
    "RESULT=ok"
    return
}

Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools | Out-Null

$secure = ConvertTo-SecureString $SafeModePassword -AsPlainText -Force
Import-Module ADDSDeployment

# -NoRebootOnCompletion so Ansible controls the reboot (and can wait for the
# host to come back before the next play runs against it).
Install-ADDSForest `
    -DomainName $DomainDnsName `
    -DomainNetbiosName $DomainNetbiosName `
    -ForestMode $FunctionalLevel `
    -DomainMode $FunctionalLevel `
    -InstallDns `
    -SafeModeAdministratorPassword $secure `
    -NoRebootOnCompletion `
    -Force | Out-Null

"RESULT=promoted"
