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

export function MigrationSetup() {
  const [status, setStatus] = useState(null)
  const [busy, setBusy] = useState(null)
  const [error, setError] = useState(null)
  const [lastResult, setLastResult] = useState(null)

  async function loadStatus() {
    setBusy('status'); setError(null)
    try {
      setStatus(await api.migrationSetupStatus())
    } catch (e) { setError(String(e)) } finally { setBusy(null) }
  }
  useEffect(() => { loadStatus() }, [])

  async function create(item) {
    const ok = window.confirm(
      `Create "${LABELS[item]}" in the target tenant?\n\n` +
      `This MUTATES the tenant. A state snapshot is written first; if it already exists it is left unchanged.\nProceed?`
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
            {(it.status === 'missing') && (
              <button className="btn primary" disabled={!!busy} onClick={() => create(it.item)}>
                {busy === it.item ? 'Creating…' : 'Create'}
              </button>
            )}
          </div>
        ))}
        {items.length === 0 && !busy && <p className="muted">No status yet.</p>}
      </div>
    </section>
  )
}
