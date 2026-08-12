<#
.SYNOPSIS
    YOURZON — Automated Marketing Post Creator & Organizer (PowerShell / Windows)

.DESCRIPTION
    Complete workflow:
      1. ChatGPT Chat #1: Generate 5 marketing post texts for YOURZON
      2. ChatGPT Chat #2: Set brand/design guidelines, then for each post —
         paste the text and generate a branded image
      3. Download all generated post images
      4. Create a dated Desktop folder and organize the files

    Modes:
      Api        Use OpenAI API directly (default, requires OPENAI_API_KEY env var)
      Browser    Open ChatGPT in Edge with saved profile for manual workflow
      Organize   Just organize recently downloaded files (no generation)

    Requirements (Api mode):
      Set environment variable OPENAI_API_KEY or pass -ApiKey

    Requirements (Browser mode):
      Edge or Chrome with saved ChatGPT login

.EXAMPLE
    .\yourzon-download.ps1                           # Full workflow via API
    .\yourzon-download.ps1 -Mode Api -Posts 3        # Generate 3 posts
    .\yourzon-download.ps1 -Mode Browser             # Open ChatGPT in Edge
    .\yourzon-download.ps1 -Mode Organize            # Just organize downloads
    .\yourzon-download.ps1 -Mode Organize -Minutes 30
    .\yourzon-download.ps1 -Mode Api -DryRun
#>

param(
    [ValidateSet("Api", "Browser", "Organize")]
    [string]$Mode = "Api",

    [string]$ApiKey = "",
    [int]$Posts = 5,
    [string]$ChatModel = "gpt-4o",
    [string]$ImageModel = "dall-e-3",
    [switch]$NoProfile,
    [switch]$DryRun,
    [int]$Minutes = 10,
    [string]$FolderName = "",
    [string]$DownloadsDir = "",
    [string]$DesktopDir = ""
)

# --- Constants ---

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

$PostsPromptTemplate = "תכתוב לי {0} פוסטים ליורזון"

$BrandDesignPrompt = @"
כל פוסט שאני נותן לך עכשיו אתה יוצר אותו בדיוק לפי זה בדיוק -

Design a professional logo for a digital marketing
company called "YourZon".

LOGO STRUCTURE:

- The word "YOUR" in Deep Red color
- The word "ZON" in Dark Navy color
- Both words use a gradient that flows from
  Deep Red (left) to Dark Navy (right)
- A small computer cursor/arrow icon placed
  at the bottom-right of the letter "N"
- The cursor is dark navy colored
- Font: Extra Bold, Heavy Weight, Sans-Serif
  (similar to Black Han Sans or Bebas Neue)
- Letters are uppercase only
- Tight letter spacing — letters sit close together
- No outlines, no shadows, clean flat style

BRAND COLORS — EXACT VALUES:

- Deep Red:     #8B0000  /  RGB(139, 0, 0)
- Dark Navy:    #1A2340  /  RGB(26, 35, 64)
- Light Gray:   #F2F2F2  /  RGB(242, 242, 242)
- White:        #FFFFFF
  ⚠️ NO other colors allowed

BACKGROUND OPTIONS:
Option A — Light gray #F2F2F2 with:

- Faint network/node graph pattern on LEFT side
  (small dots connected by thin lines, deep red
  at 10% opacity)
- Faint topographic contour lines on RIGHT side
  (dark navy at 8% opacity, organic curved lines)

Option B — Pure white #FFFFFF, logo centered only

LOGO VERSIONS NEEDED:

1. Horizontal version — YOUR ZON on one line
2. Stacked version — YOUR on top / ZON below
3. Icon only — cursor arrow in deep red + navy gradient
4. White version — for dark backgrounds

STYLE KEYWORDS:
Premium, Corporate, Digital, Trustworthy,
Modern, Clean, Minimal, Bold, Professional

DO NOT include:

- Gradients other than red-to-navy
- Drop shadows or 3D effects
- Decorative fonts or script styles
- Any colors outside the brand palette
- Emojis or decorative symbols
- Tagline in the logo itself

OUTPUT FORMAT:

- SVG vector format preferred
- Transparent background (PNG as backup)
- Minimum size: 2000x2000px
"@

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

function Split-Posts {
    param([string]$Text)
    $chunks = [regex]::Split($Text, '\n\s*(?:\d+[\.\)]\s*|#{1,3}\s+פוסט\s*\d+|---+)')
    $posts = @()
    foreach ($c in $chunks) {
        $trimmed = $c.Trim()
        if ($trimmed -and $trimmed.Length -gt 20) {
            $posts += $trimmed
        }
    }
    if ($posts.Count -eq 0 -and $Text.Trim()) {
        $posts = @($Text.Trim())
    }
    return $posts
}

# --- Resolve paths ---

if (-not $DesktopDir) { $DesktopDir = [Environment]::GetFolderPath("Desktop") }
if (-not $DownloadsDir) {
    $DownloadsDir = Join-Path ([Environment]::GetFolderPath("UserProfile")) "Downloads"
}

# --- Mode: Api (OpenAI API) ---

function Invoke-Api {
    $key = $ApiKey
    if (-not $key) { $key = $env:OPENAI_API_KEY }
    if (-not $key) {
        Write-Host "Set OPENAI_API_KEY environment variable or pass -ApiKey" -ForegroundColor Red
        return
    }

    $headers = @{
        "Authorization" = "Bearer $key"
        "Content-Type"  = "application/json"
    }

    $folderNameResolved = Get-DatedFolderName -Custom $FolderName
    $folderPath = Join-Path $DesktopDir $folderNameResolved

    Write-Host "=== YOURZON Post Creator ===" -ForegroundColor Cyan
    Write-Host ""

    # --- Step 1: Generate post texts ---
    $prompt = $PostsPromptTemplate -f $Posts
    Write-Host "Step 1: Generating $Posts post texts..." -ForegroundColor Cyan

    if ($DryRun) {
        Write-Host "  [DRY RUN] Would send to ${ChatModel}: `"$prompt`"" -ForegroundColor Yellow
        Write-Host "  [DRY RUN] Then generate $Posts images with $ImageModel" -ForegroundColor Yellow
        Write-Host "  [DRY RUN] Save to: $folderPath" -ForegroundColor Yellow
        return
    }

    $chatBody = @{
        model    = $ChatModel
        messages = @(
            @{ role = "user"; content = $prompt }
        )
    } | ConvertTo-Json -Depth 5

    try {
        $chatResponse = Invoke-RestMethod -Uri "https://api.openai.com/v1/chat/completions" `
            -Method Post -Headers $headers -Body $chatBody
    } catch {
        Write-Host "API error (chat): $_" -ForegroundColor Red
        return
    }

    $fullText = $chatResponse.choices[0].message.content
    $postsList = Split-Posts -Text $fullText
    if ($postsList.Count -gt $Posts) {
        $postsList = $postsList[0..($Posts - 1)]
    }

    Write-Host "  Generated $($postsList.Count) posts:" -ForegroundColor Green
    Write-Host ""
    for ($i = 0; $i -lt $postsList.Count; $i++) {
        $preview = $postsList[$i].Substring(0, [math]::Min(80, $postsList[$i].Length)).Replace("`n", " ")
        $ellipsis = if ($postsList[$i].Length -gt 80) { "..." } else { "" }
        Write-Host "  $($i + 1). ${preview}${ellipsis}"
    }

    # --- Step 2: Generate branded image for each post ---
    Write-Host ""
    Write-Host "Step 2: Generating branded images ($ImageModel)..." -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-Path $folderPath)) {
        New-Item -ItemType Directory -Path $folderPath -Force | Out-Null
    }

    $savedFiles = @()

    for ($i = 0; $i -lt $postsList.Count; $i++) {
        $postText = $postsList[$i]
        Write-Host "  Generating image $($i + 1)/$($postsList.Count)..." -NoNewline

        $imagePrompt = "$BrandDesignPrompt`n`nהפוסט:`n$postText"

        $qualityValue = if ($ImageModel -eq "dall-e-3") { "hd" } else { "auto" }
        $imageBody = @{
            model   = $ImageModel
            prompt  = $imagePrompt
            size    = "1024x1024"
            quality = $qualityValue
            n       = 1
        } | ConvertTo-Json -Depth 5

        try {
            $imgResponse = Invoke-RestMethod -Uri "https://api.openai.com/v1/images/generations" `
                -Method Post -Headers $headers -Body $imageBody

            $imageUrl = $imgResponse.data[0].url
            $filename = "yourzon_post_$($i + 1).png"
            $filepath = Join-Path $folderPath $filename

            Invoke-WebRequest -Uri $imageUrl -OutFile $filepath
            $savedFiles += $filepath
            Write-Host " saved: $filename" -ForegroundColor Green
        } catch {
            Write-Host " error: $_" -ForegroundColor Red
        }
    }

    # --- Step 3: Summary ---
    Write-Host ""
    Write-Host "Step 3: Done!" -ForegroundColor Cyan
    Write-Host "  Saved $($savedFiles.Count) post(s) to: $folderPath" -ForegroundColor Green
    foreach ($f in $savedFiles) {
        $sz = [math]::Round((Get-Item $f).Length / 1MB, 2)
        Write-Host "  $(Split-Path $f -Leaf)  ($sz MB)"
    }
    Start-Process explorer.exe $folderPath
    Write-Host "`nDone!" -ForegroundColor Green
}

# --- Mode: Browser (ChatGPT in Edge with saved profile) ---

function Invoke-Browser {
    $stamp = Get-Date

    Write-Host "=== YOURZON Post Creator — Browser Mode ===" -ForegroundColor Cyan
    Write-Host ""

    $hasSelenium = $false
    try {
        Import-Module Selenium -ErrorAction Stop
        $hasSelenium = $true
    } catch {}

    if ($hasSelenium -and -not $NoProfile) {
        Write-Host "Launching Edge with Selenium..." -ForegroundColor Cyan

        $edgeOpts = New-Object OpenQA.Selenium.Edge.EdgeOptions
        $profileDir = Join-Path $env:LOCALAPPDATA "Microsoft\Edge\User Data"
        if (Test-Path $profileDir) {
            $edgeOpts.AddArgument("user-data-dir=$profileDir")
            Write-Host "Using Edge profile: $profileDir"
        }
        $edgeOpts.AddArgument("--disable-blink-features=AutomationControlled")

        try {
            $driver = New-Object OpenQA.Selenium.Edge.EdgeDriver($edgeOpts)

            # --- Chat #1: Generate post texts ---
            Write-Host "`nStep 1: Opening ChatGPT for post generation..." -ForegroundColor Cyan
            $driver.Navigate().GoToUrl("https://chatgpt.com")
            Start-Sleep -Seconds 3

            $prompt = $PostsPromptTemplate -f $Posts
            Write-Host "  Type this prompt into ChatGPT:" -ForegroundColor Yellow
            Write-Host "  `"$prompt`""

            try {
                $inputEl = $driver.FindElementByCssSelector('textarea, [contenteditable="true"], #prompt-textarea')
                $inputEl.SendKeys($prompt)
                Start-Sleep -Seconds 1
                $inputEl.SendKeys([OpenQA.Selenium.Keys]::Return)
                Write-Host "  Prompt sent. Waiting for response..." -ForegroundColor Green
            } catch {
                Write-Host "  Could not auto-type. Please type the prompt manually." -ForegroundColor Yellow
            }

            Read-Host "`n  Press Enter when Chat #1 posts are ready"

            # --- Chat #2: Brand guidelines + images ---
            Write-Host "`nStep 2: Opening new chat for image generation..." -ForegroundColor Cyan
            Write-Host "  Pasting brand/design guidelines..." -ForegroundColor Yellow

            $driver.Navigate().GoToUrl("https://chatgpt.com")
            Start-Sleep -Seconds 3

            try {
                $inputEl2 = $driver.FindElementByCssSelector('textarea, [contenteditable="true"], #prompt-textarea')
                $inputEl2.SendKeys($BrandDesignPrompt)
                Start-Sleep -Seconds 1
                $inputEl2.SendKeys([OpenQA.Selenium.Keys]::Return)
                Write-Host "  Brand guidelines sent." -ForegroundColor Green
            } catch {
                Write-Host "  Could not auto-paste. Paste the brand guidelines manually." -ForegroundColor Yellow
            }

            Write-Host "`n  Now paste each post from Chat #1 into this chat, one at a time."
            Write-Host "  ChatGPT will generate a branded image for each post."
            Write-Host "  Download each generated image when ready."
            Read-Host "`n  Press Enter when all images are downloaded"

            try { $driver.Quit() } catch {}

        } catch {
            Write-Host "Selenium error: $_" -ForegroundColor Red
            Write-Host "Falling back to Start-Process..." -ForegroundColor Yellow
            Start-Process "https://chatgpt.com"

            Write-Host "`n--- ChatGPT Workflow ---" -ForegroundColor Cyan
            Write-Host "Chat #1 prompt: $($PostsPromptTemplate -f $Posts)" -ForegroundColor Yellow
            Write-Host "`nChat #2 prompt (brand guidelines) is copied to clipboard." -ForegroundColor Yellow
            $BrandDesignPrompt | Set-Clipboard
            Write-Host "  (Paste it into a new ChatGPT conversation)"
            Write-Host "`n  Then paste each post from Chat #1 into Chat #2, one at a time."
            Write-Host "  Download each generated image."
            Read-Host "`n  Press Enter when done"
        }
    } else {
        Write-Host "Opening ChatGPT: https://chatgpt.com" -ForegroundColor Cyan
        Start-Process "https://chatgpt.com"

        Write-Host "`n--- ChatGPT Workflow ---" -ForegroundColor Cyan
        $prompt = $PostsPromptTemplate -f $Posts
        Write-Host "1. Chat #1 — type: `"$prompt`"" -ForegroundColor Yellow
        Write-Host "2. Open a NEW chat"
        Write-Host "3. Chat #2 — paste the brand guidelines (copied to clipboard)" -ForegroundColor Yellow
        $BrandDesignPrompt | Set-Clipboard
        Write-Host "4. Paste each post from Chat #1 into Chat #2, one at a time"
        Write-Host "5. Download each generated image"
        Read-Host "`nPress Enter when all images are downloaded"
    }

    # --- Organize downloads ---
    Write-Host "`nStep 3: Organizing downloaded files..." -ForegroundColor Cyan
    $files = Get-RecentImages -Path $DownloadsDir -Since $stamp
    if (-not $files -or $files.Count -eq 0) {
        $files = Get-RecentImages -Path $DownloadsDir -Since (Get-Date).AddMinutes(-30)
    }
    if (-not $files -or $files.Count -eq 0) {
        Write-Host "No downloaded images found." -ForegroundColor Red
        return
    }

    Show-Files -Files $files -Label "Downloaded"

    $folderNameResolved = Get-DatedFolderName -Custom $FolderName
    $folderPath = Join-Path $DesktopDir $folderNameResolved

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

    $folderNameResolved = Get-DatedFolderName -Custom $FolderName
    $folderPath = Join-Path $DesktopDir $folderNameResolved

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

# --- Main ---

Write-Host ""
switch ($Mode) {
    "Organize" { Invoke-Organize }
    "Browser"  { Invoke-Browser }
    "Api"      { Invoke-Api }
}
