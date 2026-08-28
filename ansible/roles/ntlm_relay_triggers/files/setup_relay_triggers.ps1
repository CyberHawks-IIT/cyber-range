param(
    [Parameter(Mandatory = $true)][string]$CsvPath
)
$ErrorActionPreference = "Stop"

$rows = Import-Csv -Path $CsvPath
$httpAccount = $rows | Where-Object { $_.role -eq "ntlm_relay_http" }
$smbAccount  = $rows | Where-Object { $_.role -eq "ntlm_relay_smb" }

if (-not $httpAccount) { throw "No pool account found with role 'ntlm_relay_http'" }
if (-not $smbAccount)  { throw "No pool account found with role 'ntlm_relay_smb'" }

$payloadDir = "C:\ProgramData\CyberHawksSync"

# schtasks /Create with /RU + /RP does NOT reliably grant the account "Log on
# as a batch job" itself (that only happens through the Task Scheduler MMC
# snap-in) -- without it, the task registers cleanly but every run attempt
# fails at LogonUserExEx with STATUS_LOGON_FAILURE, even though the same
# credentials work fine interactively. Grant the right directly via secedit
# rather than relying on schtasks to have done it.
function Grant-BatchLogonRight {
    param([string]$SamAccountName)

    $sid = (New-Object System.Security.Principal.NTAccount("CYBERHAWKS", $SamAccountName)).
        Translate([System.Security.Principal.SecurityIdentifier]).Value

    $cfgPath = "C:\Windows\Temp\relay_secpol.cfg"
    $dbPath = "C:\Windows\Temp\relay_secedit.sdb"
    secedit /export /cfg $cfgPath /areas USER_RIGHTS | Out-Null
    $lines = Get-Content $cfgPath

    $found = $false
    $lines = $lines | ForEach-Object {
        if ($_ -match "^SeBatchLogonRight\s*=\s*(.*)$") {
            $found = $true
            $existing = $Matches[1]
            if ($existing -notmatch [regex]::Escape("*$sid")) {
                "SeBatchLogonRight = $existing,*$sid"
            } else {
                $_
            }
        } else {
            $_
        }
    }
    if (-not $found) {
        $lines += "SeBatchLogonRight = *$sid"
    }
    Set-Content -Path $cfgPath -Value $lines

    secedit /configure /db $dbPath /cfg $cfgPath /areas USER_RIGHTS | Out-Null
    Remove-Item -Path $cfgPath, $dbPath -Force -ErrorAction SilentlyContinue

    Write-Output "Granted 'Log on as a batch job' to CYBERHAWKS\$SamAccountName"
}

function Register-RelayTask {
    param($TaskName, $ScriptName, $Domain, $User, $Password)

    Grant-BatchLogonRight -SamAccountName $User

    $scriptPath = Join-Path $payloadDir $ScriptName
    $action = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""

    schtasks /Create /TN $TaskName /TR $action /SC MINUTE /MO 5 `
        /RU "$Domain\$User" /RP "$Password" /RL LIMITED /F | Out-Null

    Write-Output "Registered scheduled task '$TaskName' running as $Domain\$User every 5 minutes"
}

Register-RelayTask -TaskName "CyberHawksSync-FileServiceCheck" -ScriptName "http_relay_trigger.ps1" `
    -Domain "CYBERHAWKS" -User $httpAccount.username -Password $httpAccount.password

Register-RelayTask -TaskName "CyberHawksSync-BackupMountCheck" -ScriptName "smb_relay_trigger.ps1" `
    -Domain "CYBERHAWKS" -User $smbAccount.username -Password $smbAccount.password

# Removes the one variable that could silently block the SMB relay path from
# this host: if this box's own outbound SMB client required signing, the
# periodic backup-mount check above couldn't be relayed at all regardless of
# the target's own settings.
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters" `
    -Name "RequireSecuritySignature" -PropertyType DWord -Value 0 -Force | Out-Null
Write-Output "Confirmed outbound SMB client signing is not required on this host"

Write-Output "DONE"
