# restore-terminals.ps1
#
# Windows rollback for the "context limit" fix (fix-context-limit.sh /
# apply-globally.sh) that made Claude Code terminals exit right after
# startup. Reverts every machine-level change the fix made and reports
# anything suspicious it cannot safely change on its own.
#
# Run from PowerShell (no admin needed):
#   irm https://raw.githubusercontent.com/khnzyw710-hub/-/claude/claude-code-terminals-b7wh24/.claude/restore-terminals.ps1 | iex
#
# Options (set BEFORE the one-liner, in the same line):
#   $Check = $true;       # dry run - report only, change nothing
#   $KeepCompact = $true; # keep the auto-compact settings, remove only
#                         # the tool-search parts (the crash cause)
#
# Example dry run:
#   $Check = $true; irm https://raw.githubusercontent.com/khnzyw710-hub/-/claude/claude-code-terminals-b7wh24/.claude/restore-terminals.ps1 | iex
#
# Compatible with Windows PowerShell 5.1 and PowerShell 7+.
# Every file it modifies is backed up first (*.restore-bak / *.corrupt-bak).

$restorePrevEap = $ErrorActionPreference
$ErrorActionPreference = 'Stop'

# --- options (settable from the calling shell; no param() so iex works) ---
if (-not (Test-Path variable:Check))       { $Check = $false }
if (-not (Test-Path variable:KeepCompact)) { $KeepCompact = $false }

# --- output helpers ---
function Say-Info  ($m) { Write-Host "  $m" }
function Say-Ok    ($m) { Write-Host "  [OK]      $m" -ForegroundColor Green }
function Say-Change($m) { Write-Host "  [CHANGED] $m" -ForegroundColor Cyan;   $script:changes++ }
function Say-Would ($m) { Write-Host "  [WOULD]   $m" -ForegroundColor Cyan;   $script:changes++ }
function Say-Warn  ($m) { Write-Host "  [WARN]    $m" -ForegroundColor Yellow; $script:warnings++ }
function Say-Head  ($m) { Write-Host ""; Write-Host "== $m ==" -ForegroundColor White }

$script:changes  = 0
$script:warnings = 0

$homeDir = $HOME
if (-not $homeDir) { $homeDir = $env:USERPROFILE }
$configDir = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $homeDir '.claude' }

Write-Host ""
Write-Host "Claude Code terminal restore (Windows)" -ForegroundColor White
if ($Check)       { Write-Host "Mode: CHECK ONLY - nothing will be changed" -ForegroundColor Yellow }
if ($KeepCompact) { Write-Host "Mode: keeping auto-compact settings, removing only tool-search" -ForegroundColor Yellow }
Say-Info "Home:       $homeDir"
Say-Info "Config dir: $configDir"

# Settings keys the fix added
$envKeysAlways = @('ENABLE_TOOL_SEARCH')
$envKeysCompact = @('CLAUDE_CODE_AUTO_COMPACT_WINDOW', 'MAX_MCP_OUTPUT_TOKENS')
$topKeysCompact = @('autoCompactWindow', 'autoCompactEnabled')

# Variables that can break/redirect Claude Code if set machine-wide
$watchVars = @(
    'ENABLE_TOOL_SEARCH',
    'CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS',
    'CLAUDE_CODE_MAX_CONTEXT_TOKENS',
    'DISABLE_AUTO_COMPACT',
    'DISABLE_COMPACT',
    'CLAUDE_CODE_BLOCKING_LIMIT_OVERRIDE',
    'ANTHROPIC_BASE_URL',
    'CLAUDE_CODE_AUTO_COMPACT_WINDOW',
    'MAX_MCP_OUTPUT_TOKENS'
)

function Backup-File ($path) {
    $bak = "$path.restore-bak"
    Copy-Item -LiteralPath $path -Destination $bak -Force
    Say-Info "backup: $bak"
}

function Write-Utf8NoBom ($path, $text) {
    $full = [System.IO.Path]::GetFullPath($path)
    [System.IO.File]::WriteAllText($full, $text, [System.Text.UTF8Encoding]::new($false))
}

# ------------------------------------------------------------------
Say-Head "1. Claude settings files ($configDir)"
# ------------------------------------------------------------------
foreach ($name in @('settings.json', 'settings.local.json')) {
    $path = Join-Path $configDir $name
    if (-not (Test-Path -LiteralPath $path)) { Say-Info "$name - not present, nothing to do"; continue }

    $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
    $json = $null
    $parseOk = $true
    try {
        if ($raw -and $raw.Trim()) { $json = $raw | ConvertFrom-Json } else { $parseOk = $false }
    } catch { $parseOk = $false }

    if (-not $parseOk) {
        if ($Check) {
            Say-Warn "$name is not valid JSON - would move it aside to $name.corrupt-bak"
        } else {
            Move-Item -LiteralPath $path -Destination "$path.corrupt-bak" -Force
            Say-Change "$name was not valid JSON - moved to $name.corrupt-bak"
        }
        continue
    }

    $toRemoveEnv = @($envKeysAlways)
    $toRemoveTop = @()
    if (-not $KeepCompact) {
        $toRemoveEnv += $envKeysCompact
        $toRemoveTop += $topKeysCompact
    }

    $found = @()
    foreach ($k in $toRemoveTop) {
        if ($json.PSObject.Properties[$k]) { $found += $k }
    }
    $envObj = $null
    if ($json.PSObject.Properties['env']) { $envObj = $json.env }
    if ($envObj) {
        foreach ($k in $toRemoveEnv) {
            if ($envObj.PSObject.Properties[$k]) { $found += "env.$k" }
        }
    }

    if ($found.Count -eq 0) { Say-Ok "$name - already clean"; continue }

    if ($Check) {
        Say-Would "$name - would remove: $($found -join ', ')"
        continue
    }

    Backup-File $path
    foreach ($k in $toRemoveTop) { [void]$json.PSObject.Properties.Remove($k) }
    if ($envObj) {
        foreach ($k in $toRemoveEnv) { [void]$envObj.PSObject.Properties.Remove($k) }
        if (@($envObj.PSObject.Properties).Count -eq 0) { [void]$json.PSObject.Properties.Remove('env') }
    }
    Write-Utf8NoBom $path (($json | ConvertTo-Json -Depth 64) + "`n")
    Say-Change "$name - removed: $($found -join ', ')"
}

# ------------------------------------------------------------------
Say-Head "2. Claude state file ($homeDir\.claude.json)"
# ------------------------------------------------------------------
$statePath = Join-Path $homeDir '.claude.json'
if (-not (Test-Path -LiteralPath $statePath)) {
    Say-Info ".claude.json not present (Claude will create it on next run)"
} else {
    $stateOk = $true
    try {
        $rawState = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop
        if ($rawState -and $rawState.Trim()) { $null = $rawState | ConvertFrom-Json } else { $stateOk = $false }
    } catch { $stateOk = $false }

    if ($stateOk) {
        Say-Ok ".claude.json is valid JSON"
    } elseif ($Check) {
        Say-Warn ".claude.json is CORRUPT - would move it aside (a corrupt state file makes claude exit right after startup)"
    } else {
        Move-Item -LiteralPath $statePath -Destination "$statePath.corrupt-bak" -Force
        Say-Change ".claude.json was corrupt - moved to .claude.json.corrupt-bak"
        Say-Warn "Claude will start fresh: you may need to run /login once and re-add MCP servers"
    }
}

# ------------------------------------------------------------------
Say-Head "3. Git Bash / WSL-style shell profiles in $homeDir"
# ------------------------------------------------------------------
$startMarker = '# --- claude-code context fix (added by fix-context-limit.sh) ---'
$endMarker   = '# --- end claude-code context fix ---'
$profileNames = @('.zshrc', '.zprofile', '.bashrc', '.bash_profile', '.profile')
$foundAnyProfile = $false

foreach ($name in $profileNames) {
    $path = Join-Path $homeDir $name
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $foundAnyProfile = $true

    $lines = @(Get-Content -LiteralPath $path -ErrorAction Stop)
    if ($lines -notcontains $startMarker) { Say-Ok "$name - no fix block"; continue }

    if ($Check) {
        Say-Would "$name - would remove the claude-code context fix block"
        continue
    }

    Backup-File $path
    $keep = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($line in $lines) {
        if ($line -eq $startMarker) { $skip = $true; continue }
        if ($line -eq $endMarker)   { $skip = $false; continue }
        if (-not $skip) { $keep.Add($line) }
    }
    Write-Utf8NoBom $path (($keep -join "`n") + "`n")
    Say-Change "$name - removed the claude-code context fix block"
}
if (-not $foundAnyProfile) { Say-Info "no bash/zsh profile files found (fine on Windows)" }

# ------------------------------------------------------------------
Say-Head "4. Windows environment variables"
# ------------------------------------------------------------------
$removeVars = @($envKeysAlways)
if (-not $KeepCompact) { $removeVars += $envKeysCompact }

foreach ($v in $removeVars) {
    $userVal = [Environment]::GetEnvironmentVariable($v, 'User')
    if ($null -ne $userVal) {
        if ($Check) {
            Say-Would "User-level variable $v=$userVal - would remove it"
        } else {
            [Environment]::SetEnvironmentVariable($v, $null, 'User')
            Say-Change "removed User-level variable $v (was: $userVal)"
        }
    }
}

foreach ($v in $watchVars) {
    $machineVal = $null
    try { $machineVal = [Environment]::GetEnvironmentVariable($v, 'Machine') } catch { }
    if ($null -ne $machineVal) {
        Say-Warn "MACHINE-level variable $v=$machineVal is set. Removing it needs an admin PowerShell:"
        Say-Info "    [Environment]::SetEnvironmentVariable('$v', `$null, 'Machine')"
    }
}

$openWindowVars = @()
foreach ($v in $watchVars) {
    if ($null -ne [Environment]::GetEnvironmentVariable($v)) { $openWindowVars += $v }
}
if ($openWindowVars.Count -gt 0) {
    Say-Warn "still set in THIS window: $($openWindowVars -join ', ')"
    Say-Warn "close ALL terminal windows after this script so no window keeps the old values"
} else {
    Say-Ok "no watched variables active in this window"
}

# ------------------------------------------------------------------
Say-Head "5. PowerShell profile scan (report only)"
# ------------------------------------------------------------------
$psProfiles = @(
    (Join-Path $homeDir 'Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $homeDir 'Documents\WindowsPowerShell\profile.ps1'),
    (Join-Path $homeDir 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'),
    (Join-Path $homeDir 'Documents\PowerShell\profile.ps1')
)
$watchPattern = ($watchVars -join '|')
$hitAny = $false
foreach ($p in $psProfiles) {
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $hits = @(Select-String -LiteralPath $p -Pattern $watchPattern -ErrorAction SilentlyContinue)
    if ($hits.Count -gt 0) {
        $hitAny = $true
        Say-Warn "$p mentions Claude-related variables - review these lines:"
        foreach ($h in $hits) { Say-Info "    line $($h.LineNumber): $($h.Line.Trim())" }
    }
}
if (-not $hitAny) { Say-Ok "PowerShell profiles do not set any watched variables" }

# ------------------------------------------------------------------
Say-Head "6. Claude Code installation"
# ------------------------------------------------------------------
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
if ($claudeCmd) {
    $ver = ''
    try { $ver = (& claude --version 2>$null | Select-Object -First 1) } catch { }
    if ($ver) { Say-Ok "claude found: $ver" } else { Say-Ok "claude found at $($claudeCmd.Source)" }
} else {
    Say-Warn "claude is not on PATH in this window. If it normally works from your shortcuts, that's fine."
    Say-Info "To reinstall/repair: irm https://claude.ai/install.ps1 | iex"
}

# ------------------------------------------------------------------
Say-Head "Result"
# ------------------------------------------------------------------
if ($Check) {
    if ($script:changes -eq 0) {
        Write-Host "  Check finished: nothing left from the fix to remove." -ForegroundColor Green
    } else {
        Write-Host "  Check finished: $($script:changes) change(s) would be made. Run again without `$Check to apply." -ForegroundColor Yellow
    }
} elseif ($script:changes -eq 0) {
    Write-Host "  Nothing needed changing - the fix's leftovers were already gone." -ForegroundColor Green
} else {
    Write-Host "  Done: $($script:changes) change(s) applied. Backups end in .restore-bak / .corrupt-bak" -ForegroundColor Green
}
if ($script:warnings -gt 0) {
    Write-Host "  $($script:warnings) warning(s) above need a look." -ForegroundColor Yellow
}
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor White
Write-Host "   1. Close ALL terminal / PowerShell windows (old windows keep old variables)"
Write-Host "   2. Open your Claude Code shortcut (or a new terminal) and run: claude"
Write-Host "   3. Still broken? Run: claude doctor   and send the output back"
Write-Host ""

$ErrorActionPreference = $restorePrevEap
