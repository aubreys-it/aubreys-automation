<?php
/** Shared <head>. Expects $theme, $pageTitle, $cssFiles (relative to menu-lib). */
$lib = dirname(__DIR__);
$fontFaces = [
    ['Barlow Condensed', 500, 'normal', 'barlow-condensed-latin-500-normal.woff2'],
    ['Barlow Condensed', 600, 'normal', 'barlow-condensed-latin-600-normal.woff2'],
    ['Barlow Condensed', 700, 'normal', 'barlow-condensed-latin-700-normal.woff2'],
    ['Libre Franklin', 400, 'normal', 'libre-franklin-latin-400-normal.woff2'],
    ['Libre Franklin', 400, 'italic', 'libre-franklin-latin-400-italic.woff2'],
    ['Libre Franklin', 600, 'normal', 'libre-franklin-latin-600-normal.woff2'],
];
?>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="robots" content="noindex">
<title><?= e($pageTitle) ?></title>
<style>
<?php foreach ($fontFaces as [$family, $weight, $style, $file]): ?>
@font-face{font-family:"<?= $family ?>";font-weight:<?= $weight ?>;font-style:<?= $style ?>;font-display:swap;src:url("<?= e(menu_asset_url("assets/fonts/$file")) ?>") format("woff2")}
<?php endforeach; ?>
<?php
// Theme first (tokens), then layout. Inlined: one request per page, no relative-URL surprises.
foreach (array_merge(["themes/$theme/theme.css"], $cssFiles) as $css) {
    if (is_file("$lib/$css")) {
        echo file_get_contents("$lib/$css"), "\n";
    }
}
?>
</style>
