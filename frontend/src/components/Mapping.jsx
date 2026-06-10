import { useEffect, useRef, useState } from 'react'
import { api } from '../api'
import { StatusDot } from './StatusDot'

export function Mapping() {
  const [summary, setSummary] = useState(null)
  const [busy, setBusy] = useState(null)
  const [error, setError] = useState(null)
  const [edits, setEdits] = useState({}) // sourceUpn -> targetUpn
  const fileRef = useRef(null)

  async function load() {
    try {
      setSummary(await api.mappingList())
    } catch (e) {
      setError(String(e))
    }
  }
  useEffect(() => {
    load()
  }, [])

  async function run(label, fn) {
    setBusy(label)
    setError(null)
    try {
      const res = await fn()
      // Most actions return a summary (or {summary}).
      setSummary(res.rows ? res : res.summary ?? (await api.mappingList()))
    } catch (e) {
      setError(String(e))
    } finally {
      setBusy(null)
    }
  }

  async function onImportFile(e) {
    const file = e.target.files?.[0]
    if (!file) return
    const csv = await file.text()
    await run('import', () => api.mappingImportCsv(csv))
    if (fileRef.current) fileRef.current.value = ''
  }

  function setEdit(upn, val) {
    setEdits((m) => ({ ...m, [upn]: val }))
  }

  async function saveEdits() {
    const rows = (summary?.rows ?? [])
      .filter((r) => edits[r.sourceUpn] !== undefined)
      .map((r) => ({ ...r, targetUpn: edits[r.sourceUpn] }))
    if (rows.length === 0) return
    await run('save', () => api.mappingSave(rows))
    setEdits({})
  }

  const rows = summary?.rows ?? []

  return (
    <section>
      <div className="panel-head">
        <h2>Identity Mapping</h2>
      </div>
      <p className="muted">
        Pull users from each tenant via Graph, auto-match on UPN then proxyAddresses, then
        review. Read-only against tenants — edits persist to SQLite only.
      </p>

      <div className="btn-row">
        <button className="btn" disabled={!!busy} onClick={() => run('sync-source', () => api.mappingSync('source'))}>
          {busy === 'sync-source' ? 'Syncing…' : 'Sync source'}
        </button>
        <button className="btn" disabled={!!busy} onClick={() => run('sync-target', () => api.mappingSync('target'))}>
          {busy === 'sync-target' ? 'Syncing…' : 'Sync target'}
        </button>
        <button className="btn primary" disabled={!!busy} onClick={() => run('automatch', () => api.mappingAutoMatch())}>
          {busy === 'automatch' ? 'Matching…' : 'Auto-match'}
        </button>
        <button className="btn" disabled={!!busy} onClick={() => fileRef.current?.click()}>Import CSV</button>
        <input ref={fileRef} type="file" accept=".csv" hidden onChange={onImportFile} />
        <a className="btn" href={api.mappingExportUrl()}>Export CSV</a>
        <button className="btn" disabled={!!busy || Object.keys(edits).length === 0} onClick={saveEdits}>
          Save edits ({Object.keys(edits).length})
        </button>
      </div>

      {error && <p className="error">{error}</p>}

      {summary && (
        <div className="chips">
          <span className="chip"><b>{summary.total}</b> total</span>
          <span className="chip"><StatusDot status="matched" label={`${summary.matched} matched`} /></span>
          <span className="chip"><StatusDot status="unmatched" label={`${summary.unmatched} unmatched`} /></span>
          <span className="chip"><StatusDot status="conflict" label={`${summary.conflict} conflict`} /></span>
          <span className="chip"><StatusDot status="warn" label={`${summary.missingTarget} target missing`} /></span>
        </div>
      )}

      <div className="table-scroll">
        <table className="grid-table">
          <thead>
            <tr>
              <th>State</th>
              <th>Source UPN</th>
              <th>Source name</th>
              <th>Target UPN</th>
              <th>Target exists</th>
              <th>Method</th>
            </tr>
          </thead>
          <tbody>
            {rows.length === 0 && (
              <tr><td colSpan={6} className="muted">No mappings yet. Sync both tenants, then Auto-match.</td></tr>
            )}
            {rows.map((r) => (
              <tr key={r.sourceUpn} className={r.matchState}>
                <td><StatusDot status={r.matchState} /></td>
                <td className="mono">{r.sourceUpn}</td>
                <td>{r.sourceDisplayName}</td>
                <td>
                  <input
                    value={edits[r.sourceUpn] ?? r.targetUpn ?? ''}
                    placeholder="(unmapped)"
                    onChange={(e) => setEdit(r.sourceUpn, e.target.value)}
                  />
                </td>
                <td>{r.targetUpn ? (r.targetExists ? '✓' : <span className="error">missing</span>) : '—'}</td>
                <td className="muted">{r.matchMethod ?? '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}
