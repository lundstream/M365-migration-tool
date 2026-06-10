import { useEffect, useState } from 'react'
import './App.css'

function App() {
  const [state, setState] = useState({ status: 'loading', data: null, error: null })

  async function checkHealth() {
    setState((s) => ({ ...s, status: 'loading' }))
    try {
      const res = await fetch('/api/health')
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const data = await res.json()
      setState({ status: 'ok', data, error: null })
    } catch (err) {
      setState({ status: 'down', data: null, error: String(err) })
    }
  }

  useEffect(() => {
    checkHealth()
  }, [])

  const up = state.status === 'ok'
  const color = state.status === 'loading' ? '#9aa0a6' : up ? '#1e8e3e' : '#d93025'

  return (
    <main className="app">
      <header>
        <h1>M365 Cross-Tenant Migration Tool</h1>
        <p className="sub">Phase 0 — scaffold &amp; health check</p>
      </header>

      <section className="card">
        <div className="status-row">
          <span className="dot" style={{ backgroundColor: color }} />
          <span className="status-label">
            {state.status === 'loading' && 'Checking backend…'}
            {state.status === 'ok' && 'Backend healthy'}
            {state.status === 'down' && 'Backend unreachable'}
          </span>
          <button className="refresh" onClick={checkHealth}>
            Refresh
          </button>
        </div>

        {up && (
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
            {state.error}
            <br />
            Start the backend: <code>pwsh -File backend/server.ps1</code>
          </p>
        )}
      </section>
    </main>
  )
}

export default App
