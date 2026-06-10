# M365 Cross-Tenant Migration Tool

A local Windows orchestration + UX layer for a one-off cross-tenant Microsoft 365
migration (mailboxes, OneDrive, SharePoint) run by two admins. **This tool does not copy
data itself** — Microsoft's Mailbox Replication Service (MRS) and the SharePoint Online
cross-tenant engine do the moves in-cloud. The tool handles identity mapping, preflight
validation, batching, scheduling, monitoring, reporting, and safe cutover.

See [`M365-migration-tool-brief.md`](M365-migration-tool-brief.md) for the full build brief,
guardrails, and phased plan.

> **Status:** Phase 0 complete — scaffold + SPO hosting risk spike resolved. No migration
> logic yet. Everything so far is read-only / local.

---

## Stack

| Layer    | Choice |
|----------|--------|
| Backend  | PowerShell **7.6.2** hosting a localhost HTTP API via **Pode** 2.13.4 |
| Frontend | **React 18 + Vite**, built to static files and served by Pode |
| State    | **SQLite** via **PSSQLite** 1.1.0 (run/batch/item state, mappings, audit) |
| Logging  | Structured **JSONL** per run + a human-readable run log |
| M365     | `ExchangeOnlineManagement`, `Microsoft.Online.SharePoint.PowerShell`, `Microsoft.Graph` (added in later phases) |

---

## Phase 0 finding — SharePoint Online hosting decision

**Decision: run the SharePoint Online cross-tenant cmdlets directly in PowerShell 7,
in-process. No Windows PowerShell 5.1 sidecar is required.**

BRIEF.md section 4 flagged a known risk: the SharePoint Online Management Shell
(`Microsoft.Online.SharePoint.PowerShell`) was historically Windows PowerShell 5.1-only and
would not load inside a PS7 process — yet Pode and `ExchangeOnlineManagement` run on PS7.

[`scripts/Test-SpoHosting.ps1`](scripts/Test-SpoHosting.ps1) gathered machine-verified
evidence on this box (raw output in `data/spo-hosting-finding.json`, gitignored):

- **PS7:** 7.6.2 — `C:\Program Files\WindowsApps\...\pwsh.exe`
- **Windows PowerShell:** 5.1.26100
- **`Microsoft.Online.SharePoint.PowerShell` 16.0.27313.12000 imports cleanly under PS7**
  (`imported: true`, no error).
- All cross-tenant cmdlets the brief depends on are present and exported under PS7, including:
  `Set-SPOCrossTenantRelationship`, `Get-SPOCrossTenantRelationship`,
  `Test-SPOCrossTenantRelationship`, `Start-SPOCrossTenantUserContentMove`,
  `Start-SPOCrossTenantSiteContentMove`, `Get-SPOCrossTenantUserContentMoveState`,
  `Get-SPOCrossTenantSiteContentMoveState`, `Stop-SPOCrossTenantUserContentMove`.
  (354 SPO cmdlets total.)
- `PnP.PowerShell` 3.2.0 also imports under PS7 (useful for read-only inventory).

The modern SPO Management Shell (16.0.273xx) is therefore PS7-compatible — the inverse of
the historical concern. **Approach (a) from the brief applies: use it directly.**

> **Caveat on the 5.1 probe:** the spike's `importsUnderWin51: false` result is *not*
> evidence of incompatibility. `Install-Module` ran under `pwsh`, which on Windows installs
> to `Documents\PowerShell\Modules` (the PS7 path), so the module simply isn't on Windows
> PowerShell 5.1's search path. The decisive, positive evidence is that it imports under PS7.

> **Still required (guardrail #4):** importing proves the assembly loads; it does **not**
> verify parameter signatures. Before first use in Phase 4/6, confirm exact syntax via
> `Get-Command <cmdlet> -Syntax` / `Get-Help <cmdlet> -Full` against the installed module.
> Do not assume parameters from training data.

To re-run the spike: `pwsh -File scripts/Test-SpoHosting.ps1`

---

## Repo layout

```
M365-migration-tool/
  M365-migration-tool-brief.md   # the build brief
  README.md
  .gitignore
  config/
    config.example.json          # template (committed)
    config.json                  # real values (gitignored — you create this)
  backend/
    server.ps1                   # Pode entrypoint
    api/health.ps1               # /api/health route
    modules/
      Logging.psm1               # JSONL + run-id + correlation-id
      State.psm1                 # SQLite init, migrations, runs, audit
    migrations/001_init.sql      # schema_version, runs, audit_log
  frontend/                      # React + Vite (health dashboard)
  scripts/
    Install-Requirements.ps1     # installs Pode + PSSQLite (+ service modules)
    Test-SpoHosting.ps1          # Phase 0 risk spike
  data/                          # SQLite db + JSONL logs (gitignored, created at runtime)
```

---

## Setup & run

Prerequisites: **PowerShell 7**, **Node.js 18+**, and **git** (all present on the dev box).

```powershell
# 1. Install backend PowerShell modules (Pode + PSSQLite)
pwsh -File scripts/Install-Requirements.ps1

# 2. Create your local config (gitignored) from the template
Copy-Item config/config.example.json config/config.json
#    then fill in tenant IDs / app IDs / cert thumbprints

# 3. Build the frontend (Pode serves the static output)
cd frontend; npm install; npm run build; cd ..

# 4. Start the backend (serves API + frontend on http://127.0.0.1:8080)
pwsh -File backend/server.ps1
```

Open <http://127.0.0.1:8080> — the dashboard shows a green/red backend health indicator.

**Frontend dev mode** (hot reload, proxies `/api` to Pode):

```powershell
# terminal 1
pwsh -File backend/server.ps1
# terminal 2
cd frontend; npm run dev     # http://localhost:5173
```

---

## Guardrails (enforced in code, not just docs)

1. A successful cross-tenant **mailbox** move **deletes the source mailbox** — completion is
   always an explicit, per-batch operator action, gated behind a passing verification step.
2. OneDrive/SharePoint cross-tenant moves are **one-and-done** (no delta passes) — read-only
   window and cutover timing are first-class in the UI.
3. **Snapshot run state to disk** before any destructive/finalizing step; everything resumes
   after a crash.
4. Treat every cross-tenant cmdlet signature as **unverified** until checked against the
   installed module.
5. **No secrets in source control** — `config.json` and `/data` are gitignored; certs live in
   the Windows cert store.
6. **Read-only by default** — preflight, mapping, and validation never mutate either tenant.
