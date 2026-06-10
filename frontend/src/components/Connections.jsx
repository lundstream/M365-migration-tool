import { useEffect, useState } from 'react'
import { api } from '../api'
import { StatusDot } from './StatusDot'

const SERVICES = ['Graph', 'ExchangeOnline', 'SharePoint']

export function Connections() {
  const [health, setHealth] = useState(null)
  const [probing, setProbing] = useState(false)
  const [error, setError] = useState(null)

  async function probe() {
    setProbing(true)
    setError(null)
    try {
      setHealth(await api.connectionHealth())
    } catch (e) {
      setError(String(e))
    } finally {
      setProbing(false)
    }
  }

  useEffect(() => {
    probe()
  }, [])

  return (
    <section>
      <div className="panel-head">
        <h2>Connections</h2>
        <button className="btn" onClick={probe} disabled={probing}>
          {probing ? 'Probing…' : 'Re-probe'}
        </button>
      </div>
      <p className="muted">
        App-only certificate auth to Graph, Exchange Online, and SharePoint admin for both
        tenants. Read-only — no mutations. Fill in <code>config/config.json</code> (or use the
        backend <code>PUT /api/connections</code>) and place the certs in the Windows store.
      </p>

      {error && <p className="error">{error}</p>}

      <div className="tenant-grid">
        {health?.tenants?.map((t) => (
          <div className="card" key={t.tenant}>
            <div className="card-head">
              <h3>{t.displayName}</h3>
              <span className="tag">{t.tenant}</span>
            </div>
            <div className="mono muted small">{t.tenantId}</div>
            <table className="svc-table">
              <tbody>
                {SERVICES.map((name) => {
                  const svc = t.services.find((s) => s.service === name)
                  return (
                    <tr key={name}>
                      <td className="svc-name">{name}</td>
                      <td><StatusDot status={svc?.status ?? 'loading'} /></td>
                      <td className="svc-detail">
                        {svc?.connected && svc.identity}
                        {svc?.status === 'error' && <span className="error">{svc.error}</span>}
                        {svc?.status === 'not-configured' && <span className="muted">not configured</span>}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        ))}
      </div>
    </section>
  )
}
