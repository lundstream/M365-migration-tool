import { useEffect, useRef, useState } from 'react'
import { api } from '../api'
import { StatusDot } from './StatusDot'

const DOT = { created: 'not-configured', running: 'warn', completed: 'ok', failed: 'error', stopped: 'error' }

function Bar({ done, total }) {
  const pct = total > 0 ? Math.round((done / total) * 100) : 0
  return (
    <div className="bar" style={{ minWidth: 120 }}>
      <div className="bar-fill" style={{ width: `${pct}%`, background: pct >= 100 ? '#1e8e3e' : '#2563eb' }} />
      <span className="bar-label">{done}/{total}</span>
    </div>
  )
}

export function MailboxCopy() {
  const [matched, setMatched] = useState([])
  const [pick, setPick] = useState('')
  const [scope, setScope] = useState({ mail: true, calendar: true, contacts: true })
  const [jobs, setJobs] = useState([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const timer = useRef(null)

  async function loadJobs() {
    try { setJobs((await api.mailboxCopyJobs()).jobs ?? []) } catch (e) { setError(String(e)) }
  }
  useEffect(() => {
    api.mappingList().then((s) => setMatched((s.rows ?? []).filter((r) => r.matchState === 'matched' && r.targetUpn))).catch(() => {})
    loadJobs()
    timer.current = setInterval(loadJobs, 4000)
    return () => clearInterval(timer.current)
  }, [])

  async function start() {
    const m = matched.find((x) => x.sourceUpn === pick)
    if (!m) { setError('Pick a matched user.'); return }
    const sc = Object.entries(scope).filter(([, v]) => v).map(([k]) => k).join(',')
    if (!sc) { setError('Select at least one of mail/calendar/contacts.'); return }
    if (!window.confirm(
      `Copy ${sc} from\n${m.sourceUpn}\n→ ${m.targetUpn}\n\nThe SOURCE is read-only and untouched. The target must be a licensed mailbox. Proceed?`)) return
    setBusy(true); setError(null)
    try { await api.mailboxCopyStart(m.sourceUpn, m.targetUpn, sc); await loadJobs() }
    catch (e) { setError(String(e)) } finally { setBusy(false) }
  }

  return (
    <section>
      <div className="panel-head"><h2>Mailbox copy (Graph)</h2></div>
      <p className="muted">
        Copy-based migration via Microsoft Graph — <b>no Azure, no Key Vault, no add-on licence</b>,
        and the <b>source mailbox is never touched</b>. Copies mail (as MIME), calendar, and contacts
        into the target's <b>licensed</b> mailbox. Runs in the background; progress updates live.
      </p>
      <div className="oneanddone">
        ℹ Requires Graph <b>application</b> permissions (admin-consented): source app
        <code>Mail.Read, Calendars.Read, Contacts.Read</code>; target app
        <code>Mail.ReadWrite, Calendars.ReadWrite, Contacts.ReadWrite</code>. The target user must be licensed.
      </div>

      {error && <p className="error">{error}</p>}

      <div className="card" style={{ margin: '1rem 0' }}>
        <div className="prov-controls">
          <label>User&nbsp;
            <select value={pick} onChange={(e) => setPick(e.target.value)}>
              <option value="">— pick a matched user —</option>
              {matched.map((m) => <option key={m.sourceUpn} value={m.sourceUpn}>{m.sourceUpn} → {m.targetUpn}</option>)}
            </select>
          </label>
          <fieldset className="pw-fieldset">
            {['mail', 'calendar', 'contacts'].map((k) => (
              <label key={k}><input type="checkbox" checked={scope[k]} onChange={(e) => setScope((s) => ({ ...s, [k]: e.target.checked }))} /> {k}</label>
            ))}
          </fieldset>
        </div>
        <div className="btn-row">
          <button className="btn primary" disabled={busy || !pick} onClick={start}>{busy ? 'Starting…' : 'Start copy'}</button>
        </div>
        {matched.length === 0 && <p className="muted small">No matched users. Sync + Auto-match in Identity Mapping first.</p>}
      </div>

      <h3 style={{ fontSize: '1rem' }}>Copy jobs</h3>
      <div className="table-scroll">
        <table className="grid-table">
          <thead><tr><th>Status</th><th>Source → Target</th><th>Phase</th><th>Mail</th><th>Calendar</th><th>Contacts</th></tr></thead>
          <tbody>
            {jobs.length === 0 && <tr><td colSpan={6} className="muted">No copy jobs yet.</td></tr>}
            {jobs.map((j) => (
              <tr key={j.jobId}>
                <td><StatusDot status={DOT[j.status] ?? 'loading'} label={j.status} /></td>
                <td className="mono small">{j.sourceUpn}<br/>→ {j.targetUpn}</td>
                <td className="muted small">{j.phase ?? '—'}{j.error ? ` · ${j.error}` : ''}</td>
                <td><Bar done={j.mail.done} total={j.mail.total} /></td>
                <td><Bar done={j.events.done} total={j.events.total} /></td>
                <td><Bar done={j.contacts.done} total={j.contacts.total} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}
