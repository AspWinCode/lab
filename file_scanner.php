<?php
/**
 * Анализатор файлов сайта на 1С-Битрикс.
 * Загрузить через файловый менеджер Битрикс в корень сайта,
 * открыть в браузере, после анализа — удалить.
 *
 * URL для запуска: https://lab-venera.ru/file_scanner.php
 */

// Простая защита — только из браузера с этим ключом
$ACCESS_KEY = 'scan2024secure';
if (empty($_GET['key']) || $_GET['key'] !== $ACCESS_KEY) {
    http_response_code(403);
    die('Forbidden. Add ?key=' . $ACCESS_KEY . ' to URL.');
}

set_time_limit(120);
// Show errors so we can diagnose blank-page issues
error_reporting(E_ALL);
ini_set('display_errors', '1');

$root = realpath(__DIR__);
$output_format = isset($_GET['format']) && $_GET['format'] === 'json' ? 'json' : 'html';

// -----------------------------------------------------------------------
// Классификация путей
// -----------------------------------------------------------------------

function classify(string $path): array
{
    $rel = str_replace('\\', '/', $path);

    $safe_delete = [
        '/bitrix/cache',
        '/bitrix/managed_cache',
        '/bitrix/stack_cache',
        '/bitrix/html_pages',
        '/.logs',
        '/upload/tmp',
        '/bitrix/backup',
    ];

    $keep_always = [
        '/bitrix/modules',
        '/bitrix/components',
        '/bitrix/templates',
        '/bitrix/php_interface',
        '/bitrix/js',
        '/bitrix/admin',
        '/local',
        '/upload',      // только хранилище — сами файлы пользователей
    ];

    $suspicious_patterns = [
        '/\.bak$/i'       => 'backup-файл',
        '/\.old$/i'       => 'старый файл',
        '/\.orig$/i'      => 'оригинал',
        '/backup/i'       => 'резервная копия',
        '/phpinfo\.php$/i' => 'phpinfo — УДАЛИТЬ',
        '/test\.php$/i'   => 'тестовый файл',
        '/info\.php$/i'   => 'info-файл',
        '/\.sql(\.gz)?$/i' => 'дамп базы данных',
        '/shell\.php$/i'  => 'ШЕЛЛ — УДАЛИТЬ НЕМЕДЛЕННО',
        '/c99\.php$/i'    => 'ШЕЛЛ — УДАЛИТЬ НЕМЕДЛЕННО',
        '/r57\.php$/i'    => 'ШЕЛЛ — УДАЛИТЬ НЕМЕДЛЕННО',
        '/webshell/i'     => 'ШЕЛЛ — УДАЛИТЬ НЕМЕДЛЕННО',
    ];

    foreach ($safe_delete as $d) {
        if (strpos($rel, $d) === 0) {
            return ['status' => 'SAFE_DELETE', 'color' => '#f0ad4e', 'note' => 'кеш/временные файлы'];
        }
    }

    foreach ($suspicious_patterns as $pat => $note) {
        if (preg_match($pat, $rel)) {
            if (strpos($note, 'ШЕЛЛ') !== false) {
                return ['status' => 'DANGER', 'color' => '#d9534f', 'note' => $note];
            }
            return ['status' => 'LIKELY_DELETE', 'color' => '#e67e22', 'note' => $note];
        }
    }

    foreach ($keep_always as $d) {
        if (strpos($rel, $d) === 0) {
            return ['status' => 'KEEP', 'color' => '#5cb85c', 'note' => 'системная директория'];
        }
    }

    return ['status' => 'REVIEW', 'color' => '#5bc0de', 'note' => 'требует проверки'];
}

// -----------------------------------------------------------------------
// Рекурсивное сканирование (с ограничением глубины)
// -----------------------------------------------------------------------

function scan_dir(string $dir, string $root, int $depth = 0, int $max_depth = 4): array
{
    if ($depth > $max_depth) return [];

    $items = [];
    try {
        $entries = new DirectoryIterator($dir);
    } catch (Exception $e) {
        return [];
    }

    foreach ($entries as $entry) {
        if ($entry->isDot()) continue;

        $abs  = $entry->getPathname();
        $rel  = str_replace($root, '', str_replace('\\', '/', $abs));
        $cls  = classify($rel);
        $size = $entry->isFile() ? $entry->getSize() : null;

        $item = [
            'name'   => $entry->getFilename(),
            'rel'    => $rel,
            'type'   => $entry->isDir() ? 'dir' : 'file',
            'size'   => $size,
            'mtime'  => date('Y-m-d H:i', $entry->getMTime()),
            'status' => $cls['status'],
            'color'  => $cls['color'],
            'note'   => $cls['note'],
        ];

        // Для директорий — рекурсивно (кроме кешей — они огромные)
        if ($entry->isDir() && $cls['status'] !== 'SAFE_DELETE') {
            $item['children'] = scan_dir($abs, $root, $depth + 1, $max_depth);
        } elseif ($entry->isDir() && $cls['status'] === 'SAFE_DELETE') {
            // Для кеш-директорий только подсчитываем размер
            $item['cache_size'] = dir_size($abs);
            $item['children']   = [];
        }

        $items[] = $item;
    }

    // Sort: directories first, then files (PHP 5.3+ compatible)
    usort($items, function($a, $b) {
        return ($a['type'] === 'dir' ? 0 : 1) - ($b['type'] === 'dir' ? 0 : 1);
    });

    return $items;
}

function dir_size(string $path): int
{
    $size = 0;
    try {
        $iter = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator($path, FilesystemIterator::SKIP_DOTS)
        );
        foreach ($iter as $file) {
            $size += $file->getSize();
        }
    } catch (Exception $e) {}
    return $size;
}

function format_size(int $bytes): string
{
    if ($bytes >= 1073741824) return round($bytes / 1073741824, 2) . ' GB';
    if ($bytes >= 1048576)    return round($bytes / 1048576, 2)    . ' MB';
    if ($bytes >= 1024)       return round($bytes / 1024, 2)       . ' KB';
    return $bytes . ' B';
}

// -----------------------------------------------------------------------
// Статистика
// -----------------------------------------------------------------------

function collect_stats(array $items, array &$stats = []): array
{
    if (empty($stats)) {
        $stats = ['KEEP' => 0, 'SAFE_DELETE' => 0, 'LIKELY_DELETE' => 0,
                  'DANGER' => 0, 'REVIEW' => 0, 'total_size' => 0,
                  'deletable_size' => 0, 'danger_files' => []];
    }

    foreach ($items as $item) {
        $stats[$item['status']] = ($stats[$item['status']] ?? 0) + 1;
        if ($item['type'] === 'file' && $item['size']) {
            $stats['total_size'] += $item['size'];
            if (in_array($item['status'], ['SAFE_DELETE', 'LIKELY_DELETE'])) {
                $stats['deletable_size'] += $item['size'];
            }
        }
        if ($item['status'] === 'DANGER') {
            $stats['danger_files'][] = $item['rel'];
        }
        if (!empty($item['children'])) {
            collect_stats($item['children'], $stats);
        }
        if (!empty($item['cache_size'])) {
            $stats['deletable_size'] += $item['cache_size'];
        }
    }

    return $stats;
}

// -----------------------------------------------------------------------
// Запуск сканирования
// -----------------------------------------------------------------------

$start    = microtime(true);
$tree     = scan_dir($root, $root);
$stats    = collect_stats($tree);
$duration = round(microtime(true) - $start, 2);

// -----------------------------------------------------------------------
// JSON вывод
// -----------------------------------------------------------------------

if ($output_format === 'json') {
    header('Content-Type: application/json; charset=utf-8');
    echo json_encode(['root' => $root, 'stats' => $stats, 'tree' => $tree], JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT);
    exit;
}

// -----------------------------------------------------------------------
// HTML вывод
// -----------------------------------------------------------------------

function render_tree(array $items, int $level = 0)
{
    foreach ($items as $item) {
        $indent  = str_repeat('&nbsp;&nbsp;&nbsp;&nbsp;', $level);
        $icon    = $item['type'] === 'dir' ? '📁' : '📄';
        $size    = $item['size'] ? ' <small style="color:#999">(' . format_size($item['size']) . ')</small>' : '';
        if (!empty($item['cache_size'])) {
            $size = ' <small style="color:#999">(~' . format_size($item['cache_size']) . ' кеш)</small>';
        }
        $badge = '<span style="background:' . $item['color'] . ';color:#fff;padding:1px 6px;border-radius:3px;font-size:11px;margin-left:6px">'
               . $item['status'] . '</span>';
        $note  = $item['note'] ? ' <em style="color:#777;font-size:12px">— ' . htmlspecialchars($item['note']) . '</em>' : '';
        $mtime = '<small style="color:#bbb;margin-left:8px">' . $item['mtime'] . '</small>';

        echo '<div style="padding:2px 0;font-family:monospace;font-size:13px">'
            . $indent . $icon . ' '
            . htmlspecialchars($item['name'])
            . $size . $badge . $note . $mtime
            . "</div>\n";

        if (!empty($item['children'])) {
            render_tree($item['children'], $level + 1);
        }
    }
}

?>
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="UTF-8">
<title>Анализ файлов — <?= htmlspecialchars($root) ?></title>
<style>
  body { font-family: sans-serif; background: #1e1e1e; color: #d4d4d4; margin: 20px; }
  h1 { color: #569cd6; }
  .stats { display: flex; gap: 16px; flex-wrap: wrap; margin: 16px 0; }
  .stat-box { background: #252526; border-radius: 6px; padding: 12px 20px; min-width: 140px; }
  .stat-box .val { font-size: 28px; font-weight: bold; }
  .legend { margin: 16px 0; }
  .legend span { display: inline-block; padding: 3px 10px; border-radius: 4px; margin: 2px; color: #fff; font-size: 12px; }
  .tree { background: #252526; padding: 16px; border-radius: 8px; overflow-x: auto; }
  .danger-block { background: #5a1a1a; border: 1px solid #d9534f; border-radius: 6px; padding: 12px; margin: 16px 0; }
</style>
</head>
<body>

<h1>Анализ файлов сайта</h1>
<p>Корень: <code><?= htmlspecialchars($root) ?></code> &nbsp;|&nbsp; Время сканирования: <?= $duration ?> сек.</p>
<p><a href="?key=<?= $ACCESS_KEY ?>&format=json" style="color:#569cd6">Скачать JSON</a></p>

<?php if (!empty($stats['danger_files'])): ?>
<div class="danger-block">
  <strong style="color:#d9534f">⚠️ ОБНАРУЖЕНЫ ОПАСНЫЕ ФАЙЛЫ!</strong>
  <ul>
    <?php foreach ($stats['danger_files'] as $f): ?>
      <li style="color:#e74c3c"><?= htmlspecialchars($f) ?></li>
    <?php endforeach; ?>
  </ul>
</div>
<?php endif; ?>

<div class="stats">
  <div class="stat-box">
    <div class="val" style="color:#5cb85c"><?= $stats['KEEP'] ?></div>
    <div>Хранить</div>
  </div>
  <div class="stat-box">
    <div class="val" style="color:#f0ad4e"><?= $stats['SAFE_DELETE'] ?></div>
    <div>Кеш (безопасно удалить)</div>
  </div>
  <div class="stat-box">
    <div class="val" style="color:#e67e22"><?= $stats['LIKELY_DELETE'] ?></div>
    <div>Вероятно удалить</div>
  </div>
  <div class="stat-box">
    <div class="val" style="color:#d9534f"><?= $stats['DANGER'] ?></div>
    <div>ОПАСНО</div>
  </div>
  <div class="stat-box">
    <div class="val" style="color:#5bc0de"><?= $stats['REVIEW'] ?></div>
    <div>Требует проверки</div>
  </div>
  <div class="stat-box">
    <div class="val" style="color:#aaa"><?= format_size($stats['deletable_size']) ?></div>
    <div>Можно освободить</div>
  </div>
</div>

<div class="legend">
  <strong>Легенда:</strong>
  <span style="background:#5cb85c">KEEP</span> — системные файлы Битрикс, не трогать
  <span style="background:#f0ad4e">SAFE_DELETE</span> — кеш, можно удалить
  <span style="background:#e67e22">LIKELY_DELETE</span> — backup/temp файлы
  <span style="background:#d9534f">DANGER</span> — подозрительные файлы (шеллы, дампы)
  <span style="background:#5bc0de">REVIEW</span> — проверить вручную
</div>

<h2>Структура файлов</h2>
<div class="tree">
<?php render_tree($tree); ?>
</div>

<p style="color:#666;margin-top:24px">
  ⚠️ После использования удалите этот файл: <code>/file_scanner.php</code>
</p>
</body>
</html>
