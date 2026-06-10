import { useEffect, useState } from 'react'
import { api } from '../api'
import { StatusDot } from './StatusDot'

export function Preflight() {
  const [report, setReport] = useState(null)
  const [running, setRunning] = useState(false)
  const [error, setError] = useState(null)

  async function loadLatest() {
    try {
      const r = await api.preflightLatest()
      setReport(r?.empty ? null : r)
    } catch (e) {
      setError(String(e))
    }
  }
  useEffect(() => {
    loadLatest()
  }, [])

  async function run() {
    setRunning(true)
    setError(null)
    try {
      setReport(await api.preflightRun())
    } catch (e) {
      setError(String(e))
    } finally {
      setRunning(false)
    }
  }

  const results = report?.results ?? []

  return (
    <section>
      <div className="panel-head">
        <h2>Preflight</h2>
        <button className="btn primary" onClick={run} disabled={running}>
          {running ? 'Running…' : 'Run preflight'}
        </button>
      </div>
      <p className="muted">
        Read-only validation of the current mapping set: target MailUsers, the Cross Tenant
        migration add-on, source mailbox holds, and the migration / SPO relationships.
        <b> BLOCK</b> = unsafe to proceed, <b> WARN</b> = unverified or needs attention.
      </p>

      {error && <p className="error">{error}</p>}

      {report && (
        <>
          <div className="chips">
            <span className="chip"><StatusDot status="PASS" label={`${report.pass} PASS`} /></span>
            <span className="chip"><StatusDot status="WARN" label={`${report.warn} WARN`} /></span>
            <span className="chip"><StatusDot status="BLOCK" label={`${report.block} BLOCK`} /></span>
            <span className="chip muted mono">{report.runId}</span>
          </div>
          <div className="btn-row">
            <a className="btn" href={api.preflightExportHtmlUrl(report.runId)}>Export HTML</a>
            <a className="btn" href={api.preflightExportCsvUrl(report.runId)}>Export CSV</a>
          </div>
        </>
      )}

      <div className="table-scroll">
        <table className="grid-table">
          <thead>
            <tr><th>Status</th><th>Scope</th><th>Subject</th><th>Check</th><th>Reason</th></tr>
          </thead>
          <tbody>
            {results.length === 0 && (
              <tr><td colSpan={5} className="muted">No preflight run yet. Click “Run preflight”.</td></tr>
            )}
            {results.map((r, i) => (
              <tr key={i} className={r.status === 'BLOCK' ? 'conflict' : r.status === 'WARN' ? 'unmatched' : ''}>
                <td><StatusDot status={r.status} label={r.status} /></td>
                <td>{r.scope}</td>
                <td className="mono">{r.subject}</td>
                <td>{r.check}</td>
                <td className="muted">{r.reason}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}
