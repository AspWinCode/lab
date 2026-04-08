# ============================================================
# Bitrix File Scanner via Admin PHP Console
# Uses /bitrix/admin/php_command_line.php to run code server-side
# ============================================================

$BASE_URL  = "https://lab-venera.ru"
$LOGIN     = "admin"
$PASSWORD  = "M8U-PZB-m7x-Mrv"
$COOKIE_JAR = Join-Path $env:TEMP "bx_cookies.txt"

$curlCmd = Get-Command "curl.exe" -ErrorAction SilentlyContinue
$curlExe = if ($curlCmd) { $curlCmd.Source } else { "curl" }

Write-Host "`n=== Bitrix File Scanner (via PHP Console) ===" -ForegroundColor Cyan

# -----------------------------------------------------------------------
# Step 1. Login
# -----------------------------------------------------------------------
Write-Host "[1/3] Logging in..." -ForegroundColor Yellow

$loginTmp = Join-Path $env:TEMP "bx_login.html"
& $curlExe -sk --cookie-jar $COOKIE_JAR --output $loginTmp "$BASE_URL/bitrix/admin/index.php" | Out-Null
$loginHtml = Get-Content $loginTmp -Raw -ErrorAction SilentlyContinue
$sessid = if ($loginHtml -match 'name="sessid"\s+value="([^"]+)"') { $Matches[1] } else { "" }

$authTmp = Join-Path $env:TEMP "bx_auth.html"
$postData = "AUTH_FORM=Y&TYPE=AUTH&backurl=%2Fbitrix%2Fadmin%2F&USER_LOGIN=${LOGIN}&USER_PASSWORD=${PASSWORD}&USER_REMEMBER=N"
if ($sessid) { $postData += "&sessid=$sessid" }

& $curlExe -sk --cookie $COOKIE_JAR --cookie-jar $COOKIE_JAR `
    --data $postData --output $authTmp --location `
    "$BASE_URL/bitrix/admin/index.php" | Out-Null

$authHtml = Get-Content $authTmp -Raw -ErrorAction SilentlyContinue
if ($authHtml -match '"sessid":"([^"]+)"') { $sessid = $Matches[1] }
if (-not $sessid -and $authHtml -match "sessid=([a-f0-9]{32})") { $sessid = $Matches[1] }

# Try getting sessid from admin page
$adminTmp = Join-Path $env:TEMP "bx_admin.html"
& $curlExe -sk --cookie $COOKIE_JAR --cookie-jar $COOKIE_JAR `
    --output $adminTmp "$BASE_URL/bitrix/admin/php_command_line.php" | Out-Null
$adminHtml = Get-Content $adminTmp -Raw -ErrorAction SilentlyContinue
if ($adminHtml -match 'name="sessid"\s+value="([^"]+)"') { $sessid = $Matches[1] }
if ($adminHtml -match '"sessid":"([a-f0-9]{32})"') { $sessid = $Matches[1] }

Write-Host "    sessid: $sessid" -ForegroundColor Gray

# -----------------------------------------------------------------------
# Step 2. Helper: run PHP code via admin console
# -----------------------------------------------------------------------
function Invoke-BxPHP($phpCode) {
    $tmpOut = Join-Path $env:TEMP "bx_phpout.html"

    # URL-encode the PHP code
    $encoded = [System.Uri]::EscapeDataString($phpCode)
    $body    = "sessid=$sessid&lang=ru&site_id=s1&code=$encoded"

    & $curlExe -sk `
        --cookie $COOKIE_JAR --cookie-jar $COOKIE_JAR `
        --data $body `
        --output $tmpOut `
        --referer "$BASE_URL/bitrix/admin/php_command_line.php" `
        "$BASE_URL/bitrix/admin/php_command_line.php" | Out-Null

    $html = Get-Content $tmpOut -Raw -ErrorAction SilentlyContinue
    if (-not $html) { return "" }

    # Extract result from <div class="adm-wraper"> or <pre> block
    if ($html -match '(?s)<div[^>]*class="[^"]*adm-cmd-output[^"]*"[^>]*>(.*?)</div>') {
        return $Matches[1] -replace '<[^>]+>','' -replace '&amp;','&' -replace '&lt;','<' -replace '&gt;','>'
    }
    if ($html -match '(?s)<pre[^>]*>(.*?)</pre>') {
        return $Matches[1] -replace '<[^>]+>','' -replace '&amp;','&' -replace '&lt;','<' -replace '&gt;','>'
    }
    # Try textarea
    if ($html -match '(?s)<textarea[^>]*>(.*?)</textarea>') {
        return $Matches[1] -replace '&amp;','&' -replace '&lt;','<' -replace '&gt;','>'
    }
    return ""
}

# -----------------------------------------------------------------------
# Step 3. Test console is working
# -----------------------------------------------------------------------
Write-Host "[2/3] Testing PHP console..." -ForegroundColor Yellow

$testResult = Invoke-BxPHP 'echo "CONSOLE_OK:".PHP_VERSION;'
Write-Host "    Result: $testResult" -ForegroundColor Gray

if ($testResult -notmatch "CONSOLE_OK") {
    Write-Host "    PHP console not responding. Trying alternative extraction..." -ForegroundColor Yellow

    # Show raw page for diagnosis
    $rawPage = Join-Path $PSScriptRoot "console_page.html"
    $adminHtml | Set-Content $rawPage -Encoding UTF8
    Write-Host "    Admin page saved to: $rawPage" -ForegroundColor Gray
    Write-Host "    Page size: $($adminHtml.Length) chars" -ForegroundColor Gray

    # Check if we're actually logged in
    if ($adminHtml -match 'id="user_login"') {
        Write-Host "    NOT logged in to admin panel!" -ForegroundColor Red
    } elseif ($adminHtml -match 'php_command_line|PHP.*код|PHP.*code' ) {
        Write-Host "    Console page found but output parsing failed." -ForegroundColor Yellow
    } else {
        Write-Host "    Console may be disabled. Trying shell via fileman..." -ForegroundColor Yellow
    }
}

# -----------------------------------------------------------------------
# Step 4. Scan filesystem
# -----------------------------------------------------------------------
Write-Host "[3/3] Scanning filesystem..." -ForegroundColor Yellow

$scanCode = @'
$root = realpath($_SERVER["DOCUMENT_ROOT"]);
$result = ["root"=>$root,"items"=>[]];
$dirs = new DirectoryIterator($root);
foreach($dirs as $e){
  if($e->isDot()) continue;
  $size = $e->isDir() ? 0 : $e->getSize();
  $result["items"][] = [
    "name"=>$e->getFilename(),
    "type"=>($e->isDir()?"dir":"file"),
    "size"=>$size,
    "mtime"=>date("Y-m-d",$e->getMTime())
  ];
}
echo json_encode($result);
'@

$scanResult = Invoke-BxPHP $scanCode
$resultFile = Join-Path $PSScriptRoot "scan_result.json"

if ($scanResult -match '^\{') {
    $scanResult | Set-Content $resultFile -Encoding UTF8
    Write-Host "    Got JSON result!" -ForegroundColor Green

    $json = $scanResult | ConvertFrom-Json
    Write-Host "`n=== ROOT: $($json.root) ===" -ForegroundColor Cyan
    Write-Host ""

    $json.items | Sort-Object type,name | ForEach-Object {
        $icon = if ($_.type -eq "dir") { "DIR " } else { "file" }
        $sz   = if ($_.size -gt 0) { "{0,10}" -f $_.size } else { "          " }
        Write-Host ("  [{0}] {1}  {2}  {3}" -f $icon, $_.mtime, $sz, $_.name)
    }

    Write-Host "`n  JSON saved: $resultFile" -ForegroundColor Gray
} else {
    Write-Host "    No JSON from scanner. Raw output:" -ForegroundColor Yellow
    Write-Host "    '$scanResult'" -ForegroundColor Gray
    Write-Host ""
    Write-Host "    Opening admin PHP console in browser for manual run..." -ForegroundColor Cyan
    Start-Process "$BASE_URL/bitrix/admin/php_command_line.php"
    Write-Host "    Paste this code into the console:" -ForegroundColor Yellow
    Write-Host @'

$root=realpath($_SERVER["DOCUMENT_ROOT"]);
$d=new DirectoryIterator($root);
foreach($d as $e){
  if($e->isDot())continue;
  echo ($e->isDir()?"DIR ":"FILE")." ".$e->getFilename()." ".($e->isFile()?$e->getSize():"")."\n";
}

'@ -ForegroundColor White
}
