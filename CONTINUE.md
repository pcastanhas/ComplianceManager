# CONTINUE — Session Resume & Decision Log

**What this is:** the working "resume here" file for the NYC Compliance Manager build. It records the architecture decisions made so far, the environment/setup ritual, and the open questions, so each session can pick up from settled decisions rather than re-deriving them. Read this first, then the design docs (`README.md`, `Compliance-Manager-Data-Model.md`, `Compliance-Manager-UI-Wireframes.md`, `Catalog-Data-Model.md`).

**Status note (be honest about where we are):** the repo contains the design docs plus a first **infrastructure scaffold** under `/infra` (Bicep — authored but **not yet validated/deployed**; no Azure access in the build sandbox). There is still **no application code** (no .NET solution yet). The decisions below define the target architecture being built toward.

---

## 1. Environment & session setup

- **Repo:** `github.com/pcastanhas/ComplianceManager`.
- **Session start ritual:** a short-lived, fine-grained PAT scoped to the repo is provided at the start of each session. Clone the repo if it isn't already present, then read this file.
- **.NET 10 SDK install** (the sandbox starts without it): the SDK is in Ubuntu Noble's main archive — no Microsoft repo needed (`archive.ubuntu.com` / `security.ubuntu.com` are both in the egress allowlist).
  - Command: `apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y dotnet-sdk-10.0` (root sandbox, so no `sudo` needed).
  - Installs to `/usr/lib/dotnet/sdk`, CLI symlinked at `/usr/bin/dotnet`.
  - The first `apt-get install` after a fresh sandbox can 404 on a slightly-stale index — run `apt-get update` first, then retry.
- **SDK limitation (important):** the SDK works locally, but `dotnet restore` (and everything downstream — build, publish, test, run) is blocked because `api.nuget.org` is **not** in the egress allowlist. Use the SDK for static inspection, template generation, and CLI-shape checks; **build verification happens on CI** (which is also the deploy pipeline — see §6).

---

## 2. Confirmed technology decisions

| Area | Decision | Notes |
|---|---|---|
| Runtime | **.NET 10** | LTS. |
| Web framework | **Blazor Web App**, default **Interactive Server** | Pure WASM rejected as default (see §3.1). |
| UI library | **MudBlazor** | Runs on .NET 10 (8.15+ / 9.x). Needs an interactive render mode — no static SSR. Pin a version. |
| Database | **PostgreSQL** via **Azure Database for PostgreSQL Flexible Server** | |
| Data access | **EF Core 10** + **Npgsql.EntityFrameworkCore.PostgreSQL 10.0.x** | EF Core 10 JSON complex-type mapping suits the model's `jsonb` fields. |
| Identity | **Entra ID** (workforce) for staff + **Entra External ID** (external tenant) for external users | Email OTP for external; Entra ID **P1** for Conditional Access on the admin app. See §3.5. |

---

## 3. Architecture decisions

### 3.1 Render model — Interactive Server, not pure WASM
Data-heavy, internal, multi-tenant LOB app. Pure WASM rejected as default (forces an API for every data op, public client can't hold secrets or enforce tenancy, heavy first load). The domain core (state machine, deadline engine, reconciliation) stays in a **UI-agnostic class library** so a WASM render mode can be added per-page later if a driver appears.

**Solution layout:** `Domain` → `Application` → `Infrastructure` (EF Core/Npgsql, Blob, connectors, ERP) + catalog model → `Web.Admin` + `Web.Main` → `Workers` (Functions). Shared libraries referenced by both apps so the tenant schema/migrations are defined once.

### 3.2 Compute / Azure topology
- **App host:** Azure **App Service (Linux)**, **two App Services** — admin app and main app (see §3.4). Blazor Server needs WebSockets + ARR affinity (sticky sessions) enabled on each.
- **Background jobs:** **Azure Functions** on **Flex Consumption or Premium** (legacy Consumption caps execution at 10 min and has no VNet integration). Multi-tenant batch jobs use **Durable Functions fan-out/fan-in**.
- **Documents:** Azure **Blob Storage**.
- **Secrets / identity:** **Key Vault + Managed Identity**; distinct managed identities per app (see §3.4).

### 3.3 Multi-tenancy — server-per-tenant (driven by PITR)
- **Each tenant's compliance database lives on its own Flexible Server.** Hard driver: **per-tenant point-in-time restore is a critical requirement**, and Flexible Server PITR restores the **entire server to a new server** — no per-database restore. One server per tenant is the only way to get independent per-tenant PITR.
- **No cross-client reporting** (confirmed). Removes any need for a fan-out reporting path or warehouse; the catalog stays a pure control-plane directory.
- **Catalog (directory) database on its own dedicated Flexible Server** — see `Catalog-Data-Model.md`. Stores routing, not secrets.
- **User ↔ client is many-to-many** (`user_client` + per-client role).

> **Layer reminder:** the app does **not** "run on a Flexible Server." A Flexible Server is managed Postgres (data only). The app runs on App Service; it reads the catalog server to resolve a tenant, then connects to that tenant's own Flexible Server.

### 3.4 Two-app split (control plane vs data plane)
- **Admin app** (platform admins only): add clients, provision databases, manage users platform-wide, run tenant schema migrations. Holds the elevated identity (scoped ARM create rights, catalog read/write, set Entra admin on new servers, DDL on tenant DBs). Locked down with Conditional Access (P1).
- **Main app** (all client users): resolves the signed-in user's `user_client` memberships and connects them to their tenant DB(s). Holds **no** infra/routing/ARM rights — only catalog **read** plus **scoped write** on `user`/`user_client` for delegated `client_admin` user management.
- Distinct managed identities per app preserve least privilege. A compromise of the larger-surface main app cannot touch infrastructure or the client registry's routing.

### 3.5 Identity & auth
- **Internal/staff** → workforce Entra tenant. **Conditional Access via Entra ID P1** on the admin app (small set of platform admins).
- **External users** → separate **Entra External ID external tenant**, **email one-time passcode**, no password, no guest objects in the corporate directory. (Cost: free up to 50,000 MAU, then ~$0.03/MAU; email OTP avoids the paid SMS add-on — keep external verification on email.)
- `user.idp` (`workforce` / `external`) tells the app which authority issued a token. No credentials stored in the catalog.

---

## 4. Tenant lifecycle operations (mechanisms confirmed)

### 4.1 Provision a new tenant — one-click, templated
A single admin click triggers an async, status-tracked orchestration (Durable Functions): write `client` row (`provisioning`) → trigger a **Bicep/ARM template deployment** to create the Flexible Server (idempotent, version-controlled) → configure + create DB/role → migrate + seed → create the **initial `client_admin`** user → write routing back, flip to `active`, log `client_provisioned`.
- Provisioner identity uses a **custom RBAC role scoped to one resource group** (Postgres-server create/config only; **no delete** — deprovisioning stays deliberate).
- Guardrail: `provisioning.max_active_clients` setting; subscription quota as backstop.
- Native `CREATE DATABASE … TEMPLATE` is same-server only, so it cannot copy across servers — provisioning uses migrate+seed (alternatives: dump/restore, or `az postgres flexible-server restore` to clone the model server).

### 4.2 Apply schema changes to all servers
Iterate the catalog's client registry; run `Database.Migrate()` against the **model first**, then every tenant server and the catalog. Idempotent + resumable, with per-server version tracking. Runs as a **gated CD stage** under the migrator identity — never from app startup, never from the main app.

### 4.3 Run jobs against all servers
Timer-triggered Function reads the catalog → **Durable fan-out/fan-in** across tenants (ingestion / deadline / reconciliation / alerts), with per-tenant failure isolation. Watch connection sprawl (cap concurrency / PgBouncer).

---

## 5. CI/CD
- **Single GitHub Actions pipeline, monorepo.** Restore/build the solution once; `dotnet publish` each web project to its own artifact; deploy to **two App Services** (admin, main) plus the **Function App** via `azure/webapps-deploy`.
- Each App Service keeps its **own managed identity, app registration, and config** — preserving the least-privilege split at deploy time. Never share an identity between the two apps.
- **Migrations run as a separate gated CD stage** under the migrator identity (§4.2).
- Build verification lives here (the sandbox can't restore/build against NuGet).
- Optional path-filtered selective deploy, but a shared-library change touches both apps — at this scale, deploy both on every merge to main.

---

## 6. Open questions / pending decisions
1. **External identity invites** — may admins *invite* brand-new external identities (Graph against the external tenant), or only grant access to existing ones?
2. **Provisioning sub-detail** — final add-client form fields (name + initial admin email; region/SKU default from `setting`).
3. **RLS on `user_client`** as defense-in-depth for the delegated-admin write surface (deferred; app-layer enforcement first).
4. **Carried over from `README.md` §7 / tenant data model §11:** unified vs split obligation table; building attributes (PLUTO-derived vs manual authoritative); `recurrence_config` jsonb vs normalized; OATH entity-resolution structure; external-party permissions + note visibility; ERP push-vs-pull.

---

## 7. Housekeeping pending
- **README filename drift:** `README.md` §9 references `Compliance-Tracker-*` (actual files are `Compliance-Manager-*`) and an `HPD-Violation-Workflows.md` that does not exist. Reconcile when convenient.

---

## 8. Decision log
- **2026-06-18 (1)** — Stack (.NET 10 / Blazor Web App–Interactive Server / MudBlazor / Postgres / EF Core 10 + Npgsql 10); Azure topology (App Service + Functions + Blob + Key Vault + Entra); multi-tenancy as **server-per-tenant** (driven by per-tenant PITR) with a dedicated catalog server; tenant lifecycle mechanisms (migrate-based provisioning, migration fan-out, Durable-Functions job fan-out).
- **2026-06-18 (2)** — **No cross-client reporting required.** Catalog data model defined (`Catalog-Data-Model.md`: `client`, `user`, `user_client`, `setting`, `catalog_event`). **Two-app split** (admin/control-plane vs main/data-plane) with distinct managed identities. **One-click templated provisioning** (Bicep/ARM deploy, scoped RBAC, no delete) creating an initial `client_admin`. Delegated `client_admin` user management in the main app. Auth: workforce Entra for staff (**P1 Conditional Access** on admin app), **Entra External ID external tenant + email OTP** for external users (no guest objects in the corporate directory). **Monorepo CI/CD** deploying to two App Services + a Function App.
- **2026-06-18 (3)** — **Infra scaffold** added under `/infra` (Bicep): subscription-scoped `main.bicep` creating a platform RG + dedicated tenants RG; `modules/platform.bicep` (catalog Postgres with Entra-only auth, two App Services, Flex Consumption Function app on .NET 10 isolated, Key Vault, document + Functions storage, Log Analytics/App Insights, least-privilege RBAC); reusable `modules/tenant-postgres.bicep`; dev/prod param files. Region **East US 2**, **Burstable** Postgres for dev. Not yet validated/deployed (no Azure access in sandbox) — validate with `az deployment sub what-if` on CI. Entra objects (admin group, app registrations, External ID tenant) and Postgres data-plane role grants are a separate track, documented in `infra/README.md`.
