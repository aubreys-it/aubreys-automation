"""
Generates the ADF resources for the menus domain into adf/dmcp-data-factory/ in the layout
ADF native git integration uses (linkedService/, dataset/, pipeline/, trigger/).

Edit THIS file and re-run it rather than hand-editing the JSON, or edit in ADF Studio once
the factory is connected to git and stop using this script; don't do both.

    python tools/build_adf.py
"""
import json
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1] / "adf" / "dmcp-data-factory"

# ---- environment values: CONFIRM before connecting the factory to git ----
KEY_VAULT = "kv-aub-automation"                     # Key Vault holding ig-sftp-password + Slack webhooks
WEB_STORAGE = "aubwebpub"                           # public-read account serving menu JSON
MAIL_SENDER = "automation@aubreys.group"            # shared mailbox (Graph sendMail)
FUNCTION_URL = "https://aub-ig-etl-btfsheaedcfuhyby.eastus-01.azurewebsites.net"           # az functionapp show ... --query defaultHostName
FUNCTION_APP_ID_URI = "api://5d0b5f6b-8185-47a7-8ae6-42bbef337164"  # Expose an API -> Application ID URI of the aub-ig-etl app registration
DATAIN_LS = "ls_adls_aubdatain"                     # managed-identity linked service to aubdatain (defined below)
SQL = {"referenceName": "ls_sql_domesday_mi", "type": "LinkedServiceReference"}


def write(kind, name, props):
    path = ROOT / kind / f"{name}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"name": name, "properties": props}, indent=4) + "\n", encoding="utf-8")


def ex(expr):
    return {"value": expr, "type": "Expression"}


def dep(name, *conds):
    return {"activity": name, "dependencyConditions": list(conds or ["Succeeded"])}


def sp(name, proc, params, depends=None, timeout="0.00:10:00"):
    """Stored procedure activity. params: {name: (value, type)}"""
    return {
        "name": name, "type": "SqlServerStoredProcedure", "dependsOn": depends or [],
        "policy": {"timeout": timeout, "retry": 1, "retryIntervalInSeconds": 30, "secureOutput": False, "secureInput": False},
        "linkedServiceName": SQL,
        "typeProperties": {"storedProcedureName": proc,
                           "storedProcedureParameters": {k: {"value": v, "type": t} for k, (v, t) in params.items()}},
    }


def lookup(name, proc, params, first_row=True, depends=None):
    return {
        "name": name, "type": "Lookup", "dependsOn": depends or [],
        "policy": {"timeout": "0.00:10:00", "retry": 1, "retryIntervalInSeconds": 30},
        "typeProperties": {
            "source": {"type": "AzureSqlSource", "sqlReaderStoredProcedureName": proc,
                       "storedProcedureParameters": {k: {"value": v, "type": t} for k, (v, t) in params.items()},
                       "queryTimeout": "00:10:00"},
            "dataset": {"referenceName": "ds_sql_domesday", "type": "DatasetReference"},
            "firstRowOnly": first_row,
        },
    }


def log_event(name, code, message, depends, loc=None, severity=None, detail=None, step=None):
    p = {"runId": (ex("@pipeline().parameters.runId"), "String"), "domainCode": ("menus", "String"),
         "code": (code, "String"), "message": (message, "String")}
    if loc is not None:
        p["locId"] = (loc, "Int32")
    if severity is not None:
        p["severity"] = (severity, "String")
    if detail is not None:
        p["detail"] = (detail, "String")
    if step is not None:
        p["step"] = (step, "String")
    return sp(name, "ops.usp_log_event", p, depends)


def web(name, method, url, depends, body=None, headers=None, resource=None, secure_in=False, secure_out=False):
    tp = {"method": method, "url": url}
    if headers:
        tp["headers"] = headers
    if body is not None:
        tp["body"] = body
    if resource:
        tp["authentication"] = {"type": "MSI", "resource": resource}
    return {"name": name, "type": "WebActivity", "dependsOn": depends,
            "policy": {"timeout": "0.00:02:00", "retry": 2, "retryIntervalInSeconds": 30,
                       "secureInput": secure_in, "secureOutput": secure_out},
            "typeProperties": tp}


def pipeline(name, activities, params=None, folder="menus", variables=None, annotations=None):
    props = {"activities": activities, "folder": {"name": folder}, "annotations": annotations or []}
    if params:
        props["parameters"] = params
    if variables:
        props["variables"] = variables
    write("pipeline", name, props)


# ======================= linked services =======================
write("linkedService", "ls_kv_automation", {
    "type": "AzureKeyVault", "annotations": [],
    "typeProperties": {"baseUrl": f"https://{KEY_VAULT}.vault.azure.net/"}})

write("linkedService", "ls_sql_domesday_mi", {
    "type": "AzureSqlDatabase", "annotations": [],
    "typeProperties": {"server": "mcp-alex.database.windows.net", "database": "domesday",
                       "encrypt": "mandatory", "trustServerCertificate": False,
                       "authenticationType": "SystemAssignedManagedIdentity"}})

write("linkedService", "ls_sftp_ig", {
    "type": "Sftp", "annotations": [],
    "description": "InfoGenesis export SFTP (Agilysys hosted). Password in Key Vault; replaces the Basic-auth IgSftp once proven.",
    "typeProperties": {
        "host": "portal.ftp.infogenesisasp.com", "port": 22,
        "skipHostKeyValidation": False,
        "hostKeyFingerprint": "ssh-rsa 2048 0c:98:90:73:46:3d:d6:90:8d:a3:90:d8:a8:50:f4:e0",
        "authenticationType": "Basic", "userName": "AUBR1.ftpadmin",
        "password": {"type": "AzureKeyVaultSecret",
                     "store": {"referenceName": "ls_kv_automation", "type": "LinkedServiceReference"},
                     "secretName": "ig-sftp-password"}}})

write("linkedService", DATAIN_LS, {
    "type": "AzureBlobFS", "annotations": [],
    "description": "aubdatain (ADLS Gen2) using the factory's managed identity.",
    "typeProperties": {"url": "https://aubdatain.dfs.core.windows.net/"}})

write("linkedService", "ls_fn_ig_etl", {
    "type": "AzureFunction", "annotations": [],
    "typeProperties": {"functionAppUrl": FUNCTION_URL, "authentication": "MSI", "resourceId": FUNCTION_APP_ID_URI}})

# ======================= datasets =======================
write("dataset", "ds_sql_domesday", {
    "linkedServiceName": SQL, "annotations": [], "type": "AzureSqlTable", "schema": [], "typeProperties": {},
    "folder": {"name": "domesday"}})

write("dataset", "ds_sql_stg_table", {
    "linkedServiceName": SQL, "annotations": [], "type": "AzureSqlTable", "schema": [],
    "parameters": {"tableName": {"type": "string"}},
    "typeProperties": {"schema": "stg", "table": ex("@dataset().tableName")},
    "folder": {"name": "domesday"}})

write("dataset", "ds_ig_sftp_mi_exp", {
    "linkedServiceName": {"referenceName": "ls_sftp_ig", "type": "LinkedServiceReference"},
    "annotations": [], "type": "Binary",
    "parameters": {"nn": {"type": "string"}},
    "typeProperties": {"location": {"type": "SftpLocation", "folderPath": ex("@concat('Export/', dataset().nn)"),
                                    "fileName": "MI_Exp.txt"}},
    "folder": {"name": "infogenesis"}})

write("dataset", "ds_datain_binary", {
    "linkedServiceName": {"referenceName": DATAIN_LS, "type": "LinkedServiceReference"},
    "annotations": [], "type": "Binary",
    "parameters": {"folderPath": {"type": "string"}, "fileName": {"type": "string"}},
    "typeProperties": {"location": {"type": "AzureBlobFSLocation", "fileSystem": "infogenesis",
                                    "folderPath": ex("@dataset().folderPath"), "fileName": ex("@dataset().fileName")}},
    "folder": {"name": "infogenesis"}})

write("dataset", "ds_datain_csv", {
    "linkedServiceName": {"referenceName": DATAIN_LS, "type": "LinkedServiceReference"},
    "annotations": [], "type": "DelimitedText", "schema": [],
    "parameters": {"folderPath": {"type": "string"}},
    "typeProperties": {"location": {"type": "AzureBlobFSLocation", "fileSystem": "infogenesis",
                                    "folderPath": ex("@dataset().folderPath")},
                       "columnDelimiter": ",", "encodingName": "UTF-8",
                       "escapeChar": "\"", "quoteChar": "\"", "firstRowAsHeader": True, "nullValue": ""},
    "folder": {"name": "infogenesis"}})

# ======================= pl_menus_ingest_store =======================
# One store: SFTP -> raw blob -> parser function -> CSVs. Never fails the parent for store-level problems.
RUN = "@pipeline().parameters.runId"
LOC = "@pipeline().parameters.locId"
NN = "@pipeline().parameters.nn"
NN_E = NN[1:]    # same expressions without the leading @, for use inside concat(...)
RUN_E = RUN[1:]
RAW_FOLDER = "@concat('menu_items/raw/', formatDateTime(utcNow(), 'yyyy/MM/dd'))"

ingest_ok = [
    {"name": "Copy raw file", "type": "Copy", "dependsOn": [],
     "policy": {"timeout": "0.00:10:00", "retry": 2, "retryIntervalInSeconds": 60},
     "typeProperties": {
         "source": {"type": "BinarySource", "storeSettings": {"type": "SftpReadSettings", "recursive": False,
                                                               "disableChunking": False}},
         "sink": {"type": "BinarySink", "storeSettings": {"type": "AzureBlobFSWriteSettings"}}},
     "inputs": [{"referenceName": "ds_ig_sftp_mi_exp", "type": "DatasetReference", "parameters": {"nn": ex(NN)}}],
     "outputs": [{"referenceName": "ds_datain_binary", "type": "DatasetReference",
                  "parameters": {"folderPath": ex("@variables('rawFolder')"),
                                 "fileName": ex(f"@concat({NN_E}, '_MI_Exp.txt')")}}]},
    sp("Record arrival", "ops.usp_record_arrival", {
        "runId": (ex(RUN), "String"), "domainCode": ("menus", "String"), "feedCode": ("MI_Exp", "String"),
        "locId": (ex(LOC), "Int32"),
        "sourceModifiedUtc": (ex("@activity('Check IG file').output.lastModified"), "DateTime"),
        "sourcePath": (ex(f"@concat('infogenesis/', variables('rawFolder'), '/', {NN_E}, '_MI_Exp.txt')"), "String")},
       [dep("Copy raw file")]),
    {"name": "Parse file", "type": "AzureFunctionActivity", "dependsOn": [dep("Record arrival")],
     "policy": {"timeout": "0.00:05:00", "retry": 1, "retryIntervalInSeconds": 30},
     "linkedServiceName": {"referenceName": "ls_fn_ig_etl", "type": "LinkedServiceReference"},
     "typeProperties": {"functionName": "mi-export/parse", "method": "POST",
                        "body": ex("@json(concat('{\"runId\":\"', pipeline().parameters.runId, "
                                   "'\",\"storageAccount\":\"aubdatain\",\"container\":\"infogenesis\",\"rawBlob\":\"', "
                                   "variables('rawFolder'), '/', pipeline().parameters.nn, '_MI_Exp.txt', "
                                   "'\",\"outputPrefix\":\"menu_items/parsed/', pipeline().parameters.runId, "
                                   "'\",\"locId\":', string(pipeline().parameters.locId), "
                                   "',\"rejectThresholdPct\":', string(pipeline().parameters.rejectThresholdPct), '}'))")}},
    sp("Log parse result", "ig.usp_log_parse_result", {
        "runId": (ex(RUN), "String"), "locId": (ex(LOC), "Int32"),
        "result": (ex("@string(activity('Parse file').output)"), "String")}, [dep("Parse file")]),
    log_event("Log copy failure", "LOAD_FAILED",
              ex(f"@concat('Store ', {NN_E}, ': could not copy MI_Exp.txt from IG SFTP: ', activity('Copy raw file').error.message)"),
              [dep("Copy raw file", "Failed")], loc=ex(LOC), step="ingest"),
    log_event("Log parser failure", "PARSE_FAILED",
              ex(f"@concat('Store ', {NN_E}, ': parser function call failed: ', activity('Parse file').error.message)"),
              [dep("Parse file", "Failed")], loc=ex(LOC), step="parse"),
]

pipeline("pl_menus_ingest_store", [
    {"name": "Set raw folder", "type": "SetVariable", "dependsOn": [],
     "typeProperties": {"variableName": "rawFolder", "value": ex(RAW_FOLDER)}},
    {"name": "Check IG file", "type": "GetMetadata", "dependsOn": [dep("Set raw folder")],
     "policy": {"timeout": "0.00:02:00", "retry": 2, "retryIntervalInSeconds": 60},
     "typeProperties": {"dataset": {"referenceName": "ds_ig_sftp_mi_exp", "type": "DatasetReference",
                                    "parameters": {"nn": ex(NN)}},
                        "fieldList": ["exists", "lastModified", "size"],
                        "storeSettings": {"type": "SftpReadSettings", "recursive": False},
                        "formatSettings": {"type": "BinaryReadSettings"}}},
    {"name": "File state", "type": "Switch", "dependsOn": [dep("Check IG file")],
     "typeProperties": {
         "on": ex("@if(not(activity('Check IG file').output.exists), 'missing', "
                  "if(less(ticks(coalesce(activity('Check IG file').output?.lastModified, utcNow())), "
                  "ticks(addHours(utcNow(), mul(-1, pipeline().parameters.maxFileAgeHours)))), 'stale', 'ok'))"),
         "cases": [
             {"value": "missing", "activities": [
                 log_event("Log missing file", "FILE_MISSING",
                           ex(f"@concat('Store ', {NN_E}, ': no MI_Exp.txt in /Export/', {NN_E}, ' on the IG SFTP')"),
                           [], loc=ex(LOC), severity=ex("@pipeline().parameters.missingSeverity"), step="ingest")]},
             {"value": "stale", "activities": [
                 log_event("Log stale file", "FILE_STALE",
                           ex(f"@concat('Store ', {NN_E}, ': MI_Exp.txt was last updated ', "
                              "activity('Check IG file').output.lastModified, ' UTC')"),
                           [], loc=ex(LOC), severity=ex("@pipeline().parameters.missingSeverity"), step="ingest")]},
             {"value": "ok", "activities": ingest_ok},
         ]}},
    log_event("Log SFTP failure", "LOAD_FAILED",
              ex(f"@concat('Store ', {NN_E}, ': could not reach the IG SFTP: ', activity('Check IG file').error.message)"),
              [dep("Check IG file", "Failed")], loc=ex(LOC), step="ingest"),
], params={
    "runId": {"type": "string"}, "locId": {"type": "int"}, "nn": {"type": "string"},
    "maxFileAgeHours": {"type": "int", "defaultValue": 20},
    "rejectThresholdPct": {"type": "float", "defaultValue": 1.0},
    "missingSeverity": {"type": "string", "defaultValue": "ERROR"},
}, variables={"rawFolder": {"type": "String"}})

# ======================= pl_menus_publish_store =======================
pipeline("pl_menus_publish_store", [
    lookup("Build menu JSON", "menu.usp_publish_store",
           {"locId": (ex(LOC), "Int32"), "runId": (ex(RUN), "String")}),
    {"name": "If publishing", "type": "IfCondition", "dependsOn": [dep("Build menu JSON")],
     "typeProperties": {
         "expression": ex("@bool(activity('Build menu JSON').output.firstRow.shouldPublish)"),
         "ifTrueActivities": [
             web("Upload JSON", "PUT",
                 ex(f"@concat('https://{WEB_STORAGE}.blob.core.windows.net/menus/', "
                    "activity('Build menu JSON').output.firstRow.blobName)"),
                 [], body=ex("@activity('Build menu JSON').output.firstRow.menuJson"),
                 headers={"x-ms-blob-type": "BlockBlob", "x-ms-version": "2023-11-03",
                          "Content-Type": "application/json; charset=utf-8",
                          "x-ms-blob-content-type": "application/json; charset=utf-8",
                          "x-ms-blob-cache-control": "public, max-age=300"},
                 resource="https://storage.azure.com/"),
             sp("Record publish", "ops.usp_record_arrival", {
                 "runId": (ex(RUN), "String"), "domainCode": ("menus", "String"), "feedCode": ("menu_json", "String"),
                 "locId": (ex(LOC), "Int32"),
                 "rowCount": (ex("@activity('Build menu JSON').output.firstRow.itemCount"), "Int32"),
                 "sourcePath": (ex(f"@concat('{WEB_STORAGE}/menus/', activity('Build menu JSON').output.firstRow.blobName)"), "String")},
                [dep("Upload JSON")]),
             log_event("Log published", "MENU_PUBLISHED",
                       ex(f"@concat('Store ', {NN_E}, ': ', string(activity('Build menu JSON').output.firstRow.itemCount), ' items published')"),
                       [dep("Record publish")], loc=ex(LOC), step="publish"),
             log_event("Log upload failure", "PUBLISH_FAILED",
                       ex(f"@concat('Store ', {NN_E}, ': menu JSON upload failed: ', activity('Upload JSON').error.message)"),
                       [dep("Upload JSON", "Failed")], loc=ex(LOC), step="publish"),
         ]}},
    log_event("Log build failure", "PUBLISH_FAILED",
              ex(f"@concat('Store ', {NN_E}, ': building the menu JSON failed: ', activity('Build menu JSON').error.message)"),
              [dep("Build menu JSON", "Failed")], loc=ex(LOC), step="publish"),
], params={"runId": {"type": "string"}, "locId": {"type": "int"}, "nn": {"type": "string"}})

# ======================= pl_menus_core =======================
ENTITIES = [
    {"entity": "item", "table": "mi_item"},
    {"entity": "price_level", "table": "mi_price_level"},
    {"entity": "store_price_level", "table": "mi_store_price_level"},
    {"entity": "sku_code", "table": "mi_sku_code"},
    {"entity": "choice_group", "table": "mi_choice_group"},
    {"entity": "kitchen_printer", "table": "mi_kitchen_printer"},
]
pipeline("pl_menus_core", [
    lookup("Get stores", "menu.usp_stores_to_load", {"onlyMissing": (ex("@pipeline().parameters.onlyMissing"), "Boolean")},
           first_row=False),
    {"name": "Ingest each store", "type": "ForEach", "dependsOn": [dep("Get stores")],
     "typeProperties": {"items": ex("@activity('Get stores').output.value"), "isSequential": False, "batchCount": 6,
                        "activities": [{
                            "name": "Ingest store", "type": "ExecutePipeline", "dependsOn": [],
                            "typeProperties": {
                                "pipeline": {"referenceName": "pl_menus_ingest_store", "type": "PipelineReference"},
                                "waitOnCompletion": True,
                                "parameters": {"runId": ex(RUN), "locId": ex("@item().locId"), "nn": ex("@item().nn"),
                                               "maxFileAgeHours": ex("@pipeline().parameters.maxFileAgeHours"),
                                               "rejectThresholdPct": ex("@pipeline().parameters.rejectThresholdPct"),
                                               "missingSeverity": ex("@pipeline().parameters.missingSeverity")}}}]}},
    {"name": "Stage each table", "type": "ForEach", "dependsOn": [dep("Ingest each store", "Completed")],
     "typeProperties": {"items": ex("@json('" + json.dumps(ENTITIES) + "')"), "isSequential": False, "batchCount": 6,
                        "activities": [
                            {"name": "Check parsed files", "type": "GetMetadata", "dependsOn": [],
                             "typeProperties": {"dataset": {"referenceName": "ds_datain_csv", "type": "DatasetReference",
                                                            "parameters": {"folderPath": ex(f"@concat('menu_items/parsed/', {RUN_E}, '/', item().entity)")}},
                                                "fieldList": ["exists"],
                                                "storeSettings": {"type": "AzureBlobFSReadSettings", "recursive": False},
                                                "formatSettings": {"type": "DelimitedTextReadSettings"}}},
                            {"name": "If any parsed", "type": "IfCondition", "dependsOn": [dep("Check parsed files")],
                             "typeProperties": {"expression": ex("@activity('Check parsed files').output.exists"),
                                                "ifTrueActivities": [{
                                                    "name": "Copy to staging", "type": "Copy", "dependsOn": [],
                                                    "policy": {"timeout": "0.00:15:00", "retry": 1, "retryIntervalInSeconds": 30},
                                                    "typeProperties": {
                                                        "source": {"type": "DelimitedTextSource",
                                                                   "storeSettings": {"type": "AzureBlobFSReadSettings", "recursive": False,
                                                                                     "wildcardFolderPath": ex(f"@concat('menu_items/parsed/', {RUN_E}, '/', item().entity)"),
                                                                                     "wildcardFileName": "*.csv"},
                                                                   "formatSettings": {"type": "DelimitedTextReadSettings"}},
                                                        "sink": {"type": "AzureSqlSink",
                                                                 "preCopyScript": ex("@concat('DELETE FROM stg.', item().table, ';')"),
                                                                 "writeBehavior": "insert", "sqlWriterUseTableLock": False,
                                                                 "disableMetricsCollection": False},
                                                        "enableStaging": False,
                                                        "translator": {"type": "TabularTranslator",
                                                                       "typeConversion": True,
                                                                       "typeConversionSettings": {"allowDataTruncation": False,
                                                                                                  "treatBooleanAsNumber": False}}},
                                                    "inputs": [{"referenceName": "ds_datain_csv", "type": "DatasetReference",
                                                                "parameters": {"folderPath": ex(f"@concat('menu_items/parsed/', {RUN_E}, '/', item().entity)")}}],
                                                    "outputs": [{"referenceName": "ds_sql_stg_table", "type": "DatasetReference",
                                                                 "parameters": {"tableName": ex("@item().table")}}]}]}}]}},
    lookup("Merge into ig", "ig.usp_mi_merge", {"runId": (ex(RUN), "String")}, first_row=False,
           depends=[dep("Stage each table")]),
    sp("Check IG data quality", "menu.usp_check_ig_quality", {"runId": (ex(RUN), "String")}, [dep("Merge into ig")]),
    {"name": "Publish each store", "type": "ForEach", "dependsOn": [dep("Check IG data quality", "Completed")],
     "typeProperties": {"items": ex("@activity('Get stores').output.value"), "isSequential": False, "batchCount": 6,
                        "activities": [{
                            "name": "Publish store", "type": "ExecutePipeline", "dependsOn": [],
                            "typeProperties": {
                                "pipeline": {"referenceName": "pl_menus_publish_store", "type": "PipelineReference"},
                                "waitOnCompletion": True,
                                "parameters": {"runId": ex(RUN), "locId": ex("@item().locId"), "nn": ex("@item().nn")}}}]}},
], params={
    "runId": {"type": "string"},
    "onlyMissing": {"type": "bool", "defaultValue": False},
    "maxFileAgeHours": {"type": "int", "defaultValue": 20},
    "rejectThresholdPct": {"type": "float", "defaultValue": 1.0},
    "missingSeverity": {"type": "string", "defaultValue": "ERROR"},
})

# ======================= pl_menus_daily (entry point) =======================
pipeline("pl_menus_daily", [
    sp("Start run log", "ops.usp_run_start", {
        "runId": (ex("@pipeline().RunId"), "String"), "domainCode": ("menus", "String"),
        "pipelineName": (ex("@pipeline().Pipeline"), "String"),
        "triggerName": (ex("@pipeline().TriggerName"), "String"),
        "triggerType": (ex("@pipeline().TriggerType"), "String")}),
    {"name": "Run menus", "type": "ExecutePipeline", "dependsOn": [dep("Start run log")],
     "typeProperties": {"pipeline": {"referenceName": "pl_menus_core", "type": "PipelineReference"},
                        "waitOnCompletion": True,
                        "parameters": {"runId": ex("@pipeline().RunId"),
                                       "onlyMissing": ex("@pipeline().parameters.onlyMissing"),
                                       "maxFileAgeHours": ex("@pipeline().parameters.maxFileAgeHours"),
                                       "rejectThresholdPct": ex("@pipeline().parameters.rejectThresholdPct"),
                                       "missingSeverity": ex("@pipeline().parameters.missingSeverity")}}},
    sp("End run log", "ops.usp_run_end", {
        "runId": (ex("@pipeline().RunId"), "String"),
        "failureMessage": (ex("@coalesce(activity('Run menus')?.error?.message, '')"), "String")},
       [dep("Run menus", "Completed")]),
    {"name": "Send notifications", "type": "ExecutePipeline", "dependsOn": [dep("End run log", "Completed")],
     "typeProperties": {"pipeline": {"referenceName": "pl_ops_notify", "type": "PipelineReference"},
                        "waitOnCompletion": True, "parameters": {"runId": ex("@pipeline().RunId")}}},
], params={
    "onlyMissing": {"type": "bool", "defaultValue": False},
    "maxFileAgeHours": {"type": "int", "defaultValue": 20},
    "rejectThresholdPct": {"type": "float", "defaultValue": 1.0},
    "missingSeverity": {"type": "string", "defaultValue": "ERROR"},
})

# ======================= pl_ops_notify (shared by every domain) =======================
def notify_branch(kind, flag, slack_col, graph_col, subject_col):
    acts = [
        web(f"Get Slack webhook - {kind}", "GET",
            ex(f"@concat('https://{KEY_VAULT}.vault.azure.net/secrets/', "
               "activity('Get payloads').output.firstRow.slackSecretName, '?api-version=7.4')"),
            [], resource="https://vault.azure.net", secure_out=True),
        web(f"Post to Slack - {kind}", "POST", ex(f"@activity('Get Slack webhook - {kind}').output.value"),
            [dep(f"Get Slack webhook - {kind}")], body=ex(f"@json(activity('Get payloads').output.firstRow.{slack_col})"),
            headers={"Content-Type": "application/json"}, secure_in=True),
        web(f"Send email - {kind}", "POST", f"https://graph.microsoft.com/v1.0/users/{MAIL_SENDER}/sendMail",
            [], body=ex(f"@json(activity('Get payloads').output.firstRow.{graph_col})"),
            headers={"Content-Type": "application/json"}, resource="https://graph.microsoft.com"),
    ]
    for ch, act, recipient in (("slack", f"Post to Slack - {kind}", "@activity('Get payloads').output.firstRow.areaCode"),
                               ("email", f"Send email - {kind}", "@activity('Get payloads').output.firstRow.emailTo")):
        for ok, cond in (("sent", "Succeeded"), ("failed", "Failed")):
            acts.append(sp(f"Log {ch} {ok} - {kind}", "ops.usp_log_notification", {
                "runId": (ex(RUN), "String"),
                "domainCode": (ex("@activity('Get payloads').output.firstRow.domainCode"), "String"),
                "channel": (ch, "String"), "kind": ("alert" if kind == "alert" else "digest", "String"),
                "status": (ok, "String"), "recipient": (ex(recipient), "String"),
                "subject": (ex(f"@activity('Get payloads').output.firstRow.{subject_col}"), "String")},
                [dep(act, cond)]))
    acts.append(sp(f"Log Slack secret failure - {kind}", "ops.usp_log_notification", {
        "runId": (ex(RUN), "String"),
        "domainCode": (ex("@activity('Get payloads').output.firstRow.domainCode"), "String"),
        "channel": ("slack", "String"), "kind": ("alert" if kind == "alert" else "digest", "String"),
        "status": ("failed", "String"), "detail": ("Could not read the Slack webhook secret from Key Vault", "String")},
        [dep(f"Get Slack webhook - {kind}", "Failed")]))
    return {"name": f"If {kind}", "type": "IfCondition", "dependsOn": [dep("Get payloads")],
            "typeProperties": {"expression": ex(f"@bool(activity('Get payloads').output.firstRow.{flag})"),
                               "ifTrueActivities": acts}}


pipeline("pl_ops_notify", [
    lookup("Get payloads", "ops.usp_run_notifications", {"runId": (ex(RUN), "String")}),
    notify_branch("alert", "sendAlert", "slackAlertBody", "graphAlertBody", "alertSubject"),
    notify_branch("digest", "sendDigest", "slackDigestBody", "graphDigestBody", "digestSubject"),
], params={"runId": {"type": "string"}}, folder="ops")

# ======================= pl_ops_watchdog =======================
pipeline("pl_ops_watchdog", [
    sp("Start run log", "ops.usp_run_start", {
        "runId": (ex("@pipeline().RunId"), "String"), "domainCode": ("ops", "String"),
        "pipelineName": (ex("@pipeline().Pipeline"), "String"),
        "triggerName": (ex("@pipeline().TriggerName"), "String"),
        "triggerType": (ex("@pipeline().TriggerType"), "String")}),
    lookup("Find late feeds", "ops.usp_watchdog", {"runId": (ex("@pipeline().RunId"), "String")},
           first_row=False, depends=[dep("Start run log")]),
    {"name": "Alert each area", "type": "ForEach", "dependsOn": [dep("Find late feeds")],
     "typeProperties": {"items": ex("@activity('Find late feeds').output.value"), "isSequential": True,
                        "activities": [
                            web("Get Slack webhook", "GET",
                                ex(f"@concat('https://{KEY_VAULT}.vault.azure.net/secrets/', item().slackSecretName, '?api-version=7.4')"),
                                [], resource="https://vault.azure.net", secure_out=True),
                            web("Post to Slack", "POST", ex("@activity('Get Slack webhook').output.value"),
                                [dep("Get Slack webhook")], body=ex("@json(item().slackBody)"),
                                headers={"Content-Type": "application/json"}, secure_in=True),
                            web("Send email", "POST", f"https://graph.microsoft.com/v1.0/users/{MAIL_SENDER}/sendMail",
                                [], body=ex("@json(item().graphBody)"), headers={"Content-Type": "application/json"},
                                resource="https://graph.microsoft.com"),
                            sp("Log email", "ops.usp_log_notification", {
                                "runId": (ex("@pipeline().RunId"), "String"), "domainCode": ("ops", "String"),
                                "channel": ("email", "String"), "kind": ("watchdog", "String"), "status": ("sent", "String"),
                                "recipient": (ex("@item().emailTo"), "String"), "subject": (ex("@item().subject"), "String")},
                               [dep("Send email")]),
                        ]}},
    sp("Purge old log rows", "ops.usp_purge", {}, [dep("Alert each area", "Completed")]),
    sp("End run log", "ops.usp_run_end", {
        "runId": (ex("@pipeline().RunId"), "String"),
        "failureMessage": (ex("@coalesce(activity('Alert each area')?.error?.message, '')"), "String")},
       [dep("Purge old log rows", "Completed")]),
], folder="ops")

# ======================= triggers (created Stopped; start after testing) =======================
def schedule(name, pipe, hour, minute, params, desc):
    write("trigger", name, {
        "description": desc, "annotations": [], "runtimeState": "Stopped",
        "pipelines": [{"pipelineReference": {"referenceName": pipe, "type": "PipelineReference"}, "parameters": params}],
        "type": "ScheduleTrigger",
        "typeProperties": {"recurrence": {"frequency": "Day", "interval": 1, "startTime": "2026-10-20T00:00:00",
                                          "timeZone": "Eastern Standard Time",
                                          "schedule": {"minutes": [minute], "hours": [hour]}}}})


schedule("tr_menus_daily_0730", "pl_menus_daily", 7, 30,
         {"onlyMissing": False, "missingSeverity": "WARN"},
         "Daily menu load. A missing/stale IG file is only a WARN here because the 8:15 retry follows.")
schedule("tr_menus_retry_0815", "pl_menus_daily", 8, 15,
         {"onlyMissing": True, "missingSeverity": "ERROR"},
         "Retries stores that did not load at 7:30. Still missing = ERROR alert.")
schedule("tr_ops_watchdog_0930", "pl_ops_watchdog", 9, 30, {},
         "Alerts on any expected feed that has not arrived (catches pipelines that never ran).")

print("written to", ROOT)
