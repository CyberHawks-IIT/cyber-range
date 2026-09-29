param(
    [Parameter(Mandatory = $true)][string]$ConfigFilePath,
    [Parameter(Mandatory = $true)][string]$SaPassword,
    [Parameter(Mandatory = $true)][string]$IsoPath,
    [Parameter(Mandatory = $true)][string]$InstanceName
)

# Unattended SQL Server Database Engine install from an Evaluation ISO.
# Idempotent: no-ops if the instance service already exists. Emits RESULT=.

$ErrorActionPreference = "Stop"

if (Get-Service -Name $InstanceName -ErrorAction SilentlyContinue) {
    "RESULT=ok"
    return
}

if (-not (Test-Path $IsoPath)) {
    throw "SQL Server ISO not found on guest at: $IsoPath"
}

# A stale "reboot pending" flag from an interrupted prior setup makes the next
# run hang forever (CLAUDE.md gotcha). Surface it clearly so the operator/task
# reboots rather than mistaking the stall for progress.
$rebootPending = Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
if ($rebootPending) {
    throw "A reboot is pending on this host; reboot before installing SQL Server."
}

$mount = Mount-DiskImage -ImagePath $IsoPath -PassThru
try {
    $drive = ($mount | Get-Volume).DriveLetter
    $setup = "${drive}:\setup.exe"
    if (-not (Test-Path $setup)) {
        throw "setup.exe not found on the mounted ISO ($setup)."
    }

    $proc = Start-Process -FilePath $setup `
        -ArgumentList @("/ConfigurationFile=$ConfigFilePath", "/SAPWD=$SaPassword", "/IAcceptSQLServerLicenseTerms") `
        -Wait -PassThru -NoNewWindow

    # 0 = success, 3010 = success + reboot required.
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        throw "SQL Server setup failed with exit code $($proc.ExitCode). See the SQL Server setup logs under C:\Program Files\Microsoft SQL Server\<ver>\Setup Bootstrap\Log."
    }
} finally {
    Dismount-DiskImage -ImagePath $IsoPath | Out-Null
}

"RESULT=installed"
