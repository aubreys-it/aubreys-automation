"""
Parser for InfoGenesis MI_Exp.txt (menu item export).

IG writes one item per line, CRLF terminated, 42 comma-separated fields.
Text fields are wrapped in double quotes, but IG does NOT escape quotes that
appear inside the text (e.g. "35_12" Cheese Pizza", "B Ridge "Ponzo" Zinfandel").
A generic CSV reader therefore cannot parse this file.

This parser knows the field layout. A quote only closes a text field when it is
followed by a comma and then by whatever the NEXT field is supposed to start
with (a quote, a brace, a number/$ sign, or an empty field). Validated against
the 2026-10-16 exports for stores 02 and 12: 10,832 of 10,832 lines parsed.

Six repeating groups are written as {a,b,a,b,...} pairs:
    priceLevels       {priceLevelId, price}
    skuCodes          {"skuCode", "skuDescription"}  <-- quoted, see below
    choiceGroups      {choiceGroupId, seqNumber}
    kitchenPrinters   {kpId, primaryFlag}
    storePriceLevels  {priceLevelId, price}

The SKU group is different: every value is a quoted string, and IG does not
escape commas or quotes inside them (confirmed 2026-10-20, store 02 item 2020023):
    {"ORIG-2020023","Comstock, MI","DESC-01-2020023","Bright citrus and pine,"}
So it is split with the same rule as text fields: a quote only closes a value
when it is followed by `,"` (next value) or by `}` and the end of the group.
Text that itself contains `","` cannot be told apart; keep SKU text simple.

This module has no Azure dependencies so it can be unit tested anywhere.
"""
from __future__ import annotations

import csv
import io
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation

# Field layout, in file order. Kind: s = quoted text, i = int, m = money,
# d = decimal, b = {brace group}, x = ignored (IG "unused" fields).
FIELDS: list[tuple[str, str]] = [
    ("recordType", "s"),
    ("itemId", "i"),
    ("itemName", "s"),
    ("buttonText1", "s"),
    ("buttonText2", "s"),
    ("printText", "s"),
    ("priceLevels", "b"),
    ("productClassId", "i"),
    ("revenueCategoryId", "i"),
    ("taxGroupId", "i"),
    ("securityLevelId", "i"),
    ("reportCategoryId", "i"),
    ("useWeightFlag", "i"),
    ("weightTareAmount", "d"),
    ("skuCodes", "b"),
    ("barGunCode", "i"),
    ("costAmount", "m"),
    ("unused1", "x"),
    ("promptForPrice", "i"),
    ("printOnCheck", "i"),
    ("discountable", "i"),
    ("voidable", "i"),
    ("notActive", "i"),
    ("taxIncluded", "i"),
    ("itemGroupId", "i"),
    ("receiptText", "s"),
    ("allowPriceOverride", "i"),
    ("unused2", "x"),
    ("choiceGroups", "b"),
    ("kitchenPrinters", "b"),
    ("covers", "i"),
    ("storeId", "i"),
    ("kdsText", "s"),
    ("kdsDepartmentId", "i"),
    ("kdsCategoryId", "i"),
    ("kdsCookTime", "i"),
    ("storePriceLevels", "b"),
    ("defaultImageId", "i"),
    ("stockItem", "i"),
    ("primaryTaxCode", "s"),
    ("promptForName", "i"),
    ("encodingLang", "s"),
]
FIELD_COUNT = len(FIELDS)  # 42

# Columns written to item.csv (scalar fields, minus ignored ones), in order.
ITEM_COLUMNS = ["locId"] + [n for n, k in FIELDS if k not in ("b", "x")]


class LineError(ValueError):
    """A line that does not match the expected layout."""


def _parse_money(text: str) -> Decimal | None:
    t = text.strip().replace("$", "").replace(",", "")
    if t == "":
        return None
    try:
        return Decimal(t)
    except InvalidOperation as exc:
        raise LineError(f"bad money value {text!r}") from exc


def _parse_int(text: str, name: str) -> int | None:
    t = text.strip()
    if t == "":
        return None
    try:
        return int(t)
    except ValueError as exc:
        raise LineError(f"{name}: expected integer, got {text!r}") from exc


def _parse_decimal(text: str, name: str) -> Decimal | None:
    t = text.strip()
    if t == "":
        return None
    try:
        return Decimal(t)
    except InvalidOperation as exc:
        raise LineError(f"{name}: expected number, got {text!r}") from exc


def _next_field_starts_ok(line: str, pos: int, next_kind: str | None) -> bool:
    """True if the text at `pos` looks like the start of a field of `next_kind`."""
    if next_kind is None:  # no next field: the quote must end the line
        return pos >= len(line)
    ch = line[pos:pos + 1]
    if next_kind == "s":
        return ch == '"'
    if next_kind == "b":
        return ch == "{"
    # numeric / money / ignored: may be empty (next char is a comma or EOL)
    return ch == "" or ch == "," or ch in "-$0123456789."


def _split_quoted_group(line: str, i: int, label: str) -> tuple[list[str], int]:
    """Split a {"a","b",...} group starting at line[i] == '{'.

    Returns (values without their quotes, index of the closing '}').
    A quote closes a value only when followed by ',"' or by '}' that ends the
    group (then a comma or end of line), so commas and stray quotes inside the
    text are kept. An unquoted value is read up to the next ',' or '}'.
    """
    n = len(line)
    j = i + 1
    values: list[str] = []
    if line[j:j + 1] == "}":
        return values, j
    while True:
        if j >= n:
            raise LineError(f"{label}: no closing '}}'")
        if line[j] == '"':
            k = j + 1
            while True:
                q = line.find('"', k)
                if q < 0:
                    raise LineError(f"{label}: no closing quote")
                after = line[q + 1:q + 3]
                if after == ',"':
                    values.append(line[j + 1:q])
                    j = q + 2
                    break
                if after[:1] == "}" and line[q + 2:q + 3] in (",", ""):
                    values.append(line[j + 1:q])
                    return values, q + 1
                k = q + 1  # a quote inside the text; keep going
        else:
            comma, close = line.find(",", j), line.find("}", j)
            if close < 0:
                raise LineError(f"{label}: no closing '}}'")
            if 0 <= comma < close:
                values.append(line[j:comma])
                j = comma + 1
            else:
                values.append(line[j:close])
                return values, close


def split_line(line: str) -> list:
    """Split one MI_Exp line into FIELD_COUNT raw values (str or list[str])."""
    out: list = []
    i, n = 0, len(line)
    for k, (name, kind) in enumerate(FIELDS):
        next_kind = FIELDS[k + 1][1] if k + 1 < FIELD_COUNT else None
        if i > n:
            raise LineError(f"line ended before field {k + 1} ({name})")
        if kind == "s":
            if line[i:i + 1] != '"':
                raise LineError(f"field {k + 1} ({name}): expected opening quote")
            j = i + 1
            while True:
                q = line.find('"', j)
                if q < 0:
                    raise LineError(f"field {k + 1} ({name}): no closing quote")
                end_of_line = q + 1 == n
                if end_of_line and next_kind is None:
                    break
                if line[q + 1:q + 2] == "," and _next_field_starts_ok(line, q + 2, next_kind):
                    break
                j = q + 1  # an unescaped quote inside the text; keep going
            out.append(line[i + 1:q])
            i = q + 2
        elif kind == "b":
            if line[i:i + 1] != "{":
                raise LineError(f"field {k + 1} ({name}): expected '{{'")
            if name == "skuCodes":
                values, close = _split_quoted_group(line, i, f"field {k + 1} ({name})")
                out.append(values)
                i = close + 2
                continue
            close = line.find("}", i)
            if close < 0:
                raise LineError(f"field {k + 1} ({name}): no closing '}}'")
            inner = line[i + 1:close]
            out.append(inner.split(",") if inner else [])
            i = close + 2
        else:
            j = line.find(",", i)
            if j < 0:
                j = n
            out.append(line[i:j])
            i = j + 1
    if i < n:
        raise LineError(f"unexpected data after field {FIELD_COUNT}: {line[i:i + 30]!r}")
    return out


def _pairs(values: list[str], name: str) -> list[tuple[str, str]]:
    if len(values) % 2:
        raise LineError(f"{name}: odd number of values ({len(values)})")
    return [(values[p], values[p + 1]) for p in range(0, len(values), 2)]


@dataclass
class ParseResult:
    loc_id: int
    line_count: int = 0
    items: list[list] = field(default_factory=list)
    price_levels: list[list] = field(default_factory=list)
    store_price_levels: list[list] = field(default_factory=list)
    sku_codes: list[list] = field(default_factory=list)
    choice_groups: list[list] = field(default_factory=list)
    kitchen_printers: list[list] = field(default_factory=list)
    rejects: list[dict] = field(default_factory=list)

    @property
    def parsed_count(self) -> int:
        return len(self.items)

    @property
    def reject_pct(self) -> float:
        return 100.0 * len(self.rejects) / self.line_count if self.line_count else 0.0


def parse_line(line: str, loc_id: int) -> dict:
    """Parse one line into typed values. Raises LineError."""
    raw = split_line(line)
    rec: dict = {"locId": loc_id}
    groups: dict = {}
    for (name, kind), value in zip(FIELDS, raw):
        if kind == "s":
            rec[name] = value
        elif kind == "i":
            rec[name] = _parse_int(value, name)
        elif kind == "m":
            rec[name] = _parse_money(value)
        elif kind == "d":
            rec[name] = _parse_decimal(value, name)
        elif kind == "b":
            groups[name] = value
    if rec["itemId"] is None:
        raise LineError("itemId is empty")
    item_id = rec["itemId"]
    rec["_priceLevels"] = [
        (_parse_int(a, "priceLevelId"), _parse_money(b)) for a, b in _pairs(groups["priceLevels"], "priceLevels")
    ]
    rec["_storePriceLevels"] = [
        (_parse_int(a, "priceLevelId"), _parse_money(b))
        for a, b in _pairs(groups["storePriceLevels"], "storePriceLevels")
    ]
    rec["_skuCodes"] = _pairs(groups["skuCodes"], "skuCodes")
    rec["_choiceGroups"] = [
        (_parse_int(a, "choiceGroupId"), _parse_int(b, "seqNumber"))
        for a, b in _pairs(groups["choiceGroups"], "choiceGroups")
    ]
    rec["_kitchenPrinters"] = [
        (_parse_int(a, "kpId"), _parse_int(b, "primaryFlag"))
        for a, b in _pairs(groups["kitchenPrinters"], "kitchenPrinters")
    ]
    rec["_itemId"] = item_id
    return rec


def parse_text(text: str, loc_id: int, max_snippet: int = 160) -> ParseResult:
    """Parse a whole MI_Exp.txt (already decoded) for one store."""
    result = ParseResult(loc_id=loc_id)
    seen: set[int] = set()
    for line_no, line in enumerate(text.split("\r\n"), start=1):
        line = line.rstrip("\n")  # tolerate a stray LF-only ending
        if not line.strip():
            continue
        result.line_count += 1
        try:
            rec = parse_line(line, loc_id)
            item_id = rec["_itemId"]
            if item_id in seen:
                raise LineError(f"duplicate itemId {item_id}")
            seen.add(item_id)
        except LineError as exc:
            result.rejects.append({"line": line_no, "reason": str(exc), "snippet": line[:max_snippet]})
            continue
        result.items.append([rec[c] for c in ITEM_COLUMNS])
        result.price_levels += [[loc_id, item_id, pl, p] for pl, p in rec["_priceLevels"]]
        result.store_price_levels += [[loc_id, item_id, pl, p] for pl, p in rec["_storePriceLevels"]]
        result.sku_codes += [[loc_id, item_id, code, desc] for code, desc in rec["_skuCodes"]]
        result.choice_groups += [[loc_id, item_id, cg, seq] for cg, seq in rec["_choiceGroups"]]
        result.kitchen_printers += [[loc_id, item_id, kp, flag] for kp, flag in rec["_kitchenPrinters"]]
    return result


def decode(data: bytes) -> str:
    """IG writes plain ASCII today. Decode as UTF-8, falling back to cp1252.

    Never strip characters: "Añejo" must stay "Añejo".
    """
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return data.decode("cp1252")


# Output tables: entity name -> (header, attribute on ParseResult)
OUTPUTS: dict[str, tuple[list[str], str]] = {
    "item": (ITEM_COLUMNS, "items"),
    "price_level": (["locId", "itemId", "priceLevelId", "price"], "price_levels"),
    "store_price_level": (["locId", "itemId", "priceLevelId", "price"], "store_price_levels"),
    "sku_code": (["locId", "itemId", "skuCode", "skuDescription"], "sku_codes"),
    "choice_group": (["locId", "itemId", "choiceGroupId", "seqNumber"], "choice_groups"),
    "kitchen_printer": (["locId", "itemId", "kpId", "primaryFlag"], "kitchen_printers"),
}


def to_csv(header: list[str], rows: list[list]) -> bytes:
    """RFC 4180 CSV (quotes doubled), UTF-8, CRLF. Matches the ADF dataset settings."""
    buf = io.StringIO()
    w = csv.writer(buf, quoting=csv.QUOTE_MINIMAL, lineterminator="\r\n")
    w.writerow(header)
    for r in rows:
        w.writerow(["" if v is None else v for v in r])
    return buf.getvalue().encode("utf-8")
