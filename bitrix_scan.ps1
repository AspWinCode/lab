# ============================================================
# Bitrix File Scanner - PowerShell
# Login to Bitrix, upload PHP scanner, run scan
# Usage: .\bitrix_scan.ps1
# ============================================================

$BASE_URL  = "https://lab-venera.ru"
$LOGIN     = "admin"
$PASSWORD  = "M8U-PZB-m7x-Mrv"
$SCAN_KEY  = "scan2024secure"
$SCAN_FILE = Join-Path $PSScriptRoot "file_scanner.php"

# Force TLS 1.2 + 1.3 and ignore SSL errors (for self-signed certs)
[System.Net.ServicePointManager]::SecurityProtocol = (
    [System.Net.SecurityProtocolType]::Tls12 -bor
    [System.Net.SecurityProtocolType]::Tls11 -bor
    [System.Net.SecurityProtocolType]::Tls
)
try {
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor
        [System.Net.SecurityProtocolType]::Tls13
} catch {}

# Bypass SSL certificate validation
Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAll : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert,
        WebRequest req, int problem) { return true; }
}
"@
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAll

Write-Host "`n=== Bitrix File Scanner ===" -ForegroundColor Cyan

# -----------------------------------------------------------------------
# Step 1. Get login page (for sessid token)
# -----------------------------------------------------------------------
Write-Host "[1/4] Connecting to admin panel..." -ForegroundColor Yellow

try {
    $loginPage = Invoke-WebRequest `
        -Uri "$BASE_URL/bitrix/admin/index.php" `
        -SessionVariable sessionVar `
        -UseBasicParsing `
        -TimeoutSec 30
} catch {
    Write-Host "Connection error: $_" -ForegroundColor Red
    exit 1
}

$session = $sessionVar

$sessidMatch = [regex]::Match($loginPage.Content, 'name="sessid"\s+value="([^"]+)"')
$sessid = if ($sessidMatch.Success) { $sessidMatch.Groups[1].Value } else { "" }

# -----------------------------------------------------------------------
# Step 2. Authenticate
# -----------------------------------------------------------------------
Write-Host "[2/4] Logging in as $LOGIN..." -ForegroundColor Yellow

$loginBody = @{
    AUTH_FORM     = "Y"
    TYPE          = "AUTH"
    backurl       = "/bitrix/admin/"
    USER_LOGIN    = $LOGIN
    USER_PASSWORD = $PASSWORD
    USER_REMEMBER = "N"
}
if ($sessid) { $loginBody["sessid"] = $sessid }

try {
    $authResp = Invoke-WebRequest `
        -Uri "$BASE_URL/bitrix/admin/index.php" `
        -Method POST `
        -Body $loginBody `
        -WebSession $session `
        -UseBasicParsing `
        -TimeoutSec 30
} catch {
    Write-Host "Auth error: $_" -ForegroundColor Red
    exit 1
}

if ($authResp.Content -match 'USER_LOGIN|id="user_login"') {
    Write-Host "Login failed - check credentials." -ForegroundColor Red
    exit 1
}
Write-Host "    Logged in successfully." -ForegroundColor Green

$sessidMatch2 = [regex]::Match($authResp.Content, '"sessid":"([^"]+)"')
if ($sessidMatch2.Success) { $sessid = $sessidMatch2.Groups[1].Value }

# -----------------------------------------------------------------------
# Step 3. Upload file_scanner.php via file manager
# -----------------------------------------------------------------------
Write-Host "[3/4] Uploading file_scanner.php to server..." -ForegroundColor Yellow

if (-not (Test-Path $SCAN_FILE)) {
    Write-Host "File not found: $SCAN_FILE" -ForegroundColor Red
    exit 1
}

$fileBytes = [System.IO.File]::ReadAllBytes($SCAN_FILE)
$boundary  = "----FormBoundary" + [System.Guid]::NewGuid().ToString("N")
$CRLF      = "`r`n"

$bodyParts = [System.Collections.Generic.List[byte]]::new()

function Add-Field([string]$name, [string]$value) {
    $part = "--$boundary$CRLF" +
            "Content-Disposition: form-data; name=`"$name`"$CRLF$CRLF" +
            "$value$CRLF"
    $bodyParts.AddRange([System.Text.Encoding]::UTF8.GetBytes($part))
}

function Add-FileField([string]$name, [string]$filename, [byte[]]$data) {
    $header = "--$boundary$CRLF" +
              "Content-Disposition: form-data; name=`"$name`"; filename=`"$filename`"$CRLF" +
              "Content-Type: application/octet-stream$CRLF$CRLF"
    $bodyParts.AddRange([System.Text.Encoding]::UTF8.GetBytes($header))
    $bodyParts.AddRange($data)
    $bodyParts.AddRange([System.Text.Encoding]::UTF8.GetBytes($CRLF))
}

Add-Field "action"  "upload"
Add-Field "path"    "/"
Add-Field "site_id" "s1"
Add-Field "sessid"  $sessid
Add-FileField "file" "file_scanner.php" $fileBytes
$bodyParts.AddRange([System.Text.Encoding]::UTF8.GetBytes("--$boundary--$CRLF"))

$uploadUri = $BASE_URL + "/bitrix/admin/fileman_file_upload.php?action=upload" +
             "&path=%2F&site_id=s1"

try {
    $uploadResp = Invoke-WebRequest `
        -Uri $uploadUri `
        -Method POST `
        -Body $bodyParts.ToArray() `
        -ContentType "multipart/form-data; boundary=$boundary" `
        -WebSession $session `
        -UseBasicParsing `
        -TimeoutSec 30

    if ($uploadResp.StatusCode -eq 200) {
        Write-Host "    File uploaded." -ForegroundColor Green
    } else {
        Write-Host "    Upload status: $($uploadResp.StatusCode)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "    Upload via fileman failed: $_" -ForegroundColor Yellow
    Write-Host "    Upload file_scanner.php manually via Bitrix file manager." -ForegroundColor Yellow
}

# -----------------------------------------------------------------------
# Step 4. Run scan and save result
# -----------------------------------------------------------------------
Write-Host "[4/4] Running scan..." -ForegroundColor Yellow

$scanUrl     = $BASE_URL + "/file_scanner.php?key=" + $SCAN_KEY
$scanUrlJson = $scanUrl + "&format=json"

Write-Host "    URL: $scanUrl" -ForegroundColor Gray

try {
    $scanResp = Invoke-WebRequest `
        -Uri $scanUrlJson `
        -WebSession $session `
        -UseBasicParsing `
        -TimeoutSec 120

    $resultFile = Join-Path $PSScriptRoot "scan_result.json"
    [System.IO.File]::WriteAllText($resultFile, $scanResp.Content, [System.Text.Encoding]::UTF8)

    Start-Process $scanUrl

    Write-Host "`n=== SCAN RESULT ===" -ForegroundColor Cyan
    $json = $scanResp.Content | ConvertFrom-Json
    $s = $json.stats

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

    Write-Host "`n  JSON saved: $resultFile" -ForegroundColor Gray
    Write-Host "  HTML opened in browser." -ForegroundColor Gray

} catch {
    Write-Host "Scan failed: $_" -ForegroundColor Red
    Write-Host "Make sure file_scanner.php is uploaded to the site root." -ForegroundColor Yellow
}

Write-Host "`n[!] Remember to DELETE file_scanner.php from server after analysis!" -ForegroundColor Red
