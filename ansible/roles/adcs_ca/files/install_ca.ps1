param(
    [Parameter(Mandatory = $true)][string]$CACommonName,
    [Parameter(Mandatory = $true)][string]$DomainAdminUser,
    [Parameter(Mandatory = $true)][string]$DomainAdminPassword,
    [int]$ValidityYears = 10
)

# Installs an Enterprise Root CA + Web Enrollment, matching the live
# cyberhawks-CA (2048-bit, SHA256, 10-year root). Idempotent: no-ops if the CA
# service is already configured.
#
# The actual Install-AdcsCertificationAuthority / Install-AdcsWebEnrollment
# calls write to AD (config container, templates) -- a second network hop this
# NTLM WinRM session cannot delegate. So they run inside a one-shot Scheduled
# Task as the domain admin (a real password logon with full network creds),
# the pattern CLAUDE.md's "WinRM double-hop" note settled on. This wrapper
# runs over WinRM as the local automation account and orchestrates that task.

$ErrorActionPreference = "Stop"

function Test-CaConfigured {
    # CertSvc present and a CA CommonName registered = already installed.
    if (-not (Get-Service -Name CertSvc -ErrorAction SilentlyContinue)) { return $false }
    $reg = certutil -getreg CA\CommonName 2>$null | Out-String
    return ($reg -match [regex]::Escape($CACommonName))
}

if (Test-CaConfigured) {
    "RESULT=ok"
    return
}

# Roles first (local operation, no double hop) so the task only does AD work.
Install-WindowsFeature -Name ADCS-Cert-Authority, ADCS-Web-Enrollment -IncludeManagementTools | Out-Null

$work = "C:\Windows\Temp\ca_install_task.ps1"
$marker = "C:\Windows\Temp\ca_install_done.txt"
if (Test-Path $marker) { Remove-Item $marker -Force }

@"
`$ErrorActionPreference = 'Stop'
try {
    Import-Module ADCSDeployment
    Install-AdcsCertificationAuthority ``
        -CAType EnterpriseRootCA ``
        -CACommonName '$CACommonName' ``
        -KeyLength 2048 ``
        -HashAlgorithmName SHA256 ``
        -CryptoProviderName 'RSA#Microsoft Software Key Storage Provider' ``
        -ValidityPeriod Years ``
        -ValidityPeriodUnits $ValidityYears ``
        -Force | Out-Null
    Install-AdcsWebEnrollment -Force | Out-Null
    'OK' | Set-Content -Path '$marker'
} catch {
    "FAIL: `$(`$_.Exception.Message)" | Set-Content -Path '$marker'
}
"@ | Set-Content -Path $work -Encoding UTF8

$taskName = "CyberHawksCAInstall"
schtasks /Create /TN $taskName /TR "powershell.exe -ExecutionPolicy Bypass -NonInteractive -File $work" `
    /SC ONCE /ST 00:00 /RU $DomainAdminUser /RP $DomainAdminPassword /RL HIGHEST /F | Out-Null
schtasks /Run /TN $taskName | Out-Null

# Wait for the marker the inner script writes on completion.
$deadline = (Get-Date).AddMinutes(15)
while (-not (Test-Path $marker) -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
}
schtasks /Delete /TN $taskName /F | Out-Null
Remove-Item $work -Force -ErrorAction SilentlyContinue

if (-not (Test-Path $marker)) {
    throw "CA install task did not complete within the timeout."
}
$outcome = (Get-Content $marker -Raw).Trim()
Remove-Item $marker -Force -ErrorAction SilentlyContinue
if ($outcome -ne 'OK') {
    throw "CA install failed: $outcome"
}

"RESULT=installed"
