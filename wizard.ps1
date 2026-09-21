<#
.SYNOPSIS
  Interactive wizard for preparing and shipping a rickroll page.

.DESCRIPTION
  Collects the handful of values that actually change between pranks, writes them
  into src/index.html (every duplicated tag at once), verifies the thumbnail,
  serves the page locally for review, then — only on your say-so — commits on a
  branch, merges to main, pushes, and prints the live URL with a unique cache-
  busting query string.

  Run it from anywhere:  .\wizard.ps1

.NOTES
  Follows the workflow in CLAUDE.md: work on a branch, test, then merge to main.
  Merging to main is what deploys.
#>

[CmdletBinding()]
param(
    [int]$Port = 8000,
    # Skip the local server step (not recommended).
    [switch]$NoServe,
    # Non-interactive check that the rewrite still finds every anchor. Changes nothing.
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$IndexPath = Join-Path $Root 'src\index.html'
$ThumbPath = Join-Path $Root 'src\thumb.jpg'

# ---------------------------------------------------------------- presentation

function Write-Step  { param($Text) Write-Host "`n=== $Text ===" -ForegroundColor Cyan }
function Write-Ok    { param($Text) Write-Host "  [ok] $Text" -ForegroundColor Green }
function Write-Warn2 { param($Text) Write-Host "  [!]  $Text" -ForegroundColor Yellow }
function Write-Bad   { param($Text) Write-Host "  [x]  $Text" -ForegroundColor Red }
function Write-Info  { param($Text) Write-Host "  $Text" -ForegroundColor Gray }

function Fail { param($Text) Write-Bad $Text; Write-Host ''; exit 1 }

# Prompt with a default; Enter keeps the current value.
function Ask {
    param([string]$Label, [string]$Default, [scriptblock]$Validate, [string]$ValidationHint)
    while ($true) {
        if ([string]::IsNullOrEmpty($Default)) {
            $answer = Read-Host "  $Label"
        } else {
            Write-Host "  $Label" -ForegroundColor White
            Write-Host "    current: $Default" -ForegroundColor DarkGray
            $answer = Read-Host "    new (Enter to keep)"
            if ([string]::IsNullOrWhiteSpace($answer)) { $answer = $Default }
        }
        if ($null -eq $Validate) { return $answer }
        if (& $Validate $answer) { return $answer }
        Write-Warn2 $ValidationHint
    }
}

function Confirm2 {
    param([string]$Question, [string]$DefaultAnswer = 'n')
    $suffix = '[y/N]'
    if ($DefaultAnswer -eq 'y') { $suffix = '[Y/n]' }
    $a = Read-Host "  $Question $suffix"
    if ([string]::IsNullOrWhiteSpace($a)) { $a = $DefaultAnswer }
    return ($a -match '^(y|yes)$')
}

# ------------------------------------------------------------------- utilities

function HtmlAttr {
    param([string]$s)
    $s = $s -replace '&', '&amp;'
    $s = $s -replace '"', '&quot;'
    $s = $s -replace '<', '&lt;'
    $s = $s -replace '>', '&gt;'
    return $s
}

function JsString {
    param([string]$s)
    $s = $s -replace '\\', '\\'
    $s = $s -replace '"', '\"'
    return $s
}

function Read-Utf8 { param($Path) return [System.IO.File]::ReadAllText($Path) }

function Write-Utf8 {
    param($Path, $Text)
    $enc = New-Object System.Text.UTF8Encoding($false)   # no BOM
    [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

# Replace exactly one regex match, failing loudly if the anchor moved.
function Replace-Once {
    param([string]$Text, [string]$Pattern, [string]$Replacement, [string]$What)
    $rx = [regex]$Pattern
    $count = $rx.Matches($Text).Count
    if ($count -lt 1) { Fail "Could not find $What in src/index.html. The file may have been restructured; fix it by hand." }
    return $rx.Replace($Text, $Replacement)
}

function Get-Match {
    param([string]$Text, [string]$Pattern)
    $m = [regex]::Match($Text, $Pattern)
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Invoke-Git {
    param([string[]]$Arguments, [switch]$AllowFail)
    $out = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFail) {
        Fail ("git " + ($Arguments -join ' ') + " failed:`n$out")
    }
    return $out
}

# ------------------------------------------------------- local server (no deps)

# Is `python` a real interpreter, or the Microsoft Store stub?
function Test-RealPython {
    $cmd = Get-Command python -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { return $false }
    try {
        $probe = & python -c "print('pythonok')" 2>$null
        return ($probe -join '') -match 'pythonok'
    } catch { return $false }
}

# Minimal static file server on raw sockets. Needs no admin rights and no
# dependencies, unlike HttpListener (URL ACLs) or python (may not be installed).
$ServerScript = {
    param($RootDir, $Port)

    $mime = @{
        '.html' = 'text/html; charset=utf-8'
        '.htm'  = 'text/html; charset=utf-8'
        '.jpg'  = 'image/jpeg'
        '.jpeg' = 'image/jpeg'
        '.png'  = 'image/png'
        '.gif'  = 'image/gif'
        '.ico'  = 'image/x-icon'
        '.css'  = 'text/css; charset=utf-8'
        '.js'   = 'application/javascript; charset=utf-8'
        '.svg'  = 'image/svg+xml'
        '.json' = 'application/json; charset=utf-8'
    }

    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
    $listener.Start()

    try {
        while ($true) {
            $client = $listener.AcceptTcpClient()
            try {
                $client.ReceiveTimeout = 5000
                $client.SendTimeout = 5000
                $stream = $client.GetStream()

                # Read just the request head.
                $buf = New-Object byte[] 8192
                $sb = New-Object System.Text.StringBuilder
                while ($true) {
                    $n = $stream.Read($buf, 0, $buf.Length)
                    if ($n -le 0) { break }
                    [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buf, 0, $n))
                    if ($sb.ToString().Contains("`r`n`r`n")) { break }
                }
                $request = $sb.ToString()
                if ([string]::IsNullOrWhiteSpace($request)) { continue }

                $requestLine = ($request -split "`r`n")[0]
                $parts = $requestLine -split ' '
                $method = $parts[0]
                $target = '/'
                if ($parts.Count -gt 1) { $target = $parts[1] }

                # Strip query/fragment, decode, normalise.
                $path = ($target -split '\?')[0]
                $path = ($path -split '#')[0]
                $path = [System.Uri]::UnescapeDataString($path)
                if ($path.EndsWith('/')) { $path = $path + 'index.html' }
                $relative = $path.TrimStart('/')

                $status = '200 OK'
                $body = $null
                $type = 'application/octet-stream'

                if ($method -ne 'GET' -and $method -ne 'HEAD') {
                    $status = '405 Method Not Allowed'
                    $body = [System.Text.Encoding]::UTF8.GetBytes('405')
                    $type = 'text/plain; charset=utf-8'
                } else {
                    $full = [System.IO.Path]::GetFullPath((Join-Path $RootDir $relative))
                    $rootFull = [System.IO.Path]::GetFullPath($RootDir)
                    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
                        $status = '403 Forbidden'
                        $body = [System.Text.Encoding]::UTF8.GetBytes('403')
                        $type = 'text/plain; charset=utf-8'
                    } elseif (Test-Path -LiteralPath $full -PathType Leaf) {
                        $body = [System.IO.File]::ReadAllBytes($full)
                        $ext = [System.IO.Path]::GetExtension($full).ToLowerInvariant()
                        if ($mime.ContainsKey($ext)) { $type = $mime[$ext] }
                    } else {
                        $status = '404 Not Found'
                        $body = [System.Text.Encoding]::UTF8.GetBytes('404 not found')
                        $type = 'text/plain; charset=utf-8'
                    }
                }

                $head = "HTTP/1.1 $status`r`n" +
                        "Content-Type: $type`r`n" +
                        "Content-Length: $($body.Length)`r`n" +
                        "Cache-Control: no-store`r`n" +
                        "Connection: close`r`n`r`n"
                $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
                $stream.Write($headBytes, 0, $headBytes.Length)
                if ($method -ne 'HEAD') { $stream.Write($body, 0, $body.Length) }
                $stream.Flush()
            } catch {
                # A dropped connection is normal; keep serving.
            } finally {
                $client.Close()
            }
        }
    } finally {
        $listener.Stop()
    }
}

function Start-LocalServer {
    param([string]$ServeRoot, [int]$Port)

    if (Test-RealPython) {
        Write-Info "Using python -m http.server on port $Port"
        $p = Start-Process -FilePath 'python' -ArgumentList @('-m', 'http.server', "$Port") `
                           -WorkingDirectory $ServeRoot -PassThru -WindowStyle Hidden
        return [pscustomobject]@{ Kind = 'process'; Handle = $p }
    }

    Write-Info "Python not available; using the built-in PowerShell server on port $Port"
    $job = Start-Job -ScriptBlock $script:ServerScript -ArgumentList $ServeRoot, $Port
    return [pscustomobject]@{ Kind = 'job'; Handle = $job }
}

function Stop-LocalServer {
    param($Server)
    if ($null -eq $Server) { return }
    try {
        if ($Server.Kind -eq 'process') {
            if (-not $Server.Handle.HasExited) { Stop-Process -Id $Server.Handle.Id -Force }
        } else {
            Stop-Job -Job $Server.Handle -ErrorAction SilentlyContinue
            Remove-Job -Job $Server.Handle -Force -ErrorAction SilentlyContinue
        }
    } catch { }
}

function Wait-ForServer {
    param([int]$Port, [int]$TimeoutSeconds = 10)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $c = New-Object System.Net.Sockets.TcpClient
            $c.Connect('127.0.0.1', $Port)
            $c.Close()
            return $true
        } catch {
            Start-Sleep -Milliseconds 300
        }
    }
    return $false
}

# ------------------------------------------------------------- the rewrite --

# Everything that varies between pranks, applied in one place. Returns the new
# HTML. Kept as a function so -SelfTest can exercise it without the prompts.
function Set-PrankValues {
    param([string]$Html, [hashtable]$V)

    $eTitle = HtmlAttr $V.PageTitle
    $eDesc  = HtmlAttr $V.Description
    $eOg    = HtmlAttr $V.OgTitle
    $eViews = $V.Views          # may legitimately contain entities like &middot;

    $Html = Replace-Once $Html '<title>.*?</title>' "<title>$eTitle</title>" 'the <title> tag'
    $Html = Replace-Once $Html '<meta name="description" content=".*?">' "<meta name=`"description`" content=`"$eDesc`">" 'the description tag'
    $Html = Replace-Once $Html '<meta property="og:title" content=".*?">' "<meta property=`"og:title`" content=`"$eOg`">" 'og:title'
    $Html = Replace-Once $Html '<meta property="og:description" content=".*?">' "<meta property=`"og:description`" content=`"$eDesc`">" 'og:description'
    $Html = Replace-Once $Html '<meta name="twitter:title" content=".*?">' "<meta name=`"twitter:title`" content=`"$eOg`">" 'twitter:title'
    $Html = Replace-Once $Html '<meta name="twitter:description" content=".*?">' "<meta name=`"twitter:description`" content=`"$eDesc`">" 'twitter:description'

    # Absolute image URLs, derived from the remote, plus the real pixel dimensions.
    $Html = Replace-Once $Html '<meta property="og:image" content=".*?">' "<meta property=`"og:image`" content=`"$($V.ThumbUrl)`">" 'og:image'
    $Html = Replace-Once $Html '<meta name="twitter:image" content=".*?">' "<meta name=`"twitter:image`" content=`"$($V.ThumbUrl)`">" 'twitter:image'
    $Html = Replace-Once $Html '<meta property="og:image:width" content="\d+">' "<meta property=`"og:image:width`" content=`"$($V.ThumbW)`">" 'og:image:width'
    $Html = Replace-Once $Html '<meta property="og:image:height" content="\d+">' "<meta property=`"og:image:height`" content=`"$($V.ThumbH)`">" 'og:image:height'

    $Html = Replace-Once $Html '<div class="meta">.*?</div>' "<div class=`"meta`">$eViews</div>" 'the view count line'

    # ${1} must be brace-delimited: "$1" followed by a digit reads as group 1x.
    $Html = Replace-Once $Html 'decoyVideoId:(\s*)"[^"]*"' ("decoyVideoId:`${1}`"" + (JsString $V.DecoyId) + '"') 'decoyVideoId'
    $Html = Replace-Once $Html 'decoyStartSeconds:(\s*)\d+' "decoyStartSeconds:`${1}$($V.DecoyStart)" 'decoyStartSeconds'
    $Html = Replace-Once $Html 'switchAfterSeconds:(\s*)\d+' "switchAfterSeconds:`${1}$($V.SwitchAfter)" 'switchAfterSeconds'
    $Html = Replace-Once $Html 'rickStartSeconds:(\s*)\d+' "rickStartSeconds:`${1}$($V.RickStart)" 'rickStartSeconds'

    return $Html
}

# ============================================================== -1. SELFTEST ==

if ($SelfTest) {
    Write-Host ''
    Write-Host '  SELF TEST (nothing is written or pushed)' -ForegroundColor Magenta

    $sample = @{
        PageTitle   = 'Tab & "heading" <test>'
        Description = 'Teaser with & and "quotes"'
        OgTitle     = 'Headline'
        Views       = '9.9M views &middot; 1 hour ago'
        ThumbUrl    = 'https://example.com/thumb.jpg'
        ThumbW      = 1200
        ThumbH      = 630
        DecoyId     = 'abcdefghijk'
        DecoyStart  = 5
        SwitchAfter = 11
        RickStart   = 43
    }

    $before = Read-Utf8 $IndexPath
    $after = Set-PrankValues -Html $before -V $sample

    $checks = @(
        @{ Name = 'page title';   Pattern = '<title>Tab &amp; &quot;heading&quot; &lt;test&gt;</title>' },
        @{ Name = 'description';  Pattern = '<meta name="description" content="Teaser with &amp; and &quot;quotes&quot;">' },
        @{ Name = 'og:title';     Pattern = '<meta property="og:title" content="Headline">' },
        @{ Name = 'twitter:title';Pattern = '<meta name="twitter:title" content="Headline">' },
        @{ Name = 'og:image';     Pattern = '<meta property="og:image" content="https://example\.com/thumb\.jpg">' },
        @{ Name = 'twitter:image';Pattern = '<meta name="twitter:image" content="https://example\.com/thumb\.jpg">' },
        @{ Name = 'image width';  Pattern = '<meta property="og:image:width" content="1200">' },
        @{ Name = 'image height'; Pattern = '<meta property="og:image:height" content="630">' },
        @{ Name = 'view count';   Pattern = '<div class="meta">9\.9M views &middot; 1 hour ago</div>' },
        @{ Name = 'decoy id';     Pattern = 'decoyVideoId:\s*"abcdefghijk"' },
        @{ Name = 'decoy start';  Pattern = 'decoyStartSeconds:\s*5\b' },
        @{ Name = 'switch after'; Pattern = 'switchAfterSeconds:\s*11\b' },
        @{ Name = 'rick start';   Pattern = 'rickStartSeconds:\s*43\b' }
    )

    $failed = 0
    foreach ($c in $checks) {
        if ($after -match $c.Pattern) { Write-Ok $c.Name } else { Write-Bad "$($c.Name) NOT applied"; $failed++ }
    }

    # The structural bits the prank depends on must survive untouched.
    foreach ($guard in @('id="rick"', 'id="yt"', 'z-index: 3', 'preloadRick', 'onYouTubeIframeAPIReady')) {
        if ($after -match [regex]::Escape($guard)) { Write-Ok "preserved: $guard" } else { Write-Bad "LOST: $guard"; $failed++ }
    }

    if ($after -eq $before) { Write-Bad 'Nothing changed at all.'; $failed++ }

    Write-Host ''
    if ($failed -eq 0) { Write-Ok 'All checks passed.'; exit 0 } else { Write-Bad "$failed check(s) failed."; exit 1 }
}

# ============================================================== 0. PREFLIGHT ==

Write-Host ''
Write-Host '  RICKROLL WIZARD' -ForegroundColor Magenta
Write-Host '  ---------------' -ForegroundColor Magenta

Write-Step '0. Checking the repo'

if (-not (Test-Path $IndexPath)) { Fail "src\index.html not found. Run this script from inside the project." }
Set-Location $Root

if ($null -eq (Get-Command git -ErrorAction SilentlyContinue)) { Fail 'git is not on PATH.' }

$dirty = Invoke-Git @('status', '--porcelain')
if (-not [string]::IsNullOrWhiteSpace(($dirty -join ''))) {
    Write-Warn2 'You have uncommitted changes:'
    Write-Host ($dirty -join "`n") -ForegroundColor DarkGray
    Write-Info 'Only src/index.html and src/thumb.jpg get committed, so anything else stays put.'
    if (-not (Confirm2 'Continue anyway?')) {
        Fail 'Stopped. Commit or stash first.'
    }
}

# main must be current, or the ff-only merge at the end will fail after you have
# already answered every question.
Invoke-Git @('fetch', '-q', 'origin') | Out-Null
$behind = (Invoke-Git @('rev-list', '--count', 'HEAD..origin/main') -AllowFail)
if ($behind -match '^\s*[1-9]') {
    Write-Warn2 "Your main is $($behind.Trim()) commit(s) behind origin/main."
    if (Confirm2 'Pull now?' 'y') {
        Invoke-Git @('pull', '--ff-only', 'origin', 'main') | Out-Null
        Write-Ok 'Pulled.'
    } else {
        Fail 'Stopped. The merge at the end would fail.'
    }
}

$currentBranch = (Invoke-Git @('rev-parse', '--abbrev-ref', 'HEAD')).Trim()
Write-Ok "On branch $currentBranch"

# Work out the Pages URL from the origin remote rather than hardcoding it.
$remote = (Invoke-Git @('remote', 'get-url', 'origin')).Trim()
$owner = ''; $repo = ''
$m = [regex]::Match($remote, '(?:github\.com[:/])([^/]+)/([^/\.]+)')
if ($m.Success) { $owner = $m.Groups[1].Value; $repo = $m.Groups[2].Value }
if ([string]::IsNullOrEmpty($owner)) { Fail "Could not parse the GitHub owner/repo out of origin: $remote" }

$siteUrl = "https://$owner.github.io/$repo/"
$thumbUrl = "$siteUrl" + 'thumb.jpg'
Write-Ok "Site URL: $siteUrl"

# ======================================================== 1. THUMBNAIL CHECK ==

Write-Step '1. Verifying the thumbnail'

if (-not (Test-Path $ThumbPath)) {
    Fail "src\thumb.jpg is missing. Put your image there (this same file is both the chat preview and the pre-play cover), then re-run."
}

Add-Type -AssemblyName System.Drawing
$thumbW = 0; $thumbH = 0
try {
    $img = [System.Drawing.Image]::FromFile($ThumbPath)
    $thumbW = $img.Width; $thumbH = $img.Height
    $img.Dispose()
} catch {
    Fail "src\thumb.jpg could not be read as an image: $($_.Exception.Message)"
}

$thumbBytes = (Get-Item $ThumbPath).Length
$thumbKb = [math]::Round($thumbBytes / 1KB, 1)
Write-Ok "thumb.jpg is ${thumbW}x${thumbH}, $thumbKb KB"

if ($thumbBytes -gt 1MB) {
    Write-Warn2 'Over 1 MB. Some chat apps skip large preview images; consider compressing it.'
}
if ($thumbW -lt 600) {
    Write-Warn2 "Only ${thumbW}px wide. Chat apps tend to demote images under ~600px to a small"
    Write-Warn2 'square thumbnail instead of the big preview card. 1200x630 is the ideal.'
    if (-not (Confirm2 'Use it anyway?' 'y')) { Fail 'Stopped. Swap in a wider image and re-run.' }
}

$freshThumb = (Get-Item $ThumbPath).LastWriteTime
Write-Info "Last modified: $freshThumb"
if (-not (Confirm2 'Is this the image you want for THIS prank?' 'y')) {
    Fail 'Stopped. Replace src\thumb.jpg, then re-run.'
}

# =========================================================== 2. GATHER INPUT ==

Write-Step '2. The story'

$html = Read-Utf8 $IndexPath

$curPageTitle   = Get-Match $html '<title>(.*?)</title>'
$curDescription = Get-Match $html '<meta name="description" content="(.*?)">'
$curOgTitle     = Get-Match $html '<meta property="og:title" content="(.*?)">'
$curOgDesc      = Get-Match $html '<meta property="og:description" content="(.*?)">'
$curViews       = Get-Match $html '<div class="meta">(.*?)</div>'
$curDecoy       = Get-Match $html 'decoyVideoId:\s*"([^"]*)"'
$curDecoyStart  = Get-Match $html 'decoyStartSeconds:\s*(\d+)'
$curSwitch      = Get-Match $html 'switchAfterSeconds:\s*(\d+)'
$curRickStart   = Get-Match $html 'rickStartSeconds:\s*(\d+)'

Write-Info 'This is the headline the chat app shows in the preview card.'
$ogTitle = Ask -Label 'Preview headline (og:title)' -Default $curOgTitle

Write-Info ''
Write-Info 'One-line teaser under the headline. Used in all three description tags.'
$description = Ask -Label 'Preview description' -Default $curOgDesc

Write-Info ''
Write-Info 'Browser tab text, also shown as the heading under the player.'
$pageTitle = Ask -Label 'Page title' -Default $curPageTitle

Write-Info ''
$views = Ask -Label 'Fake view count line' -Default $curViews

Write-Step '3. The videos'

$idValidator = { param($v) return ($v -match '^[A-Za-z0-9_-]{11}$') }
$decoyId = Ask -Label 'Decoy YouTube video id (11 chars)' -Default $curDecoy `
               -Validate $idValidator -ValidationHint 'Must be exactly 11 characters from A-Z a-z 0-9 _ -'

# Embedding check: a video that refuses embedding shows "Video unavailable" and
# the prank dies on the doorstep.
Write-Info 'Checking that the decoy allows embedding...'
$embeddable = $false
try {
    $oembed = "https://www.youtube.com/oembed?url=https://www.youtube.com/watch?v=$decoyId&format=json"
    $resp = Invoke-WebRequest -Uri $oembed -UseBasicParsing -TimeoutSec 15
    if ($resp.StatusCode -eq 200) {
        $embeddable = $true
        $meta = $resp.Content | ConvertFrom-Json
        Write-Ok "Embeddable: `"$($meta.title)`" by $($meta.author_name)"
    }
} catch {
    Write-Warn2 "oEmbed check failed: $($_.Exception.Message)"
}
if (-not $embeddable) {
    Write-Warn2 'That video may not be embeddable, or the check could not reach YouTube.'
    if (-not (Confirm2 'Continue with this id anyway?')) { Fail 'Stopped. Pick another video.' }
}

$intValidator = { param($v) return ($v -match '^\d+$') }
$decoyStart = Ask -Label 'Start the decoy at (seconds, 0 = beginning)' -Default $curDecoyStart `
                  -Validate $intValidator -ValidationHint 'Whole seconds, 0 or more.'
$switchAfter = Ask -Label 'Switch to Rick after (seconds of decoy playback)' -Default $curSwitch `
                   -Validate $intValidator -ValidationHint 'Whole seconds, 0 or more.'
$rickStart = Ask -Label 'Start Rick at (seconds, 43 = straight into the chorus)' -Default $curRickStart `
                 -Validate $intValidator -ValidationHint 'Whole seconds, 0 or more.'

# ============================================================== 4. APPLY IT ==

Write-Step '4. Writing src/index.html'

$html = Set-PrankValues -Html $html -V @{
    PageTitle   = $pageTitle
    Description = $description
    OgTitle     = $ogTitle
    Views       = $views
    ThumbUrl    = $thumbUrl
    ThumbW      = $thumbW
    ThumbH      = $thumbH
    DecoyId     = $decoyId
    DecoyStart  = $decoyStart
    SwitchAfter = $switchAfter
    RickStart   = $rickStart
}

Write-Utf8 $IndexPath $html
Write-Ok 'Written.'

# Leftover placeholder guard.
if ((Read-Utf8 $IndexPath) -match 'REPLACE-ME') {
    Fail 'A REPLACE-ME placeholder is still in the file. Fix it before shipping.'
}
Write-Ok 'No REPLACE-ME placeholders left.'

Write-Host ''
Write-Info 'Summary of what the chat will show:'
Write-Host "    headline:    $ogTitle" -ForegroundColor White
Write-Host "    description: $description" -ForegroundColor White
Write-Host "    image:       $thumbUrl (${thumbW}x${thumbH})" -ForegroundColor White
Write-Host "    decoy:       $decoyId from ${decoyStart}s, switching after ${switchAfter}s" -ForegroundColor White
Write-Host "    payoff:      Rick from ${rickStart}s" -ForegroundColor White

# ============================================================ 5. LOCAL TEST ==

$server = $null
if (-not $NoServe) {
    Write-Step '5. Local test'

    $serveRoot = Join-Path $Root 'src'
    $server = Start-LocalServer -ServeRoot $serveRoot -Port $Port

    if (Wait-ForServer -Port $Port) {
        $localUrl = "http://localhost:$Port/"
        Write-Ok "Serving $serveRoot at $localUrl"
        Write-Info 'Opening a browser. Check, in order:'
        Write-Info '  1. Your thumbnail and title show (NOT the real YouTube poster or title bar)'
        Write-Info '  2. Press play: the decoy runs'
        Write-Info "  3. It swaps to Rick at about ${switchAfter}s, with no ad at the switch"
        Write-Info '  4. No errors in the browser console (F12)'
        Write-Info 'Use a private window with extensions off; ad blockers can break the embed.'
        Start-Process $localUrl | Out-Null
    } else {
        Write-Warn2 "Could not reach the local server on port $Port. Try another port with -Port."
    }

    Write-Host ''
    Read-Host '  Press Enter when you are done testing'
    Stop-LocalServer $server
    Write-Ok 'Local server stopped.'
}

# ================================================================= 6. SHIP IT ==

Write-Step '6. Ship it'

Write-Host ''
Write-Info 'Nothing has been committed or pushed yet.'
if (-not (Confirm2 'Does it all look right — ship it?')) {
    Write-Host ''
    Write-Warn2 'Not shipping. Your edits are still in src\index.html.'
    Write-Info  'Undo them with:  git checkout -- src/index.html'
    Write-Host ''
    exit 0
}

# --- secret scan ----------------------------------------------------------
# This repo is a static page; nothing here should ever need a credential.
Write-Info 'Scanning the change for anything credential-shaped...'

$pendingDiff = (Invoke-Git @('diff', '--', 'src/', '.github/')) -join "`n"
$secretPatterns = @(
    @{ Name = 'private key block';  Pattern = '-----BEGIN [A-Z ]*PRIVATE KEY-----' },
    @{ Name = 'AWS access key id';  Pattern = 'AKIA[0-9A-Z]{16}' },
    @{ Name = 'GitHub token';       Pattern = 'gh[pousr]_[A-Za-z0-9]{20,}' },
    @{ Name = 'Slack token';        Pattern = 'xox[baprs]-[A-Za-z0-9-]{10,}' },
    @{ Name = 'Google API key';     Pattern = 'AIza[0-9A-Za-z_\-]{35}' },
    @{ Name = 'bearer token';       Pattern = '(?i)authorization:\s*bearer\s+\S{20,}' },
    @{ Name = 'assigned secret';    Pattern = '(?i)\b(password|passwd|secret|api[_-]?key|access[_-]?token)\b\s*[:=]\s*["''][^"'']{8,}["'']' }
)

$found = @()
foreach ($p in $secretPatterns) {
    if ($pendingDiff -match $p.Pattern) { $found += $p.Name }
}
if ($found.Count -gt 0) {
    Write-Bad 'Possible credentials in the diff:'
    foreach ($f in $found) { Write-Bad "  - $f" }
    Fail 'Refusing to commit. Remove them, then re-run. Nothing was pushed.'
}
Write-Ok 'No credentials found. This project needs none.'

# --- branch, commit, merge, push -----------------------------------------
$slug = ($ogTitle -replace '[^a-zA-Z0-9]+', '-').Trim('-').ToLowerInvariant()
if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40).Trim('-') }
if ([string]::IsNullOrWhiteSpace($slug)) { $slug = 'post' }
$branch = "post/$slug-" + (Get-Date -Format 'yyyyMMdd-HHmm')

Write-Info "Branch: $branch"
Invoke-Git @('checkout', '-q', '-b', $branch) | Out-Null
Invoke-Git @('add', 'src/index.html', 'src/thumb.jpg') | Out-Null

$commitMessage = @"
Set up prank: $ogTitle

Decoy $decoyId from ${decoyStart}s, switching after ${switchAfter}s.
Payoff starts at ${rickStart}s. Thumbnail ${thumbW}x${thumbH}.

Generated by wizard.ps1.
"@
Invoke-Git @('-c', 'commit.gpgsign=false', 'commit', '-q', '-m', $commitMessage) | Out-Null
Write-Ok 'Committed on the branch.'

Invoke-Git @('push', '-q', '-u', 'origin', $branch) | Out-Null
Write-Ok 'Branch pushed (this does not deploy).'

Invoke-Git @('checkout', '-q', 'main') | Out-Null
Invoke-Git @('merge', '--ff-only', $branch) | Out-Null
Invoke-Git @('push', '-q', 'origin', 'main') | Out-Null
$sha = (Invoke-Git @('rev-parse', 'HEAD')).Trim()
Write-Ok "Merged to main and pushed ($($sha.Substring(0,7))). Deploy triggered."

# --- wait for Pages ------------------------------------------------------
Write-Info 'Waiting for the GitHub Pages deploy...'
$runsApi = "https://api.github.com/repos/$owner/$repo/actions/runs?per_page=5"
$conclusion = ''
$deadline = (Get-Date).AddMinutes(5)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 10
    try {
        $runs = Invoke-RestMethod -Uri $runsApi -Headers @{ 'User-Agent' = 'rickroll-wizard' } -TimeoutSec 20
        $run = $runs.workflow_runs | Where-Object { $_.head_sha -eq $sha } | Select-Object -First 1
        if ($null -ne $run) {
            if ($run.status -eq 'completed') { $conclusion = $run.conclusion; break }
            Write-Info "  status: $($run.status)"
        }
    } catch {
        Write-Info '  (could not reach the GitHub API; retrying)'
    }
}

if ($conclusion -eq 'success') {
    Write-Ok 'Deployed.'
} elseif ([string]::IsNullOrEmpty($conclusion)) {
    Write-Warn2 "Timed out waiting. Check https://github.com/$owner/$repo/actions"
} else {
    Write-Bad "Deploy finished with: $conclusion"
    Write-Info "See https://github.com/$owner/$repo/actions"
}

# ================================================================ 7. THE LINK ==

Write-Step '7. Your link'

$uuid = [guid]::NewGuid().ToString()
$short = $uuid.Replace('-', '').Substring(0, 8)

Write-Host ''
Write-Host '  Paste this:' -ForegroundColor Green
Write-Host "    ${siteUrl}?v=$short" -ForegroundColor White
Write-Host ''
Write-Info 'Full UUID version, if you want maximum certainty of a cache miss:'
Write-Host "    ${siteUrl}?v=$uuid" -ForegroundColor DarkGray
Write-Host ''
Write-Info 'The query string is what defeats chat-app preview caching: those apps key'
Write-Info 'their cached preview on the exact URL, so a fresh ?v= forces a refetch of'
Write-Info 'your new title, description and image. A new one is generated every run.'

try {
    Set-Clipboard -Value "${siteUrl}?v=$short"
    Write-Ok 'Short link copied to your clipboard.'
} catch {
    Write-Info '(Could not reach the clipboard; copy it by hand.)'
}

Write-Host ''
Write-Info 'Before the real drop: paste it into a chat with only yourself and confirm the'
Write-Info 'preview renders.'
Write-Info "Branch kept as $branch"
Write-Info "Delete it with: git branch -d $branch; git push origin --delete $branch"
Write-Host ''
