# Infrastructure (Bicep)

Infrastructure-as-code for the NYC Compliance Manager platform. See `../CONTINUE.md` for the architecture decisions these templates implement.

> **Not yet validated.** These templates were authored without Azure access and have **not** been compiled or `what-if`'d. Run `az bicep build` and `az deployment sub what-if` before any real deployment. Treat resource API versions, the Flex Consumption schema, and built-in role GUIDs as needing confirmation on first run.

## Layout

| File | Purpose |
|---|---|
| `main.bicep` | Subscription-scoped entry point. Creates the **platform RG** + a dedicated **tenants RG**, deploys the platform module, and grants the provisioner a least-privilege custom role scoped to the tenants RG. |
| `modules/platform.bicep` | Catalog Postgres, two App Services (admin + main), Flex Consumption Function app, Key Vault, document storage, monitoring, and RBAC wiring. |
| `modules/tenant-postgres.bicep` | Reusable per-tenant Flexible Server (+ `compliance` db). The "model" template the one-click provisioner deploys once per client. |
| `main.dev.bicepparam` / `main.prod.bicepparam` | Per-environment parameters. |
| `tenant.example.bicepparam` | Example inputs for provisioning a single tenant. |

## What this creates (platform, per environment)

- Catalog **Postgres Flexible Server** on its own server (Entra auth only, password auth disabled), with PITR retention.
- Two **App Services** (Linux, .NET 10) — `admin` and `main` — each with its own system-assigned identity, WebSockets, and sticky sessions for Blazor Server.
- A **Flex Consumption Function app** (.NET 10 isolated) for the workers and the provisioning orchestration.
- **Key Vault** (RBAC mode), a **document Blob Storage** account, a separate **Functions storage** account, and **Log Analytics + Application Insights**.
- **Least-privilege RBAC**: each identity gets only what it needs (Key Vault Secrets User; the main app gets blob access to documents; the Function app gets its host-storage roles and the scoped tenant-provisioner custom role on the tenants RG). The two apps never share an identity, and only the Function (provisioner) identity can create tenant servers.

## Deploy

```bash
# Validate first (always)
az deployment sub what-if \
  --location eastus2 \
  --template-file main.bicep \
  --parameters main.dev.bicepparam

# Deploy
az deployment sub create \
  --location eastus2 \
  --template-file main.bicep \
  --parameters main.dev.bicepparam
```

Requires an identity with permission to create resource groups and role assignments at subscription scope (Owner, or Contributor + User Access Administrator).

## Not handled here — separate identity track

The resource templates do **not** create Entra objects. Set these up alongside:

1. **Entra admin group for Postgres.** Create the group, then put its object id + name into the `entraAdminObjectId` / `entraAdminPrincipalName` params (they default to a placeholder GUID). Password auth is disabled on the servers, so this is required.
2. **App registrations** for the admin app and the main app (two separate registrations; Conditional Access / Entra ID P1 on the admin app).
3. **Entra External ID external tenant** for external users (email one-time passcode). Kept out of the corporate workforce directory.
4. **Postgres data-plane roles.** After deploy, connect to each server as the Entra admin and create the database roles for the app/Function managed identities (`pgaadauth` / `CREATE ROLE`). ARM RBAC does not grant Postgres logins.

## Per-tenant provisioning

The one-click flow deploys `modules/tenant-postgres.bicep` into the tenants RG per client, then applies the schema via EF Core migrations and seeds the initial `client_admin`. See `tenant.example.bicepparam` for the shape.
