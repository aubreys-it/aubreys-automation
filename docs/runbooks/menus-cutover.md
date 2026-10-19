# Menus: cutover and rollback, one store at a time

Prerequisites (once): setup steps 1–10 done, pipeline running for three days with no errors.

## Per store

**Before (any day)**
1. The store is in `menu.store` with `isPublished = 1`, and `menus/v1/NN.json` is current (`SELECT * FROM menu.publish_state`).
2. The IG sysadmin has cleared that store's items from the exceptions email.
3. Side-by-side copy: in cPanel, create `…/<store>/menu/bar-new/` next to the live `bar/`. Upload the files from `web/store-bar-folder/` and set the two digits in `_store.php`.
4. Open `bar-new/`, `bar-new/mobileMenu.php` and the three print pages on a phone and a desktop. Compare against what the bar actually pours; fix differences in IG, not on the site.
5. Show the manager. Their job changes: no more Excel or Word file. The bar menu follows the POS screens the next morning.

**Cutover (Monday–Thursday, before 4 PM)**
1. Turn **off** that store's old flows (table below). Turn off only; don't edit or delete them.
2. In cPanel File Manager: rename `bar` → `bar-old`, then `bar-new` → `bar`.
3. Check the URLs the store already uses: `…/menu/bar/`, `index.html`, `mobileMenu.php`, `printBeerMenu.php`, `printLiquorMenu.php`, plus the QR code on the tables. Add the new `printWineMenu.php` link to the store's desktop shortcut or SharePoint page.
4. Stores still on the **v1 PDF** method: change the website's "Bar menu" link to `…/menu/bar/`, and add a redirect from the old PDF path in that site's `.htaccess`, e.g. `Redirect 301 /aubreys/powell/menu/beer.pdf /aubreys/powell/menu/bar/`.
5. Note the date in the table below.

**Rollback (about 2 minutes)**
1. Rename `bar` → `bar-new`, `bar-old` → `bar`.
2. Turn the store's old flows back on.
3. Tell the manager to keep updating the old file until it's fixed.

Keep `bar-old` for 30 days, then delete it.

## Order

1. **02 Powell** (pilot): export confirmed, mid-size menu.
2. **12 Bluetick**: export confirmed, separate domain, so it also tests a second theme.
3. The rest of the Aubrey's stores, two or three a week.
4. **09 Papermill** once Agilysys adds its MI export.

## After the last store

- Delete every flow in the table below, plus `Extract Menu Item Info` and `Upload Menu Item Headers to DMCP` (they watch `aubdlakegen2`).
- Remove the per-store FTP logins on the web host (`<store>@arburleson.com`, `sunupload@`, `upc@`, the `grant@` login the flows use, and `bluetick-auto@blueticktavern.com`).
- Drop the legacy `ig.mi_header`, `ig.mi_price_levels`, `ig.mi_store_price_levels`, `ig.mi_sku_codes`, `ig.mi_choice_groups`, `ig.mi_kitchen_printers` (nothing reads them).
- Retire `agilysys-etl/parse-menu-items` (uses a SAS key) and the `cherokee/menu_items` folders in `aubdlakegen2`.
- Delete the old `IgSftp` linked service once nothing references it.

## Old flows by site folder

From the 2026-10-16 audit (32 started). "FTP login" is the web-host account the flow writes with, which usually equals the store's site folder.

> Check before turning off: **"12 - Bluetick - Update Website Beer Menu" logs in as `cedarbluff@`**, so it may be overwriting Cedar Bluff's files. Several stores run a v1 and a v2 flow at the same time.

| FTP login (= site folder) | Flow | Owner | State | Type | Audit note | Turned off |
|---|---|---|---|---|---|---|
| bluetick | Update Online Bar Menus | bluetick@ | Suspended | v1 file | OneDrive connection unauthorized | |
| bristol | Update Website Bar Menu | bristol@ | Started | v1 file | | |
| cedarbluff | 12 - Bluetick - Update Website Beer Menu | it@ | Started | v1 file | wrong store's FTP login | |
| cedarbluff | Update Cedar Bluff Website Bar Menu | it@ | Started | v2 Excel | | |
| cleveland | Update Cleveland Website Bar Menu v2 | it@ | Started | v2 Excel | | |
| cleveland | Update Website Bar Menu | cleveland@ | Started | v1 file | | |
| grant | 02 - Powell - Update Website Beer Menu | it@ | Started | v1 file | | |
| grant | 03 - Sunspot - Update Website Beer Menu | it@ | Started | v1 file | | |
| grant | 04 - Cedar Bluff - Update Website Beer Menu | it@ | Suspended | v1 file | | |
| grant | 09 - Papermill - Update Website Beer Menu | it@ | Started | v1 file | | |
| grant | 13 - Oak Ridge - Update Website Beer Menu | it@ | Started | v1 file | | |
| grant | 22 - Stefanos HV - Update Website Beer Menu | it@ | Started | v1 file | | |
| grant | Update Website Bar Menu v2 | cedarbluff@ | Started | v1 file | | |
| grant | Update Website Beer Menu | cedarbluff@ | Stopped | v1 file | | |
| greeneville | Update Greeneville Website Bar Menu v2 | it@ | Started | v2 Excel | | |
| greeneville | Update Website Bar Menu | greeneville@ | Started | v1 file | | |
| hixson | Update Hixson Website Bar Menu v2 | it@ | Started | v2 Excel | | |
| hixson | Update Website Bar Menu | hixson@ | Started | v1 file | | |
| johnsoncity | Update Johnson City Bar Menu | it@ | Started | v1 file | | |
| johnsoncity | Update Website Bar Menu | johnsoncity@ | Stopped | v1 file | connections unauthorized | |
| lebanon | Update Lebanon Website Bar Menu v2 | it@ | Started | v2 Excel | reads papermill@'s Excel connection | |
| lenoircity | Update Lenoir City Website Bar Menu | it@ | Stopped | v2 Excel | | |
| lenoircity | Update Website Bar Menu | lenoircity@ | Stopped | v1 file | | |
| maryville | Update Maryville Website Bar Menu v2 | it@ | Started | v2 Excel | Excel connection unauthorized | |
| maryville | Update Website Bar Menu | maryville@ | Stopped | v1 file | | |
| morristown | Update Morristown Website Bar Menu v2 | it@ | Stopped | v2 Excel | | |
| morristown | Update Website Bar Menu | morristown@ | Started | v1 file | | |
| morristown | Update Website Bar Menu v2 | morristown@ | Started | v2 Excel | | |
| oakridge | Update Website Bar Menu | oakridge@ | Started | v1 file | | |
| oakridge | Update Website Bar Menu v2 | oakridge@ | Started | v2 Excel | | |
| papermill | Update Papermill Website Bar Menu | it@ | Started | v2 Excel | | |
| papermill | Update Website Bar Menu v2 | papermill@ | Started | v1 file | | |
| papermill (SharePoint) | Update Website Beer Menu | papermill@ | Stopped | v1 file | | |
| powell | Update Powell Website Bar Menu v2 | it@ | Stopped | v2 Excel | | |
| powell | Update Website Bar Menu | powell@ | Stopped | v1 file | | |
| powell | Update Website Bar Menu v2 | powell@ | Started | v2 Excel | | |
| sevierville | Update Sevierville Website Bar Menu v2 | it@ | Started | v2 Excel | | |
| sevierville | Update Website Bar Menu | sevierville@ | Stopped | v1 file | | |
| springhill | Update Spring Hill Website Bar Menu v2 | it@ | Started | v2 Excel | reads papermill@'s Excel connection | |
| stefanoshv | Update Online Bar Menu | stefanoshv@ | Started | v1 file | | |
| strawplains | Update Straw Plains Website Bar Menu v2 | it@ | Started | v2 Excel | | |
| strawplains | Update Website Bar Menu | strawplains@ | Started | v1 file | | |
| sunupload (Sunspot) | Update Online Bar Menu | sunspot@ | Started | v1 file | | |
| upc | Update UPC Website Bar Menu | it@ | Started | v2 Excel | | |

Out of scope, leave running: `03 - Sunspot - QR Brunch/Main Menu Activate`, `Switch Sunspot Brunch/Main Menu`.
