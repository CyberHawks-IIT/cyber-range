$ErrorActionPreference = "Stop"

# ESC9: StrongCertificateBindingEnforcement must be 0 or 1 (not 2) for the
# NO_SECURITY_EXTENSION template flag to actually be exploitable.
$kdcPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Kdc"
$current = Get-ItemProperty -Path $kdcPath -Name "StrongCertificateBindingEnforcement" -ErrorAction SilentlyContinue
if (-not $current -or $current.StrongCertificateBindingEnforcement -eq 2) {
    New-ItemProperty -Path $kdcPath -Name "StrongCertificateBindingEnforcement" -PropertyType DWord -Value 1 -Force | Out-Null
    Write-Output "ESC9: set StrongCertificateBindingEnforcement=1 on $env:COMPUTERNAME"
} else {
    Write-Output "ESC9: StrongCertificateBindingEnforcement already $($current.StrongCertificateBindingEnforcement) on $env:COMPUTERNAME"
}

# ESC10: Schannel CertificateMappingMethods must include the UPN bit (0x4),
# plus the same StrongCertificateBindingEnforcement=0 requirement above
# (both are DC/Schannel registry settings, no template involved at all).
$schannelPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\Schannel"
$currentMapping = Get-ItemProperty -Path $schannelPath -Name "CertificateMappingMethods" -ErrorAction SilentlyContinue
$currentValue = if ($currentMapping) { $currentMapping.CertificateMappingMethods } else { 0 }
if (($currentValue -band 0x4) -eq 0) {
    New-ItemProperty -Path $schannelPath -Name "CertificateMappingMethods" -PropertyType DWord -Value ($currentValue -bor 0x4) -Force | Out-Null
    Write-Output "ESC10: set CertificateMappingMethods to include UPN bit on $env:COMPUTERNAME"
} else {
    Write-Output "ESC10: CertificateMappingMethods already includes UPN bit on $env:COMPUTERNAME"
}
