import { useEffect, useState } from 'react'
import { api } from '../api'
import { StatusDot } from './StatusDot'

export function Health() {
  const [state, setState] = useState({ status: 'loading', data: null, error: null })

  async function check() {
    setState((s) => ({ ...s, status: 'loading' }))
    try {
      const data = await api.health()
      setState({ status: 'ok', data, error: null })
    } catch (err) {
      setState({ status: 'down', data: null, error: String(err) })
    }
  }

  useEffect(() => {
    check()
  }, [])

  return (
    <section>
      <div className="panel-head">
        <h2>Backend health</h2>
        <button className="btn" onClick={check}>Refresh</button>
      </div>
      <div className="card">
        <StatusDot
          status={state.status}
          label={
            state.status === 'loading' ? 'Checking…'
            : state.status === 'ok' ? 'Backend healthy'
            : 'Backend unreachable'
          }
        />
        {state.status === 'ok' && (
          <dl className="meta">
            <dt>Service</dt><dd>{state.data.service}</dd>
            <dt>Version</dt><dd>{state.data.version}</dd>
            <dt>PowerShell</dt><dd>{state.data.powershell}</dd>
            <dt>Database</dt><dd className="mono">{state.data.db}</dd>
            <dt>Server time (UTC)</dt><dd className="mono">{state.data.timeUtc}</dd>
          </dl>
        )}
        {state.status === 'down' && (
          <p className="error">
            {state.error}<br />
            Start the backend: <code>pwsh -File backend/server.ps1</code>
          </p>
        )}
      </div>
    </section>
  )
}
