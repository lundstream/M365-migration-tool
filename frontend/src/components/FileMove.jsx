import { useEffect, useState } from 'react'
import { api } from '../api'
import { StatusDot } from './StatusDot'

const JOB_DOT = {
  created: 'not-configured', validated: 'not-configured', scheduled: 'warn',
  inprogress: 'warn', success: 'ok', failed: 'error', stopped: 'error',
}

export function FileMove() {
  const [mode, setMode] = useState('onedrive')
  const [jobs, setJobs] = useState([])
  const [matched, setMatched] = useState([])
  const [sel, setSel] = useState({})
  const [sitePairs, setSitePairs] = useState([{ source: '', target: '' }])
  const [begin, setBegin] = useState('')
  const [end, setEnd] = useState('')
  const [validation, setValidation] = useState(null)
  const [busy, setBusy] = useState(null)
  const [error, setError] = useState(null)
  const [sourceSites, setSourceSites] = useState(null)
  const [siteResult, setSiteResult] = useState(null)

  async function loadSourceSites() {
    setBusy('sites'); setError(null)
    try { setSourceSites((await api.fileMoveSourceSites()).sites ?? []) }
    catch (e) { setError(String(e)) } finally { setBusy(null) }
  }
  function pickSite(s) {
    setSitePairs([{ source: s.url, target: s.targetUrl }])
    setValidation(null); setSiteResult(null)
  }
  async function siteAction(action) {
    const sourceUrl = sitePairs[0]?.source
    if (!sourceUrl) { setError('Pick a source site first.'); return }
    if (action === 'provision' && !window.confirm(`Create the target in Reformea for:\n${sourceUrl}?`)) return
    if (action === 'migrate' && !window.confirm(
      `Start the cross-tenant move of:\n${sourceUrl}\n\nONE-AND-DONE — no re-runs. Source goes read-only during the move and is redirected after.\nProceed?`)) return
    setBusy(action); setError(null); setSiteResult(null)
    try {
      const body = { sourceUrl, action, confirm: true }
      if (begin) body.preferredBegin = new Date(begin).toISOString()
      if (end) body.preferredEnd = new Date(end).toISOString()
      const r = await api.fileMoveSiteMigrate(body)
      setSiteResult(r)
      if (action === 'migrate' && r.ok) await loadJobs()
    } catch (e) { setError(String(e)) } finally { setBusy(null) }
  }

  async function loadJobs() {
    try { setJobs((await api.fileMoveJobs()).jobs ?? []) } catch (e) { setError(String(e)) }
  }
  useEffect(() => {
    loadJobs()
    api.mappingList().then((s) => setMatched((s.rows ?? []).filter((r) => r.matchState === 'matched' && r.targetUpn))).catch(() => {})
  }, [])

  // Build the list of {source,target} items for the chosen mode.
  function items() {
    if (mode === 'onedrive') {
      return matched.filter((m) => sel[m.sourceUpn]).map((m) => ({ source: m.sourceUpn, target: m.targetUpn }))
    }
    return sitePairs.filter((p) => p.source && p.target)
  }

  async function validateFirst() {
    const list = items()
    if (list.length === 0) { setError('Select/enter at least one item.'); return }
    setBusy('validate'); setError(null)
    try {
      const r = await api.fileMoveValidate(mode, list[0].source, list[0].target)
      setValidation(r)
    } catch (e) { setError(String(e)) } finally { setBusy(null) }
  }

  async function start() {
    const list = items()
    if (list.length === 0) { setError('Select/enter at least one item.'); return }
    const ok = window.confirm(
      `Start ${list.length} ${mode === 'onedrive' ? 'OneDrive' : 'SharePoint site'} move(s)?\n\n` +
      `ONE-AND-DONE: cross-tenant content moves have NO incremental re-runs. Source content goes ` +
      `read-only during the move and the source is redirected to the target afterward.\nProceed?`
    )
    if (!ok) return
    setBusy('start'); setError(null)
    try {
      const body = { type: mode, items: list }
      if (begin) body.preferredBegin = new Date(begin).toISOString()
      if (end) body.preferredEnd = new Date(end).toISOString()
      const res = await api.fileMoveStart(body)
      const failed = res.results.filter((r) => !r.ok)
      if (failed.length) setError(`${failed.length} failed: ${failed.map((f) => `${f.source}: ${f.error}`).join(' | ')}`)
      setValidation(null); setSel({})
      await loadJobs()
    } catch (e) { setError(String(e)) } finally { setBusy(null) }
  }

  async function refresh(id) {
    setBusy(id); setError(null)
    try { await api.fileMoveRefresh(id); await loadJobs() } catch (e) { setError(String(e)) } finally { setBusy(null) }
  }
  async function stop(id) {
    if (!window.confirm('Stop this in-progress move?')) return
    setBusy(id); setError(null)
    try { await api.fileMoveStop(id); await loadJobs() } catch (e) { setError(String(e)) } finally { setBusy(null) }
  }

  return (
    <section>
      <div className="panel-head"><h2>OneDrive &amp; SharePoint moves</h2></div>

      <div className="oneanddone">
        ⚠ <b>One-and-done.</b> Cross-tenant content moves have <b>no incremental/delta passes</b>.
        Plan a read-only window: during the move the source is read-only, and afterward the source
        URL is redirected to the target. A move <b>cannot be re-run</b> for the same source.
      </div>

      <div className="tabs" style={{ margin: '1rem 0' }}>
        <button className={`tab ${mode === 'onedrive' ? 'active' : ''}`} onClick={() => { setMode('onedrive'); setValidation(null) }}>OneDrive accounts</button>
        <button className={`tab ${mode === 'site' ? 'active' : ''}`} onClick={() => { setMode('site'); setValidation(null) }}>SharePoint sites</button>
      </div>

      {error && <p className="error">{error}</p>}

      <div className="card" style={{ marginBottom: '1rem' }}>
        <div className="prov-controls" style={{ marginBottom: '0.75rem' }}>
          <label>Preferred move begin&nbsp;<input type="datetime-local" value={begin} onChange={(e) => setBegin(e.target.value)} /></label>
          <label>Preferred move end&nbsp;<input type="datetime-local" value={end} onChange={(e) => setEnd(e.target.value)} /></label>
        </div>
        <div className="btn-row">
          <button className="btn" disabled={!!busy} onClick={validateFirst}>{busy === 'validate' ? 'Validating…' : 'Validate first item'}</button>
          <button className="btn primary" disabled={!!busy} onClick={start}>{busy === 'start' ? 'Starting…' : 'Start move(s)'}</button>
        </div>
        {validation && (
          <p className={validation.ok ? 'muted small' : 'error'}>
            Validation {validation.ok ? 'OK' : 'failed'} for {validation.source}: {validation.result ?? validation.error}
          </p>
        )}
      </div>

      {/* Source selection */}
      {mode === 'onedrive' ? (
        <div className="table-scroll" style={{ maxHeight: '40vh', marginBottom: '1rem' }}>
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
      ) : (
        <div className="card" style={{ marginBottom: '1rem' }}>
          {/* Source-site picker */}
          <div className="btn-row">
            <button className="btn" disabled={!!busy} onClick={loadSourceSites}>
              {busy === 'sites' ? 'Loading…' : 'Browse source sites'}
            </button>
            <span className="muted small">Pick a source site — the target URL is derived automatically.</span>
          </div>
          {sourceSites && (
            <div className="table-scroll" style={{ maxHeight: '32vh', marginBottom: '0.75rem' }}>
              <table className="grid-table">
                <thead><tr><th></th><th>Source site</th><th>Type</th><th>→ Target URL</th></tr></thead>
                <tbody>
                  {sourceSites.length === 0 && <tr><td colSpan={4} className="muted">No sites found.</td></tr>}
                  {sourceSites.map((s) => (
                    <tr key={s.url} className={sitePairs[0]?.source === s.url ? 'unmatched' : ''}>
                      <td><button className="btn" onClick={() => pickSite(s)}>Pick</button></td>
                      <td className="mono small">{s.url}{s.title ? ` — ${s.title}` : ''}</td>
                      <td>{s.isGroup ? <span style={{ color: '#f9ab00' }}>group</span> : 'site'}</td>
                      <td className="mono small">{s.targetUrl}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          {sitePairs.some((p) => p.source) && sourceSites?.find((s) => s.url === sitePairs[0]?.source)?.isGroup && (
            <p className="error small">
              Heads up: this is a <b>group/Teams-connected site</b>. Group sites need the group
              migration path (target M365 group created first) — plain site move may be rejected
              at validation. Validate first to see.
            </p>
          )}

          {/* Three-step flow for the picked site */}
          {sitePairs[0]?.source && (
            <div style={{ margin: '0.5rem 0' }}>
              <div className="btn-row">
                <button className="btn" disabled={!!busy} onClick={() => siteAction('provision')}>{busy === 'provision' ? '…' : '1 · Provision target'}</button>
                <button className="btn" disabled={!!busy} onClick={() => siteAction('validate')}>{busy === 'validate' ? '…' : '2 · Validate'}</button>
                <button className="btn primary" disabled={!!busy} onClick={() => siteAction('migrate')}>{busy === 'migrate' ? '…' : '3 · Migrate'}</button>
              </div>
              {siteResult && (
                <p className={siteResult.ok ? 'muted small' : 'error'}>
                  {siteResult.detail ?? siteResult.error}
                </p>
              )}
              <p className="muted small">Group sites: Provision creates the target M365 group, then Validate, then Migrate. Wait a few minutes after Provision for the target site to come up.</p>
            </div>
          )}

          {/* Manual / selected pairs */}
          {sitePairs.map((p, i) => (
            <div className="btn-row" key={i}>
              <input className="filter" style={{ flex: 1 }} placeholder="source site URL" value={p.source}
                onChange={(e) => setSitePairs((arr) => arr.map((x, j) => j === i ? { ...x, source: e.target.value } : x))} />
              <input className="filter" style={{ flex: 1 }} placeholder="target site URL (auto-derived)" value={p.target}
                onChange={(e) => setSitePairs((arr) => arr.map((x, j) => j === i ? { ...x, target: e.target.value } : x))} />
            </div>
          ))}
          <button className="btn" onClick={() => setSitePairs((a) => [...a, { source: '', target: '' }])}>+ Add site</button>
        </div>
      )}

      {/* Jobs */}
      <h3 style={{ fontSize: '1rem' }}>Move jobs</h3>
      <div className="table-scroll">
        <table className="grid-table">
          <thead><tr><th>Status</th><th>Type</th><th>Source</th><th>Target</th><th>Redirect</th><th>Window</th><th></th></tr></thead>
          <tbody>
            {jobs.length === 0 && <tr><td colSpan={7} className="muted">No move jobs yet.</td></tr>}
            {jobs.map((j) => (
              <tr key={j.jobId}>
                <td><StatusDot status={JOB_DOT[j.status] ?? 'loading'} label={j.status} /></td>
                <td>{j.type}</td>
                <td className="mono small">{j.source}</td>
                <td className="mono small">{j.target}</td>
                <td className="muted small">{j.redirectStatus ?? '—'}</td>
                <td className="muted small">{j.preferredBegin ? `${j.preferredBegin?.slice(0,16)} → ${j.preferredEnd?.slice(0,16) ?? ''}` : '—'}</td>
                <td>
                  <button className="btn" disabled={busy === j.jobId} onClick={() => refresh(j.jobId)}>Refresh</button>
                  {(j.status === 'inprogress' || j.status === 'scheduled') && (
                    <button className="btn" disabled={busy === j.jobId} onClick={() => stop(j.jobId)}>Stop</button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}
