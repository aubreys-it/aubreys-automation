# Menus

Website bar menus for every store, built daily from InfoGenesis. Nobody uploads or edits menu files any more: what is on the POS screens is what is on the website.

| | |
|---|---|
| Owner | IT (Grant) |
| Ops area | `ops`: Slack `#alert-ops-automation`, email Automation Ops Admins |
| Runs | 7:30 AM ET daily, retry 8:15 AM ET for stores that didn't load; watchdog 9:30 AM ET |
| Identity | `dmcp-data-factory` system-assigned managed identity (ADF); `aub-ig-etl` managed identity (function) |
| Source | IG SFTP `portal.ftp.infogenesisasp.com:/Export/NN/MI_Exp.txt` (one per store, overwritten daily around 6:40 AM) |
| Database | `mcp-alex` / `domesday`, schemas `ig`, `menu`, `stg`, `ops` |
| Output | `https://aubwebpub.blob.core.windows.net/menus/v1/NN.json` (public read) |
| Websites | Bluehost; shared PHP library `/home1/arburles/menu-lib`, per-store shims in each `.../menu/bar/` folder |
| Code | `functions/ig-etl`, `sql/domesday`, `adf/dmcp-data-factory`, `web/`, `contracts/menu-v1.schema.json` |

## How it works

```
IG SFTP /Export/NN/MI_Exp.txt
   │  pl_menus_ingest_store (per store, 6 in parallel)
   │    Check IG file ── missing/stale ─► FILE_MISSING / FILE_STALE (store keeps yesterday's menu)
   ▼
aubdatain / infogenesis / menu_items/raw/yyyy/MM/dd/NN_MI_Exp.txt     (kept 90 days)
   │  aub-ig-etl  POST /api/mi-export/parse      (rejected lines → PARSE_REJECT; >1% → PARSE_FAILED)
   ▼
aubdatain / infogenesis / menu_items/parsed/<runId>/<entity>/NN.csv   (kept 14 days)
   │  Copy → stg.mi_*   →   ig.usp_mi_merge
   ▼
ig.item, ig.item_price_level, ig.item_store_price_level   (temporal: 12 months of history)
ig.item_sku_code, ig.item_choice_group, ig.item_kitchen_printer  (current only)
   │  menu.usp_check_ig_quality  → IG_* exceptions (digest email)
   │  menu.usp_publish_store     → JSON
   ▼
aubwebpub / menus / v1 / NN.json   →   PHP (cached 10 min, falls back to last good copy)
```

Every step writes to `ops.pipeline_run` / `ops.run_event`; `ops.usp_run_notifications` turns a run's events into Slack and email.

## What decides what's on the menu

All of this comes from IG. There is no override table on purpose: a wrong item gets fixed in IG.

| Rule | Where |
|---|---|
| On the menu = `itemGroupId <> 1` at that store | `ig.item.isOnScreen` |
| Section = product class | `menu.product_class` (same ids at every store) |
| Cocktails (24) and cordials (25) are excluded | `menu.product_class.isExcluded` |
| Wine glass vs bottle = product class (19/21/23 glass, 18/20/22 bottle); the website shows one row with both prices | `menu.product_class.serving`, PHP `menu_section_rows()` |
| Price = price level 1; a store price level 1 overrides it | `menu.v_item_candidate` |
| Web name = IG item name minus `NN_`, `B `/`G `/`C `, `(1)`, trailing `.` | `menu.fn_clean_name` |
| Origin, style, ABV, description = SKU codes `ORIG-`, `STYLE-`, `ABV-`, `DESC-NN-` + item id | `menu.attribute_type` (sortRank sets display order) |

Sections in order: Draft Beer, Bottled & Canned Beer, Seltzers & Canned Cocktails (Beer); Whiskey & Bourbon, Vodka, Gin, Tequila, Scotch, Rum (Liquor); White & Blush, Sparkling, Red (Wine).

To add a section or remap a class: edit `sql/domesday/080_seed.sql`, re-run it, and the next run picks it up. Section names are part of the JSON, so the website changes with no PHP change.

## Alerts

| What happened | Slack | Email |
|---|---|---|
| Pipeline failed, store not loaded at the 8:15 retry, upload failed, menu would be empty | specific line | immediately, with "What to do" |
| IG data problems, unreadable lines, store not loaded yet at 7:30 | one line with counts | one digest per run |
| No arrival within 25 hours (pipeline never ran) | watchdog line | watchdog email, once per day |

Subjects: `[ALERT][ops] Menus – …`, `[EXCEPTIONS][ops] Menus – …` for Outlook rules. Reply-To is the admin group.

## Where to look

```sql
SELECT * FROM ops.v_open_issues WHERE domainCode = 'menus' ORDER BY loggedUtc DESC;  -- last 24 h
SELECT * FROM ops.v_feed_health WHERE domainCode = 'menus';                           -- per store freshness
SELECT * FROM ops.v_daily_summary WHERE domainCode = 'menus' ORDER BY runDateEastern DESC;
SELECT * FROM menu.publish_state;                                                      -- last publish per store
SELECT * FROM menu.v_item_web WHERE locId = 2 ORDER BY sectionCode, displayName;       -- what 02 shows
-- price history
SELECT * FROM ig.item_price_level FOR SYSTEM_TIME ALL WHERE locId = 2 AND itemId = 70 ORDER BY validFrom;
```

Preview a store's menu from an export file without touching Azure:

```
python tools/preview_menu.py 02_MI_Exp.txt --loc 2 --name "Aubrey's Powell" --out 02.json --issues 02_issues.csv
```

## Common fixes

| Symptom | Fix |
|---|---|
| FILE_MISSING for a store every day | Agilysys hasn't set up (or dropped) the MI export for that store. Ticket with Agilysys. Store 09 has none yet. |
| A drink shows that isn't poured any more | Take it off the screens in IG (`itemGroupId` 1). |
| A drink is in the wrong section | Fix its product class in IG. |
| Item name looks wrong online | Fix the IG item name; see `docs/ig/menu-item-standards.md`. |
| Website shows an old menu | Check `ops.v_feed_health` for that store; PHP keeps serving its last good copy if Azure is unreachable (see Bluehost `error_log`). |
| Need to re-run today | Debug-run `pl_menus_daily` in ADF (`onlyMissing` = true reloads only stores not loaded today). |
| New store | Add it to `menu.store` (isPublished = 1), run `EXEC menu.usp_sync_feed_expectations`, copy the `web/store-bar-folder` shims with the new number. |

## Retention

| Data | Kept |
|---|---|
| Raw MI_Exp files | 90 days (lifecycle rule on aubdatain) |
| Parsed CSVs | 14 days |
| `ig.*_history` | 12 months (`HISTORY_RETENTION_PERIOD`) |
| `ops.*` log rows | 13 months (`ops.usp_purge`, run by the watchdog) |
