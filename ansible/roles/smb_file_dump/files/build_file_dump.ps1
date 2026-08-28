$ErrorActionPreference = "Stop"

$leakUsername = $env:SMBSHARE_USERNAME
$leakPassword = $env:SMBSHARE_PASSWORD
if (-not $leakUsername -or -not $leakPassword) { throw "SMBSHARE_USERNAME/SMBSHARE_PASSWORD environment variables not set" }

$root = "C:\Shared"

# --- Folder tree ---
$topFolders = @{
    "HR"          = @("Onboarding", "Policies", "Reviews", "Payroll")
    "IT"          = @("PasswordResets", "Tickets", "Inventory", "Backups", "Scripts")
    "Finance"     = @("Invoices", "Budgets", "Audits", "Expenses")
    "Engineering" = @("Specs", "Designs", "Reports", "TestPlans")
    "Scans"       = @()
    "Archive"     = @("Old Stuff", "2019 Backup", "Misc", "Do Not Delete")
    "Legal"       = @("Contracts", "NDAs")
    "Marketing"   = @("Campaigns", "Branding", "Social")
    "Facilities"  = @("Maintenance", "Vendors")
}
$userNames = @("jsmith", "mjohnson", "rwilliams", "abrown", "kjones", "tgarcia", "lmiller", "sdavis",
    "jrodriguez", "cmartinez", "pwilson", "aanderson", "mthomas", "jtaylor", "rmoore",
    "dclark", "elewis", "nwalker", "bhall", "kyoung")

$allFolders = New-Object System.Collections.Generic.List[string]
foreach ($top in $topFolders.Keys) {
    $allFolders.Add($top)
    foreach ($sub in $topFolders[$top]) {
        $allFolders.Add("$top\$sub")
    }
}
foreach ($u in $userNames) {
    $allFolders.Add("Users\$u")
}

foreach ($f in $allFolders) {
    $path = Join-Path $root $f
    if (-not (Test-Path $path)) {
        New-Item -Path $path -ItemType Directory -Force | Out-Null
    }
}
Write-Output "Created $($allFolders.Count) folders"

# --- Filler files: realistic names, mostly-empty content ---
$fileTypePrefixes = @{
    ".docx" = @("Memo", "Letter", "Report", "Minutes", "Summary", "Proposal", "Policy")
    ".xlsx" = @("Budget", "Tracker", "Inventory", "Timesheet", "Expenses", "Forecast")
    ".pdf"  = @("Invoice", "Scan", "Signed_Form", "Contract", "Receipt", "Statement")
    ".txt"  = @("notes", "readme", "todo", "log", "export")
    ".pptx" = @("Presentation", "Overview", "Training", "Kickoff")
}
$years = @("2022", "2023", "2024", "2025", "2026")

$rng = New-Object System.Random
$totalFiles = 0
foreach ($f in $allFolders) {
    $path = Join-Path $root $f
    $count = $rng.Next(3, 9)
    for ($i = 0; $i -lt $count; $i++) {
        $ext = (Get-Random -InputObject $fileTypePrefixes.Keys)
        $prefix = Get-Random -InputObject $fileTypePrefixes[$ext]
        $year = Get-Random -InputObject $years
        $num = $rng.Next(100, 999)
        $fileName = "${prefix}_${year}_${num}${ext}"
        $filePath = Join-Path $path $fileName
        if (-not (Test-Path $filePath)) {
            Set-Content -Path $filePath -Value "" -NoNewline
            $totalFiles++
        }
    }
}
Write-Output "Created $totalFiles filler files"

# --- The real leak: a plaintext password buried in IT\PasswordResets ---
$leakFile = Join-Path $root "IT\PasswordResets\ResetLog_2026.txt"
if (-not (Test-Path $leakFile)) {
    @"
IT Password Reset Log

Date: 2026-03-14
User: $leakUsername
Reason: forgot password, verified over phone
Temp password set: $leakPassword
Ticket: IT-4471
"@ | Set-Content -Path $leakFile
    Write-Output "Created the leaked credential file"
}

# --- Share it ---
if (-not (Get-SmbShare -Name "Shared" -ErrorAction SilentlyContinue)) {
    New-SmbShare -Name "Shared" -Path $root -FullAccess "Everyone" | Out-Null
    Write-Output "Created SMB share \\$env:COMPUTERNAME\Shared"
} else {
    Write-Output "SMB share Shared already exists"
}

Write-Output "DONE"
