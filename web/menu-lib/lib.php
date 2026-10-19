<?php
declare(strict_types=1);

require_once __DIR__ . '/config.php';

/** HTML-escape. */
function e(?string $s): string
{
    return htmlspecialchars((string) $s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

/** 7 -> "7", 6.5 -> "6.50", null -> "" */
function menu_price(?float $p): string
{
    if ($p === null) {
        return '';
    }
    return fmod($p, 1.0) == 0.0 ? number_format($p, 0) : number_format($p, 2);
}

function menu_local_date(?string $utc, string $format = 'M j, Y'): string
{
    if (!$utc) {
        return '';
    }
    try {
        $d = new DateTimeImmutable($utc);
        return $d->setTimezone(new DateTimeZone(MENU_TIMEZONE))->format($format);
    } catch (Exception $ex) {
        return '';
    }
}

/**
 * Fetch a store's menu JSON with a local cache.
 * Order: fresh cache -> Azure -> stale cache -> null.
 * Returns ['menu' => array|null, 'from' => 'cache'|'azure'|'stale-cache'|'none'].
 */
function menu_load(string $storeCode): array
{
    if (!preg_match('/^\d{2}$/', $storeCode)) {
        throw new InvalidArgumentException('Store code must be two digits');
    }
    $cacheFile = MENU_CACHE_DIR . "/$storeCode.json";
    clearstatcache(true, $cacheFile);
    $cached = is_file($cacheFile) ? @file_get_contents($cacheFile) : false;
    $age = $cached !== false ? time() - (int) @filemtime($cacheFile) : PHP_INT_MAX;

    if ($cached !== false && $age < MENU_CACHE_TTL_SECONDS && ($m = menu_decode($cached))) {
        return ['menu' => $m, 'from' => 'cache'];
    }

    $remote = menu_http_get(MENU_JSON_BASE . "$storeCode.json");
    if ($remote !== null && ($m = menu_decode($remote))) {
        if (!is_dir(MENU_CACHE_DIR)) {
            @mkdir(MENU_CACHE_DIR, 0750, true);
        }
        $tmp = $cacheFile . '.' . getmypid() . '.tmp';
        if (@file_put_contents($tmp, $remote) !== false) {
            @rename($tmp, $cacheFile);   // atomic swap: readers never see half a file
        }
        menu_check_stale($m, $storeCode);
        return ['menu' => $m, 'from' => 'azure'];
    }

    if ($cached !== false && ($m = menu_decode($cached))) {
        @touch($cacheFile);   // don't hammer Azure while it is unreachable
        error_log("bar menu $storeCode: Azure unreachable or invalid, serving cached copy");
        return ['menu' => $m, 'from' => 'stale-cache'];
    }

    error_log("bar menu $storeCode: no menu available (Azure unreachable and no cache)");
    return ['menu' => null, 'from' => 'none'];
}

function menu_decode(string $json): ?array
{
    $m = json_decode($json, true);
    if (!is_array($m) || ($m['schema'] ?? '') !== 'aubreys-menu/1' || !isset($m['groups']) || !is_array($m['groups'])) {
        return null;
    }
    return $m;
}

function menu_http_get(string $url): ?string
{
    if (function_exists('curl_init')) {
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_FOLLOWLOCATION => false,
            CURLOPT_CONNECTTIMEOUT => MENU_FETCH_TIMEOUT_SECONDS,
            CURLOPT_TIMEOUT => MENU_FETCH_TIMEOUT_SECONDS,
            CURLOPT_HTTPHEADER => ['Accept: application/json'],
        ]);
        $body = curl_exec($ch);
        $code = (int) curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
        curl_close($ch);
        return ($body !== false && $code === 200) ? (string) $body : null;
    }
    $ctx = stream_context_create(['http' => ['timeout' => MENU_FETCH_TIMEOUT_SECONDS, 'ignore_errors' => true]]);
    $body = @file_get_contents($url, false, $ctx);
    $ok = isset($http_response_header[0]) && strpos($http_response_header[0], ' 200') !== false;
    return ($body !== false && $ok) ? $body : null;
}

function menu_check_stale(array $m, string $storeCode): void
{
    $gen = strtotime($m['generatedAt'] ?? '') ?: 0;
    if ($gen && (time() - $gen) > MENU_STALE_HOURS * 3600) {
        error_log("bar menu $storeCode: published file is older than " . MENU_STALE_HOURS . "h (generatedAt {$m['generatedAt']})");
    }
}

/** Theme folder for a menu (falls back if the concept has no theme yet). */
function menu_theme(?array $m): string
{
    $t = $m['store']['theme'] ?? MENU_FALLBACK_THEME;
    return (preg_match('/^[a-z0-9_-]+$/', $t) && is_dir(__DIR__ . "/themes/$t")) ? $t : MENU_FALLBACK_THEME;
}

/** URL for a theme/asset file, served through the store's own shim (no cross-domain requests). */
function menu_asset_url(string $path): string
{
    $file = __DIR__ . '/' . $path;
    $v = is_file($file) ? substr(md5((string) filemtime($file)), 0, 8) : '0';
    return 'index.php?asset=' . rawurlencode($path) . '&v=' . $v;
}

/** Logo for the theme, or null when the theme has none (store name is shown instead). */
function menu_logo(string $theme, string $kind = 'logo'): ?string
{
    foreach (['svg', 'png', 'jpg', 'webp'] as $ext) {
        if (is_file(__DIR__ . "/themes/$theme/$kind.$ext")) {
            return menu_asset_url("themes/$theme/$kind.$ext");
        }
    }
    return null;
}

/**
 * Rows for one section. Sections with glass and bottle servings are merged into one row per
 * name with two prices, which is how a wine list reads. Returns:
 *   ['columns' => ['glass','bottle'] | ['all'], 'rows' => [[name, prices => [code => price], attributes]]]
 */
function menu_section_rows(array $section): array
{
    $servings = $section['servings'] ?? [];
    $codes = array_column($servings, 'code');
    if (count($servings) === 1 && $codes[0] === 'all') {
        $rows = [];
        foreach ($servings[0]['items'] as $it) {
            $rows[] = ['name' => $it['name'], 'prices' => ['all' => $it['price']], 'attributes' => $it['attributes'] ?? []];
        }
        return ['columns' => ['all'], 'rows' => $rows];
    }
    $order = array_values(array_intersect(['glass', 'bottle'], $codes));
    $byName = [];
    foreach ($servings as $sv) {
        foreach ($sv['items'] as $it) {
            $key = mb_strtolower($it['name']);
            $byName[$key] ??= ['name' => $it['name'], 'prices' => [], 'attributes' => []];
            $byName[$key]['prices'][$sv['code']] = $it['price'];
            if (!$byName[$key]['attributes'] && !empty($it['attributes'])) {
                $byName[$key]['attributes'] = $it['attributes'];
            }
        }
    }
    uasort($byName, fn($a, $b) => strnatcasecmp($a['name'], $b['name']));
    return ['columns' => $order, 'rows' => array_values($byName)];
}

/** Short attributes inline, long ones (descriptions) on their own line. */
function menu_attributes_html(array $attrs): string
{
    if (!$attrs) {
        return '';
    }
    $inline = [];
    $blocks = [];
    foreach ($attrs as $a) {
        $text = ($a['showLabel'] ?? false) ? $a['label'] . ' ' . $a['value'] : $a['value'];
        if (mb_strlen($a['value']) > 40) {
            $blocks[] = '<p class="desc">' . e($text) . '</p>';
        } else {
            $inline[] = '<span>' . e($text) . '</span>';
        }
    }
    $html = $inline ? '<p class="facts">' . implode('', $inline) . '</p>' : '';
    return $html . implode('', $blocks);
}

const MENU_COLUMN_LABELS = ['glass' => 'Glass', 'bottle' => 'Bottle', 'all' => ''];
