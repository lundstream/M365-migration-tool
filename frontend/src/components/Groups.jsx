import { useEffect, useState } from 'react'
import { api } from '../api'
import { StatusDot } from './StatusDot'

const G_DOT = { discovered: 'not-configured', created: 'ok', skipped: 'warn', failed: 'error' }

export function Groups() {
  const [groups, setGroups] = useState([])
  const [sel, setSel] = useState({})
  const [busy, setBusy] = useState(null)
  const [error, setError] = useState(null)

  async function load() {
    try { setGroups((await api.groups()).groups ?? []) } catch (e) { setError(String(e)) }
  }
  useEffect(() => { load() }, [])

  async function sync() {
    setBusy('sync'); setError(null)
    try { await api.groupsSync(); await load() } catch (e) { setError(String(e)) } finally { setBusy(null) }
  }
  async function create() {
    const ids = Object.keys(sel).filter((k) => sel[k])
    if (ids.length === 0) { setError('Select groups to recreate.'); return }
    if (!window.confirm(`Recreate ${ids.length} group(s) in the TARGET tenant and remap membership via the mapping?`)) return
    setBusy('create'); setError(null)
    try { await api.groupsCreate(ids); setSel({}); await load() } catch (e) { setError(String(e)) } finally { setBusy(null) }
  }

  return (
    <section>
      <div className="panel-head">
        <h2>Groups</h2>
        <div className="btn-row" style={{ margin: 0 }}>
          <button className="btn" disabled={!!busy} onClick={sync}>{busy === 'sync' ? 'Syncing…' : 'Sync source groups'}</button>
          <button className="btn primary" disabled={!!busy} onClick={create}>{busy === 'create' ? 'Creating…' : 'Recreate in target'}</button>
        </div>
      </div>
      <p className="muted">
        Groups are recreated in the target (membership remapped via the identity mapping), not
        moved. Security + Microsoft 365 groups are created via Graph; distribution /
        mail-enabled-security groups are flagged (need EXO). Recreate groups <b>before</b>
        SharePoint site moves so group-based permissions resolve.
      </p>
      {error && <p className="error">{error}</p>}

      <div className="table-scroll">
        <table className="grid-table">
          <thead><tr><th></th><th>Status</th><th>Display name</th><th>Kind</th><th>Members</th><th>Detail</th></tr></thead>
          <tbody>
            {groups.length === 0 && <tr><td colSpan={6} className="muted">No groups. Click “Sync source groups”.</td></tr>}
            {groups.map((g) => (
              <tr key={g.groupId}>
                <td><input type="checkbox" disabled={g.kind === 'distribution' || g.kind === 'mailSecurity'} checked={!!sel[g.groupId]} onChange={(e) => setSel((s) => ({ ...s, [g.groupId]: e.target.checked }))} /></td>
                <td><StatusDot status={G_DOT[g.status] ?? 'loading'} label={g.status} /></td>
                <td>{g.displayName}</td>
                <td>{g.kind}</td>
                <td>{g.memberCount}</td>
                <td className="muted small">{g.detail}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}
