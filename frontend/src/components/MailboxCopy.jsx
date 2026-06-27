import { useEffect, useRef, useState } from 'react'
import { api } from '../api'
import { StatusDot } from './StatusDot'

const DOT = { created: 'not-configured', running: 'warn', completed: 'ok', failed: 'error', stopped: 'error' }

function Bar({ done, total, label }) {
  const pct = total > 0 ? Math.round((done / total) * 100) : 0
  return (
    <div className="bar" style={{ minWidth: 120 }}>
      <div className="bar-fill" style={{ width: `${pct}%`, background: pct >= 100 ? '#1e8e3e' : '#2563eb' }} />
      <span className="bar-label">{label ?? `${done}/${total}`}</span>
    </div>
  )
}

function elapsedSince(iso) {
  if (!iso) return null
  const ms = Date.now() - new Date(iso).getTime()
  if (ms < 0 || !isFinite(ms)) return null
  const s = Math.floor(ms / 1000), m = Math.floor(s / 60), h = Math.floor(m / 60)
  return h > 0 ? `${h}h${m % 60}m` : m > 0 ? `${m}m${s % 60}s` : `${s}s`
}
function ratePerMin(count, iso) {
  if (!iso || !count) return null
  const min = (Date.now() - new Date(iso).getTime()) / 60000
  if (min <= 0.05) return null
  return Math.round(count / min)
}

export function MailboxCopy() {
  const [matched, setMatched] = useState([])
  const [pick, setPick] = useState('')
  const [scope, setScope] = useState({ mail: true, calendar: true, contacts: true })
  const [jobs, setJobs] = useState([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState(null)
  const [keepCopy, setKeepCopy] = useState(true)
  const [fwd, setFwd] = useState(null) // last forwarding result
  const [policy, setPolicy] = useState(null) // { autoForwardingMode }
  const timer = useRef(null)

  async function loadPolicy() {
    try { setPolicy(await api.mailboxCopyForwardingPolicy()) } catch { /* source EXO may be down; ignore */ }
  }
  async function allowExternalForwarding() {
    if (!window.confirm('Allow external auto-forwarding on the SOURCE tenant (AutoForwardingMode = On)?\n\nThis lets forwarded mail leave the old tenant to the new addresses. It is a source-tenant policy change.')) return
    setBusy(true); setError(null)
    try { setPolicy(await api.mailboxCopySetForwardingPolicy('On')) } catch (e) { setError(String(e)) } finally { setBusy(false) }
  }

  async function loadJobs() {
    try { setJobs((await api.mailboxCopyJobs()).jobs ?? []) } catch (e) { setError(String(e)) }
  }
  useEffect(() => {
    api.mappingList().then((s) => setMatched((s.rows ?? []).filter((r) => r.matchState === 'matched' && r.targetUpn))).catch(() => {})
    loadJobs(); loadPolicy()
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

  // Cutover forwarding. `pick` (if set) scopes to one user; otherwise all matched users.
  async function forward(remove) {
    const one = matched.find((x) => x.sourceUpn === pick)
    const scopeUsers = one ? [one] : matched
    const who = one ? one.sourceUpn : `ALL ${matched.length} matched users`
    const verb = remove ? 'REMOVE forwarding from' : 'Forward new mail from'
    if (scopeUsers.length === 0) { setError('No matched users.'); return }
    if (!window.confirm(
      `${verb} the SOURCE mailbox(es):\n${who}\n\n${remove ? 'Source mailboxes stop forwarding.' : `New mail → the target address.${keepCopy ? ' A copy is also kept in the old mailbox.' : ' No copy kept in the old mailbox.'}`}\n\nThis MODIFIES the source tenant. Proceed?`)) return
    setBusy(true); setError(null); setFwd(null)
    try {
      const body = { keepCopy, remove }
      if (one) body.sourceUpns = [one.sourceUpn]
      setFwd(await api.mailboxCopyForwarding(body))
    } catch (e) { setError(String(e)) } finally { setBusy(false) }
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

      <div className="card" style={{ margin: '1rem 0' }}>
        <div className="panel-head" style={{ marginBottom: '0.3rem' }}><h3 style={{ fontSize: '1rem', margin: 0 }}>Cutover forwarding</h3></div>
        <p className="muted small" style={{ marginTop: 0 }}>
          Server-side forwarding on the <b>source</b> mailbox → the matched target address, so new
          mail lands in the new tenant. Admin-set (not a user inbox rule). Applies to the user picked
          above, or <b>all matched users</b> if none is picked. Reversible.
        </p>
        {policy && policy.autoForwardingMode && policy.autoForwardingMode !== 'On' && (
          <div className="oneanddone" style={{ borderColor: '#b45309', background: 'rgba(180,83,9,0.12)' }}>
            ⚠ The source tenant blocks external forwarding (AutoForwardingMode =
            <b> {policy.autoForwardingMode}</b>), so forwarded mail to the new addresses is dropped.
            <div className="btn-row" style={{ marginTop: '0.4rem' }}>
              <button className="btn primary" disabled={busy} onClick={allowExternalForwarding}>Allow external forwarding (set On)</button>
            </div>
            <span className="muted small">Policy changes can take up to ~1 hour to take effect across Exchange Online.</span>
          </div>
        )}
        {policy && policy.autoForwardingMode === 'On' && (
          <p className="muted small">External forwarding policy: <b>On</b> ✓ (forwarded mail can leave the source tenant).</p>
        )}
        <div className="btn-row" style={{ alignItems: 'center' }}>
          <label><input type="checkbox" checked={keepCopy} onChange={(e) => setKeepCopy(e.target.checked)} /> Keep a copy in the old mailbox too</label>
        </div>
        <div className="btn-row">
          <button className="btn primary" disabled={busy || matched.length === 0} onClick={() => forward(false)}>
            {busy ? 'Working…' : pick ? 'Set forwarding (1 user)' : `Set forwarding (all ${matched.length})`}
          </button>
          <button className="btn" disabled={busy || matched.length === 0} onClick={() => forward(true)}>Remove forwarding</button>
        </div>
        {fwd && (
          <div className="table-scroll" style={{ maxHeight: '30vh', marginTop: '0.5rem' }}>
            <table className="grid-table">
              <thead><tr><th>Source</th><th>Result</th><th>Detail</th></tr></thead>
              <tbody>
                {(fwd.results ?? []).map((r) => (
                  <tr key={r.sourceUpn} className={r.status === 'failed' ? 'unmatched' : ''}>
                    <td className="mono small">{r.sourceUpn}</td>
                    <td><StatusDot status={r.status === 'failed' ? 'error' : 'ok'} label={r.status} /></td>
                    <td className="muted small">{r.target ? `→ ${r.target}` : ''}{r.reason ? r.reason : ''}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      <h3 style={{ fontSize: '1rem' }}>Copy jobs</h3>
      <div className="table-scroll">
        <table className="grid-table">
          <thead><tr><th>Status</th><th>Source → Target</th><th>Activity</th><th>Mail (↓ / ↑)</th><th>Calendar</th><th>Contacts</th></tr></thead>
          <tbody>
            {jobs.length === 0 && <tr><td colSpan={6} className="muted">No copy jobs yet.</td></tr>}
            {jobs.map((j) => {
              const active = j.status === 'running'
              const upRate = ratePerMin(j.mail.done, j.startedUtc)
              return (
              <tr key={j.jobId}>
                <td>
                  <StatusDot status={DOT[j.status] ?? 'loading'} label={j.status} />
                  {j.startedUtc && <div className="muted small">{elapsedSince(j.startedUtc)}{upRate ? ` · ${upRate}/min` : ''}</div>}
                </td>
                <td className="mono small">{j.sourceUpn}<br/>→ {j.targetUpn}</td>
                <td className="muted small" style={{ maxWidth: 220 }}>
                  <b>{j.phase ?? '—'}</b>{active ? ' ⏳' : ''}<br />
                  {j.error ? <span className="error">{j.error}</span> : (j.detail ?? '—')}
                </td>
                <td>
                  <Bar done={j.mail.downloaded} total={j.mail.total} label={`↓ ${j.mail.downloaded}/${j.mail.total}`} />
                  <Bar done={j.mail.done} total={Math.max(j.mail.downloaded, j.mail.done)} label={`↑ ${j.mail.done}`} />
                  {j.mail.skipped > 0 && <div className="muted small">skipped {j.mail.skipped} (already there)</div>}
                </td>
                <td><Bar done={j.events.done} total={j.events.total} />{j.events.skipped > 0 && <div className="muted small">skip {j.events.skipped}</div>}</td>
                <td><Bar done={j.contacts.done} total={j.contacts.total} />{j.contacts.skipped > 0 && <div className="muted small">skip {j.contacts.skipped}</div>}</td>
              </tr>
            )})}
          </tbody>
        </table>
      </div>
    </section>
  )
}
