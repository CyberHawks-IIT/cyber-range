$ErrorActionPreference = "Stop"

$regPath = "HKLM:\Software\Microsoft\Policies\LAPS"
if (-not (Test-Path $regPath)) {
    New-Item -Path $regPath -Force | Out-Null
}
New-ItemProperty -Path $regPath -Name "BackupDirectory" -PropertyType DWord -Value 2 -Force | Out-Null   # 2 = Active Directory (1 = Azure AD)
New-ItemProperty -Path $regPath -Name "PasswordComplexity" -PropertyType DWord -Value 4 -Force | Out-Null
New-ItemProperty -Path $regPath -Name "PasswordLength" -PropertyType DWord -Value 20 -Force | Out-Null
New-ItemProperty -Path $regPath -Name "PasswordAgeDays" -PropertyType DWord -Value 30 -Force | Out-Null
# Disable password encryption. At domain functional level 2016+, Windows LAPS
# encrypts the password by default (DPAPI-NG, decryptable only by the authorized
# decryptor principal -- Domain Admins) and stores it in msLAPS-EncryptedPassword,
# leaving the cleartext msLAPS-Password attribute empty. For this range the whole
# point is that a granted low-priv account (and tooling like netexec --laps) can
# read the password, so we force cleartext storage in msLAPS-Password instead.
New-ItemProperty -Path $regPath -Name "ADPasswordEncryptionEnabled" -PropertyType DWord -Value 0 -Force | Out-Null

Import-Module LAPS
Invoke-LapsPolicyProcessing
# Force a rotation so the stored password reflects the current (unencrypted)
# policy regardless of prior state -- on a re-run the existing password isn't
# expired, so Invoke-LapsPolicyProcessing alone would leave a stale (possibly
# still-encrypted) value in place.
Reset-LapsPassword
Write-Output "LAPS policy applied (encryption disabled) and rotation forced"
