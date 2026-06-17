# M365 Cross-Tenant Migration Tool — Build Brief

> Drop this file in the repo root (`C:\Dev\Powershell\M365-migration-tool\BRIEF.md`).
> Feed Claude Code the **master context** once, then paste **one phase prompt at a time**.
> After each phase, review and commit before moving on.

---

## 1. Context & goal

A local Windows app for **two admins** to run a one-off-style cross-tenant Microsoft 365 migration (mailboxes, OneDrive, SharePoint sites) with bulk user/site support, good logging, and clear reporting.

This tool is an **orchestration + UX layer**. It does **not** copy data itself. Microsoft's Mailbox Replication Service (MRS) and the SharePoint Online cross-tenant engine perform the actual moves in-cloud. Our job is identity mapping, preflight validation, batching, scheduling, monitoring, reporting, and safe cutover.

Runs locally on a Windows machine. No multi-user server, no cloud hosting, no auth beyond the operator already being on the box.

## 2. Non-negotiable guardrails

These are the reason the tool exists rather than raw cmdlets. Enforce them in code, not just docs.

1. **A successful cross-tenant mailbox move DELETES the source mailbox.** Never auto-finalize. Mailbox completion must be an explicit, per-batch operator action that is only enabled *after* a verification step passes.
2. **OneDrive/SharePoint cross-tenant moves are one-and-done** — no incremental/delta passes. Cutover timing and the read-only window must be first-class in the UI, never implicit.
3. **Snapshot run state to disk before any destructive or finalizing step.** Every long-running operation must be resumable after a crash or restart.
4. **Treat every cross-tenant cmdlet signature as unverified.** Before using `New-MigrationEndpoint`, `New-MigrationBatch`, `Set-SPOCrossTenantRelationship`, the SPO content-move cmdlets, etc., confirm exact parameter names against the installed module via `Get-Help <cmdlet> -Full` / `Get-Command <cmdlet> -Syntax`. Do not assume parameters from training data.
5. **No secrets in source control.** App IDs, cert thumbprints, tenant IDs live in a gitignored local config; certs in the Windows cert store. `.gitignore` from day one.
6. **Idempotent + read-only by default.** Preflight, mapping, and validation never mutate either tenant. Mutating operations are explicitly gated.

## 3. Stack decision

- **Backend:** PowerShell 7 hosting a local HTTP API via **Pode** (`localhost` only). Cmdlets run **in-process** (no shelling-out / output parsing) using `ExchangeOnlineManagement`, the SharePoint admin module, and `Microsoft.Graph` SDK.
- **Frontend:** **React 18 + Vite** SPA (your daily driver), built to static files and served by Pode from `localhost`. Talks to the Pode API over JSON.
- **State:** **SQLite** (via `PSSQLite` or System.Data.SQLite) for run/batch/item state, mapping tables, and audit trail. Survives restarts; enables resume.
- **Logging:** structured **JSONL** per run, plus a human-readable run log. Reports render off SQLite + JSONL.

*Alt if you want zero Node:* swap the React frontend for **Pode.Web** (pure-PowerShell UI). Less polish, simpler toolchain. Backend is unchanged either way.

## 4. KNOWN RISK to resolve in Phase 0 (do not skip)

The **SharePoint Online Management Shell** (`Microsoft.Online.SharePoint.PowerShell`) has historically been **Windows PowerShell 5.1-only** and will not load inside a PS7 process. The cross-tenant SPO relationship and content-move cmdlets live in that module. Pode and `ExchangeOnlineManagement` run on PS7.

Phase 0 must determine the current state of play and pick one:
- (a) the SPO module now supports PS7 → use directly; or
- (b) it's still 5.1-only → run SPO operations through a **Windows PowerShell 5.1 sidecar** (separate process invoked from the PS7 backend, results returned as JSON); or
- (c) prefer Graph / PnP.PowerShell where an equivalent cross-tenant capability exists.

Verify against the actually-installed modules before committing to an approach.

## 5. Repo structure (target)

```
M365-migration-tool/
  BRIEF.md
  .gitignore
  README.md
  config/
    config.example.json        # template, committed
    config.json                # real values, gitignored
  backend/
    server.ps1                 # Pode entrypoint
    modules/
      Connections.psm1          # auth: Graph (app-only cert), EXO, SPO
      Mapping.psm1              # identity mapping + CSV
      Preflight.psm1           # read-only validation
      MigrationSetup.psm1      # endpoints / org relationship / SPO relationship
      MailboxMove.psm1         # New-MigrationBatch orchestration
      FileMove.psm1            # OneDrive + SharePoint content moves
      Monitor.psm1             # polling / status
      Reporting.psm1           # summaries + exports
      State.psm1               # SQLite + JSONL helpers
      Logging.psm1
    api/                       # Pode route definitions, one file per resource
  frontend/                    # React + Vite
  data/                        # SQLite db + JSONL logs (gitignored)
  scripts/                     # setup helpers (module install checks, cert helpers)
```

## 6. Conventions

- Every API mutation returns a correlation ID; every log line carries run ID + correlation ID.
- All cmdlet calls wrapped with throttling-aware retry honoring `Retry-After`; bounded concurrency (configurable cap, default low).
- Errors are captured per-item with the original exception message and the cmdlet that failed — surfaced in reports, never swallowed.
- PowerShell: `Set-StrictMode -Version Latest`, approved verbs, `#requires` headers, comment-based help on exported functions.

---

# PHASED BUILD PLAN

Each phase below is a standalone prompt. Paste the master context (sections 1–6) plus the phase. Build, review, commit, repeat.

## Phase 0 — Scaffold + risk spike
```
Scaffold the repo per the structure in BRIEF.md section 5. Set up:
- .gitignore (config.json, /data, node_modules, build output)
- config.example.json with placeholders for source/target tenant IDs, app (client) IDs, cert thumbprints, SPO admin URLs.
- A Pode server (backend/server.ps1) serving a health endpoint and the static frontend dir.
- A minimal React+Vite app that fetches /api/health and shows green/red.
- State.psm1 + Logging.psm1: SQLite init (schema migrations folder), JSONL writer, run-id generator.

Then do the SPO hosting RISK SPIKE from BRIEF.md section 4: detect installed PowerShell versions and modules, determine whether the SharePoint Online cross-tenant cmdlets are available in PS7 or require a 5.1 sidecar, and write your finding + chosen approach into README.md. Do not build the SPO move logic yet — just resolve the integration approach.
```

## Phase 1 — Connection manager (read-only)
```
Implement Connections.psm1 and its API routes. App-only certificate auth to Microsoft Graph for BOTH source and target tenants; authenticated Exchange Online and SharePoint admin sessions. Provide a connection-health endpoint that reports, per tenant, whether Graph / EXO / SPO connect successfully and which identity is in use. Surface this as a connections panel in the React UI (per-tenant, per-service status). No mutations anywhere. Persist non-secret connection config to config.json; never log secrets.
Verify exact module names/auth params against the installed modules before coding.
```

## Phase 2 — Identity mapping
```
Implement Mapping.psm1 + UI. Pull users from source and target via Graph. Support CSV import of an explicit mapping. Auto-match candidates on UPN and proxyAddresses. Render an editable mapping grid: matched / unmatched / conflict (duplicate target match) states clearly flagged. Persist mappings to SQLite. Export the current mapping to CSV. This is read-only against both tenants. Include validation that flags target users that don't exist yet (needed later as MailUsers).
```

## Phase 3 — Preflight engine (read-only) + report
```
Implement Preflight.psm1 + UI + first real report. For a selected mapping set, validate (read-only):
- target MailUser objects exist with the attributes cross-tenant moves require,
- the Cross Tenant User Data Migration add-on is assigned where needed,
- no source mailbox is on any hold (those are blocked from moving),
- the migration endpoint / organization relationship is present,
- the SPO cross-tenant relationship is present.
Produce a preflight report (on-screen + exportable HTML/CSV) listing per-user/per-site PASS/WARN/BLOCK with reasons. This report is the tool's most valuable safe output — make it clean and complete. Verify each check's cmdlet/Graph call against installed modules.
```

## Phase 4 — Migration setup (gated mutations begin)
```
Implement MigrationSetup.psm1 + UI. DETECT-then-CREATE the prerequisites: migration endpoint, organization relationship with mailbox-move capability, and the SPO cross-tenant relationship. If a prerequisite already exists, report it and do nothing. Creation is an explicit operator action behind a confirmation, with a state snapshot written before each change. Confirm exact cmdlet syntax (New-MigrationEndpoint, organization relationship cmdlets, Set-SPOCrossTenantRelationship and friends) via Get-Command -Syntax before use.
```

## Phase 5 — Mailbox batch executor (DESTRUCTIVE on finalize)
```
Implement MailboxMove.psm1 + UI. Queue-based executor wrapping New-MigrationBatch for cross-tenant moves: bounded concurrency, throttling-aware retry honoring Retry-After, per-item correlation IDs, full resume-after-crash via SQLite state.
CRITICAL per BRIEF.md guardrails: starting a batch syncs data but must NOT auto-complete. Completion (which deletes the source mailbox) is a SEPARATE explicit operator action, enabled only after a verification step confirms the target mailbox looks good. Snapshot state before completion. Make the destructive nature unmissable in the UI.
Function to setup forwarding rules from source to target mailboxes.
```

## Phase 6 — OneDrive + SharePoint moves
```
Implement FileMove.psm1 + UI using the approach chosen in Phase 0 (direct PS7 or 5.1 sidecar). Support bulk OneDrive account moves and SharePoint site moves. Because these are one-and-done with no delta passes, make the read-only window and cutover timing explicit in the UI: clear pre-move confirmation, status of the source redirect, and a per-item record that the move cannot be re-run incrementally. Resume/track via SQLite.
```

## Phase 7 — Monitoring / polling
```
Implement Monitor.psm1 + a live status view. Poll mailbox batch status (Get-MigrationBatch / Get-MigrationUser stats) and SPO move job status on an interval, normalize into one progress model, and stream to the UI. Show per-batch and per-item progress, current throttling state, and ETAs where available. Confirm stat cmdlet shapes against installed modules.
```

## Phase 8 — Reporting, logging, audit
```
Implement Reporting.psm1 + reports UI. From SQLite + JSONL produce: per-run summary, per-user/per-site status, failures with reasons and the failing cmdlet, and a full audit trail of every mutating action (who/when/what, correlation IDs). Exportable as CSV and self-contained HTML. Add a final post-migration reconciliation report comparing intended mappings vs actual completed moves.
```

## Phase 9 — Groups, backup and restore
```
How do we handle groups, can we migrate them and use same permissions on share point sites? Can we auto populate groups when users are created? How do we handle backup and restore before doing any migrations? Need backup/restore for: Mailboxes, onedrive, sharepoint sites. How do we handle shared mailboxes and permissions to those?
```

## Phase 10 — GUI, reporting part 2 and user manuals
```
Clean up GUI with a logical flow, starting with what to do first to the left and what to do last to the right. Maybe "step 1: x" with a under menu that have "step 1.1: y", "step 1.2: z" etc.
A function to generate a PDF-report for the customer on what was done in the project when it's finnished and all migrations are done.
Manuals in Swedish on what the end-users have to do to change tenant. (both for mac/windows and iPhone/android)
```

---

## Suggested git checkpoints
Commit after each phase. Tag `v0.1-preflight` after Phase 3 — at that point you have a genuinely useful, completely non-destructive tool (connections + mapping + preflight reporting) even if you go no further.
