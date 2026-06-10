import { useEffect, useState } from 'react'
import { api } from '../api'

function fmtBytes(n) {
  if (!n) return '—'
  const u = ['B', 'KB', 'MB', 'GB', 'TB']
  let i = 0, v = Number(n)
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++ }
  return `${v.toFixed(1)} ${u[i]}`
}

export function Manifest() {
  const [data, setData] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)

  async function load() {
    try { setData(await api.manifest()) } catch (e) { setError(String(e)) }
  }
  useEffect(() => { load() }, [])

  async function capture() {
    if (!window.confirm('Capture a pre-migration inventory snapshot from the SOURCE tenant? (read-only)')) return
    setBusy(true); setError(null)
    try { await api.manifestCapture(['mailboxes', 'onedrive', 'sites']); await load() }
    catch (e) { setError(String(e)) } finally { setBusy(false) }
  }

  const latest = data?.latest
  const items = latest?.items ?? []

  return (
    <section>
      <div className="panel-head">
        <h2>Pre-migration manifest</h2>
        <button className="btn primary" disabled={busy} onClick={capture}>{busy ? 'Capturing…' : 'Capture snapshot'}</button>
      </div>
      <div className="oneanddone">
        ℹ <b>This is an inventory snapshot, not a content backup.</b> A cross-tenant tool can't
        back up mailbox/OneDrive/SharePoint content — the real restore path is keeping the
        <b> source tenant intact</b> through a retention window. This manifest records what
        existed (sizes, counts, URLs) to prove no data loss and feed reconciliation.
      </div>

      {error && <p className="error">{error}</p>}

      {latest && (
        <div className="chips" style={{ marginTop: '1rem' }}>
          <span className="chip mono small">{latest.manifestId}</span>
          <span className="chip"><b>{latest.mailboxCount}</b> mailboxes</span>
          <span className="chip"><b>{latest.oneDriveCount}</b> OneDrive</span>
          <span className="chip"><b>{latest.siteCount}</b> sites</span>
          <span className="chip muted">{latest.createdUtc}</span>
        </div>
      )}

      <div className="table-scroll">
        <table className="grid-table">
          <thead><tr><th>Kind</th><th>Identity</th><th>Name</th><th>Size</th><th>Items</th></tr></thead>
          <tbody>
            {items.length === 0 && <tr><td colSpan={5} className="muted">No manifest yet. Capture a snapshot before migrating.</td></tr>}
            {items.map((it, i) => (
              <tr key={i}>
                <td>{it.kind}</td>
                <td className="mono small">{it.identity}</td>
                <td>{it.displayName}</td>
                <td>{fmtBytes(it.sizeBytes)}</td>
                <td>{it.itemCount ?? '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}
