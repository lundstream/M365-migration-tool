import { useState } from 'react'
import './App.css'
import { Health } from './components/Health'
import { Connections } from './components/Connections'
import { Mapping } from './components/Mapping'
import { Provisioning } from './components/Provisioning'
import { Preflight } from './components/Preflight'
import { MigrationSetup } from './components/MigrationSetup'

const TABS = [
  { id: 'health', label: 'Health', el: <Health /> },
  { id: 'connections', label: 'Connections', el: <Connections /> },
  { id: 'mapping', label: 'Identity Mapping', el: <Mapping /> },
  { id: 'provisioning', label: 'Provisioning', el: <Provisioning /> },
  { id: 'preflight', label: 'Preflight', el: <Preflight /> },
  { id: 'migration-setup', label: 'Migration Setup', el: <MigrationSetup /> },
]

function App() {
  const [active, setActive] = useState('health')

  return (
    <div className="shell">
      <header className="app-header">
        <h1>M365 Cross-Tenant Migration Tool</h1>
        <p className="sub">Read-only through Phase 3 — no tenant mutations</p>
      </header>

      <nav className="tabs">
        {TABS.map((t) => (
          <button
            key={t.id}
            className={`tab ${active === t.id ? 'active' : ''}`}
            onClick={() => setActive(t.id)}
          >
            {t.label}
          </button>
        ))}
      </nav>

      <main className="content">
        {TABS.find((t) => t.id === active)?.el}
      </main>
    </div>
  )
}

export default App
