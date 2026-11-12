# Identity Matrix Plugin (`identity-matrix` v2.0)

> **Version:** 2.0.0  
> **Priority:** 950 (Executes before `passport-router` 900)  
> **Source Story Alignment:** Dual-Region Architecture & Switch/Create Account Story  

---

## 1. Overview
The `identity-matrix` plugin enforces dual-region identity validation, security restriction guards, and dynamic routing at Kong Gateway for multi-region backends (**North** and **South**).

It evaluates account existence flags (`isNorthExisted`, `isSouthExisted`), account statuses (`ACTIVE`, `SUSPENDED`, `AML_BLOCKED`, `TERMINATED`, `NOT_INITIALIZED`), and per-device preferences by querying the customer's Passport object in Redis (`passport:<msisdn>`).

---

## 2. Key Upgrades in Version 2.0.0

1. **Account Status & Security Restriction Guards (AC-02, §2.4, §2.5):**
   - **AML / Suspended Customers:** Immediately blocked from login and registration with a neutral message (*"We are unable to process your request at this time. Please contact customer support."*, `REG-ID-013`), preventing restriction bypass.
   - **Terminated Wallets:** Cannot be logged into, but replacement registration in that region is permitted (Scenario 7).
   - **PIN Not Initialized:** Detects uninitialized PINs and directs to First-Time PIN Setup (`SW_005`), avoiding misleading 404s or invalid attempts.
   - **Suspended Default Wallet:** If the default wallet is suspended but the other regional wallet is active, automatically directs login to the active wallet (Scenario 5).

2. **Per-Device Default Wallet Resolution (AC-11, Scenario 13):**
   - Extracts `X-Device-Id` and matches against `passport.deviceDefaults[]`.
   - Routes login requests based on device-specific preferences before falling back to the global `defaultRoute`.

3. **Standardized Error Codes & Customer Messages (§4 & §5):**
   - Replaced custom error numbers with standard codes (`REG-ID-001`, `REG-ID-012`, `REG-ID-013`, `SW_003`, `SW_005`, `PIN-017`).
   - Standard customer-facing messages for 2-wallet limit, opposite region, and AML restrictions.

4. **Safe Header Serialization:**
   - Introduced `csv()` helper to properly format `X-Persona` and `X-Persona-Id` array tables into comma-separated strings instead of `table: 0x...`.

5. **Registration Idempotency Guard (AC-20):**
   - Redis distributed lock (`lock:reg:<msisdn>`) prevents duplicate submissions on rapid tapping (`PIN-017`, 429 Too Many Requests).

6. **Internal System Masking & Audit Logging (§2.1, §7, §8):**
   - `body_filter`: Scrubs occurrences of `Telepin` and `YottaGet` and replaces them with `Core Banking`.
   - `log`: Dispatches structured audit and analytics JSON logs with sensitive credential redaction.

---

## 3. Configuration Reference (`schema.lua`)

| Parameter | Type | Default | Description |
|---|---|---|---|
| `redis_host` | string | `"host.docker.internal"` | Redis hostname / IP |
| `redis_port` | integer | `6379` | Redis TCP port |
| `redis_timeout` | integer | `1000` | Redis socket timeout in ms |
| `passport_prefix` | string | `"passport:"` | Redis key prefix (`passport:<msisdn>`) |
| `north_upstream` | string | `"north-backend"` | Kong upstream name for North |
| `south_upstream` | string | `"south-backend"` | Kong upstream name for South |
| `msisdn_header` | string | `"X-MSISDN"` | Header containing customer MSISDN |
| `msisdn_body_field` | string | `"username"` | JSON body field fallback for MSISDN |
| `device_id_header` | string | `"X-Device-Id"` | Header containing device UUID (AC-11) |
| `region_header` | string | `"X-Target-Region"` | Header containing target registration region |
| `region_body_field` | string | `"region"` | JSON body field for registration region |
| `login_paths` | array | `["/NWC/rest/Login", ...]` | Paths monitored for Login flow |
| `register_paths` | array | `["/NWC/rest/register", ...]` | Paths monitored for Registration flow |
| `precheck_paths` | array | `["/NWC/rest/identity/check", ...]`| Paths for lightweight pre-check UI endpoint |
| `send_trusted_headers`| boolean | `true` | Forward `X-Region`, `X-Account-Id`, `X-Passport-Guid`, `X-Device-Id` |
| `strip_internal_names`| boolean | `true` | Scrub `Telepin` / `YottaGet` from responses |
| `idempotency_ttl_seconds`| integer | `10` | Redis lock duration for registration idempotency |
| `audit_logging_enabled` | boolean | `true` | Emit structured audit & analytics logs |

---

## 4. Test Verification
Run the updated PowerShell verification suite:
```powershell
cd C:\projects\kafka-consumer\kong\plugins\identity-matrix
.\test-identity-matrix.ps1 -KongUrl "http://localhost:8000" -RedisHost "localhost" -RedisPort 6379
```
