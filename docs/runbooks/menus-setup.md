# Menus: one-time setup

Do these in order. None of them touches a live flow or a live web page, so they are safe on any day; just don't start the triggers (step 9) on a Friday.

Values used below. Change them here and in `tools/build_adf.py` if you pick different names.

| Thing | Name |
|---|---|
| Resource group | `DMCP` (Key Vault, SQL, function app, `aubwebpub`) |
| Data factory | `adf-aub-ops` (in resource group `rg-ops-automation`) |
| Key Vault | `kv-aub-automation` (use an existing vault if you have one) |
| Web storage account | `aubwebpub`, container `menus` |
| Function app | `aub-ig-etl` |
| Sender mailbox | `automation@aubreys.group`, display name "Aubrey's Automation" |
| Admin group | Automation Ops Admins, `automation-ops-admins@aubreys.group` |
| Slack channel | `#alert-ops-automation` |

```powershell
$rg = 'DMCP'; $adfRg = 'rg-ops-automation'; $adf = 'adf-aub-ops'; $kv = 'kv-aub-automation'
$adfObjectId = az datafactory show -g $adfRg -n $adf --query identity.principalId -o tsv
$adfAppId    = az ad sp show --id $adfObjectId --query appId -o tsv
```

## 1. Mailbox and group (Exchange admin center)

1. Shared mailbox `automation@aubreys.group`, display name "Aubrey's Automation". No license needed.
2. Mail-enabled security group "Automation Ops Admins", `automation-ops-admins@aubreys.group`. Add yourself. (Entra can't create mail-enabled security groups; it has to be Exchange.)

## 2. Let the factory send mail as automation@ only

Exchange RBAC for Applications, so the factory can send from that one mailbox and nothing else. Do **not** also grant Mail.Send in Entra; that would allow every mailbox.

```powershell
Connect-ExchangeOnline
New-ServicePrincipal -AppId $adfAppId -ObjectId $adfObjectId -DisplayName 'adf-aub-ops'
New-ManagementScope -Name 'Automation sender' -RecipientRestrictionFilter "PrimarySmtpAddress -eq 'automation@aubreys.group'"
New-ManagementRoleAssignment -App $adfAppId -Role 'Application Mail.Send' -CustomResourceScope 'Automation sender'
Test-ServicePrincipalAuthorization -Identity $adfAppId -Resource 'automation@aubreys.group'   # InScope = True
Test-ServicePrincipalAuthorization -Identity $adfAppId -Resource 'grant@aubreys.group'        # InScope = False
```

Permission changes can take up to an hour to apply.

## 3. Slack

Create `#alert-ops-automation` and add an Incoming Webhook to it. The URL goes in Key Vault (next step), never in ADF or git.

## 4. Key Vault

RBAC permission model.

```powershell
az keyvault secret set --vault-name $kv --name ig-sftp-password --value '<IG SFTP password>'
az keyvault secret set --vault-name $kv --name slack-webhook-alert-ops-automation --value '<webhook URL>'
az role assignment create --assignee-object-id $adfObjectId --assignee-principal-type ServicePrincipal `
  --role 'Key Vault Secrets User' --scope (az keyvault show -n $kv --query id -o tsv)
```

## 5. Storage

**aubwebpub** (new, public read). This is a separate account on purpose: anonymous read stays off every account that holds real data.

```powershell
az storage account create -g $rg -n aubwebpub --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 `
  --allow-blob-public-access true --allow-shared-key-access false
az storage container create --account-name aubwebpub -n menus --public-access blob --auth-mode login
az role assignment create --assignee-object-id $adfObjectId --assignee-principal-type ServicePrincipal `
  --role 'Storage Blob Data Contributor' `
  --scope "$(az storage account show -g $rg -n aubwebpub --query id -o tsv)/blobServices/default/containers/menus"
```

**aubdatain**: the factory already has access through `AubDataInADLS`. Add:
- the function's identity (after step 6): Storage Blob Data Contributor on the `infogenesis` container
- a lifecycle rule: delete blobs under `infogenesis/menu_items/raw/` after 90 days and `infogenesis/menu_items/parsed/` after 14 days

## 6. Function app `aub-ig-etl`

Flex Consumption, Python 3.11, system-assigned identity on. Deploy `functions/ig-etl` (`func azure functionapp publish aub-ig-etl` or a GitHub Action).

Lock it to the factory (App Service Authentication, Microsoft Entra):
1. Create the app registration, set App ID URI `api://aub-ig-etl`.
2. Authentication → Require authentication, unauthenticated requests get HTTP 401.
3. Allowed token audiences: `api://aub-ig-etl`.
4. Allowed client applications: `$adfAppId` only.

The old `agilysys-etl/parse-menu-items` function stays as it is until cutover is finished; nothing calls it.

## 7. Database

Connect to `mcp-alex/domesday` as an Entra admin and run `sql/domesday/000…090` in order. Then:
- check `menu.store`: add every store number and name, fix the `CONFIRM` rows, and run `EXEC menu.usp_sync_feed_expectations;`
- once the group exists, run the commented `Automation Ops Admins` lines at the bottom of `090_security.sql` (gives the group read access to the ops log)

## 8. Data factory

1. In `tools/build_adf.py`, confirm the names at the top. For the IG host key: `ssh-keyscan -t ed25519 portal.ftp.infogenesisasp.com | ssh-keygen -lf -`, then put the result in `hostKeyFingerprint`. Run `python tools/build_adf.py`.
2. ADF Studio → Manage → Git configuration: GitHub, repo `aubreys-automation`, collaboration branch `main`, root folder `/adf/adf-aub-ops`, publish branch `adf_publish`, **Import existing resources: unchecked** (the repo is the source of truth).
3. Publish. Triggers arrive **Stopped**.
4. Test: Debug `pl_menus_daily` with `missingSeverity = WARN`. Check:
   - `SELECT * FROM ops.v_open_issues ORDER BY loggedUtc DESC`
   - `https://aubwebpub.blob.core.windows.net/menus/v1/02.json` opens in a browser
   - Slack line and email arrived; the exceptions email lists the IG items from `docs/ig/menu-item-standards.md`
5. Test the watchdog: Debug `pl_ops_watchdog`. With nothing late it sends nothing; to see an alert, set one store's `maxAgeHours` to 0 in `ops.feed_expectation`, run it, then set it back to 25.

## 9. Go live (not on a Friday)

Start `tr_menus_daily_0730`, `tr_menus_retry_0815`, `tr_ops_watchdog_0930`. Let it run three days before the first store cutover (`menus-cutover.md`).

## 10. Website library

Upload `web/menu-lib` to `/home1/arburles/menu-lib` (outside `public_html`). Make `menu-lib/cache` writable by PHP (cPanel File Manager → 750). Nothing changes on any live page until a store's `bar` folder is swapped.
