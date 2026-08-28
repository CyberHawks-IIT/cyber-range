$ErrorActionPreference = "Stop"

$svcPassword = $env:SVC_BACKUP_PASSWORD
if (-not $svcPassword) { throw "SVC_BACKUP_PASSWORD environment variable not set" }

# A service (not a scheduled task) is what reliably lands in LSA secrets as
# an instantly-plaintext-recoverable "_SC_<ServiceName>" entry -- a
# scheduled task's credential instead gets cached as a DCC2/MSCACHEv2 hash,
# which needs offline cracking rather than being directly readable.
$serviceName = "BackupSyncAgent"
if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
    New-Service -Name $serviceName -DisplayName "Backup Sync Agent" -BinaryPathName "C:\Windows\System32\cmd.exe /c exit" -StartupType Manual | Out-Null
    sc.exe config $serviceName obj= "CYBERHAWKS\svc-backup" password= $svcPassword | Out-Null
    Write-Output "Created service '$serviceName' running as svc-backup (caches its password in LSA secrets)"
} else {
    Write-Output "Service '$serviceName' already exists"
}
