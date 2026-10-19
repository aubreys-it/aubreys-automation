/*
  Menu views: what the website shows, derived entirely from IG data.
*/

/* Web display name. Strips IG conventions that are right on the POS but wrong on the web:
     NN_  store prefix          "12_Bud Bucket"           -> "Bud Bucket"
     B/G/C serving prefix       "B Kim Crawford"          -> "Kim Crawford"
     (n)  duplicate suffix      "Mountain Cuvee(1)"       -> "Mountain Cuvee"
     trailing periods           "Belle Meade."            -> "Belle Meade"
   The (n) and trailing-period cases are also reported in the exceptions email so IG gets fixed. */
CREATE OR ALTER FUNCTION menu.fn_clean_name (@name nvarchar(100))
RETURNS nvarchar(100)
WITH SCHEMABINDING
AS
BEGIN
    DECLARE @s nvarchar(100) = LTRIM(RTRIM(@name));
    IF @s LIKE N'[0-9][0-9][_]%' SET @s = LTRIM(SUBSTRING(@s, 4, 100));
    IF @s LIKE N'[BGC] %'         SET @s = LTRIM(SUBSTRING(@s, 3, 100));
    IF @s LIKE N'%([0-9])'        SET @s = RTRIM(LEFT(@s, LEN(@s) - 3));
    IF @s LIKE N'%([0-9][0-9])'   SET @s = RTRIM(LEFT(@s, LEN(@s) - 4));
    WHILE LEN(@s) > 1 AND RIGHT(@s, 1) = N'.' SET @s = RTRIM(LEFT(@s, LEN(@s) - 1));
    RETURN @s;
END
GO

/* Every on-screen alcohol item at every store, with its web mapping (if any) and effective price.
   Used by both publishing and the data-quality checks. */
CREATE OR ALTER VIEW menu.v_item_candidate
AS
SELECT i.locId, i.itemId, i.itemName, i.productClassId, i.revenueCategoryId, i.itemGroupId,
       pc.productClassId AS mappedClassId, pc.sectionCode, pc.serving, pc.isExcluded,
       pc.revenueCategoryId AS expectedRevenueCategoryId,
       menu.fn_clean_name(i.itemName) AS displayName,
       COALESCE(spl.price, pl.price) AS price
FROM ig.item i
LEFT JOIN menu.product_class pc ON pc.productClassId = i.productClassId
LEFT JOIN ig.item_price_level pl ON pl.locId = i.locId AND pl.itemId = i.itemId AND pl.priceLevelId = 1
LEFT JOIN ig.item_store_price_level spl ON spl.locId = i.locId AND spl.itemId = i.itemId AND spl.priceLevelId = 1
WHERE i.isOnScreen = 1
  AND (i.revenueCategoryId IN (2, 3, 4) OR pc.sectionCode IS NOT NULL);
GO

/* What goes on the website. */
CREATE OR ALTER VIEW menu.v_item_web
AS
SELECT c.locId, c.itemId, c.sectionCode, c.serving, c.displayName, c.price
FROM menu.v_item_candidate c
JOIN menu.section s ON s.sectionCode = c.sectionCode AND s.isActive = 1
WHERE c.isExcluded = 0 AND c.sectionCode IS NOT NULL;
GO

/* SKU codes parsed into attributes: PREFIX-itemId or PREFIX-NN-itemId */
CREATE OR ALTER VIEW menu.v_sku_parsed
AS
SELECT k.locId, k.itemId, k.skuCode, k.skuDescription,
       p.prefix, p.idText, p.partText,
       TRY_CAST(p.idText AS int)      AS codeItemId,
       TRY_CAST(p.partText AS int)    AS partNo,
       aty.label, aty.sortRank, aty.isMultiPart, aty.maxParts, aty.showLabel, aty.isActive AS prefixActive
FROM ig.item_sku_code k
CROSS APPLY (SELECT CHARINDEX(N'-', k.skuCode) AS d1,
                    LEN(k.skuCode) - CHARINDEX(N'-', REVERSE(k.skuCode)) + 1 AS dLast) d
CROSS APPLY (SELECT CASE WHEN d.d1 > 1 THEN UPPER(LEFT(k.skuCode, d.d1 - 1)) END AS prefix,
                    CASE WHEN d.d1 > 1 THEN SUBSTRING(k.skuCode, d.dLast + 1, 30) END AS idText,
                    CASE WHEN d.d1 > 1 AND d.dLast > d.d1 THEN SUBSTRING(k.skuCode, d.d1 + 1, d.dLast - d.d1 - 1) END AS partText) p
LEFT JOIN menu.attribute_type aty ON aty.prefix = p.prefix;
GO

/* Valid attributes, one row per item + attribute, multi-part values joined in part order. */
CREATE OR ALTER VIEW menu.v_item_attribute
AS
SELECT s.locId, s.itemId, s.prefix, s.label, s.sortRank, s.showLabel,
       STRING_AGG(CAST(LTRIM(RTRIM(s.skuDescription)) AS nvarchar(max)), N' ')
           WITHIN GROUP (ORDER BY ISNULL(s.partNo, 0)) AS value
FROM menu.v_sku_parsed s
WHERE s.prefixActive = 1
  AND s.codeItemId = s.itemId
  AND NULLIF(LTRIM(RTRIM(s.skuDescription)), N'') IS NOT NULL
  AND ( (s.isMultiPart = 0 AND s.partText IS NULL)
     OR (s.isMultiPart = 1 AND s.partNo BETWEEN 1 AND s.maxParts) )
GROUP BY s.locId, s.itemId, s.prefix, s.label, s.sortRank, s.showLabel;
GO
