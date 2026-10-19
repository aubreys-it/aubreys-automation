"""
Offline preview: build a store's menu JSON (and the IG exceptions list) straight from an
MI_Exp.txt file, using the same rules as the SQL (menu.v_item_web, menu.usp_publish_store,
menu.usp_check_ig_quality). Handy for checking what a store's menu will look like before
the pipeline is live, and for testing the PHP pages.

    python tools/preview_menu.py 20261016_02_MI_Exp.txt --loc 2 --name "Aubrey's Powell" \
        --concept aubreys --out menus/02.json --issues issues_02.csv

Keep the reference data below in step with sql/domesday/080_seed.sql.
"""
from __future__ import annotations

import argparse
import csv
import json
import pathlib
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "functions" / "ig-etl"))
from igetl.mi_export import decode, parse_line, LineError  # noqa: E402

GROUPS = [("beer", "Beer"), ("liquor", "Liquor"), ("wine", "Wine")]
SECTIONS = [  # code, group, name (in display order)
    ("draft_beer", "beer", "Draft Beer"), ("bottled_beer", "beer", "Bottled & Canned Beer"),
    ("rtd", "beer", "Seltzers & Canned Cocktails"), ("whiskey", "liquor", "Whiskey & Bourbon"),
    ("vodka", "liquor", "Vodka"), ("gin", "liquor", "Gin"), ("tequila", "liquor", "Tequila"),
    ("scotch", "liquor", "Scotch"), ("rum", "liquor", "Rum"), ("white_blush", "wine", "White & Blush"),
    ("sparkling", "wine", "Sparkling"), ("red", "wine", "Red"),
]
# productClassId: (section or None, serving, expected revenue category, excluded)
CLASSES = {
    18: ("sparkling", "bottle", 3, False), 19: ("sparkling", "glass", 3, False),
    20: ("white_blush", "bottle", 3, False), 21: ("white_blush", "glass", 3, False),
    22: ("red", "bottle", 3, False), 23: ("red", "glass", 3, False),
    24: (None, "all", 4, True), 25: (None, "all", 4, True),
    26: ("gin", "all", 4, False), 28: ("rum", "all", 4, False), 29: ("scotch", "all", 4, False),
    30: ("tequila", "all", 4, False), 31: ("vodka", "all", 4, False), 32: ("whiskey", "all", 4, False),
    52: ("bottled_beer", "all", 2, False), 54: ("draft_beer", "all", 2, False), 55: ("rtd", "all", 4, False),
}
ATTRS = {"ORIG": ("Origin", 10, False, 1, False), "STYLE": ("Style", 20, False, 1, False),
         "ABV": ("ABV", 30, False, 1, True), "DESC": ("Description", 40, True, 9, False)}
SERVING_NAME = {"glass": "By the Glass", "bottle": "By the Bottle", "all": None}
SERVING_ORDER = {"all": 0, "glass": 1, "bottle": 2}


def clean_name(name: str) -> str:
    s = name.strip()
    if re.match(r"^\d\d_", s):
        s = s[3:].lstrip()
    if re.match(r"^[BGC] ", s):
        s = s[2:].lstrip()
    s = re.sub(r"\s*\(\d{1,2}\)$", "", s)
    while len(s) > 1 and s.endswith("."):
        s = s[:-1].rstrip()
    return s


def parse_sku(code: str):
    m = re.match(r"^([A-Za-z]+)-(?:(\d+)-)?(\d+)$", code.strip())
    if not m:
        return None
    return m.group(1).upper(), (int(m.group(2)) if m.group(2) else None), int(m.group(3))


def build(path: pathlib.Path, loc: int, name: str, concept: str, home: str | None):
    items, issues = [], []
    for line in decode(path.read_bytes()).split("\r\n"):
        if not line.strip():
            continue
        try:
            r = parse_line(line, loc)
        except LineError:
            continue
        if (r["itemGroupId"] or 1) == 1:
            continue
        pc = r["productClassId"]
        mapping = CLASSES.get(pc)
        if r["revenueCategoryId"] not in (2, 3, 4) and not (mapping and mapping[0]):
            continue
        prices = dict(r["_priceLevels"]); sprices = dict(r["_storePriceLevels"])
        price = sprices.get(1, prices.get(1))
        nm = r["itemName"]
        def flag(code, info):
            issues.append({"code": code, "store": f"{loc:02d}", "itemId": r["itemId"], "itemName": nm,
                           "productClassId": pc, "info": info})
        if mapping is None:
            flag("IG_UNMAPPED_CLASS", f"product class {pc}, revenue category {r['revenueCategoryId']}")
            continue
        section, serving, exp_rc, excluded = mapping
        if excluded:
            continue
        if r["revenueCategoryId"] != exp_rc:
            flag("IG_REVCAT_MISMATCH", f"class {pc} expects revenue category {exp_rc}, item has {r['revenueCategoryId']}")
        n = nm[3:] if re.match(r"^\d\d_", nm) else nm
        if (serving == "glass" and n.startswith("B ")) or (serving == "bottle" and n.startswith("G ")):
            flag("IG_SERVING_MISMATCH", f"name says {'bottle' if n.startswith('B ') else 'glass'}, class {pc} is {serving}")
        if re.search(r"(\.|\(\d{1,2}\))$", nm.rstrip()):
            flag("IG_NAME_SUFFIX", f'shows on the web as "{clean_name(nm)}"')
        if not price:
            flag("IG_NO_PRICE", "no price level 1 (or $0.00)")
        attrs = defaultdict(list)
        for code, desc in r["_skuCodes"]:
            p = parse_sku(code)
            ok = p and p[0] in ATTRS and p[2] == r["itemId"] and desc.strip() and (
                (ATTRS[p[0]][2] and p[1] and 1 <= p[1] <= ATTRS[p[0]][3]) or (not ATTRS[p[0]][2] and p[1] is None))
            if not ok:
                flag("IG_SKU_INVALID", f'SKU "{code}"')
                continue
            attrs[p[0]].append((p[1] or 0, desc.strip()))
        attributes = [{"label": ATTRS[k][0], "value": " ".join(v for _, v in sorted(parts)), "showLabel": ATTRS[k][4]}
                      for k, parts in sorted(attrs.items(), key=lambda kv: (ATTRS[kv[0]][1], kv[0]))]
        items.append({"section": section, "serving": serving, "id": r["itemId"], "name": clean_name(nm),
                      "price": float(price) if price else None, "attributes": attributes})

    seen = defaultdict(list)
    for it in items:
        seen[(it["section"], it["serving"], it["name"])].append(it)
    for (sec, _, nm), group in seen.items():
        if len(group) > 1:
            for it in group:
                issues.append({"code": "IG_DUPLICATE_NAME", "store": f"{loc:02d}", "itemId": it["id"], "itemName": nm,
                               "productClassId": None, "info": f'"{nm}" appears {len(group)} times in {sec}'})

    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    mtime = datetime.fromtimestamp(path.stat().st_mtime, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    groups = []
    for gcode, gname in GROUPS:
        sections = []
        for scode, sg, sname in SECTIONS:
            if sg != gcode:
                continue
            its = [i for i in items if i["section"] == scode]
            if not its:
                continue
            servings = []
            for sv in sorted({i["serving"] for i in its}, key=SERVING_ORDER.get):
                rows = sorted((i for i in its if i["serving"] == sv), key=lambda i: (i["name"], i["id"]))
                servings.append({"code": sv, "name": SERVING_NAME[sv],
                                 "items": [{"id": i["id"], "name": i["name"], "price": i["price"],
                                            "attributes": i["attributes"]} for i in rows]})
            sections.append({"code": scode, "name": sname, "servings": servings})
        if sections:
            groups.append({"code": gcode, "name": gname, "sections": sections})
    doc = {"schema": "aubreys-menu/1",
           "store": {"locId": loc, "code": f"{loc:02d}", "name": name, "concept": concept, "theme": concept,
                     "homeUrl": home},
           "generatedAt": now, "contentChangedAt": now, "sourceExportAt": mtime,
           "itemCount": len(items), "groups": groups}
    return doc, issues


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file", type=pathlib.Path)
    ap.add_argument("--loc", type=int, required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--concept", default="aubreys")
    ap.add_argument("--home", default=None)
    ap.add_argument("--out", type=pathlib.Path, required=True)
    ap.add_argument("--issues", type=pathlib.Path)
    a = ap.parse_args()
    doc, issues = build(a.file, a.loc, a.name, a.concept, a.home)
    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.out.write_text(json.dumps(doc, indent=2, ensure_ascii=False), encoding="utf-8")
    if a.issues:
        with a.issues.open("w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, fieldnames=["code", "store", "itemId", "itemName", "productClassId", "info"])
            w.writeheader(); w.writerows(issues)
    print(f"{a.out}: {doc['itemCount']} items, {len(issues)} issues")


if __name__ == "__main__":
    main()
