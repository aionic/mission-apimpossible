# Negative tests

These are the requests that **must fail**. Run them after deploying to confirm
the gateway is actually enforcing its contract rather than passing everything
through.

Each example prints only headers (`-I` style via `--include` + `--output
/dev/null`) so a rejected prompt is never echoed back into your terminal.

Set up first:

```bash
export MAP_ENDPOINT=...      # gateway Responses endpoint
export MAP_MODEL=...         # approved deployment name
TOKEN="$(az account get-access-token --scope https://ai.azure.com/.default --query accessToken -o tsv)"
```

> Never add `-v`. Verbose curl prints your bearer token.

---

## 1. No token → 401

```bash
curl -i -X POST "$MAP_ENDPOINT" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MAP_MODEL\",\"input\":\"hello\",\"store\":false}"
```

Expect `401`. A `200` means token validation is not running.

---

## 2. `store: true` → 400 `store_not_permitted`

The single most important negative test. This endpoint carries proprietary
source code; server-side persistence must not be reachable.

```bash
curl -i -X POST "$MAP_ENDPOINT" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MAP_MODEL\",\"input\":\"hello\",\"store\":true}"
```

Expect `400` with code `store_not_permitted`.

Note it is **rejected, not silently rewritten**. Quietly flipping `true` to
`false` would leave the developer believing something untrue about where their
code went.

---

## 3. Unapproved model → 400 `unapproved_model`

```bash
curl -i -X POST "$MAP_ENDPOINT" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"model":"some-other-deployment","input":"hello","store":false}'
```

Expect `400`. Callers do not get to choose the deployment.

---

## 4. Unapproved feature → 400

Tools introduce external interaction, so they are outside the allowlist:

```bash
curl -i -X POST "$MAP_ENDPOINT" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MAP_MODEL\",\"input\":\"hi\",\"store\":false,\"tools\":[{\"type\":\"web_search\"}]}"
```

Expect `400`. The schema sets `additionalProperties: false`, so features that
did not exist at review time fail closed too.

Also try `previous_response_id`, `background`, and `conversation` — all
rejected for the same reason.

---

## 5. Spoofed identity headers → ignored

```bash
curl -i -X POST "$MAP_ENDPOINT" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "x-user-id: someone-else" \
  -H "x-tenant-id: 00000000-0000-0000-0000-000000000000" \
  -H "x-foundry-request-id: forged-value" \
  -d "{\"model\":\"$MAP_MODEL\",\"input\":\"hello\",\"store\":false}"
```

Expect `200`, with the request attributed to **you**. The gateway strips these
before reading anything and derives identity solely from the validated token.

Check the returned `x-foundry-request-id`: it must be the real backend value,
not `forged-value`.

---

## 6. Correlation ID handling

**Valid GUID is preserved:**

```bash
CID=$(uuidgen)
curl -i -X POST "$MAP_ENDPOINT" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "x-correlation-id: $CID" \
  -d "{\"model\":\"$MAP_MODEL\",\"input\":\"hi\",\"store\":false}" \
  | grep -i x-correlation-id
```

The response header must echo `$CID` exactly.

**Malformed value is replaced, not echoed:**

```bash
curl -i -X POST "$MAP_ENDPOINT" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "x-correlation-id: not-a-guid'; DROP TABLE--" \
  -d "{\"model\":\"$MAP_MODEL\",\"input\":\"hi\",\"store\":false}" \
  | grep -i x-correlation-id
```

The response must contain a fresh GUID and **must not** echo the supplied
string.

---

## 7. Oversized request → 400

```bash
python3 -c "print('x' * 100000)" > /tmp/big.txt
curl -i -X POST "$MAP_ENDPOINT" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @<(python3 -c "
import json,os
print(json.dumps({'model': os.environ['MAP_MODEL'], 'input': 'x'*100000, 'store': False}))
")
```

Expect `400`. The cap is 1 MiB; 512 KiB is proven to pass. Size the payload from `max_request_bytes`, not from this sentence.

---

## 8. Rate limiting → 429

```bash
for i in $(seq 1 40); do
  curl -s -o /dev/null -w "%{http_code} " -X POST "$MAP_ENDPOINT" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MAP_MODEL\",\"input\":\"hi\",\"store\":false,\"max_output_tokens\":2048}"
done
echo
```

Expect `429` with `Retry-After` once the per-user TPM ceiling is hit.

Two caveats that are properties of the platform, not bugs:

- **Daily quota** exhaustion natively returns **403**, not 429. Normalizing it
  requires proving the policy origin is distinguishable from an RBAC 403 —
  see gate G5.
- Counters are per gateway and concurrent requests can **overshoot** the
  ceiling. These are safeguards, not billing controls.

---

## 9. Direct backend access — the one that matters

```bash
FOUNDRY=$(azd env get-values --output json | jq -r .FOUNDRY_DIRECT_ENDPOINT)

curl -i -X POST "${FOUNDRY}openai/v1/responses" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MAP_MODEL\",\"input\":\"hi\",\"store\":true}"
```

| Pattern | Expected | Meaning |
| --- | --- | --- |
| `public` | **Succeeds** | Accepted, documented residual risk |
| `private` | **Connection failure / timeout** | NSG denies your subnet despite valid RBAC |

If this succeeds on the **private** pattern, the anti-bypass control has
regressed. Note that `store:true` is accepted here — which is precisely what
bypassing the gateway costs you.
