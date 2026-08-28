[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath
)

$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory

$rows = Import-Csv -Path $CsvPath
$created = 0
$skipped = 0

foreach ($row in $rows) {
    $sam = $row.username
    $pw = $row.password
    $role = $row.role

    $existing = Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue
    if ($existing) {
        $skipped++
        continue
    }

    $securePw = ConvertTo-SecureString $pw -AsPlainText -Force
    $params = @{
        Name                  = $sam
        SamAccountName        = $sam
        UserPrincipalName     = "$sam@cyberhawks.lab"
        AccountPassword       = $securePw
        Enabled               = $true
        PasswordNeverExpires  = $true
        ChangePasswordAtLogon = $false
    }

    if ($role -eq "desc_field_pw") {
        $params["Description"] = "Password: $pw"
    }

    New-ADUser @params

    if ($role -eq "asreproast") {
        Set-ADAccountControl -Identity $sam -DoesNotRequirePreAuth $true
    }

    $created++
}

Write-Output "Created: $created, Skipped (already existed): $skipped, Total: $($rows.Count)"
