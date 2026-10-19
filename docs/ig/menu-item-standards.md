# InfoGenesis item standards for the website bar menus

For the IG sysadmin. The website bar menus are built every morning from InfoGenesis, so **what's in IG is what guests see**. There's no separate place to fix the website: if something is wrong online, fix it in IG and it will be right the next morning (the menus update by 9 AM).

## What puts a drink on the website

1. It is **on a screen** at that store (item group isn't 1).
2. Its **product class** is one of the menu classes below.
3. It has a **default price** (price level 1). A store price for level 1 overrides it.

Take a drink off the screens and it leaves the website the next morning.

| Product class | Website section | Notes |
|---|---|---|
| 54 | Draft Beer | |
| 52 | Bottled & Canned Beer | |
| 55 | Seltzers & Canned Cocktails | RTD cans, hard seltzers, hard teas |
| 32 | Whiskey & Bourbon | |
| 31 | Vodka | |
| 26 | Gin | |
| 30 | Tequila | |
| 29 | Scotch | |
| 28 | Rum | |
| 21 / 20 | White & Blush, glass / bottle | still rosés and white zin go here |
| 18 / 19 | Sparkling, bottle / glass | sparkling rosé and Prosecco on draft go here |
| 23 / 22 | Red, glass / bottle | |
| 24, 25 | **not on the website** | cocktails, cordials |

Any other class on an on-screen beer, wine or liquor item shows up in the daily exceptions email.

## Names

The website uses the item name, cleaned up:

- `12_` store prefixes are removed: `12_Bud Bucket` shows as "Bud Bucket"
- `B ` / `G ` / `C ` serving prefixes are removed: `B Kim Crawford Marlborough` shows as "Kim Crawford Marlborough"
- `(1)` and trailing periods are removed, but they're also reported, because they almost always mean a duplicate item

So keep your POS conventions, and write the rest of the name the way a guest should read it:

- Spell things out: "Pinot Grigio", not "PG"; "Chardonnay", not "CH"/"Chard"; "Blackhorse", not "BH"; "Bold Rock", not "BR".
- Put the brand first, then the product: "Bieler Family Daisy Rosé".
- Wine sold by the glass and by the bottle: give both items **the same name after the B/G prefix**. The website joins them into one row with a glass price and a bottle price.
- Don't create a second item by adding "." or "(1)". If you need another button, use the same item.

## Descriptions, ABV, style, origin (optional)

These go in the item's **SKU codes**. We don't use SKUs for anything else. The SKU code says what the value is and which item it belongs to; the SKU description holds the text (50 characters max).

| SKU code | Description field | Shows as |
|---|---|---|
| `ORIG-1040029` | `Knoxville, TN` | Knoxville, TN |
| `STYLE-1040029` | `Hazy IPA` | Hazy IPA |
| `ABV-1040029` | `5.2%` | ABV 5.2% |
| `DESC-01-1040029` | `Juicy and soft with notes of mango and` | one paragraph: |
| `DESC-02-1040029` | `citrus; brewed for the Smokies.` | parts 01–09 joined with a space |

Rules:
- The number at the end **must be the item's own number**. A SKU copied from another item without changing the number is ignored and reported.
- `DESC` always has a two-digit part number (`01`, `02` …), even if there's only one part.
- Break long descriptions **between words**; the parts are joined with one space.
- They show in the order Origin, Style, ABV, Description on every item.
- Nothing is required. Add them over time; items without them look fine.

### First: one test item (do this before adding any others)

On one item that is **not on any screen**, add:
1. `ABV-<item>` = `5.2%`
2. `DESC-01-<item>` = `Crisp, dry, and light, with a "citrus" finish.` (it contains a comma and quotes on purpose)

Tell IT. We check how IG writes those characters in the next morning's export and confirm the SKU format before anyone adds real ones.

## Fix list from the 2026-10-16 exports (stores 02 and 12)

From now on the daily exceptions email produces this list automatically.

**Wrong section / shouldn't be on the bar menu**

| Item | Store | Now | Change |
|---|---|---|---|
| 4000273–4000276 Red Bull Blue / Classic / Red / Yellow | 02 | Vodka (31) | not a liquor; move to a non-menu class |
| 4070046 Pickle Shot, 4070047 Pickle Shot Spicy | 02, 12 | Vodka (31) | cocktail class (24) |
| 4000264 Girl Scout Cookie, 4000265 Lillet Spritzer, 4000266 Volrita, 4000270 Once Upon A Thyme, 4000271 Quintessential | 02 | Vodka (31) | cocktail class (24) |
| 3000012 B Miraval Rosé | 02 | Sparkling bottle (18) | still rosé: White bottle (20) |
| 4030052 Truly Wildberry | 02 | Draft Beer (54), liquor revenue | Seltzers (55), or fix the revenue category if it really is on draft |
| 738 G Gundlach Bundschu Mountain Cuvee(1) | 02 | Red **bottle** (22) with a G name | Red glass (23), and remove "(1)"; it duplicates 737 |
| 12_ … Bucket items (1194–1208, 1227, 2000094) | 12 | Bottled Beer / Seltzers | **decision for IT**: list bucket deals on the menu, or move them to a promo class |

**Names ending in a period** (likely duplicates). Check for a twin item before renaming:
4040019 Malibu Watermelon., 4040022 Ron Zacapa., 4060021 Don Julio 70., 4080019 Belle Meade., 4080214 Pappy Van Winkle 23 Year., 4080324 Calumet 15 Year., 4080330 Pappy Van Winkle 20 Year.

**No default price** (shows with no price online): 4030003 B Rey Azul (02), 4060031 Insolito Anejo (02), 4080023 Benchmark Top Floor (02), 4080112 Evan Williams Single Barrel (02), 4050033 Johnny Walker Green (12), 1227 12_Bucket Deal (12).

**Abbreviations to spell out** (examples): "Bezel Edna Valley CH", "Bieler Family "Daisy" PG", "Rodney Strong Sonoma County Chard", "BH Vanilla Cream", "BR Blackberry", "LEcole No 41" (L'Ecole).

Also worth a look while you're in there (not on any screen today): `B Prosecco` is in the red bottle class (22); `B Balfour 1503 Rose Extra Dry` (sparkling?) is in white bottle (20).
