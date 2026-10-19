/*
  Reference data. Safe to re-run: MERGE upserts, nothing is deleted.
  Items marked CONFIRM are best guesses from the 2026-10-16 audit; check them before go-live.
*/

/* ---------------- ops: areas, domains, event codes ---------------- */
MERGE ops.area t
USING (VALUES
    ('ops',     N'Store operations automation (menus, IG exports, websites)', 'alert-ops-automation',     'slack-webhook-alert-ops-automation',     N'automation-ops-admins@aubreys.group'),
    ('finance', N'Finance automation (AP, SAGE, US Foods) – not yet in use',  'alert-finance-automation', 'slack-webhook-alert-finance-automation', NULL),
    ('hr',      N'HR / payroll automation – not yet in use',                  'alert-hr-automation',      'slack-webhook-alert-hr-automation',      NULL)
) s (areaCode, description, slackChannel, slackSecretName, emailTo)
ON t.areaCode = s.areaCode
WHEN MATCHED THEN UPDATE SET description = s.description, slackChannel = s.slackChannel,
                             slackSecretName = s.slackSecretName, emailTo = s.emailTo
WHEN NOT MATCHED THEN INSERT (areaCode, description, slackChannel, slackSecretName, emailTo, isActive)
                      VALUES (s.areaCode, s.description, s.slackChannel, s.slackSecretName, s.emailTo,
                              CASE WHEN s.areaCode = 'ops' THEN 1 ELSE 0 END);

MERGE ops.domain t
USING (VALUES
    ('menus', 'ops', N'Menus', N'IG menu item export -> domesday -> per-store menu JSON for the websites', N'docs/domains/menus.md'),
    ('ops',   'ops', N'Automation platform', N'Watchdog, retention and other platform jobs', NULL)
) s (domainCode, areaCode, displayName, description, docPath)
ON t.domainCode = s.domainCode
WHEN MATCHED THEN UPDATE SET areaCode = s.areaCode, displayName = s.displayName, description = s.description, docPath = s.docPath
WHEN NOT MATCHED THEN INSERT (domainCode, areaCode, displayName, description, docPath)
                      VALUES (s.domainCode, s.areaCode, s.displayName, s.description, s.docPath);

MERGE ops.event_code t
USING (VALUES
    -- generic
    ('RUN_FAILED',        'ERROR', N'Pipeline failed',               N'Open the run in ADF Monitor (run id below) to see which activity failed.'),
    ('FEED_LATE',         'ERROR', N'Feed is late',                  N'The process has not delivered within its window. Check that the ADF trigger is started and the last run in ADF Monitor.'),
    ('NOTIFY_FAILED',     'WARN',  N'Notification failed',           N'Check the Slack webhook secret in Key Vault and the Graph Mail.Send permission for the factory identity.'),
    -- menus: ingest
    ('FILE_MISSING',      'ERROR', N'IG export missing',             N'No MI_Exp.txt in /Export/NN on the IG SFTP. Yesterday''s menu stays up. If it persists, open a ticket with Agilysys to restore the export.'),
    ('FILE_STALE',        'ERROR', N'IG export is old',              N'MI_Exp.txt exists but was not refreshed today. Yesterday''s menu stays up. If it persists, open a ticket with Agilysys.'),
    ('PARSE_FAILED',      'ERROR', N'IG export could not be read',   N'Too many lines in the file were unreadable, so the store was not loaded. The raw file is kept in aubdatain/infogenesis/menu_items/raw for 90 days.'),
    ('PARSE_REJECT',      'WARN',  N'Unreadable line in IG export',  N'One line in the export did not match the expected layout and was skipped. Usually a stray quote or brace in an item name; fix the name in IG.'),
    ('LOAD_FAILED',       'ERROR', N'Database load failed',          N'The merge into domesday failed. Check the error in ADF Monitor; nothing was changed for any store.'),
    ('LOAD_ROW_SKIPPED',  'WARN',  N'Row skipped during load',       NULL),
    ('STORE_LOADED',      'INFO',  N'Store loaded',                  NULL),
    ('NOTHING_TO_LOAD',   'INFO',  N'Nothing to load',               NULL),
    -- menus: publish
    ('MENU_EMPTY',        'ERROR', N'Menu would be empty',           N'No on-screen items in mapped product classes. Check itemGroupId values and menu.product_class.'),
    ('PUBLISH_FAILED',    'ERROR', N'Menu JSON upload failed',       N'Check the factory identity''s Storage Blob Data Contributor role on the web storage account.'),
    ('MENU_PUBLISHED',    'INFO',  N'Menu published',                NULL),
    -- menus: IG data quality (exceptions email)
    ('IG_UNMAPPED_CLASS', 'WARN',  N'Item in an unknown product class',     N'Move the item to the correct product class in IG. If the class is new and belongs on the web, add it to menu.product_class.'),
    ('IG_REVCAT_MISMATCH','WARN',  N'Revenue category does not match class',N'Fix the item''s revenue category or product class in IG.'),
    ('IG_SERVING_MISMATCH','WARN', N'Bottle/glass prefix does not match class', N'A "B " item is in a glass class (or "G " in a bottle class). Fix the name or the product class in IG.'),
    ('IG_NAME_SUFFIX',    'WARN',  N'Item name ends in "." or "(1)"',       N'Usually a duplicate item. Remove the duplicate or rename it in IG.'),
    ('IG_NO_PRICE',       'WARN',  N'No default price',                     N'Add a price at price level 1 in IG; the item shows on the web without a price until then.'),
    ('IG_DUPLICATE_NAME', 'WARN',  N'Same item listed twice',               N'Two on-screen items show as the same line on the web menu. Take one off the screens or rename it in IG.'),
    ('IG_SKU_INVALID',    'WARN',  N'Menu description SKU not used',        N'Fix the SKU code in IG. Format: PREFIX-itemId (e.g. ABV-1040029) or DESC-NN-itemId for long descriptions.')
) s (code, defaultSeverity, title, howToFix)
ON t.code = s.code
WHEN MATCHED THEN UPDATE SET defaultSeverity = s.defaultSeverity, title = s.title, howToFix = s.howToFix
WHEN NOT MATCHED THEN INSERT (code, defaultSeverity, title, howToFix) VALUES (s.code, s.defaultSeverity, s.title, s.howToFix);
GO

/* ---------------- menu reference data ---------------- */
MERGE menu.section_group t
USING (VALUES ('beer', N'Beer', 10), ('liquor', N'Liquor', 20), ('wine', N'Wine', 30)) s (groupCode, displayName, sortRank)
ON t.groupCode = s.groupCode
WHEN MATCHED THEN UPDATE SET displayName = s.displayName, sortRank = s.sortRank
WHEN NOT MATCHED THEN INSERT (groupCode, displayName, sortRank) VALUES (s.groupCode, s.displayName, s.sortRank);

MERGE menu.section t
USING (VALUES
    ('draft_beer',   'beer',   N'Draft Beer',                  10),
    ('bottled_beer', 'beer',   N'Bottled & Canned Beer',       20),
    ('rtd',          'beer',   N'Seltzers & Canned Cocktails', 30),
    ('whiskey',      'liquor', N'Whiskey & Bourbon',           40),
    ('vodka',        'liquor', N'Vodka',                       50),
    ('gin',          'liquor', N'Gin',                         60),
    ('tequila',      'liquor', N'Tequila',                     70),
    ('scotch',       'liquor', N'Scotch',                      80),
    ('rum',          'liquor', N'Rum',                         90),
    ('white_blush',  'wine',   N'White & Blush',              100),
    ('sparkling',    'wine',   N'Sparkling',                  110),
    ('red',          'wine',   N'Red',                        120)
) s (sectionCode, groupCode, displayName, sortRank)
ON t.sectionCode = s.sectionCode
WHEN MATCHED THEN UPDATE SET groupCode = s.groupCode, displayName = s.displayName, sortRank = s.sortRank
WHEN NOT MATCHED THEN INSERT (sectionCode, groupCode, displayName, sortRank) VALUES (s.sectionCode, s.groupCode, s.displayName, s.sortRank);

/* igName values are descriptive, inferred from the items in each class: CONFIRM against IG */
MERGE menu.product_class t
USING (VALUES
    (18, N'Sparkling Wine - Bottle', 'sparkling',   'bottle', 3, 0, NULL),
    (19, N'Sparkling Wine - Glass',  'sparkling',   'glass',  3, 0, N'includes Prosecco on draft'),
    (20, N'White Wine - Bottle',     'white_blush', 'bottle', 3, 0, N'still rosés live here'),
    (21, N'White Wine - Glass',      'white_blush', 'glass',  3, 0, NULL),
    (22, N'Red Wine - Bottle',       'red',         'bottle', 3, 0, NULL),
    (23, N'Red Wine - Glass',        'red',         'glass',  3, 0, NULL),
    (24, N'Cocktails',               NULL,          'all',    4, 1, N'not on the web menu (decided 2026-10-16)'),
    (25, N'Cordials',                NULL,          'all',    4, 1, N'not on the web menu (decided 2026-10-16)'),
    (26, N'Gin',                     'gin',         'all',    4, 0, NULL),
    (28, N'Rum',                     'rum',         'all',    4, 0, NULL),
    (29, N'Scotch',                  'scotch',      'all',    4, 0, NULL),
    (30, N'Tequila',                 'tequila',     'all',    4, 0, NULL),
    (31, N'Vodka',                   'vodka',       'all',    4, 0, NULL),
    (32, N'Whiskey',                 'whiskey',     'all',    4, 0, NULL),
    (52, N'Bottled Beer',            'bottled_beer','all',    2, 0, NULL),
    (54, N'Draft Beer',              'draft_beer',  'all',    2, 0, NULL),
    (55, N'Seltzers / RTD',          'rtd',         'all',    4, 0, NULL)
) s (productClassId, igName, sectionCode, serving, revenueCategoryId, isExcluded, note)
ON t.productClassId = s.productClassId
WHEN MATCHED THEN UPDATE SET igName = s.igName, sectionCode = s.sectionCode, serving = s.serving,
                             revenueCategoryId = s.revenueCategoryId, isExcluded = s.isExcluded, note = s.note
WHEN NOT MATCHED THEN INSERT (productClassId, igName, sectionCode, serving, revenueCategoryId, isExcluded, note)
                      VALUES (s.productClassId, s.igName, s.sectionCode, s.serving, s.revenueCategoryId, s.isExcluded, s.note);

/* SKU-carried attributes. sortRank = display order on every item. */
MERGE menu.attribute_type t
USING (VALUES
    ('ORIG',  N'Origin',      10, 0, 1, 0),
    ('STYLE', N'Style',       20, 0, 1, 0),
    ('ABV',   N'ABV',         30, 0, 1, 1),
    ('DESC',  N'Description', 40, 1, 9, 0)
) s (prefix, label, sortRank, isMultiPart, maxParts, showLabel)
ON t.prefix = s.prefix
WHEN MATCHED THEN UPDATE SET label = s.label, sortRank = s.sortRank, isMultiPart = s.isMultiPart,
                             maxParts = s.maxParts, showLabel = s.showLabel
WHEN NOT MATCHED THEN INSERT (prefix, label, sortRank, isMultiPart, maxParts, showLabel)
                      VALUES (s.prefix, s.label, s.sortRank, s.isMultiPart, s.maxParts, s.showLabel);

/* Concepts: CONFIRM names */
MERGE menu.concept t
USING (VALUES
    ('aubreys',  N'Aubrey''s',        'aubreys'),
    ('bluetick', N'Bluetick Tavern',  'bluetick'),
    ('sunspot',  N'Sunspot',          'sunspot'),
    ('stefanos', N'Stefano''s',       'stefanos')
) s (conceptCode, displayName, themeCode)
ON t.conceptCode = s.conceptCode
WHEN MATCHED THEN UPDATE SET displayName = s.displayName, themeCode = s.themeCode
WHEN NOT MATCHED THEN INSERT (conceptCode, displayName, themeCode) VALUES (s.conceptCode, s.displayName, s.themeCode);

/* Stores: only the numbers confirmed by flow names so far. Add the rest
   (Bristol, Cleveland, Greeneville, Hixson, Johnson City, Lebanon, Lenoir City, Maryville,
   Morristown, Sevierville, Spring Hill, Straw Plains, UPC ...) with their numbers. */
MERGE menu.store t
USING (VALUES
    (2,  N'Aubrey''s Powell',      'aubreys',  N'https://www.aubreysrestaurants.com/powell',     1, NULL),
    (3,  N'Sunspot',               'sunspot',  NULL,                                              1, N'CONFIRM homeUrl'),
    (4,  N'Aubrey''s Cedar Bluff', 'aubreys',  N'https://www.aubreysrestaurants.com/cedarbluff', 1, NULL),
    (9,  N'Aubrey''s Papermill',   'aubreys',  N'https://www.aubreysrestaurants.com/papermill',  0, N'No MI_Exp export yet: Agilysys ticket'),
    (12, N'Bluetick Tavern',       'bluetick', N'https://www.blueticktavern.com',               1, NULL),
    (13, N'Aubrey''s Oak Ridge',   'aubreys',  N'https://www.aubreysrestaurants.com/oakridge',   1, NULL),
    (22, N'Stefano''s',            'stefanos', NULL,                                              1, N'CONFIRM name + homeUrl')
) s (locId, storeName, conceptCode, homeUrl, isPublished, note)
ON t.locId = s.locId
WHEN MATCHED THEN UPDATE SET storeName = s.storeName, conceptCode = s.conceptCode, note = s.note
WHEN NOT MATCHED THEN INSERT (locId, storeName, conceptCode, homeUrl, isPublished, note)
                      VALUES (s.locId, s.storeName, s.conceptCode, s.homeUrl, s.isPublished, s.note);
GO

/* Feed expectations follow menu.store: every published store must get a fresh export and a fresh JSON. */
CREATE OR ALTER PROCEDURE menu.usp_sync_feed_expectations
AS
BEGIN
    SET NOCOUNT ON;
    MERGE ops.feed_expectation t
    USING (SELECT 'menus' AS domainCode, f.feedCode, s.locId, f.maxAgeHours, s.isPublished AS isActive
           FROM menu.store s
           CROSS JOIN (VALUES ('MI_Exp', 25), ('menu_json', 25)) f (feedCode, maxAgeHours)) s
    ON t.domainCode = s.domainCode AND t.feedCode = s.feedCode AND t.locId = s.locId
    WHEN MATCHED THEN UPDATE SET isActive = s.isActive, maxAgeHours = s.maxAgeHours
    WHEN NOT MATCHED THEN INSERT (domainCode, feedCode, locId, maxAgeHours, isActive)
                          VALUES (s.domainCode, s.feedCode, s.locId, s.maxAgeHours, s.isActive);
END
GO
EXEC menu.usp_sync_feed_expectations;
GO
