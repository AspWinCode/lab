# ============================================================
# Bitrix File Scanner - PowerShell (uses curl.exe)
# Usage: .\bitrix_scan.ps1
# ============================================================

$BASE_URL  = "https://lab-venera.ru"
$LOGIN     = "admin"
$PASSWORD  = "M8U-PZB-m7x-Mrv"
$SCAN_KEY  = "scan2024secure"
$SCAN_FILE = Join-Path $PSScriptRoot "file_scanner.php"
$COOKIE_JAR = Join-Path $env:TEMP "bx_cookies.txt"

# Verify curl.exe is available
$curlCmd = Get-Command "curl.exe" -ErrorAction SilentlyContinue
$curlExe = if ($curlCmd) { $curlCmd.Source } else { "curl" }

Write-Host "`n=== Bitrix File Scanner ===" -ForegroundColor Cyan
Write-Host "Using: $curlExe" -ForegroundColor Gray

# -----------------------------------------------------------------------
# Step 1. Get login page + collect cookies
# -----------------------------------------------------------------------
Write-Host "[1/4] Connecting to admin panel..." -ForegroundColor Yellow

$loginPageFile = Join-Path $env:TEMP "bx_login.html"

$result = & $curlExe -sk `
    --cookie-jar $COOKIE_JAR `
    --output $loginPageFile `
    --write-out "%{http_code}" `
    "$BASE_URL/bitrix/admin/index.php"

if ($LASTEXITCODE -ne 0 -or $result -eq "000") {
    Write-Host "Connection failed (curl exit: $LASTEXITCODE, HTTP: $result)" -ForegroundColor Red
    Write-Host "Make sure curl.exe is available (Windows 10+ has it built-in)." -ForegroundColor Yellow
    exit 1
}
Write-Host "    HTTP $result - OK" -ForegroundColor Green

# Extract sessid from HTML
$loginHtml = Get-Content $loginPageFile -Raw -ErrorAction SilentlyContinue
$sessid = ""
if ($loginHtml -match 'name="sessid"\s+value="([^"]+)"') {
    $sessid = $Matches[1]
    Write-Host "    sessid: $sessid" -ForegroundColor Gray
}

# -----------------------------------------------------------------------
# Step 2. Login
# -----------------------------------------------------------------------
Write-Host "[2/4] Logging in as $LOGIN..." -ForegroundColor Yellow

$authRespFile = Join-Path $env:TEMP "bx_auth.html"

$postData = "AUTH_FORM=Y&TYPE=AUTH&backurl=%2Fbitrix%2Fadmin%2F" +
            "&USER_LOGIN=$LOGIN&USER_PASSWORD=$PASSWORD&USER_REMEMBER=N"
if ($sessid) { $postData += "&sessid=$sessid" }

$result = & $curlExe -sk `
    --cookie $COOKIE_JAR `
    --cookie-jar $COOKIE_JAR `
    --data $postData `
    --output $authRespFile `
    --write-out "%{http_code}" `
    --location `
    "$BASE_URL/bitrix/admin/index.php"

$authHtml = Get-Content $authRespFile -Raw -ErrorAction SilentlyContinue

if ($authHtml -match 'id="user_login"|name="USER_LOGIN"') {
    Write-Host "Login failed - wrong credentials or Captcha required." -ForegroundColor Red
    exit 1
}
Write-Host "    Logged in. HTTP $result" -ForegroundColor Green

# Refresh sessid from auth response
if ($authHtml -match '"sessid":"([^"]+)"') { $sessid = $Matches[1] }

# -----------------------------------------------------------------------
# Step 3. Upload file_scanner.php
# -----------------------------------------------------------------------
Write-Host "[3/4] Uploading file_scanner.php..." -ForegroundColor Yellow

if (-not (Test-Path $SCAN_FILE)) {
    Write-Host "File not found: $SCAN_FILE" -ForegroundColor Red
    exit 1
}

$uploadUri = "$BASE_URL/bitrix/admin/fileman_file_upload.php?action=upload&path=%2F&site_id=s1"

$uploadRespFile = Join-Path $env:TEMP "bx_upload.html"

$result = & $curlExe -sk `
    --cookie $COOKIE_JAR `
    --cookie-jar $COOKIE_JAR `
    --form "action=upload" `
    --form "path=/" `
    --form "site_id=s1" `
    --form "sessid=$sessid" `
    --form "file=@$SCAN_FILE;type=application/octet-stream" `
    --output $uploadRespFile `
    --write-out "%{http_code}" `
    $uploadUri

if ($result -eq "200" -or $result -eq "302") {
    Write-Host "    Uploaded. HTTP $result" -ForegroundColor Green
} else {
    Write-Host "    Upload HTTP $result - may need manual upload." -ForegroundColor Yellow
    $uploadHtml = Get-Content $uploadRespFile -Raw -ErrorAction SilentlyContinue
    if ($uploadHtml) { Write-Host "    Response: $($uploadHtml.Substring(0, [Math]::Min(300, $uploadHtml.Length)))" -ForegroundColor Gray }
    Write-Host "    If upload failed - place file_scanner.php manually in site root via Bitrix file manager." -ForegroundColor Yellow
}

# -----------------------------------------------------------------------
# Step 4. Run scan
# -----------------------------------------------------------------------
Write-Host "[4/4] Running scan..." -ForegroundColor Yellow

$scanUrl     = "$BASE_URL/file_scanner.php?key=$SCAN_KEY"
$scanUrlJson = $scanUrl + "&format=json"
$resultFile  = Join-Path $PSScriptRoot "scan_result.json"

Write-Host "    URL: $scanUrl" -ForegroundColor Gray

$httpCode = & $curlExe -sk `
    --cookie $COOKIE_JAR `
    --output $resultFile `
    --write-out "%{http_code}" `
    --max-time 120 `
    $scanUrlJson

if ($httpCode -ne "200") {
    Write-Host "Scan failed. HTTP $httpCode" -ForegroundColor Red
    Write-Host "Make sure file_scanner.php is in the site root." -ForegroundColor Yellow
    exit 1
}

# Open HTML version in browser
Start-Process $scanUrl

# Parse and display results
try {
    $json = Get-Content $resultFile -Raw | ConvertFrom-Json
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
        Write-Host "`n  DANGER FILES FOUND:" -ForegroundColor Red
        $s.danger_files | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    }

    Write-Host "`n  JSON saved to: $resultFile" -ForegroundColor Gray
    Write-Host "  Full HTML report opened in browser." -ForegroundColor Gray

} catch {
    Write-Host "Could not parse JSON result: $_" -ForegroundColor Yellow
    Write-Host "Raw output saved to: $resultFile" -ForegroundColor Gray
    Start-Process $scanUrl
}

Write-Host "`n[!] DELETE file_scanner.php from server after analysis!" -ForegroundColor Red

# Cleanup temp files
Remove-Item $loginPageFile, $authRespFile, $uploadRespFile -ErrorAction SilentlyContinue
