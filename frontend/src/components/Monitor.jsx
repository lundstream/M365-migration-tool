import { useEffect, useRef, useState } from 'react'
import { api } from '../api'
import { StatusDot } from './StatusDot'

function Bar({ percent, status }) {
  const color = status === 'failed' ? '#d93025' : status === 'success' || status === 'completed' || percent >= 100 ? '#1e8e3e' : '#2563eb'
  return (
    <div className="bar">
      <div className="bar-fill" style={{ width: `${Math.max(0, Math.min(100, percent))}%`, background: color }} />
      <span className="bar-label">{percent}%</span>
    </div>
  )
}

export function Monitor() {
  const [model, setModel] = useState(null)
  const [auto, setAuto] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [error, setError] = useState(null)
  const timer = useRef(null)

  async function load() {
    try { setModel(await api.monitor()); setError(null) } catch (e) { setError(String(e)) }
  }
  async function liveRefresh() {
    setRefreshing(true); setError(null)
    try { setModel(await api.monitorRefresh()) } catch (e) { setError(String(e)) } finally { setRefreshing(false) }
  }

  useEffect(() => { load() }, [])
  useEffect(() => {
    if (auto) { timer.current = setInterval(load, 5000) }
    return () => clearInterval(timer.current)
  }, [auto])

  const s = model?.summary
  const throttling = model?.throttling

  return (
    <section>
      <div className="panel-head">
        <h2>Monitoring</h2>
        <div className="btn-row" style={{ margin: 0 }}>
          <label className="status-pill"><input type="checkbox" checked={auto} onChange={(e) => setAuto(e.target.checked)} /> Auto (5s)</label>
          <button className="btn" onClick={load}>Reload</button>
          <button className="btn primary" disabled={refreshing} onClick={liveRefresh}>{refreshing ? 'Polling cloud…' : 'Live refresh'}</button>
        </div>
      </div>
      <p className="muted">
        Unified view across mailbox batches and OneDrive/SharePoint moves. <b>Reload</b> reads
        cached state; <b>Live refresh</b> polls EXO/SPO for current status.
      </p>

      {error && <p className="error">{error}</p>}

      {s && (
        <div className="chips">
          <span className="chip"><b>{s.total}</b> items</span>
          <span className="chip"><StatusDot status="warn" label={`${s.inProgress} in progress`} /></span>
          <span className="chip"><StatusDot status="ok" label={`${s.done} done`} /></span>
          <span className="chip"><StatusDot status="error" label={`${s.failed} failed`} /></span>
          {throttling?.active
            ? <span className="chip" style={{ borderColor: '#f9ab00' }}><StatusDot status="warn" label="Throttled — backing off" /></span>
            : <span className="chip muted">no throttling</span>}
        </div>
      )}

      {/* Mailbox batches */}
      <h3 style={{ fontSize: '1rem' }}>Mailbox batches</h3>
      {(model?.mailboxBatches ?? []).length === 0 && <p className="muted small">No mailbox batches.</p>}
      {(model?.mailboxBatches ?? []).map((b) => (
        <div className="card" key={b.batchId} style={{ marginBottom: '0.75rem' }}>
          <div className="card-head">
            <h3 style={{ fontSize: '0.95rem', margin: 0 }}>{b.name} <span className="tag">{b.status}</span></h3>
            <span className="muted small">{b.itemCount} items</span>
          </div>
          <Bar percent={b.percent} status={b.status} />
          <div className="table-scroll" style={{ marginTop: '0.5rem', maxHeight: '30vh' }}>
            <table className="grid-table">
              <thead><tr><th>Status</th><th>Source</th><th>Progress</th><th>ETA</th></tr></thead>
              <tbody>
                {b.items.map((it) => (
                  <tr key={it.source}>
                    <td><StatusDot status={it.status === 'synced' || it.status === 'completed' ? 'ok' : it.status === 'failed' ? 'error' : 'warn'} label={it.status} /></td>
                    <td className="mono small">{it.source}</td>
                    <td style={{ minWidth: 140 }}><Bar percent={it.percent} status={it.status} /></td>
                    <td className="muted small">{it.eta ?? '—'}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      ))}

      {/* File moves */}
      <h3 style={{ fontSize: '1rem', marginTop: '1rem' }}>OneDrive / SharePoint moves</h3>
      <div className="table-scroll">
        <table className="grid-table">
          <thead><tr><th>Status</th><th>Kind</th><th>Source</th><th>Progress</th><th>Redirect</th></tr></thead>
          <tbody>
            {(model?.fileMoves ?? []).length === 0 && <tr><td colSpan={5} className="muted">No move jobs.</td></tr>}
            {(model?.fileMoves ?? []).map((j) => (
              <tr key={j.jobId}>
                <td><StatusDot status={j.status === 'success' ? 'ok' : j.status === 'failed' || j.status === 'stopped' ? 'error' : 'warn'} label={j.status} /></td>
                <td>{j.kind}</td>
                <td className="mono small">{j.source}</td>
                <td style={{ minWidth: 140 }}><Bar percent={j.percent} status={j.status} /></td>
                <td className="muted small">{j.redirectStatus ?? '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}
