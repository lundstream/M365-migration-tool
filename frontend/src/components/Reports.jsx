import { useEffect, useState } from 'react'
import { api } from '../api'
import { StatusDot } from './StatusDot'

const REPORTS = [
  { id: 'reconciliation', label: 'Reconciliation' },
  { id: 'status', label: 'Per-user status' },
  { id: 'failures', label: 'Failures' },
  { id: 'audit', label: 'Audit trail' },
  { id: 'runs', label: 'Runs' },
]

const RECON_DOT = { reconciled: 'ok', 'in-progress': 'warn', pending: 'not-configured', failed: 'error' }

export function Reports() {
  const [active, setActive] = useState('reconciliation')
  const [report, setReport] = useState(null)
  const [error, setError] = useState(null)
  const [loading, setLoading] = useState(false)

  async function load(name) {
    setLoading(true); setError(null)
    try { setReport(await api.report(name)) } catch (e) { setError(String(e)) } finally { setLoading(false) }
  }
  useEffect(() => { load(active) }, [active])

  const cols = report?.columns ?? []
  const rows = report?.rows ?? []

  return (
    <section>
      <div className="panel-head"><h2>Reports</h2></div>

      <div className="tabs" style={{ marginBottom: '1rem' }}>
        {REPORTS.map((r) => (
          <button key={r.id} className={`tab ${active === r.id ? 'active' : ''}`} onClick={() => setActive(r.id)}>{r.label}</button>
        ))}
      </div>

      <div className="btn-row">
        <button className="btn" onClick={() => load(active)}>Reload</button>
        <a className="btn" href={api.reportExportUrl(active, 'html')}>Export HTML</a>
        <a className="btn" href={api.reportExportUrl(active, 'csv')}>Export CSV</a>
      </div>

      {error && <p className="error">{error}</p>}

      {report?.summary && (
        <div className="chips">
          {Object.entries(report.summary).map(([k, v]) => (
            <span className="chip" key={k}>
              <StatusDot status={RECON_DOT[k] ?? 'not-configured'} label={`${v} ${k}`} />
            </span>
          ))}
        </div>
      )}

      <p className="muted small">{report?.title} · {rows.length} row(s){loading ? ' · loading…' : ''}</p>

      <div className="table-scroll">
        <table className="grid-table">
          <thead><tr>{cols.map((c) => <th key={c}>{c}</th>)}</tr></thead>
          <tbody>
            {rows.length === 0 && <tr><td colSpan={cols.length || 1} className="muted">No data.</td></tr>}
            {rows.map((row, i) => (
              <tr key={i} className={row.Reconciliation === 'failed' ? 'conflict' : ''}>
                {cols.map((c) => (
                  <td key={c} className={c.endsWith('Upn') || c === 'CorrelationId' || c === 'RunId' ? 'mono small' : ''}>
                    {c === 'Reconciliation'
                      ? <StatusDot status={RECON_DOT[row[c]] ?? 'not-configured'} label={row[c]} />
                      : String(row[c] ?? '')}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}
