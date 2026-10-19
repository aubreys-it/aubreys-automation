/*
  InfoGenesis menu-item tables (new). Built side by side with the legacy ig.mi_* tables,
  which nothing reads and which can be dropped once this is live.

  Current tables hold today's export only (one row per store + item).
  item / item_price_level / item_store_price_level are system-versioned (temporal):
  SQL Server keeps every prior version in *_history automatically and purges it after
  HISTORY_RETENTION_PERIOD. Queries against current data never touch history.
    "What did 02 charge for item 70 on Aug 1?"
      SELECT * FROM ig.item_price_level FOR SYSTEM_TIME AS OF '2026-08-01T12:00'
      WHERE locId = 2 AND itemId = 70;

  item_sku_code / item_choice_group / item_kitchen_printer are current-only (no history).

  stg.mi_* tables are written by the ADF Copy activities (all columns nullable, wide types,
  so a bad value never fails the copy; validation happens in ig.usp_mi_merge).
*/

/* ---------------- staging ---------------- */
IF OBJECT_ID(N'stg.mi_item') IS NULL
CREATE TABLE stg.mi_item (
    locId int NULL, recordType nvarchar(10) NULL, itemId int NULL, itemName nvarchar(200) NULL,
    buttonText1 nvarchar(100) NULL, buttonText2 nvarchar(100) NULL, printText nvarchar(100) NULL,
    productClassId int NULL, revenueCategoryId int NULL, taxGroupId int NULL, securityLevelId int NULL,
    reportCategoryId int NULL, useWeightFlag int NULL, weightTareAmount decimal(10,4) NULL, barGunCode int NULL,
    costAmount decimal(19,4) NULL, promptForPrice int NULL, printOnCheck int NULL, discountable int NULL,
    voidable int NULL, notActive int NULL, taxIncluded int NULL, itemGroupId int NULL, receiptText nvarchar(100) NULL,
    allowPriceOverride int NULL, covers int NULL, storeId int NULL, kdsText nvarchar(100) NULL,
    kdsDepartmentId int NULL, kdsCategoryId int NULL, kdsCookTime int NULL, defaultImageId int NULL,
    stockItem int NULL, primaryTaxCode nvarchar(200) NULL, promptForName int NULL, encodingLang nvarchar(20) NULL
);
GO
IF OBJECT_ID(N'stg.mi_price_level') IS NULL
CREATE TABLE stg.mi_price_level (locId int NULL, itemId int NULL, priceLevelId int NULL, price decimal(19,4) NULL);
IF OBJECT_ID(N'stg.mi_store_price_level') IS NULL
CREATE TABLE stg.mi_store_price_level (locId int NULL, itemId int NULL, priceLevelId int NULL, price decimal(19,4) NULL);
IF OBJECT_ID(N'stg.mi_sku_code') IS NULL
CREATE TABLE stg.mi_sku_code (locId int NULL, itemId int NULL, skuCode nvarchar(100) NULL, skuDescription nvarchar(200) NULL);
IF OBJECT_ID(N'stg.mi_choice_group') IS NULL
CREATE TABLE stg.mi_choice_group (locId int NULL, itemId int NULL, choiceGroupId int NULL, seqNumber int NULL);
IF OBJECT_ID(N'stg.mi_kitchen_printer') IS NULL
CREATE TABLE stg.mi_kitchen_printer (locId int NULL, itemId int NULL, kpId int NULL, primaryFlag int NULL);
GO

/* ---------------- current + history ---------------- */
IF OBJECT_ID(N'ig.item') IS NULL
CREATE TABLE ig.item (
    locId              int            NOT NULL,
    itemId             int            NOT NULL,
    itemName           nvarchar(100)  NOT NULL,
    buttonText1        nvarchar(40)   NULL,
    buttonText2        nvarchar(40)   NULL,
    printText          nvarchar(40)   NULL,
    productClassId     int            NULL,
    revenueCategoryId  int            NULL,
    taxGroupId         int            NULL,
    securityLevelId    int            NULL,
    reportCategoryId   int            NULL,
    useWeightFlag      int            NULL,
    weightTareAmount   decimal(10,4)  NULL,
    barGunCode         int            NULL,
    costAmount         decimal(19,4)  NULL,
    promptForPrice     int            NULL,
    printOnCheck       int            NULL,
    discountable       int            NULL,
    voidable           int            NULL,
    notActive          int            NULL,
    taxIncluded        int            NULL,
    itemGroupId        int            NULL,     -- 1 = not on any screen at this store
    receiptText        nvarchar(40)   NULL,
    allowPriceOverride int            NULL,
    covers             int            NULL,
    storeId            int            NULL,
    kdsText            nvarchar(40)   NULL,
    kdsDepartmentId    int            NULL,
    kdsCategoryId      int            NULL,
    kdsCookTime        int            NULL,
    defaultImageId     int            NULL,
    stockItem          int            NULL,
    primaryTaxCode     nvarchar(100)  NULL,
    promptForName      int            NULL,
    encodingLang       nvarchar(10)   NULL,
    isOnScreen AS (CAST(CASE WHEN ISNULL(itemGroupId, 1) <> 1 THEN 1 ELSE 0 END AS bit)),
    validFrom datetime2(0) GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,
    validTo   datetime2(0) GENERATED ALWAYS AS ROW END   HIDDEN NOT NULL,
    PERIOD FOR SYSTEM_TIME (validFrom, validTo),
    CONSTRAINT PK_ig_item PRIMARY KEY (locId, itemId)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = ig.item_history, HISTORY_RETENTION_PERIOD = 12 MONTHS));
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ig_item_class' AND object_id = OBJECT_ID(N'ig.item'))
    CREATE INDEX IX_ig_item_class ON ig.item (productClassId, locId) INCLUDE (itemName, itemGroupId, revenueCategoryId);
GO

IF OBJECT_ID(N'ig.item_price_level') IS NULL
CREATE TABLE ig.item_price_level (
    locId        int           NOT NULL,
    itemId       int           NOT NULL,
    priceLevelId int           NOT NULL,
    price        decimal(19,4) NULL,
    validFrom datetime2(0) GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,
    validTo   datetime2(0) GENERATED ALWAYS AS ROW END   HIDDEN NOT NULL,
    PERIOD FOR SYSTEM_TIME (validFrom, validTo),
    CONSTRAINT PK_ig_item_price_level PRIMARY KEY (locId, itemId, priceLevelId)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = ig.item_price_level_history, HISTORY_RETENTION_PERIOD = 12 MONTHS));
GO

IF OBJECT_ID(N'ig.item_store_price_level') IS NULL
CREATE TABLE ig.item_store_price_level (
    locId        int           NOT NULL,
    itemId       int           NOT NULL,
    priceLevelId int           NOT NULL,
    price        decimal(19,4) NULL,
    validFrom datetime2(0) GENERATED ALWAYS AS ROW START HIDDEN NOT NULL,
    validTo   datetime2(0) GENERATED ALWAYS AS ROW END   HIDDEN NOT NULL,
    PERIOD FOR SYSTEM_TIME (validFrom, validTo),
    CONSTRAINT PK_ig_item_store_price_level PRIMARY KEY (locId, itemId, priceLevelId)
)
WITH (SYSTEM_VERSIONING = ON (HISTORY_TABLE = ig.item_store_price_level_history, HISTORY_RETENTION_PERIOD = 12 MONTHS));
GO

IF OBJECT_ID(N'ig.item_sku_code') IS NULL
CREATE TABLE ig.item_sku_code (
    locId          int           NOT NULL,
    itemId         int           NOT NULL,
    skuCode        nvarchar(30)  NOT NULL,
    skuDescription nvarchar(50)  NULL,
    CONSTRAINT PK_ig_item_sku_code PRIMARY KEY (locId, itemId, skuCode)
);
IF OBJECT_ID(N'ig.item_choice_group') IS NULL
CREATE TABLE ig.item_choice_group (
    locId int NOT NULL, itemId int NOT NULL, choiceGroupId int NOT NULL, seqNumber int NULL,
    CONSTRAINT PK_ig_item_choice_group PRIMARY KEY (locId, itemId, choiceGroupId)
);
IF OBJECT_ID(N'ig.item_kitchen_printer') IS NULL
CREATE TABLE ig.item_kitchen_printer (
    locId int NOT NULL, itemId int NOT NULL, kpId int NOT NULL, primaryFlag int NULL,
    CONSTRAINT PK_ig_item_kitchen_printer PRIMARY KEY (locId, itemId, kpId)
);
GO

/* When each store was last loaded, and from which source file. */
IF OBJECT_ID(N'ig.mi_store_load') IS NULL
CREATE TABLE ig.mi_store_load (
    locId              int           NOT NULL CONSTRAINT PK_ig_mi_store_load PRIMARY KEY,
    lastRunId          varchar(64)   NOT NULL,
    lastLoadedUtc      datetime2(0)  NOT NULL,
    sourceModifiedUtc  datetime2(0)  NULL,
    itemCount          int           NOT NULL
);
GO
