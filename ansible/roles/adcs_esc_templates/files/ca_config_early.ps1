$ErrorActionPreference = "Stop"

# Cross-machine ADWS calls from ca to either DC were unreliable (TCP,
# firewall, and the ADWS service itself all checked out fine, but the
# actual application-layer exchange failed for reasons not worth
# chasing further) -- ESC5 (a pure AD object edit) was moved to run on
# dc1 instead. ESC7 below still has to run locally on ca (it edits ca's
# own local registry-stored CA security descriptor), so it takes the
# Domain Users SID as a value instead of resolving it via the AD module.
$domainUsersSidValue = $env:DOMAIN_USERS_SID
if (-not $domainUsersSidValue) { throw "DOMAIN_USERS_SID environment variable not set" }
$domainUsersSid = New-Object System.Security.Principal.SecurityIdentifier($domainUsersSidValue)

# --- ESC7: ManageCA (0x1) + ManageCertificates (0x2) to Domain Users ---
# This lives in the CA's own security descriptor, stored as a REG_BINARY
# "Security" value under the CA's service config key -- not a normal AD
# object ACL. AccessMask bit values (0x1/0x2) confirmed by inspecting the
# existing Domain Admins/Enterprise Admins ACEs on this exact CA.
$caCommonName = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration").Active
$regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\CertSvc\Configuration\$caCommonName"
$sdBytes = (Get-ItemProperty -Path $regPath -Name "Security").Security
$rawSD = New-Object System.Security.AccessControl.RawSecurityDescriptor($sdBytes, 0)

$alreadyHasEsc7 = $false
foreach ($ace in $rawSD.DiscretionaryAcl) {
    if ($ace.SecurityIdentifier -eq $domainUsersSid -and $ace.AccessMask -eq 0x3) { $alreadyHasEsc7 = $true }
}

if (-not $alreadyHasEsc7) {
    $newAce = New-Object System.Security.AccessControl.CommonAce(
        [System.Security.AccessControl.AceFlags]::None,
        [System.Security.AccessControl.AceQualifier]::AccessAllowed,
        0x3,
        $domainUsersSid,
        $false,
        $null
    )
    $rawSD.DiscretionaryAcl.InsertAce($rawSD.DiscretionaryAcl.Count, $newAce)
    $newBytes = New-Object byte[] $rawSD.BinaryLength
    $rawSD.GetBinaryForm($newBytes, 0)
    Set-ItemProperty -Path $regPath -Name "Security" -Value $newBytes
    Write-Output "ESC7: granted ManageCA+ManageCertificates (0x3) to Domain Users on the CA security descriptor"
    Restart-Service CertSvc -Force
    Start-Sleep -Seconds 5
    Write-Output "ESC7: restarted CertSvc for the security change to take effect"
} else {
    Write-Output "ESC7: Domain Users already has ManageCA+ManageCertificates"
}

# --- ESC11: disable IF_ENFORCEENCRYPTICERTREQUEST (on by default since Server 2008) ---
$flags = certutil -getreg "CA\InterfaceFlags" 2>&1 | Out-String
if ($flags -match "IF_ENFORCEENCRYPTICERTREQUEST") {
    certutil -setreg "CA\InterfaceFlags" -IF_ENFORCEENCRYPTICERTREQUEST | Out-Null
    Restart-Service CertSvc -Force
    Start-Sleep -Seconds 5
    Write-Output "ESC11: disabled IF_ENFORCEENCRYPTICERTREQUEST and restarted CertSvc"
} else {
    Write-Output "ESC11: IF_ENFORCEENCRYPTICERTREQUEST already disabled"
}

# --- ESC8: confirm (not build) Web Enrollment is HTTP + NTLM-relayable ---
try {
    $resp = Invoke-WebRequest -Uri "http://localhost/certsrv/" -UseBasicParsing -UseDefaultCredentials -ErrorAction Stop
    Write-Output "ESC8: Web Enrollment reachable over plain HTTP (status $($resp.StatusCode))"
} catch {
    Write-Output "ESC8: Web Enrollment check returned: $($_.Exception.Message)"
}
