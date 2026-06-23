import { useEffect, useState } from 'react'
import { api } from '../api'
import { StatusDot } from './StatusDot'

const LABELS = {
  endpoint: 'Migration endpoint (target EXO)',
  orgRelationship: 'Organization relationship (mailbox move)',
  spoRelationship: 'SPO cross-tenant relationship',
}

const STATUS_DOT = {
  present: 'ok',
  missing: 'warn',
  error: 'error',
  'not-configured': 'not-configured',
  created: 'ok',
  skipped: 'not-configured',
  failed: 'error',
}

// Editable migration settings (label + hint + which workload they apply to).
const CONFIG_FIELDS = [
  { key: 'migrationAppId', label: 'Migration app (client) ID', hint: 'Mailbox moves. The Reformea app with Mailbox.Migration, consented in Formea.' },
  { key: 'appSecretKeyVaultUrl', label: 'App secret — Key Vault URL', hint: 'Mailbox moves. Azure Key Vault secret URL for the migration app secret.' },
  { key: 'scopeGroupSmtp', label: 'Source scope group (SMTP)', hint: 'Mailbox moves. Mail-enabled security group in Formea listing migratable mailboxes.' },
  { key: 'targetDeliveryDomain', label: 'Target delivery domain', hint: 'Mailbox moves. e.g. reformeaorg.mail.onmicrosoft.com' },
  { key: 'endpointName', label: 'Migration endpoint name', hint: 'Mailbox moves.' },
  { key: 'organizationRelationshipName', label: 'Org relationship name', hint: 'Mailbox moves.' },
  { key: 'spoScenario', label: 'SPO scenario', hint: 'SharePoint moves. Usually MnA.' },
]

export function MigrationSetup() {
  const [status, setStatus] = useState(null)
  const [busy, setBusy] = useState(null)
  const [error, setError] = useState(null)
  const [lastResult, setLastResult] = useState(null)
  const [cfg, setCfg] = useState(null)
  const [cfgSaved, setCfgSaved] = useState(false)

  async function loadStatus() {
    setBusy('status'); setError(null)
    try {
      setStatus(await api.migrationSetupStatus())
    } catch (e) { setError(String(e)) } finally { setBusy(null) }
  }
  async function loadConfig() {
    try { setCfg(await api.migrationConfig()) } catch (e) { setError(String(e)) }
  }
  async function saveConfig() {
    setBusy('cfg'); setError(null); setCfgSaved(false)
    try { const r = await api.migrationConfigSave(cfg); setCfg(r.config); setCfgSaved(true) }
    catch (e) { setError(String(e)) } finally { setBusy(null) }
  }
  useEffect(() => { loadStatus(); loadConfig() }, [])

  async function create(item) {
    const ok = window.confirm(
      `Run "${LABELS[item]}" setup?\n\n` +
      `This MUTATES the tenant(s). A state snapshot is written first. The SPO relationship is ` +
      `(re-)established on both tenants; the endpoint/org-relationship are left unchanged if they already exist.\nProceed?`
    )
    if (!ok) return
    setBusy(item); setError(null); setLastResult(null)
    try {
      const res = await api.migrationSetupCreate(item)
      setLastResult(res.result)
      await loadStatus()
    } catch (e) { setError(String(e)) } finally { setBusy(null) }
  }

  const items = status?.items ?? []

  return (
    <section>
      <div className="panel-head">
        <h2>Migration setup</h2>
        <button className="btn" onClick={loadStatus} disabled={!!busy}>
          {busy === 'status' ? 'Detecting…' : 'Re-detect'}
        </button>
      </div>
      <p className="muted">
        Detect-then-create the cross-tenant prerequisites. <b>Gated mutations begin here.</b>
        Existing prerequisites are reported and left untouched; each create writes a state
        snapshot first and is audited. EXO create cmdlets are verified at runtime and abort
        safely if the live signature differs (set overrides in <code>config.migration</code>).
      </p>

      {error && <p className="error">{error}</p>}

      {/* Editable migration settings (saved to config.json) */}
      {cfg && (
        <div className="card" style={{ marginBottom: '1rem' }}>
          <h3 style={{ marginTop: 0, fontSize: '1rem' }}>Settings</h3>
          <p className="muted small">
            Saved to <code>config/config.json</code>. The <b>migration app</b> + scope group +
            Key Vault secret are only needed for <b>mailbox</b> moves; SharePoint needs none of them.
          </p>
          <div className="cfg-grid">
            {CONFIG_FIELDS.map((f) => (
              <label key={f.key} className="cfg-field">
                <span className="cfg-label">{f.label}</span>
                <input
                  className="filter"
                  value={cfg[f.key] ?? ''}
                  placeholder={f.hint}
                  onChange={(e) => { setCfg((c) => ({ ...c, [f.key]: e.target.value })); setCfgSaved(false) }}
                />
                <span className="muted" style={{ fontSize: '0.72rem' }}>{f.hint}</span>
              </label>
            ))}
          </div>
          <div className="btn-row">
            <button className="btn primary" disabled={busy === 'cfg'} onClick={saveConfig}>
              {busy === 'cfg' ? 'Saving…' : 'Save settings'}
            </button>
            {cfgSaved && <span className="status-pill"><StatusDot status="ok" label="Saved" /></span>}
          </div>
        </div>
      )}

      {lastResult && (
        <div className="card" style={{ marginBottom: '1rem', borderColor: lastResult.status === 'failed' ? '#d93025' : '#1e8e3e' }}>
          <div className="status-row">
            <StatusDot status={STATUS_DOT[lastResult.status] ?? 'loading'} label={`${LABELS[lastResult.item] ?? lastResult.item}: ${lastResult.status}`} />
          </div>
          <p className="muted small" style={{ marginTop: '0.5rem' }}>{lastResult.detail}</p>
          {lastResult.planned && (
            <pre className="planned">{JSON.stringify(lastResult.planned, null, 2)}</pre>
          )}
        </div>
      )}

      <div className="tenant-grid">
        {items.map((it) => (
          <div className="card" key={it.item}>
            <div className="card-head">
              <h3 style={{ fontSize: '0.95rem' }}>{LABELS[it.item] ?? it.item}</h3>
              <StatusDot status={STATUS_DOT[it.status] ?? 'loading'} label={it.status} />
            </div>
            <div className="muted small mono" style={{ margin: '0.4rem 0' }}>{it.name}</div>
            <p className="muted small">{it.detail}</p>
            {(it.status === 'missing' || it.status === 'present') && (
              <button className="btn primary" disabled={!!busy} onClick={() => create(it.item)}>
                {busy === it.item ? 'Working…' : (it.status === 'missing' ? 'Create' : 'Re-run / re-establish')}
              </button>
            )}
          </div>
        ))}
        {items.length === 0 && !busy && <p className="muted">No status yet.</p>}
      </div>
    </section>
  )
}
