<#
.SYNOPSIS
    YOURZON Marketing Post Downloader — Full Browser Automation (PowerShell / Windows)

.DESCRIPTION
    Automates the complete workflow for downloading and organizing
    marketing posts from the YOURZON platform:

    1. Launch Edge/Chrome with saved profile (persistent login)
    2. Navigate to YOURZON platform
    3. Scroll through the post feed
    4. Detect user's own posts and download them (posts with Remove/↓ controls)
    5. Create a dated Desktop folder (פוסטים יורזון יום {day} {date})
    6. Move downloaded images into the folder
    7. Open the folder in File Explorer

    Uses Selenium WebDriver for browser automation with fallback to
    manual browsing mode.

    Requirements:
      Install-Module Selenium  (or download Edge WebDriver manually)

.EXAMPLE
    .\yourzon-download.ps1                     # Full automation (default)
    .\yourzon-download.ps1 -Mode Browse        # Manual browse, auto-organize
    .\yourzon-download.ps1 -Mode Organize      # Just organize recent downloads
    .\yourzon-download.ps1 -DryRun             # Preview without moving
    .\yourzon-download.ps1 -Minutes 30         # Wider download detection window
    .\yourzon-download.ps1 -Url "https://www.yourzon.com/?campaignid=..."
#>

param(
    [ValidateSet("Auto", "Browse", "Organize")]
    [string]$Mode = "Auto",

    [string]$Url = "",
    [switch]$NoProfile,
    [switch]$DryRun,
    [int]$Minutes = 10,
    [int]$MaxScrolls = 80,
    [double]$ScrollPause = 1.5,
    [string]$FolderName = "",
    [string]$DownloadsDir = "",
    [string]$DesktopDir = ""
)

# --- Constants ---

$YOURZON_URL = "https://www.yourzon.com"
$ImageExtensions = @(".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".svg")

$HebrewDays = @{
    "Monday"    = "שני"
    "Tuesday"   = "שלישי"
    "Wednesday" = "רביעי"
    "Thursday"  = "חמישי"
    "Friday"    = "שישי"
    "Saturday"  = "שבת"
    "Sunday"    = "ראשון"
}

# --- Helper Functions ---

function Get-DatedFolderName {
    param([string]$Custom)
    if ($Custom) { return $Custom }
    $now = Get-Date
    $dayName = $HebrewDays[$now.DayOfWeek.ToString()]
    return "פוסטים יורזון יום $dayName $($now.Day)"
}

function Get-RecentImages {
    param(
        [string]$Path,
        [datetime]$Since
    )
    if (-not (Test-Path $Path)) { return @() }
    Get-ChildItem -Path $Path -File |
        Where-Object {
            $ImageExtensions -contains $_.Extension.ToLower() -and
            $_.LastWriteTime -ge $Since
        } |
        Sort-Object LastWriteTime -Descending
}

function Move-ToFolder {
    param(
        [System.IO.FileInfo[]]$Files,
        [string]$Destination
    )
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }
    $moved = @()
    foreach ($file in $Files) {
        $dest = Join-Path $Destination $file.Name
        if (Test-Path $dest) {
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
            $ext = $file.Extension
            $n = 1
            while (Test-Path $dest) {
                $dest = Join-Path $Destination "${stem}_${n}${ext}"
                $n++
            }
        }
        Move-Item -Path $file.FullName -Destination $dest
        $moved += @{ Source = $file.FullName; Dest = $dest }
    }
    return $moved
}

function Show-Files {
    param(
        [System.IO.FileInfo[]]$Files,
        [string]$Label = "Found"
    )
    $total = ($Files | Measure-Object -Property Length -Sum).Sum
    Write-Host "`n$Label $($Files.Count) image(s) ($([math]::Round($total / 1MB, 2)) MB):" -ForegroundColor Green
    foreach ($f in $Files) {
        $sz = [math]::Round($f.Length / 1MB, 2)
        $ts = $f.LastWriteTime.ToString("HH:mm:ss")
        Write-Host "  $($f.Name)  ($sz MB, $ts)"
    }
}

function Get-EdgeDriverPath {
    $edgeVersion = (Get-Item "C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe" -ErrorAction SilentlyContinue).VersionInfo.FileVersion
    if (-not $edgeVersion) {
        $edgeVersion = (Get-Item "C:\Program Files\Microsoft\Edge\Application\msedge.exe" -ErrorAction SilentlyContinue).VersionInfo.FileVersion
    }
    return $edgeVersion
}

function Test-SeleniumAvailable {
    try {
        Import-Module Selenium -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

# --- Resolve paths ---

if (-not $DesktopDir) { $DesktopDir = [Environment]::GetFolderPath("Desktop") }
if (-not $DownloadsDir) {
    $DownloadsDir = Join-Path ([Environment]::GetFolderPath("UserProfile")) "Downloads"
}
if (-not $Url) { $Url = $YOURZON_URL }

# --- Mode: Organize ---

function Invoke-Organize {
    Write-Host "Scanning: $DownloadsDir" -ForegroundColor Cyan
    Write-Host "Looking for images from the last $Minutes minutes..."

    $since = (Get-Date).AddMinutes(-$Minutes)
    $files = Get-RecentImages -Path $DownloadsDir -Since $since

    if (-not $files -or $files.Count -eq 0) {
        Write-Host "No recent image files found." -ForegroundColor Red
        Write-Host "Tip: try  -Minutes $($Minutes * 3)" -ForegroundColor Yellow
        return
    }

    Show-Files -Files $files

    $folderName = Get-DatedFolderName -Custom $FolderName
    $folderPath = Join-Path $DesktopDir $folderName

    if ($DryRun) {
        Write-Host "`n[DRY RUN] Would create: $folderPath" -ForegroundColor Yellow
        Write-Host "[DRY RUN] Would move $($files.Count) file(s)" -ForegroundColor Yellow
        return
    }

    $moved = Move-ToFolder -Files $files -Destination $folderPath
    Write-Host "`nMoved $($moved.Count) file(s) to: $folderPath" -ForegroundColor Green
    foreach ($m in $moved) { Write-Host "  $(Split-Path $m.Dest -Leaf)" }
    Start-Process explorer.exe $folderPath
    Write-Host "`nDone!" -ForegroundColor Green
}

# --- Mode: Browse (semi-automatic) ---

function Invoke-Browse {
    $stamp = Get-Date

    Write-Host "=== YOURZON Post Downloader — Browse Mode ===" -ForegroundColor Cyan

    $hasSelenium = Test-SeleniumAvailable

    if ($hasSelenium -and -not $NoProfile) {
        Write-Host "Launching browser with Selenium..." -ForegroundColor Cyan

        $edgeOpts = New-Object OpenQA.Selenium.Edge.EdgeOptions
        $profileDir = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data"
        if (Test-Path $profileDir) {
            $edgeOpts.AddArgument("user-data-dir=$profileDir")
            Write-Host "Using Edge profile: $profileDir"
        }
        $edgeOpts.AddArgument("--disable-blink-features=AutomationControlled")

        try {
            $driver = New-Object OpenQA.Selenium.Edge.EdgeDriver($edgeOpts)
            $driver.Navigate().GoToUrl($Url)
            Write-Host "`nBrowse the feed and download the posts you need." -ForegroundColor Yellow
            Read-Host "Press Enter when done"
            $driver.Quit()
        } catch {
            Write-Host "Selenium error: $_" -ForegroundColor Red
            Write-Host "Falling back to Start-Process..." -ForegroundColor Yellow
            Start-Process $Url
            Read-Host "Press Enter when done downloading"
        }
    } else {
        Write-Host "Opening YOURZON: $Url" -ForegroundColor Cyan
        Start-Process $Url
        Write-Host "`nBrowse the feed and download the posts you need." -ForegroundColor Yellow
        Read-Host "Press Enter when done"
    }

    $files = Get-RecentImages -Path $DownloadsDir -Since $stamp
    if (-not $files -or $files.Count -eq 0) {
        $files = Get-RecentImages -Path $DownloadsDir -Since (Get-Date).AddMinutes(-15)
    }
    if (-not $files -or $files.Count -eq 0) {
        Write-Host "No new images detected." -ForegroundColor Red
        return
    }

    Show-Files -Files $files -Label "Detected"

    $folderName = Get-DatedFolderName -Custom $FolderName
    $folderPath = Join-Path $DesktopDir $folderName

    if ($DryRun) {
        Write-Host "`n[DRY RUN] Would move to: $folderPath" -ForegroundColor Yellow
        return
    }

    $moved = Move-ToFolder -Files $files -Destination $folderPath
    Write-Host "`nMoved $($moved.Count) file(s) to: $folderPath" -ForegroundColor Green
    foreach ($m in $moved) { Write-Host "  $(Split-Path $m.Dest -Leaf)" }
    Start-Process explorer.exe $folderPath
    Write-Host "`nDone!" -ForegroundColor Green
}

# --- Mode: Auto (full browser automation) ---

function Invoke-Auto {
    $hasSelenium = Test-SeleniumAvailable

    if (-not $hasSelenium) {
        Write-Host "Selenium module not found." -ForegroundColor Yellow
        Write-Host "Install with:  Install-Module Selenium" -ForegroundColor Yellow
        Write-Host "Falling back to Browse mode...`n" -ForegroundColor Yellow
        Invoke-Browse
        return
    }

    $stamp = Get-Date
    $downloadedCount = 0

    Write-Host "=== YOURZON Post Downloader — Auto Mode ===" -ForegroundColor Cyan
    Write-Host ""

    # Launch Edge with profile
    $edgeOpts = New-Object OpenQA.Selenium.Edge.EdgeOptions
    if (-not $NoProfile) {
        $profileDir = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data"
        if (Test-Path $profileDir) {
            $edgeOpts.AddArgument("user-data-dir=$profileDir")
            Write-Host "Using Edge profile: $profileDir"
        }
    }
    $edgeOpts.AddArgument("--disable-blink-features=AutomationControlled")
    $edgeOpts.AddUserProfilePreference("download.default_directory", $DownloadsDir)

    try {
        $driver = New-Object OpenQA.Selenium.Edge.EdgeDriver($edgeOpts)
    } catch {
        Write-Host "Failed to launch Edge WebDriver: $_" -ForegroundColor Red
        Write-Host "Falling back to Browse mode..." -ForegroundColor Yellow
        Invoke-Browse
        return
    }

    # Step 1 — Navigate to YOURZON
    Write-Host "Step 1: Opening YOURZON ($Url)..." -ForegroundColor Cyan
    $driver.Navigate().GoToUrl($Url)
    Start-Sleep -Seconds 3

    # Step 2 — Check login state
    Write-Host "Step 2: Checking login state..." -ForegroundColor Cyan
    $pageText = $driver.FindElementByTagName("body").Text
    if ($pageText -match "Log in|Sign up") {
        Write-Host "  Login required — please log in manually." -ForegroundColor Yellow
        Write-Host "  Waiting for authentication..."
        $loginWait = 0
        while ($loginWait -lt 120) {
            Start-Sleep -Seconds 3
            $loginWait += 3
            try {
                $bodyText = $driver.FindElementByTagName("body").Text
                if ($bodyText -notmatch "Log in|Sign up") {
                    Write-Host "  Logged in!" -ForegroundColor Green
                    break
                }
            } catch { break }
        }
    } else {
        Write-Host "  Already authenticated." -ForegroundColor Green
    }

    # Step 3 — Scroll and download
    Write-Host "Step 3: Scrolling through the feed..." -ForegroundColor Cyan

    $ownPostSelectors = @(
        "remove", "הסרה"
    )
    $downloadSelectors = @(
        "[data-action='download']",
        "a[download]",
        "[aria-label*='download']",
        "[aria-label*='הורדה']"
    )

    $prevHeight = 0
    $staleRounds = 0
    $clickedPositions = @{}

    for ($i = 1; $i -le $MaxScrolls; $i++) {
        # Look for post containers
        try {
            $articles = $driver.FindElementsByCssSelector("article, [class*='post'], [class*='card'], [role='article']")
        } catch {
            $articles = @()
        }

        foreach ($article in $articles) {
            try {
                $text = $article.Text
            } catch { continue }

            # Check if this is the user's own post
            $isOwn = $false
            foreach ($marker in $ownPostSelectors) {
                if ($text -match [regex]::Escape($marker)) {
                    $isOwn = $true
                    break
                }
            }
            if (-not $isOwn) { continue }

            # Find and click download button
            foreach ($dlSel in $downloadSelectors) {
                try {
                    $btns = $article.FindElementsByCssSelector($dlSel)
                    foreach ($btn in $btns) {
                        if (-not $btn.Displayed) { continue }
                        $loc = $btn.Location
                        $key = "$($loc.X),$($loc.Y)"
                        if ($clickedPositions.ContainsKey($key)) { continue }
                        $clickedPositions[$key] = $true

                        $beforeFiles = Get-RecentImages -Path $DownloadsDir -Since $stamp
                        $btn.Click()
                        Start-Sleep -Seconds 3
                        $afterFiles = Get-RecentImages -Path $DownloadsDir -Since $stamp

                        if ($afterFiles.Count -gt $beforeFiles.Count) {
                            $newest = $afterFiles[0]
                            $downloadedCount++
                            Write-Host "  ↓ Downloaded: $($newest.Name)" -ForegroundColor Green
                        }
                    }
                } catch { continue }
            }
        }

        # Scroll down
        try {
            $driver.ExecuteScript("window.scrollBy(0, window.innerHeight * 0.8)")
        } catch { break }
        Start-Sleep -Seconds $ScrollPause

        try {
            $curHeight = $driver.ExecuteScript("return document.documentElement.scrollHeight")
        } catch { break }

        if ($curHeight -eq $prevHeight) {
            $staleRounds++
            if ($staleRounds -ge 5) {
                Write-Host "`n  Reached end of feed after $i scrolls." -ForegroundColor Cyan
                break
            }
        } else {
            $staleRounds = 0
        }
        $prevHeight = $curHeight

        if ($i % 10 -eq 0) {
            $progress = Get-RecentImages -Path $DownloadsDir -Since $stamp
            Write-Host "  ... scrolled $i/$MaxScrolls, $($progress.Count) file(s) so far"
        }
    }

    # Manual fallback if nothing was auto-detected
    if ($downloadedCount -eq 0) {
        $check = Get-RecentImages -Path $DownloadsDir -Since $stamp
        if (-not $check -or $check.Count -eq 0) {
            Write-Host "`n  No downloads detected automatically." -ForegroundColor Yellow
            Write-Host "  Browse and download manually, then press Enter." -ForegroundColor Yellow
            Read-Host "  Press Enter when done"
        }
    }

    try { $driver.Quit() } catch {}

    # Step 4 — Collect downloads
    Write-Host "`nStep 4: Collecting downloads..." -ForegroundColor Cyan
    $files = Get-RecentImages -Path $DownloadsDir -Since $stamp
    if (-not $files -or $files.Count -eq 0) {
        $files = Get-RecentImages -Path $DownloadsDir -Since (Get-Date).AddMinutes(-15)
    }
    if (-not $files -or $files.Count -eq 0) {
        Write-Host "No downloaded images found." -ForegroundColor Red
        return
    }

    Show-Files -Files $files -Label "Downloaded"

    # Step 5 — Organize
    Write-Host "`nStep 5: Organizing files..." -ForegroundColor Cyan
    $folderName = Get-DatedFolderName -Custom $FolderName
    $folderPath = Join-Path $DesktopDir $folderName

    if ($DryRun) {
        Write-Host "[DRY RUN] Would create: $folderPath" -ForegroundColor Yellow
        Write-Host "[DRY RUN] Would move $($files.Count) file(s)" -ForegroundColor Yellow
        return
    }

    $moved = Move-ToFolder -Files $files -Destination $folderPath
    Write-Host "`nMoved $($moved.Count) file(s) to: $folderPath" -ForegroundColor Green
    foreach ($m in $moved) { Write-Host "  $(Split-Path $m.Dest -Leaf)" }
    Start-Process explorer.exe $folderPath
    Write-Host "`nDone!" -ForegroundColor Green
}

# --- Main ---

Write-Host ""
switch ($Mode) {
    "Organize" { Invoke-Organize }
    "Browse"   { Invoke-Browse }
    "Auto"     { Invoke-Auto }
}
