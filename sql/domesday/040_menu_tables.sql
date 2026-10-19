/*
  Website menu model. Reference data only: everything about an individual item
  (name, class, price, on-screen, descriptions via SKUs) comes from InfoGenesis.
  There is deliberately no per-item override table: a wrong item is fixed in IG.
*/

/* Accordion groups on the mobile menu, and the printable menus. */
IF OBJECT_ID(N'menu.section_group') IS NULL
CREATE TABLE menu.section_group (
    groupCode    varchar(20)  NOT NULL CONSTRAINT PK_menu_section_group PRIMARY KEY,
    displayName  nvarchar(40) NOT NULL,
    sortRank     int          NOT NULL
);
GO

IF OBJECT_ID(N'menu.section') IS NULL
CREATE TABLE menu.section (
    sectionCode  varchar(30)  NOT NULL CONSTRAINT PK_menu_section PRIMARY KEY,
    groupCode    varchar(20)  NOT NULL CONSTRAINT FK_menu_section_group REFERENCES menu.section_group (groupCode),
    displayName  nvarchar(60) NOT NULL,
    sortRank     int          NOT NULL,
    isActive     bit          NOT NULL CONSTRAINT DF_menu_section_isActive DEFAULT (1)
);
GO

/* IG product class -> web section. Same ids at every store.
   sectionCode NULL + isExcluded = 1 : known class, deliberately not on the web (cocktails, cordials, food)
   class not in this table          : flagged in the exceptions email if a live alcohol item uses it */
IF OBJECT_ID(N'menu.product_class') IS NULL
CREATE TABLE menu.product_class (
    productClassId     int           NOT NULL CONSTRAINT PK_menu_product_class PRIMARY KEY,
    igName             nvarchar(60)  NOT NULL,
    sectionCode        varchar(30)   NULL CONSTRAINT FK_menu_product_class_section REFERENCES menu.section (sectionCode),
    serving            varchar(10)   NOT NULL CONSTRAINT DF_menu_product_class_serving DEFAULT ('all')
                       CONSTRAINT CK_menu_product_class_serving CHECK (serving IN ('all','glass','bottle')),
    revenueCategoryId  int           NULL,   -- expected IG revenue category; mismatches are flagged
    isExcluded         bit           NOT NULL CONSTRAINT DF_menu_product_class_excluded DEFAULT (0),
    note               nvarchar(200) NULL,
    CONSTRAINT CK_menu_product_class_mapped CHECK (isExcluded = 1 OR sectionCode IS NOT NULL)
);
GO

/* Descriptive attributes carried in IG SKU codes: <PREFIX>-<itemId> or <PREFIX>-<NN>-<itemId>.
   sortRank sets display order on every item (lower first). */
IF OBJECT_ID(N'menu.attribute_type') IS NULL
CREATE TABLE menu.attribute_type (
    prefix       varchar(10)  NOT NULL CONSTRAINT PK_menu_attribute_type PRIMARY KEY
                 CONSTRAINT CK_menu_attribute_type_prefix CHECK (prefix NOT LIKE '%[^A-Z]%'),
    label        nvarchar(40) NOT NULL,
    sortRank     int          NOT NULL,
    isMultiPart  bit          NOT NULL CONSTRAINT DF_menu_attribute_type_multi DEFAULT (0),
    maxParts     tinyint      NOT NULL CONSTRAINT DF_menu_attribute_type_maxParts DEFAULT (1),
    showLabel    bit          NOT NULL CONSTRAINT DF_menu_attribute_type_showLabel DEFAULT (1),
    isActive     bit          NOT NULL CONSTRAINT DF_menu_attribute_type_isActive DEFAULT (1)
);
GO

/* Concepts (brands). Theme colors and logos live in the PHP theme folder named by themeCode. */
IF OBJECT_ID(N'menu.concept') IS NULL
CREATE TABLE menu.concept (
    conceptCode  varchar(20)  NOT NULL CONSTRAINT PK_menu_concept PRIMARY KEY,
    displayName  nvarchar(60) NOT NULL,
    themeCode    varchar(20)  NOT NULL
);
GO

IF OBJECT_ID(N'menu.store') IS NULL
CREATE TABLE menu.store (
    locId         int           NOT NULL CONSTRAINT PK_menu_store PRIMARY KEY,
    storeName     nvarchar(60)  NOT NULL,     -- e.g. Aubrey's Powell
    conceptCode   varchar(20)   NOT NULL CONSTRAINT FK_menu_store_concept REFERENCES menu.concept (conceptCode),
    homeUrl       nvarchar(200) NULL,         -- the "No, I'm not 21" button goes here
    isPublished   bit           NOT NULL CONSTRAINT DF_menu_store_isPublished DEFAULT (0),  -- pipeline loads + publishes
    note          nvarchar(200) NULL
);
GO

/* Detects real menu changes so the website can say when the menu last changed. */
IF OBJECT_ID(N'menu.publish_state') IS NULL
CREATE TABLE menu.publish_state (
    locId              int            NOT NULL CONSTRAINT PK_menu_publish_state PRIMARY KEY,
    contentHash        varbinary(32)  NOT NULL,
    contentChangedUtc  datetime2(0)   NOT NULL,
    lastPublishedUtc   datetime2(0)   NOT NULL,
    lastRunId          varchar(64)    NOT NULL,
    itemCount          int            NOT NULL
);
GO
