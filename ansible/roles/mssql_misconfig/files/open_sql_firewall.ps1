if (-not (Get-NetFirewallRule -DisplayName "SQL Server TCP 1433" -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName "SQL Server TCP 1433" -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow | Out-Null
    Write-Output "Created SQL Server firewall rule"
} else {
    Write-Output "SQL Server firewall rule already exists"
}
