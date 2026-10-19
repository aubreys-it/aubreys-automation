/* Stores for a pipeline run. @onlyMissing = 1 (the 8:15 retry) returns only stores that have
   not loaded today, so a retry does nothing when every store is already done. */
CREATE OR ALTER PROCEDURE menu.usp_stores_to_load
    @onlyMissing bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @todayEt date = CAST(ops.fn_eastern(SYSUTCDATETIME()) AS date);
    SELECT s.locId, RIGHT('0' + CAST(s.locId AS varchar(3)), 2) AS nn
    FROM menu.store s
    WHERE s.isPublished = 1
      AND (@onlyMissing = 0 OR NOT EXISTS (
            SELECT 1 FROM ig.mi_store_load l
            WHERE l.locId = s.locId AND CAST(ops.fn_eastern(l.lastLoadedUtc) AS date) = @todayEt))
    ORDER BY s.locId;
END
GO

/*
  menu.usp_check_ig_quality  -> WARN events for the exceptions email (things to fix in IG)
  menu.usp_publish_store     -> the store's menu JSON, ready for ADF to write to blob
*/

CREATE OR ALTER PROCEDURE menu.usp_check_ig_quality
    @runId varchar(64)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @domain varchar(40) = 'menus';

    /* Only stores loaded in this run */
    SELECT c.*
    INTO #c
    FROM menu.v_item_candidate c
    JOIN ig.mi_store_load l ON l.locId = c.locId AND l.lastRunId = @runId;

    CREATE TABLE #issue (code varchar(40) NOT NULL, locId int NOT NULL, itemId int NOT NULL,
                         itemName nvarchar(100) NULL, productClassId int NULL, info nvarchar(300) NULL);

    /* 1. Live alcohol item in a product class the web menu doesn't know */
    INSERT #issue SELECT 'IG_UNMAPPED_CLASS', locId, itemId, itemName, productClassId,
           CONCAT(N'product class ', productClassId, N', revenue category ', revenueCategoryId)
    FROM #c WHERE mappedClassId IS NULL;

    /* 2. Revenue category doesn't match the class (e.g. a liquor item in a beer class) */
    INSERT #issue SELECT 'IG_REVCAT_MISMATCH', locId, itemId, itemName, productClassId,
           CONCAT(N'class ', productClassId, N' expects revenue category ', expectedRevenueCategoryId,
                  N', item has ', revenueCategoryId)
    FROM #c WHERE isExcluded = 0 AND expectedRevenueCategoryId IS NOT NULL
              AND ISNULL(revenueCategoryId, -1) <> expectedRevenueCategoryId;

    /* 3. B/G prefix disagrees with the bottle/glass class */
    INSERT #issue SELECT 'IG_SERVING_MISMATCH', locId, itemId, itemName, productClassId,
           CONCAT(N'name says ', CASE WHEN n LIKE N'B %' THEN N'bottle' ELSE N'glass' END,
                  N', class ', productClassId, N' is ', serving)
    FROM (SELECT *, CASE WHEN itemName LIKE N'[0-9][0-9][_]%' THEN SUBSTRING(itemName, 4, 100) ELSE itemName END AS n FROM #c) x
    WHERE isExcluded = 0 AND ((serving = 'glass' AND n LIKE N'B %') OR (serving = 'bottle' AND n LIKE N'G %'));

    /* 4. Duplicate-item naming tricks: "(1)" suffix or trailing period */
    INSERT #issue SELECT 'IG_NAME_SUFFIX', locId, itemId, itemName, productClassId,
           N'name ends in a period or (n); shows on the web as "' + displayName + N'"'
    FROM #c WHERE isExcluded = 0 AND sectionCode IS NOT NULL
              AND (RTRIM(itemName) LIKE N'%.' OR RTRIM(itemName) LIKE N'%([0-9])' OR RTRIM(itemName) LIKE N'%([0-9][0-9])');

    /* 5. No usable default (level 1) price: item is published without a price */
    INSERT #issue SELECT 'IG_NO_PRICE', locId, itemId, itemName, productClassId, N'no price level 1 (or $0.00)'
    FROM #c WHERE isExcluded = 0 AND sectionCode IS NOT NULL AND ISNULL(price, 0) = 0;

    /* 6. Two live items show as the same line in the same section */
    INSERT #issue SELECT 'IG_DUPLICATE_NAME', c.locId, c.itemId, c.itemName, c.productClassId,
           CONCAT(N'"', c.displayName, N'" appears ', d.n, N' times in ', c.sectionCode)
    FROM #c c
    JOIN (SELECT locId, sectionCode, serving, displayName, COUNT(*) AS n
          FROM #c WHERE isExcluded = 0 AND sectionCode IS NOT NULL
          GROUP BY locId, sectionCode, serving, displayName HAVING COUNT(*) > 1) d
      ON d.locId = c.locId AND d.sectionCode = c.sectionCode AND d.serving = c.serving AND d.displayName = c.displayName;

    /* 7. SKU attribute codes that won't be shown (any item: SKUs are used for nothing else) */
    INSERT #issue SELECT 'IG_SKU_INVALID', s.locId, s.itemId, i.itemName, i.productClassId,
           CONCAT(N'SKU "', s.skuCode, N'": ',
                  CASE WHEN s.prefix IS NULL OR s.label IS NULL THEN N'unknown prefix (valid: '
                            + (SELECT STRING_AGG(prefix, N', ') WITHIN GROUP (ORDER BY sortRank) FROM menu.attribute_type WHERE isActive = 1) + N')'
                       WHEN s.prefixActive = 0 THEN N'prefix is turned off'
                       WHEN s.codeItemId IS NULL THEN N'does not end in an item number'
                       WHEN s.codeItemId <> s.itemId THEN CONCAT(N'item number ', s.idText, N' does not match this item (', s.itemId, N')')
                       WHEN s.isMultiPart = 1 AND (s.partNo IS NULL OR s.partNo NOT BETWEEN 1 AND s.maxParts)
                            THEN CONCAT(N'needs a part number 01-', RIGHT('0' + CAST(s.maxParts AS varchar(3)), 2), N', e.g. ', s.prefix, N'-01-', s.itemId)
                       WHEN s.isMultiPart = 0 AND s.partText IS NOT NULL THEN CONCAT(N'should not have a part number, use ', s.prefix, N'-', s.itemId)
                       ELSE N'description is empty' END)
    FROM menu.v_sku_parsed s
    JOIN ig.mi_store_load l ON l.locId = s.locId AND l.lastRunId = @runId
    JOIN ig.item i ON i.locId = s.locId AND i.itemId = s.itemId
    WHERE NOT ( s.prefixActive = 1 AND s.codeItemId = s.itemId
                AND NULLIF(LTRIM(RTRIM(s.skuDescription)), N'') IS NOT NULL
                AND ( (s.isMultiPart = 0 AND s.partText IS NULL) OR (s.isMultiPart = 1 AND s.partNo BETWEEN 1 AND s.maxParts) ) );

    /* One event per item + problem, listing the stores (the item master is company-wide) */
    INSERT ops.run_event (runId, domainCode, severity, step, locId, itemId, code, message, detail)
    SELECT @runId, @domain, 'WARN', N'quality', NULL, g.itemId, g.code,
           LEFT(CONCAT(g.itemName, N' – ', g.info), 1000),
           (SELECT g.stores AS stores, g.productClassId AS productClassId, g.itemName AS itemName FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM (
        SELECT code, itemId, MAX(itemName) AS itemName, MAX(productClassId) AS productClassId, MAX(info) AS info,
               STRING_AGG(RIGHT('0' + CAST(locId AS varchar(3)), 2), N', ') WITHIN GROUP (ORDER BY locId) AS stores
        FROM (SELECT DISTINCT code, locId, itemId, itemName, productClassId, info FROM #issue) d
        GROUP BY code, itemId
    ) g;

    SELECT code, COUNT(DISTINCT itemId) AS items FROM #issue GROUP BY code;
END
GO

/* Returns one row: shouldPublish, blobName, itemCount, menuJson.
   Does not publish a store that was not loaded in this run (keeps yesterday's file, so the
   website's staleness check and the watchdog stay truthful). */
CREATE OR ALTER PROCEDURE menu.usp_publish_store
    @locId int,
    @runId varchar(64)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @domain varchar(40) = 'menus';
    DECLARE @nn char(2) = RIGHT('0' + CAST(@locId AS varchar(3)), 2);
    DECLARE @blobName nvarchar(200) = CONCAT(N'v1/', @nn, N'.json');   -- container: menus

    IF NOT EXISTS (SELECT 1 FROM ig.mi_store_load WHERE locId = @locId AND lastRunId = @runId)
       OR NOT EXISTS (SELECT 1 FROM menu.store WHERE locId = @locId AND isPublished = 1)
    BEGIN
        SELECT @locId AS locId, CAST(0 AS bit) AS shouldPublish, @blobName AS blobName, 0 AS itemCount,
               CAST(NULL AS nvarchar(max)) AS menuJson;
        RETURN;
    END

    SELECT w.sectionCode, w.serving, w.itemId, w.displayName, w.price,
           COALESCE((SELECT a.label, a.value, a.showLabel
                     FROM menu.v_item_attribute a
                     WHERE a.locId = w.locId AND a.itemId = w.itemId
                     ORDER BY a.sortRank, a.prefix
                     FOR JSON PATH), N'[]') AS attrs
    INTO #w
    FROM menu.v_item_web w
    WHERE w.locId = @locId;

    DECLARE @itemCount int = (SELECT COUNT(*) FROM #w);

    IF @itemCount = 0
    BEGIN
        EXEC ops.usp_log_event @runId = @runId, @domainCode = @domain, @code = 'MENU_EMPTY', @step = N'publish',
             @locId = @locId, @message = N'No web menu items for this store; yesterday''s menu was left in place.';
        SELECT @locId AS locId, CAST(0 AS bit) AS shouldPublish, @blobName AS blobName, 0 AS itemCount,
               CAST(NULL AS nvarchar(max)) AS menuJson;
        RETURN;
    END

    DECLARE @groups nvarchar(max) = (
        SELECT g.groupCode AS code, g.displayName AS name,
               JSON_QUERY((
                   SELECT s.sectionCode AS code, s.displayName AS name,
                          JSON_QUERY((
                              SELECT v.serving AS code,
                                     CASE v.serving WHEN 'glass' THEN N'By the Glass' WHEN 'bottle' THEN N'By the Bottle' END AS name,
                                     JSON_QUERY((
                                         SELECT w.itemId AS id, w.displayName AS name, CAST(w.price AS decimal(10,2)) AS price,
                                                JSON_QUERY(w.attrs) AS attributes
                                         FROM #w w
                                         WHERE w.sectionCode = s.sectionCode AND w.serving = v.serving
                                         ORDER BY w.displayName, w.itemId
                                         FOR JSON PATH, INCLUDE_NULL_VALUES)) AS items
                              FROM (SELECT DISTINCT serving,
                                           CASE serving WHEN 'glass' THEN 1 WHEN 'bottle' THEN 2 ELSE 0 END AS ord
                                    FROM #w WHERE sectionCode = s.sectionCode) v
                              ORDER BY v.ord
                              FOR JSON PATH, INCLUDE_NULL_VALUES)) AS servings
                   FROM menu.section s
                   WHERE s.groupCode = g.groupCode AND s.isActive = 1
                     AND EXISTS (SELECT 1 FROM #w x WHERE x.sectionCode = s.sectionCode)
                   ORDER BY s.sortRank
                   FOR JSON PATH)) AS sections
        FROM menu.section_group g
        WHERE EXISTS (SELECT 1 FROM #w x JOIN menu.section s ON s.sectionCode = x.sectionCode WHERE s.groupCode = g.groupCode)
        ORDER BY g.sortRank
        FOR JSON PATH);

    DECLARE @hash varbinary(32) = HASHBYTES('SHA2_256', @groups);
    DECLARE @now datetime2(0) = SYSUTCDATETIME();

    MERGE menu.publish_state t
    USING (SELECT @locId AS locId) s ON t.locId = s.locId
    WHEN MATCHED THEN UPDATE SET
        contentChangedUtc = CASE WHEN t.contentHash = @hash THEN t.contentChangedUtc ELSE @now END,
        contentHash = @hash, lastPublishedUtc = @now, lastRunId = @runId, itemCount = @itemCount
    WHEN NOT MATCHED THEN INSERT (locId, contentHash, contentChangedUtc, lastPublishedUtc, lastRunId, itemCount)
        VALUES (@locId, @hash, @now, @now, @runId, @itemCount);

    DECLARE @json nvarchar(max) = (
        SELECT 'aubreys-menu/1' AS [schema],
               st.locId AS [store.locId], @nn AS [store.code], st.storeName AS [store.name],
               st.conceptCode AS [store.concept], c.themeCode AS [store.theme], st.homeUrl AS [store.homeUrl],
               CONVERT(char(19), @now, 126) + 'Z' AS generatedAt,
               CONVERT(char(19), ps.contentChangedUtc, 126) + 'Z' AS contentChangedAt,
               CONVERT(char(19), l.sourceModifiedUtc, 126) + 'Z' AS sourceExportAt,
               @itemCount AS itemCount,
               JSON_QUERY(@groups) AS groups
        FROM menu.store st
        JOIN menu.concept c ON c.conceptCode = st.conceptCode
        JOIN menu.publish_state ps ON ps.locId = st.locId
        LEFT JOIN ig.mi_store_load l ON l.locId = st.locId
        WHERE st.locId = @locId
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER, INCLUDE_NULL_VALUES);

    SELECT @locId AS locId, CAST(1 AS bit) AS shouldPublish, @blobName AS blobName, @itemCount AS itemCount, @json AS menuJson;
END
GO
