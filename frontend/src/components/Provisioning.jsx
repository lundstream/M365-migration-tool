import { useEffect, useMemo, useState } from 'react'
import { api } from '../api'
import { StatusDot } from './StatusDot'

function downloadCsv(filename, rows) {
  const esc = (v) => `"${String(v ?? '').replace(/"/g, '""')}"`
  const header = Object.keys(rows[0])
  const body = rows.map((r) => header.map((h) => esc(r[h])).join(','))
  const csv = [header.join(','), ...body].join('\r\n')
  const url = URL.createObjectURL(new Blob([csv], { type: 'text/csv' }))
  const a = document.createElement('a')
  a.href = url
  a.download = filename
  a.click()
  URL.revokeObjectURL(url)
}

export function Provisioning() {
  const [users, setUsers] = useState([])
  const [domains, setDomains] = useState([])
  const [domain, setDomain] = useState('')
  const [selected, setSelected] = useState({}) // upn -> true
  const [filter, setFilter] = useState('')
  const [pwMode, setPwMode] = useState('random')
  const [sharedPw, setSharedPw] = useState('')
  const [forceChange, setForceChange] = useState(true)
  const [addToGroups, setAddToGroups] = useState(false)
  const [plan, setPlan] = useState(null)
  const [creds, setCreds] = useState(null) // execute result incl. one-time passwords
  const [latest, setLatest] = useState(null)
  const [busy, setBusy] = useState(null)
  const [error, setError] = useState(null)

  async function load() {
    setError(null)
    try {
      const u = await api.mappingUsers('source')
      setUsers(u.users ?? [])
    } catch (e) { setError(String(e)) }
    try {
      const d = await api.provisioningDomains()
      setDomains(d.domains ?? [])
      const def = (d.domains ?? []).find((x) => x.isDefault) ?? (d.domains ?? [])[0]
      if (def) setDomain(def.id)
    } catch { /* target Graph may be unconfigured; user can still type */ }
    try {
      const l = await api.provisioningLatest()
      setLatest(l?.empty ? null : l)
    } catch { /* ignore */ }
  }
  useEffect(() => { load() }, [])

  const filtered = useMemo(() => {
    const f = filter.toLowerCase()
    return users.filter((u) => !f || u.upn?.toLowerCase().includes(f) || u.display_name?.toLowerCase().includes(f))
  }, [users, filter])

  const selectedUpns = Object.keys(selected).filter((k) => selected[k])
  const allFilteredSelected = filtered.length > 0 && filtered.every((u) => selected[u.upn])

  function toggleAll() {
    const next = { ...selected }
    const target = !allFilteredSelected
    filtered.forEach((u) => { next[u.upn] = target })
    setSelected(next)
  }

  async function preview() {
    setBusy('preview'); setError(null); setCreds(null)
    try {
      const body = { sourceUpns: selectedUpns, targetDomain: domain }
      const res = await api.provisioningPreview(body)
      setPlan(res.plan ?? [])
    } catch (e) { setError(String(e)) } finally { setBusy(null) }
  }

  async function execute() {
    const toCreate = (plan ?? []).filter((p) => !p.willSkip).length
    if (toCreate === 0) { setError('Nothing to create — preview shows no eligible users.'); return }
    if (pwMode === 'shared' && !sharedPw) { setError('Enter a shared password first.'); return }
    const ok = window.confirm(
      `Create ${toCreate} MailUser(s) in the TARGET tenant on @${domain}.\n\n` +
      `This MUTATES the target tenant. Existing accounts are skipped.\nProceed?`
    )
    if (!ok) return
    setBusy('execute'); setError(null)
    try {
      const body = {
        confirm: true, sourceUpns: selectedUpns, targetDomain: domain,
        passwordMode: pwMode, sharedPassword: pwMode === 'shared' ? sharedPw : undefined,
        forceChange, addToGroups,
      }
      const res = await api.provisioningExecute(body)
      setCreds(res)
      setPlan(null)
      const l = await api.provisioningLatest()
      setLatest(l?.empty ? null : l)
    } catch (e) { setError(String(e)) } finally { setBusy(null) }
  }

  const createdWithPw = (creds?.results ?? []).filter((r) => r.status === 'created' && r.password)

  return (
    <section>
      <div className="panel-head">
        <h2>Provisioning — target MailUsers</h2>
      </div>
      <p className="muted">
        Create mail-enabled users in the <b>target</b> tenant from selected source users —
        same info, new <code>name@{domain || 'target-domain'}</code>, temporary password.
        Creates MailUsers (no mailbox), the object the cross-tenant mailbox move expects.
        <b> This is the first mutating feature</b> — preview, then confirm.
      </p>

      {error && <p className="error">{error}</p>}

      {/* Controls */}
      <div className="card" style={{ marginBottom: '1rem' }}>
        <div className="prov-controls">
          <label>Target domain&nbsp;
            <select value={domain} onChange={(e) => setDomain(e.target.value)}>
              {domains.length === 0 && <option value="">(connect target Graph)</option>}
              {domains.map((d) => (
                <option key={d.id} value={d.id}>{d.id}{d.isDefault ? ' (default)' : ''}</option>
              ))}
            </select>
          </label>
          <fieldset className="pw-fieldset">
            <label><input type="radio" checked={pwMode === 'random'} onChange={() => setPwMode('random')} /> Random per user</label>
            <label><input type="radio" checked={pwMode === 'shared'} onChange={() => setPwMode('shared')} /> Shared</label>
            {pwMode === 'shared' && (
              <input type="text" placeholder="shared temp password" value={sharedPw} onChange={(e) => setSharedPw(e.target.value)} />
            )}
            <label><input type="checkbox" checked={forceChange} onChange={(e) => setForceChange(e.target.checked)} /> Force change at first sign-in</label>
            <label><input type="checkbox" checked={addToGroups} onChange={(e) => setAddToGroups(e.target.checked)} /> Add to mapped target groups</label>
          </fieldset>
        </div>
        <div className="btn-row">
          <button className="btn" disabled={!!busy || selectedUpns.length === 0 || !domain} onClick={preview}>
            {busy === 'preview' ? 'Building…' : `Preview (${selectedUpns.length})`}
          </button>
          <button className="btn primary" disabled={!!busy || !plan} onClick={execute}>
            {busy === 'execute' ? 'Creating…' : 'Create in target'}
          </button>
        </div>
      </div>

      {/* One-time credentials */}
      {creds && (
        <div className="card cred-card">
          <div className="card-head">
            <h3>Created — passwords shown once</h3>
            <button className="btn" disabled={createdWithPw.length === 0} onClick={() =>
              downloadCsv('credentials.csv', createdWithPw.map((r) => ({ TargetUpn: r.targetUpn, Password: r.password })))
            }>Download credentials CSV</button>
          </div>
          <div className="chips">
            <span className="chip"><StatusDot status="ok" label={`${creds.created} created`} /></span>
            <span className="chip"><StatusDot status="not-configured" label={`${creds.skipped} skipped`} /></span>
            <span className="chip"><StatusDot status="error" label={`${creds.failed} failed`} /></span>
          </div>
          <p className="muted small">Passwords are not stored on the server. Capture them now.</p>
          <div className="table-scroll">
            <table className="grid-table">
              <thead><tr><th>Status</th><th>Target UPN</th><th>Password</th><th>Reason</th></tr></thead>
              <tbody>
                {creds.results.map((r, i) => (
                  <tr key={i}>
                    <td><StatusDot status={r.status === 'created' ? 'ok' : r.status === 'failed' ? 'error' : 'not-configured'} label={r.status} /></td>
                    <td className="mono">{r.targetUpn}</td>
                    <td className="mono">{r.password ?? '—'}</td>
                    <td className="muted">{r.reason ?? ''}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* Preview plan */}
      {plan && (
        <div className="table-scroll" style={{ marginBottom: '1rem' }}>
          <table className="grid-table">
            <thead><tr><th></th><th>Source UPN</th><th>New UPN</th><th>External address</th><th>Action</th></tr></thead>
            <tbody>
              {plan.map((p) => (
                <tr key={p.sourceUpn} className={p.willSkip ? 'unmatched' : ''}>
                  <td>{p.willSkip ? '⏭' : '➕'}</td>
                  <td className="mono">{p.sourceUpn}</td>
                  <td className="mono">{p.newUpn}</td>
                  <td className="mono">{p.externalEmailAddress}</td>
                  <td className="muted">{p.willSkip ? (p.targetExists ? 'skip — exists' : 'skip — source not found') : 'create'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {/* Source user selection */}
      <div className="panel-head">
        <h3 style={{ fontSize: '1rem', margin: 0 }}>Source users</h3>
        <input className="filter" placeholder="filter…" value={filter} onChange={(e) => setFilter(e.target.value)} />
      </div>
      {users.length === 0 && <p className="muted">No cached source users. Go to Identity Mapping and “Sync source” first.</p>}
      <div className="table-scroll">
        <table className="grid-table">
          <thead>
            <tr>
              <th><input type="checkbox" checked={allFilteredSelected} onChange={toggleAll} /></th>
              <th>UPN</th><th>Display name</th>
            </tr>
          </thead>
          <tbody>
            {filtered.map((u) => (
              <tr key={u.upn}>
                <td><input type="checkbox" checked={!!selected[u.upn]} onChange={(e) => setSelected((s) => ({ ...s, [u.upn]: e.target.checked }))} /></td>
                <td className="mono">{u.upn}</td>
                <td>{u.display_name}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {latest && !creds && (
        <p className="muted small" style={{ marginTop: '0.75rem' }}>
          Last run {latest.runId}: {latest.created} created, {latest.skipped} skipped, {latest.failed} failed
          (on @{latest.targetDomain}).
        </p>
      )}
    </section>
  )
}
