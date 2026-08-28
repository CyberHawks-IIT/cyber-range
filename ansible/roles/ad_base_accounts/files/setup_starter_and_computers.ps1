$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory
Import-Module DnsServer

# Several literal passwords required by the design (user/computer$'s
# "password", the ASREPRoast account's "princess", the crackme account's
# "iloveyou") are single-case dictionary words that fail AD's default
# complexity policy. Weak/guessable passwords are the entire point of this
# lab, so complexity enforcement is disabled domain-wide rather than worked
# around per-account -- this is itself realistic (plenty of real legacy AD
# environments run with complexity off) and a necessary prerequisite for the
# rest of this build, not an incidental side effect.
$currentPolicy = Get-ADDefaultDomainPasswordPolicy
if ($currentPolicy.ComplexityEnabled) {
    Set-ADDefaultDomainPasswordPolicy -Identity "cyberhawks.lab" -ComplexityEnabled $false
    Write-Output "Disabled domain password complexity policy"
} else {
    Write-Output "Domain password complexity policy already disabled"
}

# One-time migration: earlier builds used user1/computer1 as the starter
# account names. Both were renamed to user/computer$ since "1" added no
# information once it was clear there'd only ever be one starter of each
# type. Rename (not delete+recreate) so the SID is preserved and every ACL
# grant made in later phases keeps applying to the same account untouched.
# No-op after the first run, once the old names no longer exist.
$oldUser = Get-ADUser -Filter "SamAccountName -eq 'user1'" -ErrorAction SilentlyContinue
if ($oldUser -and -not (Get-ADUser -Filter "SamAccountName -eq 'user'" -ErrorAction SilentlyContinue)) {
    Rename-ADObject -Identity $oldUser.ObjectGUID -NewName "user"
    Set-ADUser -Identity $oldUser.ObjectGUID -SamAccountName "user" -UserPrincipalName "user@cyberhawks.lab"
    Write-Output "Migrated user1 -> user (SID preserved: $($oldUser.SID))"
}

$oldComputer = Get-ADComputer -Filter "Name -eq 'computer1'" -ErrorAction SilentlyContinue
if ($oldComputer -and -not (Get-ADComputer -Filter "Name -eq 'computer'" -ErrorAction SilentlyContinue)) {
    Rename-ADObject -Identity $oldComputer.ObjectGUID -NewName "computer"
    Set-ADComputer -Identity $oldComputer.ObjectGUID -SamAccountName 'computer$' -DNSHostName "computer.cyberhawks.lab"
    Write-Output "Migrated computer1 -> computer (SID preserved: $($oldComputer.SID))"
}

$zoneNameForMigration = "cyberhawks.lab"
$reverseZoneNameForMigration = "2.0.10.in-addr.arpa"
$oldDnsA = Get-DnsServerResourceRecord -ZoneName $zoneNameForMigration -Name "computer1" -RRType A -ErrorAction SilentlyContinue
if ($oldDnsA) {
    Remove-DnsServerResourceRecord -ZoneName $zoneNameForMigration -Name "computer1" -RRType A -Force
    if (-not (Get-DnsServerResourceRecord -ZoneName $zoneNameForMigration -Name "computer" -RRType A -ErrorAction SilentlyContinue)) {
        Add-DnsServerResourceRecordA -ZoneName $zoneNameForMigration -Name "computer" -IPv4Address "10.0.2.51"
    }
    Write-Output "Migrated DNS A record computer1 -> computer"
}
$oldDnsPtr = Get-DnsServerResourceRecord -ZoneName $reverseZoneNameForMigration -Name "51" -RRType Ptr -ErrorAction SilentlyContinue
if ($oldDnsPtr -and $oldDnsPtr.RecordData.PtrDomainName -like "computer1.*") {
    Remove-DnsServerResourceRecord -ZoneName $reverseZoneNameForMigration -Name "51" -RRType Ptr -Force
    Add-DnsServerResourceRecordPtr -ZoneName $reverseZoneNameForMigration -Name "51" -PtrDomainName "computer.$zoneNameForMigration"
    Write-Output "Migrated DNS PTR record for 10.0.2.51 -> computer.$zoneNameForMigration"
}

function Ensure-User {
    param([string]$SamAccountName, [string]$Password, [switch]$ConvergeIfExists)
    $existing = Get-ADUser -Filter "SamAccountName -eq '$SamAccountName'" -ErrorAction SilentlyContinue
    $securePw = ConvertTo-SecureString $Password -AsPlainText -Force
    if ($existing) {
        if ($ConvergeIfExists) {
            # Starter accounts must reliably match the documented state even
            # if something pre-dating this build left them disabled or with
            # an unknown password (found happening to user1 in practice).
            Set-ADUser -Identity $SamAccountName -Enabled $true -PasswordNeverExpires $true
            Set-ADAccountPassword -Identity $SamAccountName -NewPassword $securePw -Reset
            Write-Output "Converged existing user $SamAccountName to documented state"
        } else {
            Write-Output "User $SamAccountName already exists, skipping."
        }
        return
    }
    New-ADUser -Name $SamAccountName -SamAccountName $SamAccountName `
        -UserPrincipalName "$SamAccountName@cyberhawks.lab" `
        -AccountPassword $securePw -Enabled $true `
        -PasswordNeverExpires $true -ChangePasswordAtLogon $false
    Write-Output "Created user $SamAccountName"
}

function Ensure-Computer {
    param([string]$Name, [string]$Password, [switch]$ConvergeIfExists)
    $existing = Get-ADComputer -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue
    $securePw = ConvertTo-SecureString $Password -AsPlainText -Force
    if ($existing) {
        if ($ConvergeIfExists) {
            Set-ADComputer -Identity $Name -Enabled $true -PasswordNeverExpires $true
            Set-ADAccountPassword -Identity "$Name`$" -NewPassword $securePw -Reset
            Write-Output "Converged existing computer $Name to documented state"
        } else {
            Write-Output "Computer $Name already exists, skipping."
        }
        return
    }
    New-ADComputer -Name $Name -SAMAccountName "$Name`$" -AccountPassword $securePw `
        -Enabled $true -PasswordNeverExpires $true
    Write-Output "Created computer $Name"
}

# --- Starter accounts (the only two accounts students are handed on day one) ---
# ConvergeIfExists: these two must always match the documented password/state
# exactly, even on re-run, since students are handed these credentials directly.
Ensure-User -SamAccountName "user" -Password "password" -ConvergeIfExists
Ensure-Computer -Name "computer" -Password "password" -ConvergeIfExists

# --- Placeholder computers 2-5 (not real VMs; targets for later phases) ---
# computer4/computer5's intentionally-weak passwords are set in a later phase
# (ad_misc_findings) -- these get ordinary secure random passwords for now,
# same as any legitimate computer join would produce.
foreach ($i in 2..5) {
    $randomPw = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
    Ensure-Computer -Name "computer$i" -Password $randomPw
}

# --- Static DNS records for computer, computer2-5 (10.0.2.51-.55) ---
$zoneName = "cyberhawks.lab"
$reverseZoneName = "2.0.10.in-addr.arpa"

if (-not (Get-DnsServerZone -Name $reverseZoneName -ErrorAction SilentlyContinue)) {
    Add-DnsServerPrimaryZone -NetworkID "10.0.2.0/24" -ReplicationScope "Forest"
    Write-Output "Created reverse lookup zone $reverseZoneName"
}

$computerIps = [ordered]@{
    "computer" = "10.0.2.51"
    "computer2" = "10.0.2.52"
    "computer3" = "10.0.2.53"
    "computer4" = "10.0.2.54"
    "computer5" = "10.0.2.55"
}

foreach ($name in $computerIps.Keys) {
    $ip = $computerIps[$name]
    $lastOctet = $ip.Split(".")[-1]

    if (-not (Get-DnsServerResourceRecord -ZoneName $zoneName -Name $name -RRType A -ErrorAction SilentlyContinue)) {
        Add-DnsServerResourceRecordA -ZoneName $zoneName -Name $name -IPv4Address $ip
        Write-Output "Created A record $name.$zoneName -> $ip"
    }

    if (-not (Get-DnsServerResourceRecord -ZoneName $reverseZoneName -Name $lastOctet -RRType Ptr -ErrorAction SilentlyContinue)) {
        Add-DnsServerResourceRecordPtr -ZoneName $reverseZoneName -Name $lastOctet -PtrDomainName "$name.$zoneName"
        Write-Output "Created PTR record $ip -> $name.$zoneName"
    }
}

Write-Output "DONE"
