import { useEffect, useState } from 'react'
import { api } from '../api'
import { StatusDot } from './StatusDot'

const ITEM_DOT = {
  queued: 'not-configured', syncing: 'warn', synced: 'ok',
  completing: 'warn', completed: 'ok', failed: 'error', stopped: 'error',
}

function CreateBatch({ onCreated }) {
  const [name, setName] = useState('')
  const [matched, setMatched] = useState([])
  const [sel, setSel] = useState({})
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  useEffect(() => {
    api.mappingList()
      .then((s) => setMatched((s.rows ?? []).filter((r) => r.matchState === 'matched' && r.targetUpn)))
      .catch((e) => setError(String(e)))
  }, [])

  const selected = matched.filter((m) => sel[m.sourceUpn])

  async function create() {
    if (!name.trim()) { setError('Enter a batch name.'); return }
    if (selected.length === 0) { setError('Select at least one matched user.'); return }
    setBusy(true); setError(null)
    try {
      const items = selected.map((m) => ({ sourceUpn: m.sourceUpn, targetUpn: m.targetUpn }))
      const res = await api.mailboxBatchCreate(name.trim(), items)
      onCreated(res.batch)
    } catch (e) { setError(String(e)) } finally { setBusy(false) }
  }

  return (
    <div className="card" style={{ marginBottom: '1rem' }}>
      <h3 style={{ marginTop: 0, fontSize: '1rem' }}>New batch (sync only — does not complete)</h3>
      {error && <p className="error">{error}</p>}
      <div className="btn-row">
        <input className="filter" placeholder="batch name" value={name} onChange={(e) => setName(e.target.value)} />
        <button className="btn primary" disabled={busy} onClick={create}>{busy ? 'Creating…' : `Create & start (${selected.length})`}</button>
      </div>
      <p className="muted small">Only <b>matched</b> mappings with a target are eligible.</p>
      <div className="table-scroll" style={{ maxHeight: '40vh' }}>
        <table className="grid-table">
          <thead><tr><th></th><th>Source UPN</th><th>Target UPN</th></tr></thead>
          <tbody>
            {matched.length === 0 && <tr><td colSpan={3} className="muted">No matched mappings. Complete Identity Mapping first.</td></tr>}
            {matched.map((m) => (
              <tr key={m.sourceUpn}>
                <td><input type="checkbox" checked={!!sel[m.sourceUpn]} onChange={(e) => setSel((s) => ({ ...s, [m.sourceUpn]: e.target.checked }))} /></td>
                <td className="mono">{m.sourceUpn}</td>
                <td className="mono">{m.targetUpn}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}

function CompletePanel({ batch, ready, onDone }) {
  const [token, setToken] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  const tokenOk = token === batch.name
  const canComplete = ready?.ready && tokenOk

  async function complete() {
    const sure = window.confirm(
      `FINAL CONFIRMATION\n\nCompleting "${batch.name}" will DELETE the source mailboxes for ` +
      `${batch.itemCount} user(s). This is IRREVERSIBLE.\n\nProceed?`
    )
    if (!sure) return
    setBusy(true); setError(null)
    try {
      await api.mailboxBatchComplete(batch.batchId, token)
      onDone()
    } catch (e) { setError(String(e)) } finally { setBusy(false) }
  }

  return (
    <div className="danger-zone">
      <div className="danger-head">⚠ Complete batch — DELETES source mailboxes</div>
      <p className="small">
        Completion finalizes the move and <b>permanently deletes the source mailbox</b> for every
        user in this batch. There is no undo. Only proceed during your planned cutover, after the
        target mailboxes are verified.
      </p>
      {!ready?.ready && (
        <p className="small"><StatusDot status="warn" label={`Not ready: ${ready?.reason ?? 'verifying…'}`} /></p>
      )}
      {error && <p className="error">{error}</p>}
      <div className="btn-row">
        <input
          className="filter"
          placeholder={`type "${batch.name}" to confirm`}
          value={token}
          onChange={(e) => setToken(e.target.value)}
          disabled={!ready?.ready}
        />
        <button className="btn danger" disabled={!canComplete || busy} onClick={complete}>
          {busy ? 'Completing…' : 'Complete & DELETE source'}
        </button>
      </div>
    </div>
  )
}

function BatchDetail({ batchId, onBack }) {
  const [data, setData] = useState(null)
  const [busy, setBusy] = useState(null)
  const [error, setError] = useState(null)

  async function load() {
    try { setData(await api.mailboxBatch(batchId)) } catch (e) { setError(String(e)) }
  }
  useEffect(() => { load() }, [batchId])

  async function refresh() {
    setBusy('refresh'); setError(null)
    try { await api.mailboxBatchRefresh(batchId); await load() }
    catch (e) { setError(String(e)) } finally { setBusy(null) }
  }
  async function forwarding() {
    if (!window.confirm('Set forwarding on the SOURCE mailboxes to the target addresses?')) return
    setBusy('fwd'); setError(null)
    try { await api.mailboxBatchForwarding(batchId); await load() }
    catch (e) { setError(String(e)) } finally { setBusy(null) }
  }

  if (!data?.batch) return <p className="muted">Loading…</p>
  const b = data.batch

  return (
    <section>
      <div className="panel-head">
        <h2><button className="btn" onClick={onBack}>← Batches</button> &nbsp; {b.name}</h2>
        <StatusDot status={ITEM_DOT[b.status] ?? 'loading'} label={b.status} />
      </div>
      {error && <p className="error">{error}</p>}
      <div className="btn-row">
        <button className="btn" disabled={!!busy} onClick={refresh}>{busy === 'refresh' ? 'Refreshing…' : 'Refresh status'}</button>
        <button className="btn" disabled={!!busy} onClick={forwarding}>{busy === 'fwd' ? 'Setting…' : 'Set source→target forwarding'}</button>
      </div>

      <div className="table-scroll">
        <table className="grid-table">
          <thead><tr><th>Status</th><th>%</th><th>Source UPN</th><th>Target UPN</th><th>Fwd</th><th>EXO status</th></tr></thead>
          <tbody>
            {b.items.map((it) => (
              <tr key={it.sourceUpn}>
                <td><StatusDot status={ITEM_DOT[it.status] ?? 'loading'} label={it.status} /></td>
                <td>{it.percent ?? '—'}</td>
                <td className="mono">{it.sourceUpn}</td>
                <td className="mono">{it.targetUpn}</td>
                <td>{it.forwardingSet ? '✓' : '—'}</td>
                <td className="muted small">{it.exoStatus ?? ''}{it.error ? ` · ${it.error}` : ''}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <CompletePanel batch={b} ready={data.readyToComplete} onDone={load} />
    </section>
  )
}

export function MailboxMove() {
  const [batches, setBatches] = useState([])
  const [openId, setOpenId] = useState(null)
  const [creating, setCreating] = useState(false)
  const [error, setError] = useState(null)

  async function load() {
    try { setBatches((await api.mailboxBatches()).batches ?? []) } catch (e) { setError(String(e)) }
  }
  useEffect(() => { load() }, [])

  if (openId) return <BatchDetail batchId={openId} onBack={() => { setOpenId(null); load() }} />

  return (
    <section>
      <div className="panel-head">
        <h2>Mailbox moves</h2>
        <button className="btn primary" onClick={() => setCreating((v) => !v)}>{creating ? 'Close' : 'New batch'}</button>
      </div>
      <p className="muted">
        Cross-tenant mailbox batches. Creating a batch <b>only syncs</b> data — it never
        completes. Completion is a separate, gated action that <b>deletes the source mailbox</b>.
      </p>
      {error && <p className="error">{error}</p>}

      {creating && <CreateBatch onCreated={(b) => { setCreating(false); load(); setOpenId(b.batchId) }} />}

      <div className="table-scroll">
        <table className="grid-table">
          <thead><tr><th>Status</th><th>Name</th><th>Items</th><th>Created</th><th></th></tr></thead>
          <tbody>
            {batches.length === 0 && <tr><td colSpan={5} className="muted">No batches yet.</td></tr>}
            {batches.map((b) => (
              <tr key={b.batchId}>
                <td><StatusDot status={ITEM_DOT[b.status] ?? 'loading'} label={b.status} /></td>
                <td>{b.name}</td>
                <td>{b.itemCount}</td>
                <td className="muted small">{b.createdUtc}</td>
                <td><button className="btn" onClick={() => setOpenId(b.batchId)}>Open</button></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}
