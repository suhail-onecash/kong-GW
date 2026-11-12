# API Success Runbook — Ordered Steps to Successfully Call Every API (Kong4 Gateway)

> **Scope:** All APIs exposed by the Kong4 DB-less gateway (port `8000`) — derived from `kong.yml`, the five custom plugins under `plugins/`, the Postman collection `kong4-gateway.postman_collection.json`, and the business story `Switch Account & Create New Account (South & North).pdf` (41 pages).
> **Audience:** Mobile app engineers, backend engineers, testers who need the exact ordered steps to reach a **successful (200/2xx)** result for each API — e.g. a successful login.

---

## 0. Global Prerequisites (before any API can succeed)

Every API in this gateway depends on the same three runtime pieces. Missing any of them = nothing else in this runbook will work.

| # | Prerequisite | How to satisfy it |
|---|---|---|
| 0.1 | **Kong gateway running** | From the project root: `docker compose up -d` (starts the `render` one-shot, then the `kong-gateway` container). Proxy: `http://localhost:8000`, Admin: `http://localhost:8001`. |
| 0.2 | **Redis running on the host (port 6379)** | All five plugins read `passport:<msisdn>` (and payment/lock keys) via `host.docker.internal:6379`. If Redis is down, plugin-guarded APIs return `503 {"errorCode":"SW_008","message":"System unavailable"}`. |
| 0.3 | **Region backends reachable** | Priv env (rendered `kong.yml`): North customer `10.200.31.18:8080`, South customer `10.200.114.22:8080`, North agent `10.200.31.20:8080`, South agent `10.200.114.25:8080` (dev env uses `host.docker.internal:8080/8081/8082/9080`). Unreachable backends → `502/504`. |
| 0.4 | **Passport seeded in Redis** | The master record `passport:<msisdn>` with `profiles[]` (each with `route`, `accountId`, `status`, `pinInitialized`, `tier`) and `defaultRoute` (+ optional `deviceDefaults[]`). Without it every passport-guarded API fails (`404 GO_TO_SIGN_UP` / `404 Passport not found`). Seed it with `redis-cli SET passport:967700000001 '{...}'` exactly like `plugins/switch-account/test-switch-account.ps1` does. |

### 0.5 Headers used by every API

| Header | Required by | Values |
|---|---|---|
| `X-MSISDN` | All passport-guarded APIs (fallback: query `msisdn`/`username`, or body `username`/`msisdn`/`phone`) | e.g. `967700000001` |
| `X-Device-Id` | Device-default resolution (AC-11), dual-login skip | e.g. `DEVICE-IPHONE-14` |
| `X-Target-Region` | Login redirect, register, switch-authenticate, create | `NORTH` \| `SOUTH` (case-insensitive; uppercased by plugins) |
| `Content-Type` | POSTs | `application/json` |
| `X-Transaction-Id` | Payment transfer only | idempotency key (optional — UUID generated if absent) |

### 0.6 Who actually guards which path (route precedence facts from `kong.yml`)

Kong picks the **most specific route**, so each exact path is served by exactly one service and its plugins:

| Request path | Winning service | Plugin(s) that run | What that means for callers |
|---|---|---|---|
| `POST /NWC/rest/Login` | `identity-svc` (exact) | **identity-matrix (950) only** | Passport guard + region routing run. The `passport-router` response transform does **not** run on this exact path. |
| `POST /NWC/rest/register` | `identity-svc` (exact) | **identity-matrix (950) only** | Registration guards (`REG-ID-*`, idempotency lock `lock:reg:`). |
| `GET /NWC/rest/identity/check` | `identity-svc` (exact) | **identity-matrix (950) only** | Precheck matrix. |
| `/NWC/rest/switch/*`, `/NWC/rest/register/second-account` | `switch-svc` (exact) | **switch-account (960) only** | Switch/create guards; body scrubbing of `Telepin`/`YottaGet`. |
| `/NWC/**` (any other path) | `customer-svc` (prefix) | **passport-router (900) only** | Routes by `defaultRoute`/device default, injects trusted headers, **transforms + annotates the response** (`_region`, add/delete fields & headers). No identity/eligibility guard on these generic paths. |
| `/AGENT/**` | `agent-svc` (prefix) | **passport-router (900) only** | Same as customer NWC, targeting the agent backends. Note: no identity-matrix guard on agent paths (its plugin default includes them, but the service isn't routed there). |
| `POST /login2`, `/auth/login2` | `dual-login-svc` | **dual-login (940) only** | Sequential North → South login chain, no Redis. |
| `POST /payment/transfer` | `payment-svc` | **payment-transfer (950) only** | Orchestrated debit→credit with reversal. |

> ⚠️ Review note: the Postman collection's Login description says "guarded by identity-matrix **then routed by passport-router**". For the exact path `/NWC/rest/Login` Kong routes to `identity-svc`, so passport-router does not participate. Verify at runtime with `GET http://localhost:8001/services`.

---

## 1. `GET /NWC/rest/identity/check` — Identity Pre-Check *(do this first in any flow)*

**Purpose:** Ask the gateway "which login/registration action is allowed for this MSISDN?" before sending credentials. Guards: identity-matrix.

**Ordered steps**
1. Ensure prerequisites §0 (Redis + passport seeded).
2. `GET {baseUrl}/NWC/rest/identity/check` with headers:
   - `X-MSISDN: {{msisdn}}` (mandatory — missing → `400 REG-ID-001 "MSISDN is required"`)
   - `X-Device-Id: {{deviceId}}` (recommended → makes `deviceRoute` visible)
3. Gateway reads `passport:<msisdn>` and returns the decision matrix.

**Success criteria** — HTTP `200`:
```json
{
  "status": true,
  "msisdn": "967700000001",
  "isNorthExisted": true, "isSouthExisted": true,
  "defaultRoute": "SOUTH", "deviceRoute": "SOUTH",
  "login":         { "action": "LOGIN_DEFAULT",  "canLogin": true,   "targetRegion": "SOUTH", "validation": null },
  "registration":  { "action": "GO_TO_LOGIN_SCREEN", "canRegister": false, "allowedRegions": [], "validation": "You already have the maximum number of accounts allowed for this mobile number." }
}
```
`login.action` ∈ `LOGIN_NORTH | LOGIN_SOUTH | LOGIN_DEFAULT | FIRST_TIME_PIN_SETUP | GO_TO_SIGN_UP`; `registration.action` ∈ `REGISTER_BASED_ON_INPUT_REGION | REGISTER_ONLY_ON_SOUTH | REGISTER_ONLY_ON_NORTH | REPLACEMENT_ON_NORTH | REPLACEMENT_ON_SOUTH | GO_TO_LOGIN_SCREEN`.

**Failure branches**

| HTTP | Body | Cause |
|---|---|---|
| 400 | `REG-ID-001` | No `X-MSISDN` (header/query/body) |
| 403 | `REG-ID-013`, `action: BLOCKED` | All existing wallets `SUSPENDED`/`AML_BLOCKED`/`BLOCKED` → neutral support message (PDF §2.4) |
| 503 | `SW_008` | Redis unreachable |

---

## 2. `POST /NWC/rest/Login` — Customer Login *(the canonical example)*

**Purpose:** Log into the wallet chosen per passport rules. Guard + routing: identity-matrix (950).

**Before you start — the "success login" checklist**
1. ✅ Prerequisites §0 done (gateway, Redis, backend, **passport exists with at least one profile**).
2. ✅ The profile you intend to log into is `ACTIVE` **and** `pinInitialized = true`.
   - `NOT_INITIALIZED`/`pinInitialized=false` → login is rejected (`400 SW_005`, action `FIRST_TIME_PIN_SETUP`). Complete first-time PIN setup via the switch journey (§7–9) first.
   - `SUSPENDED`/`AML_BLOCKED` (no other active wallet) → `403 REG-ID-013`. `BLOCKED`/`TERMINATED` → `403 SW_003`.
3. ✅ If both wallets exist: the chosen wallet = device default (`deviceDefaults[X-Device-Id]`) → else `defaultRoute` → else `NORTH`. If the default wallet is suspended/AML and the **other** wallet is `ACTIVE`, the gateway silently re-targets the other wallet (Scenario 5).

**Ordered steps**
1. (Recommended) Run pre-check §1 and confirm `login.canLogin = true` and `targetRegion`.
2. `POST http://localhost:8000/NWC/rest/Login` with:
   - Headers: `X-MSISDN: {{msisdn}}`, `X-Device-Id: {{deviceId}}`, `Content-Type: application/json`
   - Body (shape per `plugins/dual-login/south_payload.json` / Postman collection):
```json
{
  "appVersion": 18,
  "username": "967700000001",
  "pass": "7+QEKk8L5/XLlPqLztdIng==",
  "timeStp": "04-11-2026 23:13:04.900",
  "device": "DEVICE-IPHONE-14",
  "otherinfo": "Xiaomi#22101316C#Redmi Note 12 Pro",
  "hash": "5B9CDE4F4F2947129ABD9306EF600054EE859B0DD264690D9A5C5A0805174615",
  "otp": null,
  "rot": 0,
  "dvir": 1,
  "userId": null
}
```
   (`username` in the body also satisfies MSISDN extraction even without the header.)
3. Gateway (in order): extracts MSISDN → reads passport → applies status rules → if OK calls `kong.service.set_upstream(north|south-backend)` → injects trusted headers `X-Region`, `X-Account-Id`, `X-Persona`, `X-Persona-Id`, `X-Passport-Guid`, `X-Device-Id` → forwards body unchanged to the region backend.
4. Backend validates `pass`/`hash`/`device`/PIN rules (PDF §5: wrong PIN → `SW_001`, attempts exceeding → `SW_006`, device mismatch → `SW_007`).

**Success criteria** — HTTP `200` from the region backend with business success (`errorNo == 0`, non-empty token). Kafka/Redis layer should reflect the wallet. Client then refreshes balance/currency/alias per PDF AC-10/AC-22.

**Failure quick-branches**

| HTTP | Body | Meaning / next step |
|---|---|---|
| 400 | `REG-ID-001` | MSISDN missing everywhere → add header or body `username` |
| 400 | `SW_005`, `action: FIRST_TIME_PIN_SETUP`, `targetRegion` | PIN not initialized → go to §7 decision, then PIN-setup journey |
| 403 | `REG-ID-013` (`BLOCKED`) | Suspended/AML → cannot proceed or register (PDF §2.4) |
| 403 | `SW_003` (`INACCESSIBLE`) | Blocked/Terminated wallet |
| 404 | `GO_TO_SIGN_UP` | No profile in either region → run §4 Register |
| 503 | `SW_008` | Redis down → check §0.2 |
| 200 w/ `errorNo: 99887716` etc. | backend business error | Wrong credentials/PIN/device — see PDF §5 catalogue |

---

## 3. `POST /AGENT/rest/Login` — Agent Login

Same ordered steps as §2, but the request goes to `/AGENT/**` → served by `passport-router` (agent backends `north-agent-backend` / `south-agent-backend`). **Identity-matrix eligibility guards do not run here** — routing is purely `device Defaults → defaultRoute → upstream`. Success criteria identical: backend `2xx` + `errorNo == 0`. Missing `X-MSISDN` → `400 {"message":"MSISDN header is required"}` (this one is **header-only** — passport-router does not fall back to body).

---

## 4. `POST /NWC/rest/register` — First/Second-Account Registration (self-registration path)

**Purpose:** Register a wallet in a region via the classic registration endpoint. Guard: identity-matrix.

**Ordered steps**
1. Run §1 pre-check to learn `registration.allowedRegions`.
2. Build request: `POST {baseUrl}/NWC/rest/register`
   - Headers: `X-MSISDN`, `X-Device-Id`, `X-Target-Region: NORTH|SOUTH` (**mandatory for a first account** — no wallet exists yet, so the opposite-region rule can't infer it)
   - Body: registration/KYC JSON (owned by the backend; Kong only guards at the edge). MSISDN may also come from body `username`.
3. Gateway guard order (fail-fast — all close the request before the backend):
   1. Any wallet `SUSPENDED`/`AML_BLOCKED` → **403 `REG-ID-013`** (create-to-bypass ban, PDF §2.4).
   2. Both regions exist non-terminated → **409 `REG-ID-012`** "…maximum number of accounts…" (2-wallet cap, Scenario 8).
   3. Existing north + asking `NORTH` (or south + asking `SOUTH`) → **400 `REG-ID-012`** "You already have an account in this region." (opposite-region rule; the gateway *forces* the input to the valid region otherwise).
   4. First account with no valid region → **400 `REG-ID-001`** "Target region is required".
   5. Idempotency lock `lock:reg:<msisdn>` (10 s TTL, `SET NX EX`) → duplicate submit within 10 s → **429 `PIN-017`**.
4. Otherwise: upstream set to region backend + `X-Region`, `X-Passport-Guid`, `X-Device-Id` injected → forwarded.

**Success criteria** — backend `2xx`; wallet created on that side; afterwards the Kafka consumer / backend must add/refresh the profile in `passport:<msisdn>` in Redis so subsequent calls (login/switch) see it. Remember to wait ≥10 s before retrying a rejected-but-blocked submit (idempotency), or `DEL lock:reg:<msisdn>` in Redis during tests.

---

## 5. `POST /payment/transfer` — Cross-Region Transfer (North debit → South credit)

**Guard:** payment-transfer. **No passport needed** (does not read `passport:*`; it uses its own transaction state in Redis `payment:tx:<txId>`).

**Ordered steps**
1. `POST http://localhost:8000/payment/transfer`
   - Headers: `Content-Type: application/json`, optional `X-Transaction-Id: <unique>` (strongly recommended — it is the idempotency key; body `transactionId`/`txId` also accepted, otherwise a UUID is generated).
   - Body:
```json
{
  "senderMsisdn": "967700000001",
  "receiverMsisdn": "967700000002",
  "amount": 100,
  "currency": "USD"
}
```
   Body aliases: `northMsisdn`/`fromMsisdn` for sender, `southMsisdn`/`toMsisdn` for receiver. `amount` must parse to a number `> 0`. `currency` defaults to `USD`.
2. What the gateway does, in strict order:
   1. Method ≠ POST → **405**; invalid JSON → **400**; missing sender/receiver or `amount ≤ 0` → **400** (`Missing senderMsisdn`, `Missing receiverMsisdn`, `Invalid amount…`).
   2. Redis read `payment:tx:<txId>`: exists & `COMPLETED` → **200** idempotent replay; `PENDING`/`NORTH_DEBITED` → **409** in progress; any other final status → **400**.
   3. Write-ahead `PENDING`.
   4. **Phase 1 — North debit** `POST {north_target}/api/debit`. Non-2xx/no response → state `DEBIT_FAILED`, returned with the upstream status (**funds untouched**).
   5. **Phase 2 — South credit** `POST {south_target}/api/credit`.
   6. **Phase 3 — Scope-ambiguity guard**: if the credit call *timed out* (no HTTP response), `GET {south_target}/api/credit/status?transactionId=…`; `SUCCESS|COMPLETED|CREDITED` counts as success.
   7. **Phase 4 — success finalization** (state `COMPLETED`) or **Phase 5 — reversal** `POST {north_target}/api/debit/reverse`; immediate reversal success → state `REVERSED`; failure → `ngx.timer.at` background worker retries ×3 (5 s apart, header `X-Retry-Attempt`), then `NEEDS_RECONCILIATION` + Redis DLQ `payment:compensation:queue`.

**Success criteria** — HTTP `200`:
```json
{
  "statusCode": 200,
  "message": "Payment transfer completed successfully",
  "transactionId": "tx-1762145…",
  "status": "COMPLETED",
  "senderMsisdn": "967700000001",
  "receiverMsisdn": "967700000002",
  "amount": 100,
  "currency": "USD"
}
```
**Known-failure outputs (by design):** `502` with `status: REVERSED` (destination failed, source refunded) or `status: ROLLBACK_PENDING` (refund retrying in background); `503` if Redis is down. ⚠️ Review note: direction is fixed North-debit → South-credit; the plugin does not verify that `senderMsisdn` actually lives in North — verify in a real deployment.

---

## 6. `GET /switch/decision` — Switch/Create Journey Decision (AC-01–AC-04)

*(Alias: `GET /NWC/rest/switch/decision`.)* **Guard:** switch-account (960).

**Ordered steps**
1. Prereq: passport exists in Redis with ≥1 profile, and `X-MSISDN` present — else `400 REG-ID-001` / `404 {"action":"GO_TO_SIGN_UP"}`.
2. `GET {baseUrl}/switch/decision` with `X-MSISDN` (+ `X-Device-Id` — needed for the `devicePreference` field to reflect *this* device).
3. Interpret `action` (HTTP 200 unless blocked):

| Situation (passport state) | HTTP | `action` | Client next step |
|---|---|---|---|
| No profiles | 404 | `GO_TO_SIGN_UP` | Run §4 register |
| Only North exists | 200 | `CREATE`, `targetRegion: SOUTH` | Run §9 create-second-account |
| Only South exists | 200 | `CREATE`, `targetRegion: NORTH` | Run §9 |
| Two wallets (any status logic), target `ACTIVE` + initialized | 200 | `SWITCH`, `canSwitch: true` | Run §7 authenticate |
| Target wallet `NOT_INITIALIZED` | 200 | `FIRST_TIME_PIN_SETUP` (`SW_005`) | Default-PIN journey (§9.2) |
| One wallet `TERMINATED` | 200 | `SWITCH_AND_REPLACEMENT`, `replacement:{available:true,region:…}` | Replacement interpretation of §9 |
| Everything restricted / all wallets `SUSPENDED`+`AML_BLOCKED` | 403 | `BLOCKED` (`SW_003`) | Stop — support message (PDF §2.4) |
| Default suspended, other active | 200 | `SWITCH` (auto re-targeted) | §7 to the other wallet |

Success criteria: HTTP 200 + an `action` you can act on + `status:true`.

---

## 7. `POST /switch/authenticate` — Switch to Target Wallet (AC-04/05/10)

*(Alias: `/NWC/rest/switch/authenticate`.)* **Guard:** switch-account.

**Ordered steps**
1. Run §6 first; only proceed when `action = SWITCH` (target `ACTIVE`, `pinInitialized = true`).
2. `POST {baseUrl}/switch/authenticate` with headers `X-MSISDN`, `X-Device-Id`, `X-Target-Region: NORTH|SOUTH` (may alternatively be body `targetRegion`), `Content-Type: application/json`, and body `{"pin": "1234"}` — the **target wallet's** PIN, not the currently-active wallet's (PDF AC-05).
3. Gateway guard order:
   1. Missing/invalid region → **400 `SW_008`** "Target region (NORTH or SOUTH) is required".
   2. Passport / target wallet missing → **404 `SW_008`**.
   3. Target `BLOCKED|SUSPENDED|AML_BLOCKED|TERMINATED` → **403 `SW_003`** "This account is not accessible."
   4. Target `NOT_INITIALIZED` (or `pinInitialized=false`) → **400 `SW_005`** + `action: FIRST_TIME_PIN_SETUP`.
   5. `set_upstream(north|south-backend)` fails → **503 `SW_008`**.
4. Otherwise: forwards the request with PIN body to the target-region backend, stamped with trusted headers `X-Region`, `X-Account-Id`, `X-Persona`, `X-Persona-Id`, `X-Passport-Guid`, `X-Device-Id`.

**Success criteria** — backend `200` for the target wallet; you are now "in" the target wallet. Afterwards: discard previous wallet's cached data, refresh balance/currency/alias/history (AC-10/AC-22); optionally persist this device's default via §8.

---

## 8. `POST /switch/set-default` — Per-Device Default Wallet (AC-11)

*(Alias: `/NWC/rest/switch/set-default`.)* **Guard:** switch-account.

**Ordered steps**
1. Ensure the passport exists and the wallet you'll choose is usable.
2. `POST {baseUrl}/switch/set-default` with `X-MSISDN` header and body:
```json
{ "deviceId": "DEVICE-IPHONE-14", "targetRegion": "SOUTH" }
```
   (`deviceId` may alternatively be the `X-Device-Id` header; `targetRegion` may be header `X-Target-Region`/`X-Region`.)
3. Gateway checks: no device id → **400 `SW_007`**; invalid region → **400 `SW_008`**; no passport → **404 `SW_008`**; Redis save failure → **500 `SW_008`**.

**Success criteria** — HTTP `200`:
```json
{ "status": true, "message": "Default wallet updated for this device", "deviceId": "DEVICE-IPHONE-14", "route": "SOUTH" }
```
Verify in Redis: `passport:<msisdn>.deviceDefaults[]` now holds `{deviceId, route, lastUpdated}`; other devices are never affected (Scenario 13).

---

## 9. `POST /switch/create` — Create Second (Opposite-Region) Wallet

*(Alias: `/NWC/rest/register/second-account`.)* **Guard:** switch-account. **Edge-only:** KYC payload ownership is the backend; Kong enforces guards, region, idempotency and routing.

**Ordered steps**
1. Prereq: exactly **one** wallet exists (run §6 → expect `action: CREATE`), customer not suspended/AML, and the existing wallet is not a Signup/expired-verification account *per backend* (PDF §2.2 — edge sees only what `status` says).
2. `POST {baseUrl}/switch/create` with headers `X-MSISDN`, `X-Device-Id`, `Content-Type: application/json`; body = backend KYC payload (when only one side exists you may omit `X-Target-Region` — the gateway **forces** the opposite region).
3. Gateway guard order (fail-fast, in-code order):
   1. Both regions exist → **409 `REG-ID-012`** "…maximum number of accounts allowed for this mobile number." (2-per-MSISDN cap; no 3rd wallet per Scenario 8)
   2. Existing wallet `SUSPENDED`/`AML_BLOCKED` → **403 `REG-ID-013`** (neutral message)
   3. Asking for the same region you already have → **400 `REG-ID-012`** "You already have an account in this region."
   4. No valid region inferable → **400 `REG-ID-001`**
   5. Idempotency lock `lock:create:<msisdn>` (10 s `SET NX EX`) → double-tap within 10 s → **429 `PIN-017`** "Your request is already being processed. Please wait."
   6. Upstream set failure → **503 `SW_008`**
4. Forwarded to the opposite-region backend with `X-Region`, `X-Passport-Guid`, `X-Device-Id`. Backend creates the wallet (unique wallet ID, Tier 0, `pinInitialized=false`) and per PDF AC-07 generates a **temporary 4-digit Default PIN** delivered via SMS (North; South default) / WhatsApp (South optional) / WhatsApp-or-Email only for international customers. No extra OTP is required when creating from an already-authorized device (PDF §9.6).

**Success criteria** — backend `2xx`; the new profile appears in Redis `passport:<msisdn>` with `status: NOT_INITIALIZED`, `pinInitialized: false`.

**9.1 After creation — First-Time PIN setup (mandatory for success, PDF AC-06/07/08)**
1. `GET /switch/decision` now shows `action: FIRST_TIME_PIN_SETUP` (`SW_005`) for that wallet.
2. Use the Default PIN delivered per AC-07 (region-specific channel; if delivery failed you must be told — it is never assumed).
3. On the backend's PIN-setup endpoint (routed via `/NWC/**` → region backend), submit Default PIN + New PIN (exactly 4 digits, not equal to the temporary PIN, not weak/sequential per `PIN-002/008/009/010`) + confirmation.
4. On success the wallet's `pinInitialized` becomes `true` in Redis, the temporary PIN is invalidated (`PIN-005/006` errors on reuse), and the app switches to the new wallet.
5. Optionally persist this device's preference: §8.

---

## 10. Kong Admin API (port 8001) — Operational, not business

| API | Steps to success |
|---|---|
| `GET http://localhost:8001/services` | Verify `customer-svc`, `agent-svc`, `payment-svc`, `dual-login-svc`, `identity-svc`, `switch-svc` all exist → gateway loaded `kong.yml`. |
| `POST http://localhost:8001/config` (multipart `file=@kong/kong.yml`) | Hot-reload config without restarting the container. Success = `2xx` with `{"entity_versions":…}`; failure returns schema/validation errors — fix them before retrying. |

---

## 11. Ready-made aggregation test suites

- `plugins/switch-account/test-switch-account.ps1` — seeds 16 passport scenarios into Redis (`SET passport:96770000000…N`) and asserts status/action/errorCode for every §6/§7/§8/§9 branch:
  ```powershell
  cd plugins\switch-account
  .\test-switch-account.ps1 -KongUrl "http://localhost:8000" -RedisHost "localhost" -RedisPort 6379
  ```
- `plugins/identity-matrix/test-identity-matrix.ps1` — same idea for §1/§2/§4 branches.

---

## 12. End-to-End Happy-Path Journeys (ordered start → finish)

### Journey A — Successful Login (the example)
1. Prereqs §0 (Redigo: seed `passport:<msisdn>` active+initialized).
2. `GET /NWC/rest/identity/check` → expect `login.canLogin=true`, `targetRegion`.
3. `POST /NWC/rest/Login` (§2) → expect `200` + backend `errorNo==0` + token.
4. Refresh wallet data (`GET /NWC/rest/Balance` etc. — generic `/NWC/**` passthrough, now transformed by passport-router).
5. Verify Redis: after *agent* `/AGENT/rest/Login` success the passport-router writes `defaultRoute`/`deviceDefaults` (`Last Successful Session`). For `/NWC/rest/Login` confirm the §0.6 caveat at runtime.

### Journey B — Switch Account (Scenario 3)
1. §6 decision (`SWITCH`) → 2. §7 authenticate with target wallet PIN → 3. refresh wallet (AC-10) → 4. prompt → §8 set-default → 5. user cancels? No state change (AC-24).

### Journey C — Create Second Wallet (Scenario 1)
1. §6 decision (`CREATE`, opposite region) → 2. §9 create → 3. Default PIN delivered → 4. §9.1 first-time PIN setup → 5. §8 set-default → 6. balances refresh. Third-wallet attempt must end in `409 REG-ID-012` (Scenario 8).

### Journey D — Cross-Region Transfer
1. Both MSISDNs exist (one North, one South) → 2. §5 transfer → `200 COMPLETED` → 3. test idempotency: repeat with the same `X-Transaction-Id` → `200` replay → 4. create an artificial South outage → expect `REVERSED`/`ROLLBACK_PENDING` and funds back after ≤3 background retries (then DLQ).

---

## 13. Error-Code Quick Reference (PDF §5 — shared catalogue)

| Group | Codes |
|---|---|
| Switch (`SW_*`) | `SW_001` incorrect PIN · `SW_002` biometric failed · `SW_003` account not accessible · `SW_004` default PIN expired · `SW_005` PIN not initialized · `SW_006` max attempts · `SW_007` device mismatch · `SW_008` system unavailable |
| PIN | `PIN-001..017` (validation, expiry, locking, `PIN-017` too many requests / idempotency) |
| Registration | `REG-ID-001` field required · `REG-ID-005/006` ID has 3 accounts · `REG-ID-012` max accounts/same region · `REG-ID-013` AML review/suspension · others `REG-ID-002..018` |

---

## 14. Code-Review Findings (verify before production use)

1. **Route-precedence vs collection description (§0.6):** `/NWC/rest/Login`, `/NWC/rest/register`, `/NWC/rest/identity/check` are exact-match routes on `identity-svc`, so only `identity-matrix` runs on them — `passport-router`'s response transform and its "Last Successful Session" write-back do **not** execute for customer login. Consequences: customer-login success does **not** update `defaultRoute`/`deviceDefaults` in Redis from the gateway side (unlike agent login). Confirm whether this is intended.
2. **passport-router assumes `body.errorNo == 0`** for login-success detection; if the North backend speaks `errorNumber` (as dual-login tolerates), the Redis update is silently skipped.
3. **dual-login South leg uses a static payload:** `handler.lua` loads `south_payload.json` ("just -For- Development") and only overwrites `username` — `pass`, `hash`, `timeStp` stay static file values. Real dual-login success requires the South leg to receive the customer's actual South credentials.
4. **payment-transfer direction is hard-coded** North-debit → South-credit; sender/receiver region membership is never validated against the passport.
5. **`/AGENT/**` has no identity-matrix guard** in effect (plugin defaults mention agent paths, but the service only routes `/NWC` paths) — agent eligibility checks are absent at the edge.
6. **Switch decision, single-wallet case:** returns `CREATE` without checking the existing wallet's `pinInitialized`/status, while the PDF (§2.3 "Not Initialized is not a missing account") expects a Not-Initialized single wallet to guide the user into First-Time PIN Setup. Confirm intended behavior.
7. **No rate limiting** beyond the 10-second idempotency locks (`lock:reg:`, `lock:create:`) and the payment replay dedupe — coordinate with backend-side limits (PDF AC-08 attempt rules).
8. **Static timeStp/hash in samples:** the Postman samples reuse fixed `timeStp` / encrypted `pass` / `hash`; production backends check freshness and one-time values — always generate current values per the app's login contract.

---

*Runbook generated from a static review of the workspace (kong.yml, 5 plugins, Postman collection, PDF source story). No live calls were executed — the priv backends (`10.200.*.*:8080`) are network targets outside this review environment, so all "(verify at runtime)" items should be confirmed against the running gateway.*
