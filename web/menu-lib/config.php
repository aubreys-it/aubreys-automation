<?php
/*
 * Shared bar-menu library: settings.
 * Deploy the whole menu-lib folder ONCE, outside public_html (e.g. /home1/arburles/menu-lib).
 * Each store's bar/ folder only holds the small shim files from web/store-bar-folder.
 */
declare(strict_types=1);

// Public read-only container written by ADF (menu.usp_publish_store -> v1/NN.json).
// MENU_JSON_BASE env var overrides this for local testing only.
define('MENU_JSON_BASE', getenv('MENU_JSON_BASE') ?: 'https://aubwebpub.blob.core.windows.net/menus/v1/');

// Local copy of each store's JSON. Must be writable by PHP; never inside public_html.
const MENU_CACHE_DIR = __DIR__ . '/cache';

// Re-check Azure at most this often. The pipeline publishes once a day, so 10 minutes is plenty.
const MENU_CACHE_TTL_SECONDS = 600;

// Give up on Azure quickly and fall back to the cached copy.
const MENU_FETCH_TIMEOUT_SECONDS = 4;

// Log a warning (Bluehost error_log) when the published file is older than this.
// Alerting is done by the ops watchdog; this is only a breadcrumb on the web side.
const MENU_STALE_HOURS = 48;

// Shown on pages; times in the JSON are UTC.
const MENU_TIMEZONE = 'America/New_York';

// Theme used when a concept's theme folder does not exist yet.
const MENU_FALLBACK_THEME = '_default';
