# Tenant setup guide

What you must configure in the **source** and **target** Microsoft 365 tenants before this
tool is useful. There are two distinct categories — don't conflate them:

- **Part A — Auth the tool needs.** App registrations + certificates so the tool can sign in
  app-only to Graph, Exchange Online, and SharePoint admin in *each* tenant. Needed from
  **Phase 1** onward. This is fully under your control and documented precisely below.
- **Part B — Cross-tenant migration prerequisites.** Licensing, trust/relationships, and
  object provisioning that the *migration itself* requires. Some of this the tool detects
  and (from Phase 4) creates for you; some are admin-only prerequisites. Exact cmdlet
  syntax and license names here **must be verified against current Microsoft docs and
  `Get-Command <cmdlet> -Syntax`** before use (project guardrail #4) — treat the commands
  below as a checklist, not copy-paste truth.

Legend: 🟢 = do on **source**, 🔵 = do on **target**, ⚪ = do on **both**.

---

## Part A — App registration + certificate (per tenant)

The tool authenticates **app-only with a certificate**. Do this once per tenant. You may
register one app per tenant covering all three services, or split per service — the
`config.json` schema allows a different `appId` / `certThumbprint` per service if you want
least-privilege separation.

### A1. Create a certificate ⚪

On the machine that will run the tool:

```powershell
pwsh -File scripts/New-MigrationCertificate.ps1 -Name "M365Migration-Source"   # for source
pwsh -File scripts/New-MigrationCertificate.ps1 -Name "M365Migration-Target"   # for target
```

The private key stays in `CurrentUser\My`; only the `.cer` (public key) is exported for
upload. Note each printed **thumbprint**.

### A2. Register an Entra application ⚪

Entra admin center → **Identity → Applications → App registrations → New registration**.
Name it (e.g. `M365 Migration Tool`), single tenant, no redirect URI. Note the
**Application (client) ID** and the **Directory (tenant) ID**.

### A3. Upload the certificate ⚪

App registration → **Certificates & secrets → Certificates → Upload certificate** → the
`.cer` for that tenant.

### A4. Grant API permissions (Application permissions, then **admin consent**) ⚪

| Service | API → Application permission | Used for |
|---|---|---|
| Microsoft Graph | `User.Read.All` | pull users for identity mapping (Phase 2) |
| Microsoft Graph | `Organization.Read.All` (or `Directory.Read.All`) | subscribed SKUs for the add-on check (Phase 3) |
| Office 365 Exchange Online | `Exchange.ManageAsApp` | app-only EXO connection |
| SharePoint | `Sites.FullControl.All` | SPO admin + cross-tenant relationship cmdlets |

After adding, click **Grant admin consent for &lt;tenant&gt;**.

### A5. Give the app an Exchange role ⚪

`Exchange.ManageAsApp` only grants *access*; the app's service principal still needs a
**directory role** for what it does:

- **Read-only now (Phases 1–3):** assign **Global Reader** (or *Exchange Recipient
  Administrator*). Enough for `Get-Mailbox` / `Get-MailUser` / connection health.
- **Mutating later (Phases 4–5):** assign **Exchange Administrator** (mailbox moves,
  migration endpoint, organization relationship).

Entra → **Roles and administrators** → pick the role → **Add assignment** → select the app.

### A6. Fill in `config/config.json` ⚪

Copy the template and enter the non-secret values (the cert private key is referenced only
by thumbprint and never stored here):

```powershell
Copy-Item config/config.example.json config/config.json
```

For each tenant set `tenantId`, and per service `appId`, `certThumbprint`, plus
`exchangeOnline.organization` (e.g. `contoso.onmicrosoft.com`) and
`sharePoint.adminUrl` (e.g. `https://contoso-admin.sharepoint.com`).

### A7. Verify ⚪

Start the backend and open the **Connections** tab (or `GET /api/connections/health`).
Each service should report **connected** with the app identity. Fix any `error` rows before
moving on. Nothing here mutates either tenant.

---

## Part B — Cross-tenant migration prerequisites

> The tool's **Phase 4** will *detect-then-create* the organization relationship, migration
> endpoint, and SPO cross-tenant relationship. The items marked **(admin prerequisite)**
> below are **not** created by the tool and must exist first. Verify every cmdlet's exact
> syntax with `Get-Command <name> -Syntax` against your installed modules before running it.

### B1. Mailbox (Exchange Online) cross-tenant moves

Microsoft's cross-tenant mailbox migration model (MRS-based) requires:

- **(admin prerequisite) 🔵 Licensing:** assign the **Cross-tenant user data migration**
  add-on on the target for each migrating user. *(Confirm the exact SKU/part number in your
  tenant — the tool's preflight matches loosely and flags WARN until verified.)*
- **(admin prerequisite) 🔵 Migration application:** register an Entra app in the **target**
  tenant that the Mailbox Replication Service uses to pull from source, and **🟢 consent to
  it in the source** tenant. (This is separate from the tool's own app in Part A.)
- **(admin prerequisite) 🟢 Scope group:** a mail-enabled security group in the **source**
  listing the mailboxes permitted to migrate; referenced by the organization relationship.
- **🔵🟢 Organization relationship** between the two tenants with **mailbox-move capability**
  enabled on both sides. *(Tool creates/validates in Phase 4.)*
- **🔵 Migration endpoint** on the target of the cross-tenant remote-move type.
  *(Tool creates/validates in Phase 4.)*
- **(admin prerequisite) 🔵 Target MailUsers:** each migrating user must exist in the target
  as a **MailUser** with the cross-tenant attributes set (matching `ExchangeGuid`,
  `ArchiveGuid` if applicable, the source `LegacyExchangeDN` carried as an `X500` proxy, and
  a `targetAddress`/`ExternalEmailAddress` pointing at the source routing address). *(Tool
  preflight checks existence; provisioning is on you.)*
- **(admin prerequisite) 🟢 No holds:** source mailboxes on litigation/in-place/retention
  hold are **blocked** from moving. The tool's preflight flags these as **BLOCK**.

> ⚠️ **Destructive step (Phase 5):** completing a cross-tenant mailbox batch **deletes the
> source mailbox**. The tool never auto-completes — completion is a separate, explicit,
> per-batch operator action gated behind verification.

### B2. OneDrive / SharePoint cross-tenant moves

- **🔵🟢 SPO cross-tenant relationship / trust** between the tenants
  (`Set-SPOCrossTenantRelationship` and friends — verify syntax live). *(Tool
  creates/validates in Phase 4.)*
- **⚪ Identity mapping** complete (Phase 2) so source principals resolve to target ones.
- **🔵 Target users/sites provisioned** to receive the content.

> ⚠️ **One-and-done (Phase 6):** OneDrive/SharePoint cross-tenant moves have **no
> incremental/delta passes**. Plan the read-only window and cutover; a move cannot be
> re-run incrementally.

---

## Quick checklist

**Both tenants (Part A — for the tool to connect):**
- [ ] Certificate created; `.cer` uploaded to the app registration
- [ ] App registration created; client ID + tenant ID recorded
- [ ] Graph `User.Read.All` + `Organization.Read.All` (admin-consented)
- [ ] EXO `Exchange.ManageAsApp` (admin-consented) + directory role assigned
- [ ] SharePoint `Sites.FullControl.All` (admin-consented)
- [ ] `config/config.json` filled in
- [ ] Connections tab all green

**Migration prerequisites (Part B — before Phase 4+):**
- [ ] 🔵 Cross-tenant user data migration add-on assigned (mailboxes)
- [ ] 🔵 Target MailUsers provisioned with cross-tenant attributes
- [ ] 🔵 Migration app registered; 🟢 consented in source
- [ ] 🟢 Source scope security group created
- [ ] 🟢 Source mailboxes off all holds
- [ ] 🔵🟢 Organization relationship (mailbox move) — or let Phase 4 create it
- [ ] 🔵🟢 SPO cross-tenant relationship — or let Phase 4 create it
