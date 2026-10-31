# Hesper Remote — Account / Login / API backend re-engineering plan

**Status:** Plan (grounded). Not an implementation.
**Owner:** Arke Technologies (Pty) Ltd.
**Engine repo:** `spout-technologies/hesper-remote-engine` (this repo).
**Author:** Kairos (side session `account-backend-replan`), 2026-10-31.
**Supersedes nothing; complements** the `hesper` repo's Plan 3 (`docs/plans/plan-3-endpoint-rebrand-productise.md`), WS3.3.

---

## 0. Why this document exists

Hesper Remote is Arke's rebranded RustDesk fork. The client (Flutter UI + Rust
core) speaks a fixed account/API wire protocol — login, address book, OIDC/SSO,
device sync. Today that protocol is pointed at a **dead host**:

> `pub const HESPER_API_SERVER_DEFAULT: &str = "https://dash.hesper.work";`
> — `src/common.rs:1144`

`dash.hesper.work` was never built, and `hesper.work` is retired for
`hesperitsm.com`. The backend that *did* answer this contract — the AtlasOS
version — was, in TK's words, "never solid," so the instruction is explicit:
**re-engineer it properly; do not just port it.**

This plan (a) pins the exact contract the client expects, measured from source;
(b) explains, from the Atlas source, why the original was never solid; (c)
proposes an architecture and home; (d) sequences the migration. Every
load-bearing claim is labelled **MEASURED** (ran it), **READ** (saw it in
source) or **INFERRED** (reasoned); the ledger is in §6.

**Hard constraint (unchanged):** the ID/rendezvous relay
(`artemis.spout.co.za` / the EU relay `159.195.16.230`) runs only open-source
`hbbs`/`hbbr` and has never served an account API. The account backend is
**never** colocated with it. This is already documented at `src/common.rs:1136–1143`
and is reaffirmed by hesper Plan 3 (a *second relay pair*, Docker Compose,
nftables — no account API). This plan touches neither relay.

---

## 1. The client contract (what the engine actually calls)

All paths are `{api_server}/api/...`, where `api_server` resolves through
`get_api_server()` → `get_api_server_()` (`src/common.rs:1119–1157`). The client
is **unmodified RustDesk**: the backend must fit the client, not the reverse.

### 1.1 Transport envelope — READ (`src/hbbs_http.rs:16–40`)

Every response is a JSON object. If it carries a string field `error`, the
client treats the call as failed and surfaces that string. Otherwise the **whole
object** is deserialised into the expected type.

```
{ "error": "human-readable message" }          // failure
{ ...fields of the expected type... }           // success (no envelope)
```

HTTP status matters too: `/api/login` throws on non-200; `/api/currentUser`
treats **401** as "drop the token, log out" and **400** as "token bad, keep
other state" (`user_model.dart:81–84`).

### 1.2 Auth + user — READ (`flutter/lib/models/user_model.dart`, `flutter/lib/common/hbbs/hbbs.dart`)

| Method | Path | Request | Success response | Source |
|---|---|---|---|---|
| POST | `/api/login` | `LoginRequest` (see below) | `LoginResponse` | `user_model.dart:178–202` |
| POST | `/api/logout` | `{id, uuid}` + `Authorization: Bearer <token>` | (ignored) | `user_model.dart:155–175` |
| POST | `/api/currentUser` | `{id, uuid}` + `Bearer` | `UserPayload` **flattened to top level** | `user_model.dart:50–99` |
| GET | `/api/login-options` | — | `string[]` (OIDC/SSO provider descriptors) | `user_model.dart:222–245` |

**`LoginRequest.toJson()`** (`hbbs.dart:155–177`) sends any of: `username`,
`password`, `id`, `uuid`, `autoLogin`, `type`, `verificationCode`, `tfaCode`,
`secret`, and **always** `deviceInfo` (from `bind.mainGetLoginDeviceInfo()`).

**`LoginResponse`** (`hbbs.dart:180–197`): `{access_token?, type?, tfa_type?,
secret?, user?}`.

**Request types** (`HttpType`, `hbbs.dart:10–20`): `account`, `mobile`,
`sms_code`, `email_code`, `tfa_code`.
**Response types:** `access_token` (login done), `email_check`, `tfa_check`.
The client's login UI **only branches on `access_token` and `email_check`**;
`tfa_type` then selects the TOTP dialog. Any other `type` → the client renders
"Failed, bad response from server." (This brittle branching is confirmed by the
Atlas handler's own header comment — see §2.)

**`UserPayload`** the client parses (`hbbs.dart:36–48`): `name`, `display_name`,
`avatar`, `email`, `note`, `verifier?`, `status` (`0`=disabled, `-1`=unverified,
else normal), `is_admin` (bool). The Rust mirror
(`src/hbbs_http/account.rs:79–97`) additionally carries `info` (a `UserInfo`
with `settings`, `login_device_whitelist`, `other`) and `third_auth_type`.

### 1.3 OIDC / SSO device flow — READ (`src/hbbs_http/account.rs`)

A device-code-style flow, driven entirely by the Rust core:

| Method | Path | Request | Success response | Source |
|---|---|---|---|---|
| POST | `/api/oidc/auth` | `{op, id, uuid, deviceInfo}` | `OidcAuthUrl` `{code, url}` | `account.rs:160–176` |
| GET | `/api/oidc/auth-query?code=&id=&uuid=` | — | **double-wrapped** `{body: "<AuthBody JSON string>"}` | `account.rs:178–202` |

Flow: client POSTs `/api/oidc/auth`, gets `{code, url}`, opens `url` in a
browser, then **polls** `/api/oidc/auth-query` every **1 s** for up to **3 min**
(`QUERY_INTERVAL_SECS=1.0`, `QUERY_TIMEOUT_SECS=180`, `account.rs:17–18`). While
pending, the server returns the error string **`"No authed oidc is found"`**
(matched literally at `account.rs:291`) and the client keeps polling. On
success the body is an `AuthBody` `{access_token, type:"access_token", tfa_type,
secret, user}` (`account.rs:99–108`). **Quirk to preserve:** the auth-query
response is JSON-*inside*-JSON — an outer `{body:"..."}` whose `body` is the
stringified `AuthBody` (`account.rs:189–201`).

### 1.4 Address book 2.0 — READ (`flutter/lib/models/ab_model.dart`)

Two layers. The **legacy single-blob** API (fallback / personal-only servers):

| Method | Path | Request | Response | Source |
|---|---|---|---|---|
| GET | `/api/ab` | `Bearer` | `{data:"<ab json string>"}` | `ab_model.dart:1056–1071` |
| POST | `/api/ab` | `{data:"<serialised ab>"}` | 200 | `ab_model.dart:1110–1127` |

The **multi-profile** API (RustDesk Pro "AB 2.0"):

| Method | Path | Request | Returns | Source |
|---|---|---|---|---|
| POST | `/api/ab/settings` | `Bearer` | AB settings (max peers, etc.) | `ab_model.dart:279–290` |
| POST | `/api/ab/personal` | `Bearer` | personal profile `guid` | `ab_model.dart:311–323` |
| POST | `/api/ab/shared/profiles` | paginated | `AbProfile[]` | `ab_model.dart:343–372` |
| POST | `/api/ab/peers` | `?current=&pageSize=` + profile | `PeerPayload[]` (paginated) | `ab_model.dart:1488–1518` |
| POST | `/api/ab/tags/{guid}` | — | `AbTag[]` | `ab_model.dart:1555–1573` |
| POST | `/api/ab/peer/add/{guid}` | peer JSON | 200 | `ab_model.dart:1606–1623` |
| PUT | `/api/ab/peer/update/{guid}` | `{id, tags\|alias\|note\|...}` | 200 | `ab_model.dart:1639–1776` |
| DELETE | `/api/ab/peer/{guid}` | `[ids]` | 200 | `ab_model.dart:1810–1815` |
| POST | `/api/ab/tag/add/{guid}` | `{name, color}` | 200 | `ab_model.dart:1835–1845` |
| PUT | `/api/ab/tag/rename/{guid}` | `{old, new}` | 200 | `ab_model.dart:1868–1875` |
| PUT | `/api/ab/tag/update/{guid}` | `{name, color}` | 200 | `ab_model.dart:1892–1899` |
| DELETE | `/api/ab/tag/{guid}` | `[tag]` | 200 | `ab_model.dart:1915–1920` |

Contract types: `AbProfile{guid,name,owner,note,rule,info}`,
`AbTag{name,color}`, `PeerPayload{id,info,status,user,user_name,
device_group_name,note}`, `ShareRule{read=1,readWrite=2,fullControl=3}`
(`hbbs.dart:77–302`).

### 1.5 Device sync / strategy / audit (self-host only) — READ (`src/hbbs_http/sync.rs`, `src/common.rs:1197–1203`)

| Method | Path | Request | Response | Source |
|---|---|---|---|---|
| POST | `/api/heartbeat` | `{id, uuid, ver, conns?, modified_at}` | `{sysinfo?, disconnect?, modified_at?, strategy?}` | `sync.rs:235–270` |
| POST | `/api/sysinfo` | full sysinfo JSON (os, ver, id, uuid, username, hostname, preset AB fields, strategy/group) | `"SYSINFO_UPDATED"` \| `"ID_NOT_FOUND"` \| other | `sync.rs:125–229` |
| POST | `/api/sysinfo_ver` | — | version string | `sync.rs:192` |
| GET/POST | `/api/audit/{type}` | audit payload | — | `common.rs:1197–1203` |
| — | `/api/record`, `/api/devices/deploy`, `/api/devices/cli`, `/api/device-group/accessible`, `/api/users`, `/api/peers` | — | — | grep inventory |

**Decisive gating fact — READ (`common.rs:1160–1169, 1197–1203`, `sync.rs:276–285`):**
`is_public(url)` returns true for `rustdesk.com` **and `hesper.work`**. When the
api-server is "public", `heartbeat_url()` returns `""` (no heartbeat, no
sysinfo, no strategy push) and `get_audit_server()` returns `""` (no audit). So
on the default public Hesper host the client needs **only** login, currentUser,
logout, login-options, the OIDC pair, and the address book. Heartbeat / sysinfo
/ strategy / audit matter **only for a self-hosted, non-public api-server**
(enterprise). This split sizes the MVP sharply (see §3.4).

### 1.6 Client config surface — READ

- `OPTION_API_SERVER = "api-server"` runtime option already exists
  (`libs/hbb_common/src/config.rs:3165`), read in `core_main.rs:539`,
  `flutter_ffi.rs:1038`, `ui_session_interface.rs:583`, `ui/index.tis:382,415`.
  **The client can already be repointed at runtime** — only the compiled
  *default* is hard-coded.
- `no_register_device()` → `get_api_server()` returns `""` (account layer off
  entirely) — `common.rs:1120–1122`.

---

## 2. Why the AtlasOS version was never solid (frank assessment)

The Atlas backend (`/data/StudioProjects/Atlas`) is a Next.js app on Firebase
App Hosting. Its RustDesk account routes live under `src/app/api/`. Reading them
directly (not inferring):

1. **The whole SSO/OIDC surface was never built.** The client ships a complete
   OIDC device-flow (`account.rs`, 367 lines), but Atlas has **no
   `/api/oidc/auth` and no `/api/oidc/auth-query` route** (MEASURED: `find
   src/app/api -iname oidc` → empty), and **`/api/login-options` returns `[]`**
   (READ: `src/app/api/login-options/route.ts` — "Atlas Remote has none"). Every
   SSO affordance in the client dead-ended.

2. **Device sync never worked natively.** There is **no `/api/heartbeat` and no
   `/api/sysinfo`** (MEASURED: both absent). Atlas's own dash host was a custom
   host — i.e. **not** `is_public` — so the client's `sync.rs` loop posted to
   `{dash}/api/heartbeat` and `/api/sysinfo` every few seconds against **404s**,
   forever. Device registration/strategy via the native client path was dead on
   arrival. (Atlas did device management through a *separate* agent + `/api/rmm/*`
   routes + a relay-probe cron — not the engine's contract.)

3. **Identity was welded to the accounting tenancy.** `/api/login` authenticates
   via `authenticatePracticeUser` / `PracticeRow` and mints
   `mintSessionToken({scope:'user', practiceId, ...})`
   (READ: `src/app/api/login/route.ts:5–31,53–75`). `/api/currentUser` runs
   `SELECT u.email, p.name FROM users u LEFT JOIN practices p …` against Atlas's
   **shared Cloud SQL Postgres** (READ: `src/app/api/currentUser/route.ts:16,29–35`),
   synthesising the RustDesk user from an **accounting-firm "practice"**
   (`display_name: practice.name`; `is_admin:false` and `avatar:''` hardcoded).
   A standalone remote-access product's login was a projection of the
   accounting platform's multi-tenancy — the wrong identity model, and a hard
   coupling to a monolith's schema and release cadence.

4. **The contract was reverse-engineered, not designed.** The login handler's
   own comment documents that it emits `type:'email_check'` with
   `tfa_type:'tfa_check'` **because** the client "only branches on the types
   'access_token' and 'email_check' … any other type falls into its default
   branch and renders 'Failed, bad response from server'" (READ:
   `src/app/api/login/route.ts:1–21`). The 2FA leg threads a signed
   `mfa-pending-token` as `secret` to carry identity between legs. This works,
   but it is a workaround built against the client's fragility rather than a
   designed protocol — fine as a bridge, brittle as a foundation.

5. **Runtime shape fought the workload.** DB-backed opaque sessions
   (`randomBytes(24)` hashed into a Postgres `remote_sessions`-style table with
   `expires_at`/`revoked_at`/`scope`; READ: `src/lib/rmm/remote/session-token.ts:112–182`)
   mean a Cloud SQL round-trip on **every** `currentUser` and every AB call,
   from a serverless SSR app with cold starts — under a client that polls OIDC
   at 1 Hz for up to 3 minutes and heartbeats every 15 s. The data store was
   split (Firestore + Cloud SQL), and the account routes rode the accounting
   app's deploys.

**The carried-over port.** The same code now lives in the `hesper` app
(`apps/hesper/src/app/api/{login,currentUser,ab}/route.ts`) — same
`practice-auth`, same Postgres `users ⋈ practices` join, still no `/api/oidc/*`
and no `/api/heartbeat` (MEASURED). TK's "do not just port it" is exact: the
port is already present and still carries every weakness above. Re-engineering,
not relocation, is the task.

---

## 3. Proposed architecture + home

### 3.1 Guiding decisions

- **Fit the frozen client contract; never fork the client.** The contract in §1
  is fixed. Re-engineering is **server-side**, validated against that contract
  by hesper's existing wire-contract / `tools/parity` harness (the "ab2-routes"
  suite, currently with one known failure, DEF-025 — fix it here).
- **Decouple identity from "practice".** A Hesper Remote account is a
  first-class entity, **not** an accounting-firm projection.
- **Isolate the bounded context.** The root cause was coupling to a monolith.
  The cure is a self-contained *Account service* with its own schema, its own
  identity, and a hard module boundary — co-deployed now, splittable later with
  **zero client change** (the client only knows a host).
- **Keep the relay separate** (hard constraint, §0).

### 3.2 Home — recommendation

**Primary: keep the home the `hesper` Cloud Run service (brand domain
`hesperitsm.com`), as hesper Plan 3 already intends, but re-engineer the account
surface into a properly isolated bounded context inside it.**

Grounding for this choice:
- hesper deploys as **Cloud Run** (service `hesper`, project `hesper-itsm`,
  region `africa-south1`), built by Cloud Build from `apps/hesper/Dockerfile`;
  **"Never App Hosting (not offered in africa-south1)"** (READ:
  `hesper/CLAUDE.md`). Data residency (SA) and the deployer-SA lane come for
  free.
- hesper Plan 3 WS3.7 (R3-18 / Task 3.7.2) **keeps the account routes
  `/api/login`, `/api/ab/*`, `/api/currentUser` as permanent forward-only
  routes** in that service. Standing up a brand-new separate service would
  contradict an active, deeply-sequenced plan next door.
- The wire-contract parity harness already lives there (`hesper/tools/parity`).
- hesper already ships an **import-graph gate** (`tools/gates/import-graph-gate.mjs`)
  that can *enforce* the module boundary — so "isolated bounded context" is
  checkable in CI-equivalent local gates, not just aspirational.

What "re-engineered, not ported" means concretely inside that home:
- A new module, e.g. `apps/hesper/src/lib/remote-account/` + route group
  `apps/hesper/src/app/api/(remote-account)/…`, whose **only** permitted inbound
  dependency is the platform's primitives (db pool, crypto, mailer). The
  import-graph gate forbids it from reaching into `practice`/accounting/RMM
  internals, and forbids the rest of the app from reaching into it.
- Its **own tables** (§3.3), additive-only numbered migrations (Atlas Prime
  Directive; hesper inherited rule: "additive-only numbered migrations, never
  destructive").
- Its own identity (`ra_account`), not `users ⋈ practices`.

**Clean seam to split out later.** Because the api-server is just a host, the
module is written so its HTTP surface can be lifted into a dedicated Cloud Run
service (`hesper-account`, same project/region, sharing the Postgres instance
and migrations lane) without touching the client. Split only if the poll/
heartbeat load profile (1 Hz OIDC, 15 s heartbeat) or blast-radius isolation
later justifies the extra infra. **This is the recommended target if the ITSM
app's own traffic and the account polling ever contend** — but it is a later
option, not a day-one cost.

> **Decision to put to TK (do not silently resolve):** hesper Plan 3 currently
> treats the account routes as *forward-only kept* routes. This plan proposes
> going beyond preservation to **decoupling + completing** them. Either Plan 3's
> WS3.3/WS3.7 absorbs this work, or it is scheduled as a dedicated workstream
> that Plan 3 depends on. A `hesper` rebrand session is active right now
> (worktree `app-rebrand-d9073d`); this needs coordinating with it before code.

### 3.3 Data model (new `ra_*` schema — INFERRED design from the §1 contract)

Additive, numbered migrations. Names illustrative.

- `ra_account` — `id`, `email` (unique, citext), `password_hash` (nullable for
  SSO-only), `display_name`, `avatar_url`, `status` (`0/-1/1` per §1.2),
  `is_admin`, `totp_secret_enc` (nullable), `created_at`, `updated_at`. **The
  identity. No practice_id.**
- `ra_org` + `ra_account_org(account_id, org_id, role)` — optional tenant/team,
  for shared address books and device groups. Absent ⇒ personal-only, which is
  the common consumer case.
- `ra_session` — `token_hash`, `account_id`, `scope`, `issued_at`, `expires_at`,
  `revoked_at`, `device_uuid`, `metadata`. **See §3.5 for stateless-verify vs
  DB-lookup.**
- `ra_oidc_pending` — `code` (PK), `account_id?`, `device_id`, `uuid`,
  `provider`, `created_at`, `auth_body_json?`, `consumed_at`. Backs the
  `/api/oidc/auth` → `/api/oidc/auth-query` device flow (the Atlas gap).
- `ra_ab_profile` — `guid` (PK), `owner_account_id`, `org_id?`, `name`,
  `note`, `rule` (ShareRule), `info_json`, personal-flag. `ra_ab_peer` —
  `profile_guid`, `peer_id`, `alias`, `tags[]`, `note`, `info_json`,
  `hash`, timestamps. `ra_ab_tag` — `profile_guid`, `name`, `color`. Mirrors
  §1.4 exactly, including the legacy blob (store the serialised blob against the
  personal profile for `/api/ab`).
- `ra_device` — `id` (rustdesk id), `uuid`, `account_id?`, `os`, `name`,
  `sysinfo_json`, `last_seen_at`, `strategy_id?`. **Enterprise/self-host only**
  (§3.4); the sink the Atlas backend never had.

### 3.4 Endpoint build set, by tier

- **Public tier (default host, `is_public` ⇒ lean) — MVP:** `/api/login`
  (account + email_code + tfa_code legs), `/api/logout`, `/api/currentUser`,
  `/api/login-options`, `/api/oidc/auth`, `/api/oidc/auth-query`,
  `/api/ab` (blob) + the full `/api/ab/*` 2.0 set. Nothing else is required —
  heartbeat/sysinfo/strategy/audit are gated off for public hosts (§1.5).
- **Enterprise tier (custom, non-public api-server) — later / optional:**
  `/api/heartbeat`, `/api/sysinfo`, `/api/sysinfo_ver`, strategy push,
  `/api/audit/{type}`, `/api/devices/*`, `/api/device-group/accessible`,
  `/api/peers`, `/api/users`. **Coordinate with Plan 3's agent-based RMM** so
  the engine's device channel and the agent's fleet channel do not duplicate
  device management. Likely decision: engine-native device management stays
  **out of scope** for the managed Spout/Kettle fleet (the agent owns that), and
  this tier ships only if a third party self-hosts Hesper Remote.

### 3.5 Auth model

- **Password + TOTP 2FA** — already the client's `account` → `email_check`
  (`tfa_type:'tfa_check'`) → `tfa_code` dance (§1.2). Keep the two-leg flow;
  carry the password-verified identity between legs in a **signed** pending
  token placed in `secret` (the Atlas approach is sound here; keep it).
- **OIDC/SSO (net-new)** — implement the device flow (§1.3) against a real IdP:
  the hesper platform's own OIDC, and/or Google/Microsoft via the brand domain.
  `/api/oidc/auth` creates an `ra_oidc_pending` row and returns `{code, url}`;
  the browser completes at the IdP; `/api/oidc/auth-query?code` returns the
  literal error `"No authed oidc is found"` until the row is fulfilled, then the
  double-wrapped `{body:"<AuthBody>"}`. Populate `/api/login-options` with the
  real providers (`oidc/<name>` or `common-oidc/<json>` per `user_model.dart:231–239`).
- **Sessions** — recommend **signed, self-verifying tokens** (e.g. an HMAC/JWT
  carrying `account_id`, `scope`, `exp`) **plus** a small revocation check, so
  the hot path (`/api/currentUser`, every AB call) avoids a Postgres round-trip
  per request — directly fixing §2.5. `/api/logout` revokes. Keep opaque DB
  tokens available for environments that require instant server-side kill.
- **Device identity** — the client always sends `deviceInfo` + `id`/`uuid`.
  Record it for the login-device whitelist (`UserInfo.login_device_whitelist`,
  `account.rs:46–61`) and alarm/verification settings if/when enabled; not a
  hard requirement for MVP login.

### 3.6 Engine client changes (this repo)

Minimal, and aligned with hesper Plan 3 WS3.3 ("every Hesper Remote build has a
**configurable** api-server … compile-time file + runtime `api-server` option,
with the legacy host as fallback"):

1. **Replace the hard-coded default.** `HESPER_API_SERVER_DEFAULT`
   (`src/common.rs:1144`) becomes a compile-time default sourced from
   `libs/hbb_common/hesper-api-server.txt` (per Plan 3; file does not exist yet —
   MEASURED absent), with the **existing** runtime `api-server` option
   (`OPTION_API_SERVER`, `config.rs:3165`) overriding, and a legacy fallback for
   staged rollout. `get_api_server_()` (`common.rs:1146–1157`) is the single
   edit point.
2. **Revisit `is_public()`** (`common.rs:1160–1169`). It special-cases
   `hesper.work`. For the new host (e.g. `account.hesperitsm.com`), decide
   deliberately: mark it public ⇒ lean consumer product (login + AB only, no
   heartbeat/audit); don't ⇒ the engine will attempt heartbeat/sysinfo/audit,
   which then **must** exist (§3.4). Recommendation: **public for the consumer
   host**; enterprise self-host uses a custom, non-public `api-server`.
3. No protocol/UI change. The Atlas login handler's own comment confirms the
   client is unmodified RustDesk; the backend conforms to it.

Target host naming (brand): `hesperitsm.com` is the brand/marketing domain and
appears **nowhere in the hesper repo yet** (MEASURED) — it is DNS/brand intent.
Pick an explicit account host, e.g. **`account.hesperitsm.com`** or
**`api.hesperitsm.com`**, mapped to the hesper Cloud Run service. Keep "Arke"/
"Kettle" out of every product/engine identifier (hesper rule).

---

## 4. Phased migration / rollout

Each phase is additive, parity-gated against §1, local-gated (no GitHub
Actions), deployed via the deployer SA, British English. Phases 0–3 are the
product; phase 4 is conditional.

- **Phase 0 — Freeze the contract, stand up the seam.** Lift §1 into an
  executable contract fixture in `hesper/tools/parity` (extend the existing
  wire-contract suite). Create the isolated `remote-account` module + route
  group and the import-graph-gate rules. `/api/health` + `/api/login-options`
  (returning `[]` initially) answer from the new module. Wire the engine's
  configurable api-server (`hesper-api-server.txt`) pointing at a **staging**
  host; production default unchanged (legacy fallback still in force). *Exit:*
  parity harness runs green against the frozen contract; engine builds with a
  staging default and the legacy fallback.

- **Phase 1 — Identity decoupling + core auth.** `ra_account` schema
  (additive migration). Implement `/api/login` (account + email_code + tfa_code),
  `/api/currentUser`, `/api/logout` against `ra_account`, with signed sessions +
  revocation. Provide a seeding/migration path for existing users off the
  `users ⋈ practices` join (one-way import, keyed on email; no accounting
  coupling retained). *Exit:* a real account logs in (incl. 2FA) end-to-end on
  staging; `currentUser` returns the correct `UserPayload`; parity green.

- **Phase 2 — Address book 2.0.** `ra_ab_*` schema. Implement the full
  `/api/ab/*` multi-profile surface and the legacy `/api/ab` blob fallback.
  *Exit:* the ab2-routes parity suite passes, **including DEF-025** (the current
  known failure); round-trip add/update/delete of peers and tags, personal and
  shared profiles.

- **Phase 3 — OIDC / SSO device flow (the Atlas gap).** `ra_oidc_pending`
  schema. Implement `/api/oidc/auth` + `/api/oidc/auth-query` against a real
  IdP; populate `/api/login-options` with live providers. *Exit:* a full
  browser SSO round-trip completes from the client within the 3-minute poll
  window; the double-wrapped `auth-query` body is byte-correct against the
  client parser.

- **Phase 4 — Enterprise device surface (conditional).** Only if a self-hosted
  Hesper Remote tier is in scope. `ra_device` + `/api/heartbeat`, `/api/sysinfo`,
  `/api/sysinfo_ver`, strategy push, `/api/audit/*`. **Gate:** confirm with Plan
  3 that this does not duplicate the agent's fleet management; for the managed
  Spout/Kettle fleet this phase is **skipped** (agent owns devices).

- **Phase 5 — Cutover & home.** Flip `hesper-api-server.txt` to the production
  account host (`account.hesperitsm.com`), finalise the `is_public()` decision,
  cut signed/notarised engine builds through the existing release lanes
  (honouring Plan 3's G1/G2 acceptance gates). Soak behind the legacy fallback;
  roll forward cohort-by-cohort (reuse Plan 3's cohort rollout: 1 device → 50%
  → 100%). Retire `dash.hesper.work` references once zero traffic. *Exit:* every
  new build defaults to the account host; no client reaches `dash.hesper.work`;
  the relay is untouched throughout.

**Rough size (INFERRED, not measured):** phases 0–3 are the bulk — order of a
few engineer-weeks of server work plus the engine config change (hours), bounded
by hesper's own 8–12-week Plan 3 envelope of which this is one workstream.
Elapsed time is set by soak/cutover gates, not code.

---

## 5. Risks & coordination

- **Active sibling work.** A `hesper` rebrand session is live (worktree
  `app-rebrand-d9073d`) and hesper is mid-Plan-1/2/3. **Coordinate before any
  code lands in `apps/hesper`.** This document is the engine-repo artefact; the
  server work belongs to the hesper repo and its plan owners.
- **Plan 3 scope overlap (surfaced, not resolved).** §3.2's decision box: is
  this "decouple + complete" folded into WS3.3/WS3.7, or a dependency of it? TK
  to call.
- **The `is_public()` fork** decides whether the enterprise tier is ever needed;
  resolve it before Phase 0 fixes the host.
- **Legacy fallback is the rollback.** Keeping the legacy host as a compiled
  fallback (Plan 3) means a bad account host does not brick fielded clients.
- **Owner-name hygiene.** No "Arke"/"Kettle" in any product-visible or engine
  identifier (hesper rule); "Atlas" only where the frozen wire contract requires.

---

## 6. Grounding ledger

**MEASURED (ran it):**
- Atlas has **no** `/api/oidc/*`, `/api/heartbeat`, `/api/sysinfo` route
  (`find src/app/api`).
- hesper has **no** `/api/oidc/*`, `/api/heartbeat`, `/api/sysinfo`; its
  `login`/`currentUser` import `practice-auth` + Postgres (grep).
- `hesper-api-server.txt` does **not** exist in this repo yet (`find`).
- `hesperitsm.com` appears **nowhere** in the hesper repo (grep).
- `docs/account-backend-replan.md` is **not** git-ignored (`git check-ignore`).

**READ (saw it in source):**
- Every endpoint, payload and type in §1 (file:line cited inline).
- `HESPER_API_SERVER_DEFAULT` + `get_api_server_` + `is_public` + the relay-
  separation comment (`src/common.rs:1136–1169`).
- `is_public ⇒ heartbeat_url()==""` and `get_audit_server()==""`
  (`sync.rs:276–285`, `common.rs:1197–1203`).
- The runtime `api-server` option already exists (`config.rs:3165`; call sites).
- Atlas/hesper practice-coupling, empty `login-options`, DB-session model
  (`login/route.ts`, `currentUser/route.ts`, `session-token.ts`).
- hesper deploy target (Cloud Run / `hesper-itsm` / africa-south1 / never App
  Hosting) and Plan 3 WS3.3/WS3.7 (`hesper/CLAUDE.md`,
  `docs/plans/plan-3-endpoint-rebrand-productise.md`).

**INFERRED (reasoned — not load-bearing for the contract):**
- The `ra_*` data model shape (§3.3) — a design proposal derived from the §1
  contract, to be confirmed in implementation.
- Effort sizing (§4) — not measured; bounded by Plan 3's own estimate.
- The signed-session recommendation (§3.5) — a design choice; the client only
  requires a bearer token it can replay, so either model satisfies the contract.

---

*Plan only. No backend built. The relay was not touched.*
