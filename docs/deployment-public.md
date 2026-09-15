# Deploying the public pattern

The easier of the two. APIM and Foundry are publicly reachable, with Microsoft
Entra enforced and no keys anywhere.

> **Read this first.** The public pattern does **not** prevent a developer with
> inference RBAC from calling Foundry directly and bypassing every gateway
> control. That is an accepted, documented residual risk. If you need it
> prevented, use [`deployment-private.md`](deployment-private.md).

## Prerequisites

| Requirement | Minimum |
| --- | --- |
| Terraform | 1.16 |
| Azure CLI | 2.86 |
| azd | 1.33 |
| Python + uv | 3.12 / 0.8 |
| Azure permissions | Contributor + **User Access Administrator** (role assignments) |
| Entra | Ability to sign in interactively to the target tenant |

## Step 1 — Choose a model

This repository ships **no default region or model**, and deployment fails
closed without one. Model GA status, regional availability, eligibility for
*new* deployments, quota, and data residency are five separate checks.

```powershell
az cognitiveservices account list-skus --location <region> --kind OpenAI -o table
az cognitiveservices usage list --location <region> -o table
```

Confirm against
[availability](https://learn.microsoft.com/azure/foundry/foundry-models/concepts/models-sold-directly-by-azure-region-availability)
and [lifecycle](https://learn.microsoft.com/azure/foundry/openai/concepts/model-retirements).

## Step 2 — Observe the token audience (gate G1)

`api_audience` must be the audience that actually appears in a token — not a
`.default` scope string copied from documentation.

```powershell
az login --tenant <tenant-id>
$token = az account get-access-token --scope "https://ai.azure.com/.default" --query accessToken -o tsv

# Decode the payload locally. Do not paste a token into a web decoder.
$payload = $token.Split('.')[1]
$payload = $payload.PadRight([int][Math]::Ceiling($payload.Length / 4) * 4, '=')
[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) |
    ConvertFrom-Json |
    Select-Object aud, tid, appid, azp, scp, idtyp
```

Record `aud` → `api_audience`, and `appid`/`azp` → `allowed_client_app_ids`.

> Decode locally. Pasting a live token into an online decoder hands someone
> your identity.

## Step 3 — Configure

```powershell
Copy-Item infra\profiles\public.tfvars.example infra\profiles\public.tfvars
```

Fill in:

```hcl
subscription_id  = "..."
tenant_id        = "..."
location         = "eastus2"
api_audience     = "<observed in step 2>"

model_name            = "<verified in step 1>"
model_version         = "<exact version>"
model_deployment_name = "coding-model"
model_sku             = "GlobalStandard"
model_capacity        = 10

apim_publisher_email   = "team-alias@example.com"
inference_principal_ids = ["<your-entra-object-id>"]
allowed_client_app_ids  = ["<observed in step 2>"]
```

Find your object ID:

```powershell
az ad signed-in-user show --query id -o tsv
```

> `inference_principal_ids` is **not** automatically the principal running azd.
> Set it explicitly; a group object ID is preferable.

## Step 4 — Deploy

```powershell
az login --tenant <tenant-id>
azd auth login
azd env new map-public
azd up
```

Preflight runs first and fails closed on toolchain versions and policy
invariants.

APIM Standard v2 provisioning typically takes 30–45 minutes.

## Step 5 — Verify

```powershell
.\scripts\postprovision.ps1

$env:MAP_ENDPOINT  = "<MAP_RESPONSES_ENDPOINT>"
$env:MAP_MODEL     = "<MAP_MODEL_DEPLOYMENT>"
$env:MAP_TENANT_ID = "<your tenant>"

uv run python examples/python/respond.py "Say hello in five words."
```

Then confirm the controls actually fire —
[`examples/curl/negative-tests.md`](../examples/curl/negative-tests.md) has the
full set. At minimum:

```powershell
# store:true must be REJECTED
curl.exe -i -X POST $env:MAP_ENDPOINT `
  -H "Authorization: Bearer $(az account get-access-token --scope https://ai.azure.com/.default --query accessToken -o tsv)" `
  -H "Content-Type: application/json" `
  -d "{\"model\":\"$env:MAP_MODEL\",\"input\":\"hi\",\"store\":true}"
```

Expect `400 store_not_permitted`.

## Step 6 — Confirm telemetry is clean

```powershell
uv run python examples/python/respond.py "CANARY-e3f1a9-DO-NOT-LOG please echo nothing"
```

Wait ~5 minutes, then in Application Insights Logs:

```kusto
let canary = "CANARY-e3f1a9-DO-NOT-LOG";
union traces, requests, dependencies, exceptions, customEvents
| where timestamp > ago(1h)
| where * has canary
```

Expect **zero rows** — but first confirm telemetry arrived at all, or an empty
result proves only that ingestion is broken:

```kusto
traces | where timestamp > ago(1h) | where message == "responses.invocation" | take 5
```

## Step 7 — Observe the bypass

```powershell
$foundry = (azd env get-values --output json | ConvertFrom-Json).FOUNDRY_DIRECT_ENDPOINT
curl.exe -i -X POST "${foundry}openai/v1/responses" `
  -H "Authorization: Bearer $(az account get-access-token --scope https://ai.azure.com/.default --query accessToken -o tsv)" `
  -H "Content-Type: application/json" `
  -d "{\"model\":\"$env:MAP_MODEL\",\"input\":\"hi\",\"store\":true}"
```

This **succeeds** — with `store:true`, no quotas, and no telemetry. That is
exactly what bypassing the gateway costs you, and exactly why the private
pattern exists.

## Configure VS Code

Settings (User scope — the endpoint setting is application-scoped on purpose,
so a cloned repository cannot redirect your token):

```json
{
  "missionApimpossible.endpoint": "<MAP_RESPONSES_ENDPOINT>",
  "missionApimpossible.model": "<MAP_MODEL_DEPLOYMENT>",
  "missionApimpossible.tenantId": "<your tenant>"
}
```

Build and install:

```powershell
cd src\vscode
npm ci
npm run compile
npx @vscode/vsce package --no-dependencies

# Stable VS Code:
code --install-extension mission-apimpossible-1.0.0.vsix

# VS Code Insiders is a SEPARATE installation:
code-insiders --install-extension mission-apimpossible-1.0.0.vsix
```

> **If you run Insiders, use `code-insiders` for both steps.** Stable and
> Insiders keep separate extension directories *and* separate `settings.json`
> files. Installing with `code` while running Insiders looks like it worked —
> the CLI prints "successfully installed" — and the commands simply never
> appear in the palette, with no error anywhere to explain why. The settings
> below must also be set in the Insiders `settings.json`
> (`%APPDATA%\Code - Insiders\User\settings.json`), not the stable one.

Select code → **Mission APIMpossible: Ask about the current selection**.

## Tear down

```powershell
azd down --purge
```

`--purge` is important: soft-deleted Cognitive Services accounts hold the
custom subdomain and block redeploying under the same name.

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| `401` | Token audience mismatch — re-run step 2 |
| `403 not_delegated_identity` | Using a service principal; sign in as a user |
| Commands missing from the palette | Installed with `code` while running Insiders. Reinstall with `code-insiders`. |
| `endpoint is not configured` in Insiders | Settings were set in the stable `settings.json`. Insiders uses its own. |
| `403 unapproved_client` | Client app not in `allowed_client_app_ids` |
| `403` from backend | Missing `Cognitive Services OpenAI User` on the account |
| `400 unapproved_model` | `MAP_MODEL` ≠ `model_deployment_name` |
| Provisioning fails on quota | Insufficient capacity in the region |
| Provisioning fails on role assignment | Need User Access Administrator |
