# CONTINUE — Session Resume & Decision Log

**What this is:** the working "resume here" file for the NYC Compliance Manager build. It records the architecture decisions made so far, the environment/setup ritual, and the open questions, so each session can pick up from settled decisions rather than re-deriving them. Read this first, then the design docs (`README.md`, `Compliance-Manager-Data-Model.md`, `Compliance-Manager-UI-Wireframes.md`).

**Status note (be honest about where we are):** the repo currently contains **design documents only** — there is no application code yet. Implementation has not started. The decisions below define the target architecture we are about to build toward.

---

## 1. Environment & session setup

- **Repo:** `github.com/pcastanhas/ComplianceManager`.
- **Session start ritual:** a short-lived, fine-grained PAT scoped to the repo is provided at the start of each session. Clone the repo if it isn't already present, then read this file.
- **.NET 10 SDK install** (the sandbox starts without it): the SDK is in Ubuntu Noble's main archive — no Microsoft repo needed (`archive.ubuntu.com` / `security.ubuntu.com` are both in the egress allowlist).
  - Command: `apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y dotnet-sdk-10.0` (root sandbox, so no `sudo` needed).
  - Installs to `/usr/lib/dotnet/sdk`, CLI symlinked at `/usr/bin/dotnet`.
  - The first `apt-get install` after a fresh sandbox can 404 on a slightly-stale index — run `apt-get update` first, then retry (patch bumps between the cached index and the live mirror cause this).
- **SDK limitation (important):** the SDK works locally, but `dotnet restore` (and everything downstream — build, publish, test, run) is blocked because `api.nuget.org` is **not** in the egress allowlist. The SDK is useful for static inspection, template generation, and CLI-shape checks; **build verification must happen on CI.**

---

## 2. Confirmed technology decisions

| Area | Decision | Notes |
|---|---|---|
| Runtime | **.NET 10** | LTS. |
| Web framework | **Blazor Web App** (unified render-mode model), default **Interactive Server** | See §3.1 for why not pure WASM. |
| UI library | **MudBlazor** | Runs on .NET 10 (8.15+ / 9.x). Requires an interactive render mode — does **not** support static SSR. Pin a version; 9.x drops .NET 8 (fine, we're on 10). |
| Database | **PostgreSQL** via **Azure Database for PostgreSQL Flexible Server** | jsonb-heavy data model is a strong Postgres fit. |
| Data access | **EF Core 10** + **Npgsql.EntityFrameworkCore.PostgreSQL 10.0.x** | EF Core 10's JSON complex-type mapping suits the model's `jsonb` fields (`recurrence_config`, `applicability_predicate`, payloads, etc.). |

---

## 3. Architecture decisions

### 3.1 Render model — Interactive Server, not pure WASM
This is a data-heavy, internal, multi-tenant line-of-business app. Pure Blazor WebAssembly was rejected as the default because it forces an HTTP API for every data operation, can hold no secrets, and pushes all tenant-isolation enforcement onto a public client, plus a heavy first load. The domain core (state machine, deadline engine, reconciliation) is kept in a **UI-agnostic class library**, so a WASM render mode can be added per-page later if a real driver appears (e.g. offline use by field supers) without reworking the core.

**Suggested solution layout:** `Domain` (entities, state machine, deadline rules) → `Application` (use cases) → `Infrastructure` (EF Core/Npgsql, Blob, connectors, ERP) → `Web` (Blazor + MudBlazor) + `Workers` (Functions).

### 3.2 Compute / Azure topology
- **App host:** Azure **App Service (Linux)**. *(Alternative considered: Azure Container Apps, which has a better integrated background-jobs story via Container Apps Jobs. Revisit if the Functions-based jobs become awkward.)*
- **Background jobs:** **Azure Functions**, on **Flex Consumption or Premium** — legacy Consumption caps a single execution at 10 minutes and offers no VNet integration. Multi-tenant batch jobs use **Durable Functions fan-out/fan-in** (each tenant = its own short activity; the orchestration isn't bound by the single-execution cap).
- **Documents:** Azure **Blob Storage**.
- **Secrets / identity:** **Key Vault + Managed Identity**; **Entra ID** for staff SSO; **Entra External ID** flagged for future external-party access (contractors/attorneys).

### 3.3 Multi-tenancy — server-per-tenant (driven by PITR)
- **Each tenant's compliance database lives on its own Flexible Server.** Hard driver: **per-tenant point-in-time restore is a critical requirement**, and Flexible Server PITR restores the **entire server to a new server** — there is no per-database restore (confirmed: item-level/single-database recovery is not supported). One server per tenant is the only way to get independent per-tenant PITR.
- **Catalog (directory) database on its own dedicated Flexible Server**, holding only: global settings, the **client** table, the **user** table. It is the registry of which tenant servers exist and how to reach them.
- **Routing, not secrets, in the catalog:** the client row stores routing info to the tenant's server — **never plaintext connection strings.** Store a Key Vault secret reference, or (preferred) use Entra authentication to Postgres so there is no password at all.
- **User ↔ client is many-to-many** (membership table with role), not a single client pointer — shared staff across the related owners is expected.

> **Layer reminder:** the app does **not** "run on a Flexible Server." A Flexible Server is managed Postgres (data only). The app runs on the compute host (App Service); it reads the catalog server to resolve a tenant, then connects to that tenant's own Flexible Server.

---

## 4. Tenant lifecycle operations (mechanisms confirmed)

### 4.1 Provision a new tenant (server + model schema)
Creating the server is automatable (Azure CLI / Bicep / Terraform / Azure SDK), best done from an **IaC pipeline triggered by onboarding** or a dedicated provisioning function with a managed identity scoped to create servers in the resource group — not from the web app.

Loading the "model" onto the new server: **native `CREATE DATABASE … TEMPLATE` is same-server only** and cannot copy across servers, so it is **off the table** for server-per-tenant. Copy the model one of three ways:
1. **Migrate + seed** *(recommended)* — create an empty server, run EF Core migrations + a seed routine. Schema-as-code, no drift, portable across servers/regions. In a server-per-tenant world this is effectively the only clean physical-independent option.
2. **Dump / restore** — `pg_dump` the model DB, restore into the new server.
3. **Server-clone via restore** — `az postgres flexible-server restore --source-server model-server` produces a new server pre-loaded with the model (the closest analogue to the SQL-Server "model" pattern, done at server level).

### 4.2 Apply schema changes to all servers
Iterate the catalog's client registry and run `Database.Migrate()` against the **model first**, then every tenant server and the catalog. Must be **idempotent and resumable**, with per-server schema-version tracking so a partial failure is detectable and resumable. Run as a **gated release-pipeline step** (not racing live traffic); migrator identity needs DDL rights on every server. There is no "ALTER once, applies everywhere" — fan-out is the standing operational tax of per-tenant isolation.

### 4.3 Run jobs against all servers
A timer-triggered Function reads the catalog, then **Durable fan-out/fan-in** across tenants for ingestion / deadline recompute / reconciliation / alerts, with **per-tenant failure isolation** (one bad tenant must not abort the batch). Watch connection sprawl (many function instances × many tenant servers = many pools) — cap concurrency or front the servers with PgBouncer.

---

## 5. Open questions / pending decisions

1. **Cross-client portfolio reporting (UNRESOLVED, high priority).** Server-per-tenant makes any rollup that spans multiple clients a fan-out-and-merge, or a separate read-model/warehouse pulling from all tenant servers. Portfolio-wide visibility is a headline value prop — need to confirm whether "portfolio" means *within one client* (server-per-tenant is ideal) or *across all related clients* (needs a dedicated reporting path).
2. **Catalog data model** not yet specified — needs `tenant`/`client`, `user`, `user_client` membership (+role), and `settings` tables.
3. **Carried over from `README.md` §7 / data model §11:** unified vs split obligation table; building attributes sourced from PLUTO (derived) vs maintained manually (authoritative); `recurrence_config` jsonb vs normalized; OATH entity-resolution structure (`match_candidate` vs inline); external-party permissions + note visibility; ERP integration direction (push estimates as commitments vs pull posted actuals only).
4. **App host** — App Service chosen; Container Apps remains a live alternative if the jobs story pushes that way.

---

## 6. Housekeeping pending
- **README filename drift not yet fixed:** `README.md` §9 references `Compliance-Tracker-*` (actual files are `Compliance-Manager-*`) and an `HPD-Violation-Workflows.md` that does not exist in the repo. Reconcile when convenient.

---

## 7. Decision log
- **2026-06-18** — Initial decisions captured: stack (.NET 10 / Blazor Web App–Interactive Server / MudBlazor / Postgres / EF Core 10 + Npgsql 10), Azure topology (App Service + Functions + Blob + Key Vault + Entra), multi-tenancy as **server-per-tenant** (driven by per-tenant PITR requirement) with a dedicated catalog server, and the tenant lifecycle mechanisms (migrate-based provisioning, migration fan-out, Durable-Functions job fan-out). Cross-client reporting left open.
