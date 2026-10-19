/*
  ig.usp_mi_merge
  Merges whatever stores are in stg.mi_* (only stores whose file parsed cleanly are copied
  there) into the ig current tables. Stores not in staging are not touched, so a store whose
  file was missing keeps yesterday's data.

  Rows are only updated when a value actually changed, so temporal history grows only with
  real changes. Items missing from a store's file are deleted from current (kept in history).
*/
CREATE OR ALTER PROCEDURE ig.usp_mi_merge
    @runId varchar(64)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @domain varchar(40) = 'menus';

    /* Bad staging rows (should never happen: the parser validates) */
    IF EXISTS (SELECT 1 FROM stg.mi_item WHERE locId IS NULL OR itemId IS NULL OR itemName IS NULL)
    BEGIN
        INSERT ops.run_event (runId, domainCode, severity, step, locId, code, message)
        SELECT @runId, @domain, 'WARN', N'merge', locId, 'LOAD_ROW_SKIPPED',
               CONCAT(COUNT(*), N' staged item row(s) had no locId/itemId/name and were skipped')
        FROM stg.mi_item WHERE locId IS NULL OR itemId IS NULL OR itemName IS NULL
        GROUP BY locId;
    END

    CREATE TABLE #loaded (locId int NOT NULL PRIMARY KEY, itemCount int NOT NULL);
    INSERT #loaded (locId, itemCount)
    SELECT locId, COUNT(*) FROM stg.mi_item
    WHERE locId IS NOT NULL AND itemId IS NOT NULL AND itemName IS NOT NULL
    GROUP BY locId;

    IF NOT EXISTS (SELECT 1 FROM #loaded)
    BEGIN
        -- Normal on the 8:15 retry when every store already loaded; otherwise each store's
        -- FILE_MISSING / PARSE_FAILED event already explains why.
        EXEC ops.usp_log_event @runId = @runId, @domainCode = @domain, @code = 'NOTHING_TO_LOAD', @step = N'merge',
             @message = N'No store files were staged in this run.';
        SELECT CAST(NULL AS int) AS locId, 0 AS itemCount WHERE 1 = 0;
        RETURN;
    END

    /* De-duplicated, typed sources */
    SELECT DISTINCT s.locId, s.itemId,
           LEFT(s.itemName, 100) AS itemName, LEFT(s.buttonText1, 40) AS buttonText1, LEFT(s.buttonText2, 40) AS buttonText2,
           LEFT(s.printText, 40) AS printText, s.productClassId, s.revenueCategoryId, s.taxGroupId, s.securityLevelId,
           s.reportCategoryId, s.useWeightFlag, s.weightTareAmount, s.barGunCode, s.costAmount, s.promptForPrice,
           s.printOnCheck, s.discountable, s.voidable, s.notActive, s.taxIncluded, s.itemGroupId,
           LEFT(s.receiptText, 40) AS receiptText, s.allowPriceOverride, s.covers, s.storeId, LEFT(s.kdsText, 40) AS kdsText,
           s.kdsDepartmentId, s.kdsCategoryId, s.kdsCookTime, s.defaultImageId, s.stockItem,
           LEFT(s.primaryTaxCode, 100) AS primaryTaxCode, s.promptForName, LEFT(s.encodingLang, 10) AS encodingLang
    INTO #item
    FROM stg.mi_item s JOIN #loaded l ON l.locId = s.locId
    WHERE s.itemId IS NOT NULL AND s.itemName IS NOT NULL;

    BEGIN TRAN;

    /* ---- item ---- */
    WITH t AS (SELECT * FROM ig.item WHERE locId IN (SELECT locId FROM #loaded))
    MERGE t
    USING #item s ON t.locId = s.locId AND t.itemId = s.itemId
    WHEN MATCHED AND EXISTS (
        SELECT s.itemName, s.buttonText1, s.buttonText2, s.printText, s.productClassId, s.revenueCategoryId, s.taxGroupId,
               s.securityLevelId, s.reportCategoryId, s.useWeightFlag, s.weightTareAmount, s.barGunCode, s.costAmount,
               s.promptForPrice, s.printOnCheck, s.discountable, s.voidable, s.notActive, s.taxIncluded, s.itemGroupId,
               s.receiptText, s.allowPriceOverride, s.covers, s.storeId, s.kdsText, s.kdsDepartmentId, s.kdsCategoryId,
               s.kdsCookTime, s.defaultImageId, s.stockItem, s.primaryTaxCode, s.promptForName, s.encodingLang
        EXCEPT
        SELECT t.itemName, t.buttonText1, t.buttonText2, t.printText, t.productClassId, t.revenueCategoryId, t.taxGroupId,
               t.securityLevelId, t.reportCategoryId, t.useWeightFlag, t.weightTareAmount, t.barGunCode, t.costAmount,
               t.promptForPrice, t.printOnCheck, t.discountable, t.voidable, t.notActive, t.taxIncluded, t.itemGroupId,
               t.receiptText, t.allowPriceOverride, t.covers, t.storeId, t.kdsText, t.kdsDepartmentId, t.kdsCategoryId,
               t.kdsCookTime, t.defaultImageId, t.stockItem, t.primaryTaxCode, t.promptForName, t.encodingLang)
    THEN UPDATE SET
        itemName = s.itemName, buttonText1 = s.buttonText1, buttonText2 = s.buttonText2, printText = s.printText,
        productClassId = s.productClassId, revenueCategoryId = s.revenueCategoryId, taxGroupId = s.taxGroupId,
        securityLevelId = s.securityLevelId, reportCategoryId = s.reportCategoryId, useWeightFlag = s.useWeightFlag,
        weightTareAmount = s.weightTareAmount, barGunCode = s.barGunCode, costAmount = s.costAmount,
        promptForPrice = s.promptForPrice, printOnCheck = s.printOnCheck, discountable = s.discountable,
        voidable = s.voidable, notActive = s.notActive, taxIncluded = s.taxIncluded, itemGroupId = s.itemGroupId,
        receiptText = s.receiptText, allowPriceOverride = s.allowPriceOverride, covers = s.covers, storeId = s.storeId,
        kdsText = s.kdsText, kdsDepartmentId = s.kdsDepartmentId, kdsCategoryId = s.kdsCategoryId,
        kdsCookTime = s.kdsCookTime, defaultImageId = s.defaultImageId, stockItem = s.stockItem,
        primaryTaxCode = s.primaryTaxCode, promptForName = s.promptForName, encodingLang = s.encodingLang
    WHEN NOT MATCHED BY TARGET THEN INSERT (
        locId, itemId, itemName, buttonText1, buttonText2, printText, productClassId, revenueCategoryId, taxGroupId,
        securityLevelId, reportCategoryId, useWeightFlag, weightTareAmount, barGunCode, costAmount, promptForPrice,
        printOnCheck, discountable, voidable, notActive, taxIncluded, itemGroupId, receiptText, allowPriceOverride,
        covers, storeId, kdsText, kdsDepartmentId, kdsCategoryId, kdsCookTime, defaultImageId, stockItem,
        primaryTaxCode, promptForName, encodingLang)
    VALUES (
        s.locId, s.itemId, s.itemName, s.buttonText1, s.buttonText2, s.printText, s.productClassId, s.revenueCategoryId,
        s.taxGroupId, s.securityLevelId, s.reportCategoryId, s.useWeightFlag, s.weightTareAmount, s.barGunCode,
        s.costAmount, s.promptForPrice, s.printOnCheck, s.discountable, s.voidable, s.notActive, s.taxIncluded,
        s.itemGroupId, s.receiptText, s.allowPriceOverride, s.covers, s.storeId, s.kdsText, s.kdsDepartmentId,
        s.kdsCategoryId, s.kdsCookTime, s.defaultImageId, s.stockItem, s.primaryTaxCode, s.promptForName, s.encodingLang)
    WHEN NOT MATCHED BY SOURCE THEN DELETE;

    /* ---- price levels (temporal) ---- */
    WITH t AS (SELECT * FROM ig.item_price_level WHERE locId IN (SELECT locId FROM #loaded)),
         s AS (SELECT locId, itemId, priceLevelId, MAX(price) AS price
               FROM stg.mi_price_level WHERE locId IN (SELECT locId FROM #loaded) AND itemId IS NOT NULL AND priceLevelId IS NOT NULL
               GROUP BY locId, itemId, priceLevelId)
    MERGE t USING s ON t.locId = s.locId AND t.itemId = s.itemId AND t.priceLevelId = s.priceLevelId
    WHEN MATCHED AND EXISTS (SELECT s.price EXCEPT SELECT t.price) THEN UPDATE SET price = s.price
    WHEN NOT MATCHED BY TARGET THEN INSERT (locId, itemId, priceLevelId, price) VALUES (s.locId, s.itemId, s.priceLevelId, s.price)
    WHEN NOT MATCHED BY SOURCE THEN DELETE;

    WITH t AS (SELECT * FROM ig.item_store_price_level WHERE locId IN (SELECT locId FROM #loaded)),
         s AS (SELECT locId, itemId, priceLevelId, MAX(price) AS price
               FROM stg.mi_store_price_level WHERE locId IN (SELECT locId FROM #loaded) AND itemId IS NOT NULL AND priceLevelId IS NOT NULL
               GROUP BY locId, itemId, priceLevelId)
    MERGE t USING s ON t.locId = s.locId AND t.itemId = s.itemId AND t.priceLevelId = s.priceLevelId
    WHEN MATCHED AND EXISTS (SELECT s.price EXCEPT SELECT t.price) THEN UPDATE SET price = s.price
    WHEN NOT MATCHED BY TARGET THEN INSERT (locId, itemId, priceLevelId, price) VALUES (s.locId, s.itemId, s.priceLevelId, s.price)
    WHEN NOT MATCHED BY SOURCE THEN DELETE;

    /* ---- current-only tables: replace per loaded store ---- */
    DELETE FROM ig.item_sku_code        WHERE locId IN (SELECT locId FROM #loaded);
    DELETE FROM ig.item_choice_group    WHERE locId IN (SELECT locId FROM #loaded);
    DELETE FROM ig.item_kitchen_printer WHERE locId IN (SELECT locId FROM #loaded);

    INSERT ig.item_sku_code (locId, itemId, skuCode, skuDescription)
    SELECT locId, itemId, LEFT(LTRIM(RTRIM(skuCode)), 30), MAX(LEFT(skuDescription, 50))
    FROM stg.mi_sku_code
    WHERE locId IN (SELECT locId FROM #loaded) AND itemId IS NOT NULL AND NULLIF(LTRIM(RTRIM(skuCode)), N'') IS NOT NULL
    GROUP BY locId, itemId, LEFT(LTRIM(RTRIM(skuCode)), 30);

    INSERT ig.item_choice_group (locId, itemId, choiceGroupId, seqNumber)
    SELECT locId, itemId, choiceGroupId, MAX(seqNumber)
    FROM stg.mi_choice_group
    WHERE locId IN (SELECT locId FROM #loaded) AND itemId IS NOT NULL AND choiceGroupId IS NOT NULL
    GROUP BY locId, itemId, choiceGroupId;

    INSERT ig.item_kitchen_printer (locId, itemId, kpId, primaryFlag)
    SELECT locId, itemId, kpId, MAX(primaryFlag)
    FROM stg.mi_kitchen_printer
    WHERE locId IN (SELECT locId FROM #loaded) AND itemId IS NOT NULL AND kpId IS NOT NULL
    GROUP BY locId, itemId, kpId;

    /* ---- load bookkeeping ---- */
    MERGE ig.mi_store_load t
    USING (SELECT l.locId, l.itemCount,
                  (SELECT MAX(fa.sourceModifiedUtc) FROM ops.feed_arrival fa
                   WHERE fa.runId = @runId AND fa.feedCode = 'MI_Exp' AND fa.locId = l.locId) AS sourceModifiedUtc
           FROM #loaded l) s ON t.locId = s.locId
    WHEN MATCHED THEN UPDATE SET lastRunId = @runId, lastLoadedUtc = SYSUTCDATETIME(),
                                 sourceModifiedUtc = s.sourceModifiedUtc, itemCount = s.itemCount
    WHEN NOT MATCHED THEN INSERT (locId, lastRunId, lastLoadedUtc, sourceModifiedUtc, itemCount)
                          VALUES (s.locId, @runId, SYSUTCDATETIME(), s.sourceModifiedUtc, s.itemCount);

    COMMIT;

    INSERT ops.run_event (runId, domainCode, severity, step, locId, code, message)
    SELECT @runId, @domain, 'INFO', N'merge', locId, 'STORE_LOADED',
           CONCAT(N'Store ', RIGHT('0' + CAST(locId AS varchar(3)), 2), N': ', itemCount, N' items loaded')
    FROM #loaded;

    /* Clear staging for the next run */
    DELETE FROM stg.mi_item;            DELETE FROM stg.mi_price_level;  DELETE FROM stg.mi_store_price_level;
    DELETE FROM stg.mi_sku_code;        DELETE FROM stg.mi_choice_group; DELETE FROM stg.mi_kitchen_printer;

    SELECT locId, itemCount FROM #loaded ORDER BY locId;
END
GO

/* Logs the parser function's JSON result for one store: every rejected line as PARSE_REJECT,
   and PARSE_FAILED when the store was not loaded. Keeps branching out of ADF. */
CREATE OR ALTER PROCEDURE ig.usp_log_parse_result
    @runId  varchar(64),
    @locId  int,
    @result nvarchar(max)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @domain varchar(40) = 'menus';
    IF @result IS NULL OR ISJSON(@result) = 0
    BEGIN
        EXEC ops.usp_log_event @runId = @runId, @domainCode = @domain, @code = 'PARSE_FAILED', @step = N'parse',
             @locId = @locId, @message = N'Parser returned no usable result.', @detail = @result;
        RETURN;
    END

    DECLARE @events nvarchar(max) = JSON_QUERY(@result, '$.events');
    EXEC ops.usp_log_events_json @runId = @runId, @domainCode = @domain, @events = @events, @step = N'parse';

    IF JSON_VALUE(@result, '$.ok') <> 'true'
    BEGIN
        DECLARE @msg nvarchar(1000) = CONCAT(N'Store ', RIGHT('0' + CAST(@locId AS varchar(3)), 2), N' not loaded: ',
                                             JSON_VALUE(@result, '$.error'));
        DECLARE @detail nvarchar(max) = (SELECT JSON_VALUE(@result, '$.rawBlob') AS rawBlob,
                                                JSON_VALUE(@result, '$.lineCount') AS lineCount,
                                                JSON_VALUE(@result, '$.rejectCount') AS rejectCount
                                         FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);
        EXEC ops.usp_log_event @runId = @runId, @domainCode = @domain, @code = 'PARSE_FAILED', @step = N'parse',
             @locId = @locId, @message = @msg, @detail = @detail;
    END
END
GO
