<#
.SYNOPSIS
    YOURZON Promotional Content Downloader (PowerShell / Windows)

.DESCRIPTION
    Automates downloading promotional images/posts from the YOURZON platform
    and organizing them in dated folders on the Desktop.

    Workflow:
    1. Opens YOURZON website in browser
    2. Waits for user to download promotional images
    3. Creates a dated folder on Desktop (e.g., "פוסטים יורזון יום רביעי 5")
    4. Moves downloaded images to the dated folder

.EXAMPLE
    .\yourzon-download.ps1                    # Full interactive workflow
    .\yourzon-download.ps1 -OrganizeOnly      # Just organize recent downloads
    .\yourzon-download.ps1 -OpenOnly          # Just open YOURZON in browser
    .\yourzon-download.ps1 -DryRun            # Preview without moving files
    .\yourzon-download.ps1 -Minutes 30        # Look back 30 minutes for downloads
    .\yourzon-download.ps1 -FolderName "Custom Name"  # Custom folder name
#>

param(
    [switch]$OpenOnly,
    [switch]$OrganizeOnly,
    [switch]$DryRun,
    [int]$Minutes = 10,
    [string]$FolderName = "",
    [string]$DownloadsDir = "",
    [string]$DesktopDir = ""
)

$YOURZON_URL = "https://www.yourzon.com"

$HebrewDays = @{
    "Monday"    = "שני"
    "Tuesday"   = "שלישי"
    "Wednesday" = "רביעי"
    "Thursday"  = "חמישי"
    "Friday"    = "שישי"
    "Saturday"  = "שבת"
    "Sunday"    = "ראשון"
}

$ImageExtensions = @(".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".svg")

function Get-DatedFolderName {
    param([string]$CustomName)

    if ($CustomName) { return $CustomName }

    $now = Get-Date
    $dayName = $HebrewDays[$now.DayOfWeek.ToString()]
    $dayNumber = $now.Day
    return "פוסטים יורזון יום $dayName $dayNumber"
}

function Get-RecentDownloads {
    param(
        [string]$Path,
        [int]$MinutesAgo
    )

    $cutoff = (Get-Date).AddMinutes(-$MinutesAgo)

    Get-ChildItem -Path $Path -File |
        Where-Object {
            $ImageExtensions -contains $_.Extension.ToLower() -and
            $_.LastWriteTime -ge $cutoff
        } |
        Sort-Object LastWriteTime -Descending
}

function Move-FilesToFolder {
    param(
        [System.IO.FileInfo[]]$Files,
        [string]$Destination
    )

    $moved = @()
    foreach ($file in $Files) {
        $destPath = Join-Path $Destination $file.Name
        if (Test-Path $destPath) {
            $counter = 1
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $ext = $file.Extension
            while (Test-Path $destPath) {
                $destPath = Join-Path $Destination "${stem}_${counter}${ext}"
                $counter++
            }
        }
        Move-Item -Path $file.FullName -Destination $destPath
        $moved += @{ Source = $file.FullName; Destination = $destPath }
    }
    return $moved
}

# Resolve paths
if (-not $DesktopDir) { $DesktopDir = [Environment]::GetFolderPath("Desktop") }
if (-not $DownloadsDir) {
    $DownloadsDir = Join-Path ([Environment]::GetFolderPath("UserProfile")) "Downloads"
}

# --- Open Only ---
if ($OpenOnly) {
    Write-Host "Opening YOURZON: $YOURZON_URL" -ForegroundColor Cyan
    Start-Process $YOURZON_URL
    Write-Host "Browser opened. Download the posts, then run:" -ForegroundColor Green
    Write-Host "  .\yourzon-download.ps1 -OrganizeOnly" -ForegroundColor Yellow
    exit
}

# --- Organize Only ---
if ($OrganizeOnly) {
    Write-Host "Scanning: $DownloadsDir" -ForegroundColor Cyan
    Write-Host "Looking for images downloaded in the last $Minutes minutes..." -ForegroundColor Cyan

    $recentFiles = Get-RecentDownloads -Path $DownloadsDir -MinutesAgo $Minutes

    if (-not $recentFiles -or $recentFiles.Count -eq 0) {
        Write-Host "No recent image files found." -ForegroundColor Red
        Write-Host "Try: .\yourzon-download.ps1 -OrganizeOnly -Minutes 30" -ForegroundColor Yellow
        exit
    }

    $totalSize = ($recentFiles | Measure-Object -Property Length -Sum).Sum
    Write-Host "`nFound $($recentFiles.Count) image(s):" -ForegroundColor Green
    foreach ($f in $recentFiles) {
        $sizeMB = [math]::Round($f.Length / 1MB, 2)
        $time = $f.LastWriteTime.ToString("HH:mm:ss")
        Write-Host "  $($f.Name) ($sizeMB MB, $time)"
    }
    Write-Host "  Total: $([math]::Round($totalSize / 1MB, 2)) MB"

    $folderName = Get-DatedFolderName -CustomName $FolderName
    $folderPath = Join-Path $DesktopDir $folderName

    if ($DryRun) {
        Write-Host "`n[DRY RUN] Would create: $folderPath" -ForegroundColor Yellow
        Write-Host "[DRY RUN] Would move $($recentFiles.Count) file(s)" -ForegroundColor Yellow
        exit
    }

    if (-not (Test-Path $folderPath)) {
        New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
    }

    $moved = Move-FilesToFolder -Files $recentFiles -Destination $folderPath
    Write-Host "`nMoved $($moved.Count) file(s) to: $folderPath" -ForegroundColor Green
    foreach ($m in $moved) {
        Write-Host "  $(Split-Path $m.Destination -Leaf)"
    }
    Write-Host "`nDone!" -ForegroundColor Green
    exit
}

# --- Full Workflow (default) ---
Write-Host "=== YOURZON Post Downloader ===" -ForegroundColor Cyan
Write-Host ""

# Step 1: Open browser
Write-Host "Step 1: Opening YOURZON..." -ForegroundColor Cyan
Start-Process $YOURZON_URL

# Step 2: Wait for user
Write-Host ""
Write-Host "Step 2: Download the posts you need from YOURZON." -ForegroundColor Yellow
Read-Host "Press Enter when done"

# Step 3: Find and move files
Write-Host ""
Write-Host "Step 3: Scanning for recent downloads..." -ForegroundColor Cyan

$recentFiles = Get-RecentDownloads -Path $DownloadsDir -MinutesAgo 15

if (-not $recentFiles -or $recentFiles.Count -eq 0) {
    Write-Host "No recent image files found. Make sure you downloaded the posts." -ForegroundColor Red
    exit
}

$folderName = Get-DatedFolderName -CustomName $FolderName
$folderPath = Join-Path $DesktopDir $folderName

if (-not (Test-Path $folderPath)) {
    New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
}

Write-Host "Created folder: $folderName" -ForegroundColor Green

$moved = Move-FilesToFolder -Files $recentFiles -Destination $folderPath

Write-Host "Moved $($moved.Count) file(s):" -ForegroundColor Green
foreach ($m in $moved) {
    Write-Host "  $(Split-Path $m.Destination -Leaf)"
}

# Step 4: Open folder
Write-Host ""
Write-Host "Opening folder..." -ForegroundColor Cyan
Start-Process explorer.exe $folderPath

Write-Host "`nDone!" -ForegroundColor Green
