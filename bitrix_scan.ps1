# ============================================================
# Bitrix File Scanner - PowerShell (curl.exe + FTP upload)
# Usage: .\bitrix_scan.ps1
# ============================================================

$BASE_URL   = "https://lab-venera.ru"
$LOGIN      = "admin"
$PASSWORD   = "M8U-PZB-m7x-Mrv"
$SCAN_KEY   = "scan2024secure"

# FTP credentials (NIC.ru hosting)
$FTP_HOST   = "ftp.h004326350.nichost.ru"
$FTP_USER   = "h004326350_new_pal"
$FTP_PASS   = "Wincode2026!"

$SCAN_FILE  = Join-Path $PSScriptRoot "file_scanner.php"
$DEBUG_FILE = Join-Path $PSScriptRoot "bx_debug.php"
$COOKIE_JAR = Join-Path $env:TEMP "bx_cookies.txt"

$curlCmd = Get-Command "curl.exe" -ErrorAction SilentlyContinue
$curlExe = if ($curlCmd) { $curlCmd.Source } else { "curl" }

Write-Host "`n=== Bitrix File Scanner ===" -ForegroundColor Cyan
Write-Host "Using: $curlExe" -ForegroundColor Gray

# -----------------------------------------------------------------------
# Step 1. Find web root via FTP
# -----------------------------------------------------------------------
Write-Host "`n[FTP] Finding web root on server..." -ForegroundColor Yellow

$ftpListFile = Join-Path $env:TEMP "bx_ftp_list.txt"

# List root FTP directory
& $curlExe -sk --user "${FTP_USER}:${FTP_PASS}" `
    "ftp://${FTP_HOST}/" `
    --output $ftpListFile 2>&1 | Out-Null

$ftpRoot = Get-Content $ftpListFile -Raw -ErrorAction SilentlyContinue
if ($ftpRoot) {
    Write-Host "    FTP root listing:" -ForegroundColor Green
    Write-Host $ftpRoot -ForegroundColor Gray

    # Try common web root paths
    $candidates = @("lab-venera.ru", "www", "public_html", "htdocs", "web")
    $webRoot = $null
    foreach ($c in $candidates) {
        $testFile = Join-Path $env:TEMP "bx_ftp_test.txt"
        $code = & $curlExe -sk --user "${FTP_USER}:${FTP_PASS}" `
            "ftp://${FTP_HOST}/$c/" `
            --output $testFile `
            --write-out "%{http_code}" 2>&1
        $content = Get-Content $testFile -Raw -ErrorAction SilentlyContinue
        if ($content -and $content.Length -gt 10) {
            $webRoot = $c
            Write-Host "    Web root found: /$c/" -ForegroundColor Green
            Write-Host $content -ForegroundColor Gray
            break
        }
    }
    if (-not $webRoot) { $webRoot = "" }
} else {
    Write-Host "    FTP connection failed - will try Bitrix file manager upload." -ForegroundColor Yellow
    $webRoot = $null
}

# -----------------------------------------------------------------------
# Step 2. Upload via FTP if available
# -----------------------------------------------------------------------
function Upload-FTP($localFile, $remoteName, $remoteDir) {
    $remoteUrl = "ftp://${FTP_HOST}/${remoteDir}/${remoteName}"
    $code = & $curlExe -sk `
        --user "${FTP_USER}:${FTP_PASS}" `
        -T $localFile `
        $remoteUrl `
        --write-out "%{http_code}" `
        --output (Join-Path $env:TEMP "bx_ftp_upload.txt") 2>&1
    return $code
}

if ($webRoot -ne $null) {
    Write-Host "`n[FTP] Uploading files via FTP..." -ForegroundColor Yellow
    if (Test-Path $DEBUG_FILE) {
        $r = Upload-FTP $DEBUG_FILE "bx_debug.php" $webRoot
        Write-Host "    bx_debug.php -> FTP code: $r" -ForegroundColor $(if ($r -match "^2") { "Green" } else { "Yellow" })
    }
    if (Test-Path $SCAN_FILE) {
        $r = Upload-FTP $SCAN_FILE "file_scanner.php" $webRoot
        Write-Host "    file_scanner.php -> FTP code: $r" -ForegroundColor $(if ($r -match "^2") { "Green" } else { "Yellow" })
    }
}

# -----------------------------------------------------------------------
# Step 3. Login to Bitrix admin (for backup upload method)
# -----------------------------------------------------------------------
Write-Host "`n[HTTP] Connecting to Bitrix admin..." -ForegroundColor Yellow

$loginPageFile = Join-Path $env:TEMP "bx_login.html"
$result = & $curlExe -sk `
    --cookie-jar $COOKIE_JAR `
    --output $loginPageFile `
    --write-out "%{http_code}" `
    "$BASE_URL/bitrix/admin/index.php"

$loginHtml = Get-Content $loginPageFile -Raw -ErrorAction SilentlyContinue
$sessid = if ($loginHtml -match 'name="sessid"\s+value="([^"]+)"') { $Matches[1] } else { "" }
Write-Host "    HTTP $result, sessid: $sessid" -ForegroundColor Gray

# Login
$authRespFile = Join-Path $env:TEMP "bx_auth.html"
$postData = "AUTH_FORM=Y&TYPE=AUTH&backurl=%2Fbitrix%2Fadmin%2F" +
            "&USER_LOGIN=${LOGIN}&USER_PASSWORD=${PASSWORD}&USER_REMEMBER=N"
if ($sessid) { $postData += "&sessid=$sessid" }

$result = & $curlExe -sk `
    --cookie $COOKIE_JAR --cookie-jar $COOKIE_JAR `
    --data $postData --output $authRespFile `
    --write-out "%{http_code}" --location `
    "$BASE_URL/bitrix/admin/index.php"

$authHtml = Get-Content $authRespFile -Raw -ErrorAction SilentlyContinue
if ($authHtml -match '"sessid":"([^"]+)"') { $sessid = $Matches[1] }
Write-Host "    Logged in. HTTP $result" -ForegroundColor Green

# Also upload via Bitrix file manager as fallback
if ($webRoot -eq $null) {
    Write-Host "`n[HTTP] Uploading via Bitrix file manager (FTP unavailable)..." -ForegroundColor Yellow
    $uploadUri = "$BASE_URL/bitrix/admin/fileman_file_upload.php?action=upload&path=%2F&site_id=s1"
    $uploadTmp = Join-Path $env:TEMP "bx_upload.html"

    foreach ($f in @($DEBUG_FILE, $SCAN_FILE)) {
        if (-not (Test-Path $f)) { continue }
        $fname = Split-Path $f -Leaf
        $r = & $curlExe -sk `
            --cookie $COOKIE_JAR --cookie-jar $COOKIE_JAR `
            --form "action=upload" --form "path=/" --form "site_id=s1" `
            --form "sessid=$sessid" `
            --form "file=@${f};filename=${fname};type=application/octet-stream" `
            --output $uploadTmp --write-out "%{http_code}" $uploadUri
        Write-Host "    $fname -> HTTP $r" -ForegroundColor $(if ($r -eq "200") { "Green" } else { "Yellow" })
    }
}

# -----------------------------------------------------------------------
# Step 4. Test debug page
# -----------------------------------------------------------------------
Write-Host "`n[CHECK] Testing bx_debug.php..." -ForegroundColor Yellow

$debugUrl    = "$BASE_URL/bx_debug.php?key=$SCAN_KEY"
$debugResult = Join-Path $PSScriptRoot "debug_result.txt"

$httpCode = & $curlExe -sk `
    --cookie $COOKIE_JAR `
    --output $debugResult `
    --write-out "%{http_code}" `
    $debugUrl

$debugContent = Get-Content $debugResult -Raw -ErrorAction SilentlyContinue
Write-Host "    HTTP $httpCode, size: $(if($debugContent){$debugContent.Length}else{0}) bytes" -ForegroundColor Gray

if ($debugContent -and $debugContent.Length -gt 50) {
    Write-Host "`n--- DEBUG OUTPUT ---" -ForegroundColor Cyan
    Write-Host ($debugContent -replace "<[^>]+>", "" | Select-Object -First 1) -ForegroundColor White
    Write-Host $debugContent.Substring(0, [Math]::Min(1000, $debugContent.Length)) -ForegroundColor Gray
    Start-Process $debugUrl
} else {
    Write-Host "    Still blank. Opening browser + saving raw bytes..." -ForegroundColor Yellow
    Start-Process $debugUrl

    # Save raw hex to see what server actually returns
    $rawFile = Join-Path $PSScriptRoot "debug_raw.bin"
    & $curlExe -sk --cookie $COOKIE_JAR -o $rawFile $debugUrl
    $bytes = [System.IO.File]::ReadAllBytes($rawFile)
    Write-Host "    Raw bytes ($($bytes.Length)): $([System.BitConverter]::ToString($bytes[0..([Math]::Min(20,$bytes.Length-1))]))" -ForegroundColor Gray

    # Check response headers
    Write-Host "`n--- RESPONSE HEADERS ---" -ForegroundColor Cyan
    & $curlExe -sk --cookie $COOKIE_JAR -I $debugUrl
}

# -----------------------------------------------------------------------
# Step 5. Run main scanner
# -----------------------------------------------------------------------
Write-Host "`n[SCAN] Running file_scanner.php..." -ForegroundColor Yellow
$scanUrl     = "$BASE_URL/file_scanner.php?key=$SCAN_KEY"
$scanUrlJson = $scanUrl + "&format=json"
$resultFile  = Join-Path $PSScriptRoot "scan_result.json"

$httpCode = & $curlExe -sk --cookie $COOKIE_JAR `
    --output $resultFile --write-out "%{http_code}" --max-time 120 `
    $scanUrlJson

Write-Host "    HTTP $httpCode" -ForegroundColor Gray
$raw = Get-Content $resultFile -Raw -ErrorAction SilentlyContinue

if (-not $raw -or $raw.Length -lt 10) {
    Write-Host "    Scanner returned empty. See debug output above." -ForegroundColor Yellow
    exit 0
}

Start-Process $scanUrl

try {
    $json = $raw | ConvertFrom-Json
    $s = $json.stats
    Write-Host "`n=== SCAN RESULT ===" -ForegroundColor Cyan
    Write-Host ("  Site root      : {0}" -f $json.root)
    Write-Host ("  Keep           : {0}" -f $s.KEEP)          -ForegroundColor Green
    Write-Host ("  Cache (delete) : {0}" -f $s.SAFE_DELETE)   -ForegroundColor Yellow
    Write-Host ("  Likely delete  : {0}" -f $s.LIKELY_DELETE) -ForegroundColor DarkYellow
    Write-Host ("  DANGER         : {0}" -f $s.DANGER)        -ForegroundColor Red
    Write-Host ("  Review         : {0}" -f $s.REVIEW)        -ForegroundColor Cyan
    Write-Host ("  Can free up    : {0} MB" -f [math]::Round($s.deletable_size / 1MB, 2)) -ForegroundColor Magenta
    if ($s.danger_files -and $s.danger_files.Count -gt 0) {
        Write-Host "`n  DANGER FILES:" -ForegroundColor Red
        $s.danger_files | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    }
    Write-Host "`n  JSON: $resultFile" -ForegroundColor Gray
} catch {
    Write-Host "JSON parse error: $_" -ForegroundColor Yellow
    Write-Host "Raw: $($raw.Substring(0,[Math]::Min(500,$raw.Length)))" -ForegroundColor Gray
}

Write-Host "`n[!] DELETE bx_debug.php and file_scanner.php from server!" -ForegroundColor Red
