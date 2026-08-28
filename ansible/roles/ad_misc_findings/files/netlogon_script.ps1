$ErrorActionPreference = "Stop"

$username = $env:NETLOGON_USERNAME
$password = $env:NETLOGON_PASSWORD
if (-not $username -or -not $password) { throw "NETLOGON_USERNAME/NETLOGON_PASSWORD environment variables not set" }

$scriptPath = "C:\Windows\SYSVOL\domain\scripts\MapDrives.ps1"
if (-not (Test-Path $scriptPath)) {
    @"
# Legacy logon script -- maps the shared drive for all staff.
`$cred = New-Object System.Management.Automation.PSCredential(
    "CYBERHAWKS\$username",
    (ConvertTo-SecureString "$password" -AsPlainText -Force)
)
New-PSDrive -Name "S" -PSProvider FileSystem -Root "\\sql1\Shared" -Credential `$cred -Persist -ErrorAction SilentlyContinue
"@ | Set-Content -Path $scriptPath
    Write-Output "Created NETLOGON script with cleartext creds for $username"
} else {
    Write-Output "NETLOGON script already exists"
}
