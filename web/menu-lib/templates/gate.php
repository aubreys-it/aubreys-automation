<?php
$storeName = $menu['store']['name'] ?? 'Bar menu';
$homeUrl = $menu['store']['homeUrl'] ?? null;
$pageTitle = "$storeName bar menu";
$cssFiles = ['assets/menu.css'];
$logo = menu_logo($theme);
?>
<!doctype html>
<html lang="en">
<head>
<?php require __DIR__ . '/_head.php'; ?>
</head>
<body class="gate">
<main class="gate-card">
    <?php if ($logo): ?>
        <img class="gate-logo" src="<?= e($logo) ?>" alt="<?= e($storeName) ?> bar menu">
    <?php else: ?>
        <p class="gate-store"><?= e($storeName) ?></p>
    <?php endif; ?>
    <h1>Our bar menu is for guests 21 and older.</h1>
    <div class="gate-actions">
        <a class="btn btn-primary" href="mobileMenu.php">I'm 21 or older</a>
        <?php if ($homeUrl): ?>
            <a class="btn btn-quiet" href="<?= e($homeUrl) ?>">Back to <?= e($storeName) ?></a>
        <?php endif; ?>
    </div>
    <p class="gate-note">Please drink responsibly.</p>
</main>
</body>
</html>
