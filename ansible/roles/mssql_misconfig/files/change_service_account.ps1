$ErrorActionPreference = "Stop"

$svcPassword = $env:SVC_MSSQL_PASSWORD
if (-not $svcPassword) { throw "SVC_MSSQL_PASSWORD environment variable not set" }

$serviceName = "MSSQLSERVER"
$account = "CYBERHAWKS\svc-mssql"

$current = (Get-CimInstance Win32_Service -Filter "Name='$serviceName'").StartName
if ($current -ne $account) {
    sc.exe config $serviceName obj= $account password= $svcPassword | Out-Null
    Restart-Service -Name $serviceName -Force
    Start-Sleep -Seconds 5
    Write-Output "Changed $serviceName service account to $account and restarted"
} else {
    Write-Output "$serviceName already runs as $account"
}
