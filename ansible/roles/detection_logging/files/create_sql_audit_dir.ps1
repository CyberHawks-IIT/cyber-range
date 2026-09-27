$ErrorActionPreference = "Stop"

# CREATE SERVER AUDIT ... TO FILE requires an already-existing directory --
# unlike an Extended Events event_file target (which defaults to the
# instance's own log directory when no path is given), there's no default
# here. MSSQLSERVER runs as the domain account CYBERHAWKS\svc-mssql on both
# sql1 and sql2 (see mssql_misconfig's change_service_account.ps1), not a
# built-in service SID, so it needs an explicit ACE -- a folder newly created
# under C:\ won't otherwise be writable by an ordinary domain account.
$auditDir = "C:\SQLAudit"

if (-not (Test-Path $auditDir)) {
    New-Item -Path $auditDir -ItemType Directory | Out-Null
    Write-Output "Created $auditDir"
} else {
    Write-Output "$auditDir already exists"
}

if ((icacls $auditDir) -notmatch [regex]::Escape('svc-mssql')) {
    icacls $auditDir /grant "CYBERHAWKS\svc-mssql:(OI)(CI)M" | Out-Null
    Write-Output "Granted svc-mssql modify rights on $auditDir"
} else {
    Write-Output "svc-mssql already has rights on $auditDir"
}
