<?php
// Quick diagnostic - upload to site root, open in browser
// URL: https://lab-venera.ru/bx_debug.php?key=scan2024secure

$KEY = 'scan2024secure';
if (empty($_GET['key']) || $_GET['key'] !== $KEY) { die('403'); }

error_reporting(E_ALL);
ini_set('display_errors', '1');

echo '<pre>';
echo "PHP version : " . PHP_VERSION . "\n";
echo "__FILE__    : " . __FILE__ . "\n";
echo "__DIR__     : " . __DIR__ . "\n";
echo "realpath    : " . realpath(__DIR__) . "\n";
echo "open_basedir: " . ini_get('open_basedir') . "\n";
echo "disable_func: " . ini_get('disable_functions') . "\n";
echo "\n";

// Test directory listing
echo "--- scandir(__DIR__) ---\n";
$files = @scandir(__DIR__);
if ($files === false) {
    echo "FAILED - open_basedir or permission denied\n";
} else {
    foreach ($files as $f) {
        if ($f === '.' || $f === '..') continue;
        $path = __DIR__ . '/' . $f;
        $type = is_dir($path) ? 'DIR ' : 'FILE';
        $size = is_file($path) ? filesize($path) : '';
        echo "$type  $f  $size\n";
    }
}

echo "\n--- parent dir ---\n";
$parent = dirname(__DIR__);
$files2 = @scandir($parent);
if ($files2 === false) {
    echo "Cannot read parent: $parent\n";
} else {
    echo "Parent: $parent\n";
    foreach ($files2 as $f) {
        if ($f === '.' || $f === '..') continue;
        $type = is_dir($parent . '/' . $f) ? 'DIR ' : 'FILE';
        echo "$type  $f\n";
    }
}

echo '</pre>';
