# ============================================================
# Bitrix File Scanner - PowerShell
# Логинится в Битрикс, загружает PHP-сканер, открывает результат
# Запуск: .\bitrix_scan.ps1
# ============================================================

$BASE_URL  = "https://lab-venera.ru"
$LOGIN     = "admin"
$PASSWORD  = "M8U-PZB-m7x-Mrv"
$SCAN_KEY  = "scan2024secure"
$SCAN_FILE = Join-Path $PSScriptRoot "file_scanner.php"

# Игнорировать ошибки SSL (если сертификат самоподписанный)
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# Сессия для хранения куки
$session = [Microsoft.PowerShell.Commands.WebRequestSession]::new()

Write-Host "`n=== Bitrix File Scanner ===" -ForegroundColor Cyan

# -----------------------------------------------------------------------
# Шаг 1. Получить страницу логина (для CSRF-токена / sessid)
# -----------------------------------------------------------------------
Write-Host "[1/4] Подключение к admin-панели..." -ForegroundColor Yellow

try {
    $loginPage = Invoke-WebRequest `
        -Uri "$BASE_URL/bitrix/admin/index.php" `
        -SessionVariable sessionVar `
        -UseBasicParsing `
        -TimeoutSec 30
} catch {
    Write-Host "Ошибка подключения: $_" -ForegroundColor Red
    exit 1
}

$session = $sessionVar

# Извлечь sessid из HTML (Битрикс передаёт его в скрытом поле)
$sessidMatch = [regex]::Match($loginPage.Content, 'name="sessid"\s+value="([^"]+)"')
$sessid = if ($sessidMatch.Success) { $sessidMatch.Groups[1].Value } else { "" }

# -----------------------------------------------------------------------
# Шаг 2. Аутентификация
# -----------------------------------------------------------------------
Write-Host "[2/4] Авторизация ($LOGIN)..." -ForegroundColor Yellow

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
    Write-Host "Ошибка авторизации: $_" -ForegroundColor Red
    exit 1
}

# Проверка успешности входа
if ($authResp.Content -match 'USER_LOGIN|id="user_login"') {
    Write-Host "Не удалось войти — проверьте логин/пароль." -ForegroundColor Red
    exit 1
}
Write-Host "    Успешно вошли в административный раздел." -ForegroundColor Green

# Обновить sessid из ответа
$sessidMatch2 = [regex]::Match($authResp.Content, '"sessid":"([^"]+)"')
if ($sessidMatch2.Success) { $sessid = $sessidMatch2.Groups[1].Value }

# -----------------------------------------------------------------------
# Шаг 3. Загрузить file_scanner.php через файловый менеджер
# -----------------------------------------------------------------------
Write-Host "[3/4] Загрузка file_scanner.php на сервер..." -ForegroundColor Yellow

if (-not (Test-Path $SCAN_FILE)) {
    Write-Host "Файл не найден: $SCAN_FILE" -ForegroundColor Red
    exit 1
}

$fileBytes    = [System.IO.File]::ReadAllBytes($SCAN_FILE)
$boundary     = "----FormBoundary" + [System.Guid]::NewGuid().ToString("N")
$CRLF         = "`r`n"

# Собираем multipart/form-data вручную
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

try {
    $uploadResp = Invoke-WebRequest `
        -Uri "$BASE_URL/bitrix/admin/fileman_file_upload.php?action=upload&path=%2F&site_id=s1" `
        -Method POST `
        -Body $bodyParts.ToArray() `
        -ContentType "multipart/form-data; boundary=$boundary" `
        -WebSession $session `
        -UseBasicParsing `
        -TimeoutSec 30

    if ($uploadResp.StatusCode -eq 200) {
        Write-Host "    Файл загружен." -ForegroundColor Green
    } else {
        Write-Host "    Статус загрузки: $($uploadResp.StatusCode)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "    Ошибка загрузки через fileman: $_" -ForegroundColor Yellow
    Write-Host "    Попробуйте загрузить file_scanner.php вручную через файловый менеджер Битрикс." -ForegroundColor Yellow
}

# -----------------------------------------------------------------------
# Шаг 4. Запустить сканирование и сохранить результат
# -----------------------------------------------------------------------
Write-Host "[4/4] Запуск сканирования..." -ForegroundColor Yellow

$scanUrl = "$BASE_URL/file_scanner.php?key=$SCAN_KEY"
Write-Host "    URL: $scanUrl" -ForegroundColor Gray

try {
    $scanResp = Invoke-WebRequest `
        -Uri "$scanUrl&format=json" `
        -WebSession $session `
        -UseBasicParsing `
        -TimeoutSec 120

    $resultFile = Join-Path $PSScriptRoot "scan_result.json"
    $scanResp.Content | Set-Content -Path $resultFile -Encoding UTF8

    # Открыть HTML-версию в браузере
    Start-Process $scanUrl

    Write-Host "`n=== РЕЗУЛЬТАТ ===" -ForegroundColor Cyan
    $json = $scanResp.Content | ConvertFrom-Json
    $s = $json.stats

    Write-Host ("  Корень сайта : {0}" -f $json.root)
    Write-Host ("  Хранить      : {0}" -f $s.KEEP)           -ForegroundColor Green
    Write-Host ("  Кеш (удалить): {0}" -f $s.SAFE_DELETE)    -ForegroundColor Yellow
    Write-Host ("  Вероятно удал: {0}" -f $s.LIKELY_DELETE)  -ForegroundColor DarkYellow
    Write-Host ("  ОПАСНО       : {0}" -f $s.DANGER)         -ForegroundColor Red
    Write-Host ("  Проверить    : {0}" -f $s.REVIEW)         -ForegroundColor Cyan
    Write-Host ("  Можно освобод: {0} MB" -f [math]::Round($s.deletable_size/1MB, 2)) -ForegroundColor Magenta

    if ($s.danger_files -and $s.danger_files.Count -gt 0) {
        Write-Host "`n  ⚠ ОПАСНЫЕ ФАЙЛЫ:" -ForegroundColor Red
        $s.danger_files | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
    }

    Write-Host "`n  JSON сохранён: $resultFile" -ForegroundColor Gray
    Write-Host "  HTML открыт в браузере." -ForegroundColor Gray

} catch {
    Write-Host "Сканирование не удалось: $_" -ForegroundColor Red
    Write-Host "Проверьте, что file_scanner.php загружен в корень сайта." -ForegroundColor Yellow
}

Write-Host "`n⚠  Не забудьте удалить file_scanner.php с сервера после анализа!" -ForegroundColor Red
