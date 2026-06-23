import { useEffect, useRef, useState } from 'react'
import { api } from '../api'
import { StatusDot } from './StatusDot'

const DOT = { created: 'not-configured', running: 'warn', completed: 'ok', failed: 'error' }
function fmtBytes(n) { if (!n) return '0'; const u = ['B', 'KB', 'MB', 'GB']; let i = 0, v = Number(n); while (v >= 1024 && i < 3) { v /= 1024; i++ } return `${v.toFixed(1)} ${u[i]}` }

export function FileCopy() {
  const [mode, setMode] = useState('onedrive')
  const [matched, setMatched] = useState([])
  const [sel, setSel] = useState({})
  const [sites, setSites] = useState(null)
  const [sitePair, setSitePair] = useState({ source: '', target: '' })
  const [jobs, setJobs] = useState([])
  const [busy, setBusy] = useState(null)
  const [error, setError] = useState(null)
  const timer = useRef(null)

  async function loadJobs() { try { setJobs((await api.fileCopyJobs()).jobs ?? []) } catch (e) { setError(String(e)) } }
  useEffect(() => {
    api.mappingList().then((s) => setMatched((s.rows ?? []).filter((r) => r.matchState === 'matched' && r.targetUpn))).catch(() => {})
    loadJobs(); timer.current = setInterval(loadJobs, 4000)
    return () => clearInterval(timer.current)
  }, [])

  async function loadSites() {
    setBusy('sites'); setError(null)
    try { setSites((await api.fileMoveSourceSites()).sites ?? []) } catch (e) { setError(String(e)) } finally { setBusy(null) }
  }

  async function startOneDrive() {
    const users = matched.filter((m) => sel[m.sourceUpn])
    if (users.length === 0) { setError('Pick at least one matched user.'); return }
    if (!window.confirm(`Copy OneDrive files for ${users.length} user(s)? Source is read-only; target OneDrive must be provisioned (licensed).`)) return
    setBusy('start'); setError(null)
    try { for (const m of users) await api.fileCopyStart('onedrive', m.sourceUpn, m.targetUpn); await loadJobs() }
    catch (e) { setError(String(e)) } finally { setBusy(null) }
  }
  async function startSite() {
    if (!sitePair.source || !sitePair.target) { setError('Source and target site URLs required.'); return }
    if (!window.confirm(`Copy document-library files\n${sitePair.source}\n→ ${sitePair.target}\n\nTarget site must already exist. Source read-only. Proceed?`)) return
    setBusy('start'); setError(null)
    try { await api.fileCopyStart('site', sitePair.source, sitePair.target); await loadJobs() }
    catch (e) { setError(String(e)) } finally { setBusy(null) }
  }

  return (
    <section>
      <div className="panel-head"><h2>File copy (Graph)</h2></div>
      <p className="muted">
        Copy-based OneDrive / SharePoint migration via Graph — <b>no Azure, source untouched</b>.
        Copies files + folders. <b>Files only</b> — sharing/permissions are not copied (access resets to target defaults).
      </p>
      <div className="oneanddone">
        ℹ Requires Graph <b>application</b> permissions (admin-consented): source
        <code>Files.Read.All</code> / <code>Sites.Read.All</code>; target
        <code>Files.ReadWrite.All</code> / <code>Sites.ReadWrite.All</code>.
        OneDrive: the target user's OneDrive must be provisioned (licensed).
      </div>

      {error && <p className="error">{error}</p>}

      <div className="tabs" style={{ margin: '1rem 0' }}>
        <button className={`tab ${mode === 'onedrive' ? 'active' : ''}`} onClick={() => setMode('onedrive')}>OneDrive (per user)</button>
        <button className={`tab ${mode === 'site' ? 'active' : ''}`} onClick={() => setMode('site')}>SharePoint site files</button>
      </div>

      {mode === 'onedrive' ? (
        <div className="card" style={{ marginBottom: '1rem' }}>
          <div className="btn-row"><button className="btn primary" disabled={!!busy} onClick={startOneDrive}>{busy === 'start' ? 'Starting…' : `Copy OneDrive (${Object.values(sel).filter(Boolean).length})`}</button></div>
          <div className="table-scroll" style={{ maxHeight: '40vh' }}>
            <table className="grid-table">
              <thead><tr><th></th><th>Source UPN</th><th>Target UPN</th></tr></thead>
              <tbody>
                {matched.length === 0 && <tr><td colSpan={3} className="muted">No matched users. Complete Identity Mapping first.</td></tr>}
                {matched.map((m) => (
                  <tr key={m.sourceUpn}>
                    <td><input type="checkbox" checked={!!sel[m.sourceUpn]} onChange={(e) => setSel((s) => ({ ...s, [m.sourceUpn]: e.target.checked }))} /></td>
                    <td className="mono small">{m.sourceUpn}</td><td className="mono small">{m.targetUpn}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      ) : (
        <div className="card" style={{ marginBottom: '1rem' }}>
          <div className="btn-row"><button className="btn" disabled={!!busy} onClick={loadSites}>{busy === 'sites' ? 'Loading…' : 'Browse source sites'}</button></div>
          {sites && (
            <div className="table-scroll" style={{ maxHeight: '30vh', marginBottom: '0.5rem' }}>
              <table className="grid-table">
                <thead><tr><th></th><th>Source site</th><th>→ Target URL</th></tr></thead>
                <tbody>
                  {sites.map((s) => (
                    <tr key={s.url} className={sitePair.source === s.url ? 'unmatched' : ''}>
                      <td><button className="btn" onClick={() => setSitePair({ source: s.url, target: s.targetUrl })}>Pick</button></td>
                      <td className="mono small">{s.url}</td><td className="mono small">{s.targetUrl}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          <div className="btn-row">
            <input className="filter" style={{ flex: 1 }} placeholder="source site URL" value={sitePair.source} onChange={(e) => setSitePair((p) => ({ ...p, source: e.target.value }))} />
            <input className="filter" style={{ flex: 1 }} placeholder="target site URL (must exist)" value={sitePair.target} onChange={(e) => setSitePair((p) => ({ ...p, target: e.target.value }))} />
          </div>
          <div className="btn-row"><button className="btn primary" disabled={!!busy} onClick={startSite}>{busy === 'start' ? 'Starting…' : 'Copy site files'}</button></div>
          <p className="muted small">Copies the default document library. The target site must already exist.</p>
        </div>
      )}

      <h3 style={{ fontSize: '1rem' }}>Copy jobs</h3>
      <div className="table-scroll">
        <table className="grid-table">
          <thead><tr><th>Status</th><th>Type</th><th>Source → Target</th><th>Phase</th><th>Files</th><th>Size</th></tr></thead>
          <tbody>
            {jobs.length === 0 && <tr><td colSpan={6} className="muted">No copy jobs yet.</td></tr>}
            {jobs.map((j) => (
              <tr key={j.jobId}>
                <td><StatusDot status={DOT[j.status] ?? 'loading'} label={j.status} /></td>
                <td>{j.type}</td>
                <td className="mono small">{j.source}<br />→ {j.target}</td>
                <td className="muted small">{j.phase ?? '—'}{j.error ? ` · ${j.error}` : ''}</td>
                <td>{j.filesDone}/{j.filesTotal}</td>
                <td className="muted small">{fmtBytes(j.bytesTotal)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}
