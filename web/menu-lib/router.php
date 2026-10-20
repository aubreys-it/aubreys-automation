<?php
/*
 * Entry point. Each store's bar/ folder has tiny shim files that set:
 *   $STORE = '02';                       (in _store.php)
 *   $VIEW  = 'gate' | 'menu' | 'print';
 *   $PRINT = 'beer' | 'liquor' | 'wine';  (print view only)
 * and then require this file.
 */
declare(strict_types=1);

require_once __DIR__ . '/lib.php';

/* ---- static assets (fonts, logos) served through the shim, so every site works on its own domain ---- */
if (isset($_GET['asset'])) {
    $path = (string) $_GET['asset'];
    $types = ['woff2' => 'font/woff2', 'png' => 'image/png', 'jpg' => 'image/jpeg', 'svg' => 'image/svg+xml',
              'webp' => 'image/webp', 'css' => 'text/css; charset=utf-8'];
    $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
    $real = realpath(__DIR__ . '/' . $path);
    $ok = preg_match('#^(assets|themes)/[A-Za-z0-9_./-]+$#', $path) && !str_contains($path, '..')
        && isset($types[$ext]) && $real && str_starts_with($real, realpath(__DIR__) . DIRECTORY_SEPARATOR);
    if (!$ok) {
        http_response_code(404);
        exit;
    }
    header('Content-Type: ' . $types[$ext]);
    header('Cache-Control: public, max-age=2592000, immutable');
    header('X-Content-Type-Options: nosniff');
    readfile($real);
    exit;
}

$STORE = $STORE ?? '';
$VIEW = $_GET['view'] ?? ($VIEW ?? 'gate');
$PRINT = $_GET['menu'] ?? ($PRINT ?? 'beer');
if (!in_array($VIEW, ['gate', 'menu', 'print'], true)) {
    $VIEW = 'gate';
}
if (!in_array($PRINT, ['beer', 'liquor', 'wine'], true)) {
    $PRINT = 'beer';
}

$loaded = menu_load($STORE);
$menu = $loaded['menu'];
$theme = menu_theme($menu);

header('Content-Type: text/html; charset=utf-8');
header('X-Content-Type-Options: nosniff');
header('Referrer-Policy: strict-origin-when-cross-origin');
// Browsers may cache the HTML briefly; the JSON behind it changes at most daily.
header('Cache-Control: private, max-age=300');      // browsers may cache briefly; shared caches may not
header('Cloudflare-CDN-Cache-Control: no-store');   // tells Cloudflare specifically not to keep menu pages

require __DIR__ . "/templates/$VIEW.php";
