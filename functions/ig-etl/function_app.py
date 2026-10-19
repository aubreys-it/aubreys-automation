"""
aub-ig-etl: InfoGenesis export parsers, called by Azure Data Factory.

Auth model (no keys, no SAS):
  * Inbound: App Service Authentication (Microsoft Entra). Only the ADF
    managed identity (adf-aub-ops) is an allowed client application.
    The function itself uses AuthLevel.ANONYMOUS because Easy Auth sits in front.
  * Outbound: the function app's system-assigned managed identity, with
    Storage Blob Data Contributor on the aubdatain/infogenesis container.

The function never writes to SQL. It returns a JSON summary (counts + rejected
lines) that the pipeline passes to ops.usp_log_events_json.
"""
from __future__ import annotations

import json
import logging

import azure.functions as func
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContentSettings

from igetl.mi_export import OUTPUTS, decode, parse_text, to_csv

app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)

_credential = DefaultAzureCredential()
_clients: dict[str, BlobServiceClient] = {}

MAX_REJECTS_RETURNED = 200


def _blob_service(account: str) -> BlobServiceClient:
    if account not in _clients:
        _clients[account] = BlobServiceClient(f"https://{account}.blob.core.windows.net", credential=_credential)
    return _clients[account]


def _bad_request(msg: str) -> func.HttpResponse:
    return func.HttpResponse(json.dumps({"ok": False, "error": msg}), status_code=400, mimetype="application/json")


@app.route(route="mi-export/parse", methods=["POST"])
def parse_mi_export(req: func.HttpRequest) -> func.HttpResponse:
    """
    Request body:
      {
        "runId": "<ADF pipeline run id>",
        "storageAccount": "aubdatain",
        "container": "infogenesis",
        "rawBlob": "menu_items/raw/2026/10/19/02_MI_Exp.txt",
        "outputPrefix": "menu_items/parsed/<runId>",
        "locId": 2,
        "rejectThresholdPct": 1.0
      }
    Writes <outputPrefix>/<entity>/<nn>.csv for each entity in OUTPUTS.

    Response 200 always once the file was read: {"ok": true|false, ...summary...}.
    ok=false (empty file, or too many rejected lines) means nothing was written for this store.
    ADF hands the whole response to ig.usp_log_parse_result, so the pipeline needs no branching.
    Response 400: malformed request (a pipeline bug).
    """
    try:
        body = req.get_json()
        account = body["storageAccount"]
        container = body["container"]
        raw_blob = body["rawBlob"]
        out_prefix = body["outputPrefix"].rstrip("/")
        loc_id = int(body["locId"])
        threshold = float(body.get("rejectThresholdPct", 1.0))
    except (ValueError, KeyError, TypeError) as exc:
        return _bad_request(f"bad request body: {exc}")

    cc = _blob_service(account).get_container_client(container)
    data = cc.get_blob_client(raw_blob).download_blob().readall()
    result = parse_text(decode(data), loc_id)

    summary = {
        "ok": True,
        "locId": loc_id,
        "rawBlob": raw_blob,
        "lineCount": result.line_count,
        "parsedCount": result.parsed_count,
        "rejectCount": len(result.rejects),
        "rejectPct": round(result.reject_pct, 3),
        "rows": {},
        # Shaped for ops.usp_log_events_json: one event per rejected line.
        "events": [
            {
                "severity": "WARN",
                "code": "PARSE_REJECT",
                "locId": loc_id,
                "message": f"Line {r['line']} of {raw_blob} rejected: {r['reason']}",
                "detail": r,
            }
            for r in result.rejects[:MAX_REJECTS_RETURNED]
        ],
    }

    if result.line_count == 0 or result.reject_pct > threshold:
        summary["ok"] = False
        summary["error"] = (
            "file is empty" if result.line_count == 0
            else f"{len(result.rejects)} of {result.line_count} lines rejected "
                 f"({result.reject_pct:.2f}% > {threshold}%); store not loaded"
        )
        logging.error(summary["error"])
        return func.HttpResponse(json.dumps(summary), status_code=200, mimetype="application/json")

    nn = f"{loc_id:02d}"
    for entity, (header, attr) in OUTPUTS.items():
        rows = getattr(result, attr)
        cc.get_blob_client(f"{out_prefix}/{entity}/{nn}.csv").upload_blob(
            to_csv(header, rows),
            overwrite=True,
            content_settings=ContentSettings(content_type="text/csv; charset=utf-8"),
        )
        summary["rows"][entity] = len(rows)

    return func.HttpResponse(json.dumps(summary), status_code=200, mimetype="application/json")
