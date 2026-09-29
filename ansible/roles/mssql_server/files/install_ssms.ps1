param(
    [Parameter(Mandatory = $true)][string]$InstallerPath
)

# Unattended SQL Server Management Studio install. Idempotent: no-ops if SSMS
# is already present. SSMS's bootstrapper needs .NET Framework 4.7.2+ (Server
# 2016 ships 4.6.2 and needs it installed first -- see the setup guide's SQL
# prerequisites). Emits RESULT=.

$ErrorActionPreference = "Stop"

# Detect an existing SSMS install via its uninstall registry entries.
$installed = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue |
    Get-ItemProperty -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like "*SQL Server Management Studio*" }
if ($installed) {
    "RESULT=ok"
    return
}

if (-not (Test-Path $InstallerPath)) {
    throw "SSMS installer not found on guest at: $InstallerPath"
}

$proc = Start-Process -FilePath $InstallerPath `
    -ArgumentList @("/install", "/quiet", "/norestart") `
    -Wait -PassThru -NoNewWindow

if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
    throw "SSMS install failed with exit code $($proc.ExitCode) (16384 usually means missing .NET 4.7.2+ on Server 2016)."
}

"RESULT=installed"
