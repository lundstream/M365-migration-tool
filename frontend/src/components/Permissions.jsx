import { useEffect, useState } from 'react'
import { api } from '../api'
import { StatusDot } from './StatusDot'

export function Permissions() {
  const [shared, setShared] = useState([])
  const [sel, setSel] = useState({})
  const [perms, setPerms] = useState([])
  const [busy, setBusy] = useState(null)
  const [error, setError] = useState(null)

  async function loadPerms() {
    try { setPerms((await api.permissions()).permissions ?? []) } catch (e) { setError(String(e)) }
  }
  useEffect(() => { loadPerms() }, [])

  async function loadShared() {
    setBusy('shared'); setError(null)
    try { setShared((await api.sharedMailboxes()).mailboxes ?? []) } catch (e) { setError(String(e)) } finally { setBusy(null) }
  }
  async function capture() {
    const ids = Object.keys(sel).filter((k) => sel[k])
    if (ids.length === 0) { setError('Select shared mailboxes to capture.'); return }
    setBusy('capture'); setError(null)
    try { await api.permissionsCapture(ids); await loadPerms() } catch (e) { setError(String(e)) } finally { setBusy(null) }
  }
  async function reapply() {
    if (!window.confirm('Re-apply captured permissions on the TARGET tenant (remapped via mapping)?')) return
    setBusy('reapply'); setError(null)
    try { await api.permissionsReapply(); await loadPerms() } catch (e) { setError(String(e)) } finally { setBusy(null) }
  }

  return (
    <section>
      <div className="panel-head"><h2>Shared mailbox permissions</h2></div>
      <p className="muted">
        Cross-tenant moves don't carry FullAccess / SendAs / SendOnBehalf. Capture them from
        the source, then re-apply on the target (mailbox + trustee remapped via the mapping)
        <b> after</b> the mailbox move.
      </p>
      {error && <p className="error">{error}</p>}

      <div className="btn-row">
        <button className="btn" disabled={!!busy} onClick={loadShared}>{busy === 'shared' ? 'Loading…' : 'List shared mailboxes'}</button>
        <button className="btn" disabled={!!busy} onClick={capture}>{busy === 'capture' ? 'Capturing…' : 'Capture permissions'}</button>
        <button className="btn primary" disabled={!!busy} onClick={reapply}>{busy === 'reapply' ? 'Applying…' : 'Reapply on target'}</button>
      </div>

      {shared.length > 0 && (
        <div className="table-scroll" style={{ maxHeight: '30vh', marginBottom: '1rem' }}>
          <table className="grid-table">
            <thead><tr><th></th><th>Shared mailbox</th><th>Name</th></tr></thead>
            <tbody>
              {shared.map((m) => (
                <tr key={m.upn}>
                  <td><input type="checkbox" checked={!!sel[m.upn]} onChange={(e) => setSel((s) => ({ ...s, [m.upn]: e.target.checked }))} /></td>
                  <td className="mono small">{m.upn}</td>
                  <td>{m.displayName}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <h3 style={{ fontSize: '1rem' }}>Captured permissions</h3>
      <div className="table-scroll">
        <table className="grid-table">
          <thead><tr><th>Reapplied</th><th>Mailbox</th><th>Type</th><th>Trustee</th><th>Error</th></tr></thead>
          <tbody>
            {perms.length === 0 && <tr><td colSpan={5} className="muted">Nothing captured yet.</td></tr>}
            {perms.map((p, i) => (
              <tr key={i}>
                <td><StatusDot status={p.reapplied ? 'ok' : p.error ? 'error' : 'not-configured'} label={p.reapplied ? 'yes' : 'no'} /></td>
                <td className="mono small">{p.mailbox}</td>
                <td>{p.type}</td>
                <td className="mono small">{p.trustee}</td>
                <td className="muted small">{p.error ?? ''}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}
