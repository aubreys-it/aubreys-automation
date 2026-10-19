<?php
$storeName = $menu['store']['name'] ?? 'Bar menu';
$pageTitle = "$storeName bar menu";
$cssFiles = ['assets/menu.css'];
$logo = menu_logo($theme);
$updated = menu_local_date($menu['contentChangedAt'] ?? null);
?>
<!doctype html>
<html lang="en">
<head>
<?php require __DIR__ . '/_head.php'; ?>
</head>
<body class="menu">
<header class="masthead">
    <?php if ($logo): ?>
        <img class="masthead-logo" src="<?= e($logo) ?>" alt="<?= e($storeName) ?> bar menu">
    <?php else: ?>
        <p class="masthead-store"><?= e($storeName) ?></p>
    <?php endif; ?>
</header>

<?php if (!$menu): ?>
    <main class="empty">
        <h1>The bar menu isn't available right now.</h1>
        <p>Ask your server for today's drinks.</p>
    </main>
<?php else: ?>

<nav class="rail" aria-label="Menu sections">
    <div class="rail-track">
        <?php foreach ($menu['groups'] as $g): foreach ($g['sections'] as $s): ?>
            <a href="#<?= e($s['code']) ?>"><?= e($s['name']) ?></a>
        <?php endforeach; endforeach; ?>
    </div>
</nav>

<div class="finder">
    <label for="find" class="visually-hidden">Find a drink</label>
    <input id="find" type="search" placeholder="Find a drink" autocomplete="off" enterkeyhint="search">
</div>
<p class="finder-empty" id="find-empty" hidden>Nothing on the menu matches that.</p>

<main id="menu">
<?php foreach ($menu['groups'] as $g): ?>
    <section class="group" aria-labelledby="g-<?= e($g['code']) ?>">
        <h2 class="group-title" id="g-<?= e($g['code']) ?>"><?= e($g['name']) ?></h2>
        <?php foreach ($g['sections'] as $s):
            $t = menu_section_rows($s);
            $multi = count($t['columns']) > 1; ?>
            <section class="section<?= $multi ? ' section-multi' : '' ?>" id="<?= e($s['code']) ?>">
                <div class="section-head">
                    <h3><?= e($s['name']) ?></h3>
                    <?php if ($multi): ?>
                        <p class="cols" aria-hidden="true">
                            <?php foreach ($t['columns'] as $c): ?><span><?= e(MENU_COLUMN_LABELS[$c]) ?></span><?php endforeach; ?>
                        </p>
                    <?php endif; ?>
                </div>
                <ul class="items">
                    <?php foreach ($t['rows'] as $r): ?>
                        <li class="item" data-name="<?= e(mb_strtolower($r['name'])) ?>">
                            <div class="line">
                                <span class="name"><?= e($r['name']) ?></span>
                                <span class="leader" aria-hidden="true"></span>
                                <?php foreach ($t['columns'] as $c):
                                    $p = $r['prices'][$c] ?? null; ?>
                                    <span class="price"<?php if ($multi): ?> aria-label="<?= e(MENU_COLUMN_LABELS[$c] . ' ' . ($p === null ? 'not available' : menu_price($p))) ?>"<?php endif; ?>><?= $p === null ? ($multi ? '–' : '') : e(menu_price($p)) ?></span>
                                <?php endforeach; ?>
                            </div>
                            <?= menu_attributes_html($r['attributes']) ?>
                        </li>
                    <?php endforeach; ?>
                </ul>
            </section>
        <?php endforeach; ?>
    </section>
<?php endforeach; ?>
</main>

<footer class="foot">
    <?php if ($updated): ?><p>Menu updated <?= e($updated) ?>.</p><?php endif; ?>
    <p>Selection and prices change often. Your server can tell you what's pouring today.</p>
    <p>Please drink responsibly.</p>
</footer>

<script>
(function () {
  var input = document.getElementById('find'), empty = document.getElementById('find-empty');
  var items = Array.prototype.slice.call(document.querySelectorAll('.item'));
  var sections = Array.prototype.slice.call(document.querySelectorAll('.section'));
  var groups = Array.prototype.slice.call(document.querySelectorAll('.group'));
  input.addEventListener('input', function () {
    var q = input.value.trim().toLowerCase(), any = false;
    items.forEach(function (li) { li.hidden = q !== '' && li.dataset.name.indexOf(q) === -1; });
    sections.forEach(function (s) {
      var shown = s.querySelector('.item:not([hidden])') !== null; s.hidden = !shown; any = any || shown;
    });
    groups.forEach(function (g) { g.hidden = g.querySelector('.section:not([hidden])') === null; });
    empty.hidden = any;
  });
})();
</script>
<?php endif; ?>
</body>
</html>
