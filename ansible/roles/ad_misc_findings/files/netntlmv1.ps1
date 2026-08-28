$ErrorActionPreference = "Stop"
$path = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
$current = Get-ItemProperty -Path $path -Name "LmCompatibilityLevel" -ErrorAction SilentlyContinue
if (-not $current -or $current.LmCompatibilityLevel -gt 1) {
    New-ItemProperty -Path $path -Name "LmCompatibilityLevel" -PropertyType DWord -Value 1 -Force | Out-Null
    Write-Output "Set LmCompatibilityLevel=1 (NTLMv1 allowed) on $env:COMPUTERNAME"
} else {
    Write-Output "LmCompatibilityLevel already permissive ($($current.LmCompatibilityLevel)) on $env:COMPUTERNAME"
}
