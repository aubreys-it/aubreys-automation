<?php
/* Printable menu: one group (beer, liquor or wine) on US Letter, three columns, black and white. */
$storeName = $menu['store']['name'] ?? 'Bar menu';
$titles = ['beer' => 'Beer', 'liquor' => 'Liquor', 'wine' => 'Wine'];
$pageTitle = "$storeName {$titles[$PRINT]} menu";
$cssFiles = ['assets/print.css'];
$logo = menu_logo($theme, 'logo-print');
$updated = menu_local_date($menu['contentChangedAt'] ?? null);
$group = null;
foreach ($menu['groups'] ?? [] as $g) {
    if ($g['code'] === $PRINT) {
        $group = $g;
    }
}
?>
<!doctype html>
<html lang="en">
<head>
<?php require __DIR__ . '/_head.php'; ?>
</head>
<body class="print">
<div class="toolbar">
    <button type="button" onclick="window.print()">Print this menu</button>
    <span>Prints on one or two letter-size pages.</span>
</div>
<header class="sheet-head">
    <?php if ($logo): ?>
        <img src="<?= e($logo) ?>" alt="<?= e($storeName) ?>">
    <?php else: ?>
        <p class="sheet-store"><?= e($storeName) ?></p>
    <?php endif; ?>
    <h1><?= e($titles[$PRINT]) ?></h1>
</header>

<?php if (!$group): ?>
    <p class="sheet-empty">There is no <?= e(strtolower($titles[$PRINT])) ?> on the menu right now.</p>
<?php else: ?>
<main class="sheet">
    <?php foreach ($group['sections'] as $s):
        $t = menu_section_rows($s);
        $multi = count($t['columns']) > 1; ?>
        <section class="section<?= $multi ? ' section-multi' : '' ?>">
            <h2>
                <span><?= e($s['name']) ?></span>
                <?php if ($multi): ?><span class="cols"><?php foreach ($t['columns'] as $c): ?><span><?= e(MENU_COLUMN_LABELS[$c]) ?></span><?php endforeach; ?></span><?php endif; ?>
            </h2>
            <?php foreach ($t['rows'] as $r): ?>
                <div class="item">
                    <div class="line">
                        <span class="name"><?= e($r['name']) ?></span>
                        <span class="leader"></span>
                        <?php foreach ($t['columns'] as $c): $p = $r['prices'][$c] ?? null; ?>
                            <span class="price"><?= $p === null ? ($multi ? '–' : '') : e(menu_price($p)) ?></span>
                        <?php endforeach; ?>
                    </div>
                    <?= menu_attributes_html($r['attributes']) ?>
                </div>
            <?php endforeach; ?>
        </section>
    <?php endforeach; ?>
</main>
<?php endif; ?>
<footer class="sheet-foot">
    <?php if ($updated): ?>Menu updated <?= e($updated) ?>. <?php endif; ?>Please drink responsibly.
</footer>
</body>
</html>
