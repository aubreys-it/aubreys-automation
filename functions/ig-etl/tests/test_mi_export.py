"""Run with:  python -m pytest functions/ig-etl/tests -q
Optional full-file test: set MI_SAMPLE_DIR to a folder holding NN_MI_Exp.txt files.
"""
import os
import pathlib
import sys
from decimal import Decimal

import pytest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from igetl.mi_export import ITEM_COLUMNS, LineError, decode, parse_line, parse_text, split_line, to_csv  # noqa: E402

PLAIN = ('"U",70,"Corralejo Silver","Corraleio","Silver","Corraleio Silver",'
         '{1,$8.50,2,$7.50,3,$8.50,4,$8.50,6,$7.50,20,$7.50},30,4,2,0,3,0,0,{},,$0.00,0,0,1,0,1,0,0,1,'
         '"Corraleio Silver",1,0,{},{1,1},0,0,"Corraleio Silver",0,0,0,{},0,0,"",0,""')

# Real lines from the 2026-10-16 exports that break naive CSV parsing.
TRICKY = [
    # quotes at start of a field and inside it
    '"U",91,"20_"Dill"ema",""Dill"ema","",""Dill"ema",{1,$15.00},24,4,2,0,3,0,0,{},,$0.00,0,0,1,0,1,0,0,1,'
    '""Dill"ema",1,0,{},{1,1},0,0,"20_"Dill"ema",0,0,0,{},0,0,"",0,""',
    # inch mark right before the closing quote: "9""
    '"U",1050019,"35_9 Inch Pizza","9"","Pizza","Kid Pizza",{1,$6.00},6,1,2,0,1,0,0,{},,$0.00,0,0,1,1,1,0,0,1,'
    '"9" Pizza",1,0,{123,1},{2,1},0,0,"35_9 Inch Pizza",0,0,0,{},0,0,"",0,""',
    # comma inside a quoted name
    '"U",3040272,"B Copacetic "gig 4" Red Blend, Lodi","Copacetic",""gig 4"","B Copacetic gig4",'
    '{1,$24.00,2,$24.00,3,$12.00,20,$12.00},22,3,2,0,4,0,0,{},,$0.00,0,0,1,0,1,0,0,1,"B Copacetic gig4",1,0,'
    '{},{1,1},0,0,"B Copacetic gig4",0,0,0,{},0,0,"",0,""',
]


def test_plain_line():
    rec = parse_line(PLAIN, 2)
    assert rec["itemId"] == 70
    assert rec["itemName"] == "Corralejo Silver"
    assert rec["productClassId"] == 30
    assert rec["itemGroupId"] == 1
    assert rec["_priceLevels"][0] == (1, Decimal("8.50"))
    assert rec["_kitchenPrinters"] == [(1, 1)]
    assert len(split_line(PLAIN)) == 42


def test_tricky_lines():
    names = [parse_line(t, 2)["itemName"] for t in TRICKY]
    assert names == ['20_"Dill"ema', "35_9 Inch Pizza", 'B Copacetic "gig 4" Red Blend, Lodi']
    assert parse_line(TRICKY[1], 2)["buttonText1"] == '9"'
    assert parse_line(TRICKY[2], 2)["productClassId"] == 22


def test_bad_line_is_rejected_not_fatal():
    text = "\r\n".join([PLAIN, '"U",71,"Broken line', TRICKY[0], ""])
    r = parse_text(text, 2)
    assert r.line_count == 3
    assert r.parsed_count == 2
    assert r.rejects[0]["line"] == 2


def test_duplicate_item_rejected():
    r = parse_text(PLAIN + "\r\n" + PLAIN, 2)
    assert r.parsed_count == 1 and len(r.rejects) == 1


def test_odd_brace_group_rejected():
    bad = PLAIN.replace("{1,1}", "{1}")
    with pytest.raises(LineError):
        parse_line(bad, 2)


def test_non_ascii_survives():
    assert decode("Añejo".encode("utf-8")) == "Añejo"
    assert decode("Añejo".encode("cp1252")) == "Añejo"


def test_csv_quotes_doubled():
    out = to_csv(["a"], [['B "x", y']]).decode()
    assert out == 'a\r\n"B ""x"", y"\r\n'


def test_item_columns():
    assert ITEM_COLUMNS[0] == "locId" and "unused1" not in ITEM_COLUMNS and "itemGroupId" in ITEM_COLUMNS


SAMPLES = os.environ.get("MI_SAMPLE_DIR")


@pytest.mark.skipif(not SAMPLES, reason="MI_SAMPLE_DIR not set")
@pytest.mark.parametrize("path", sorted(pathlib.Path(SAMPLES or ".").glob("*MI_Exp.txt")))
def test_sample_files_parse_completely(path):
    loc = int(path.name.split("_")[-3]) if path.name.count("_") >= 3 else 0
    r = parse_text(decode(path.read_bytes()), loc)
    assert r.line_count > 1000
    assert r.rejects == []
