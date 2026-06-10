import { useState } from 'react'
import './App.css'
import { Health } from './components/Health'
import { Connections } from './components/Connections'
import { Mapping } from './components/Mapping'
import { Provisioning } from './components/Provisioning'
import { Preflight } from './components/Preflight'
import { MigrationSetup } from './components/MigrationSetup'
import { MailboxMove } from './components/MailboxMove'
import { FileMove } from './components/FileMove'
import { Monitor } from './components/Monitor'
import { Reports } from './components/Reports'
import { Manifest } from './components/Manifest'
import { Groups } from './components/Groups'
import { Permissions } from './components/Permissions'

const TABS = [
  { id: 'health', label: 'Health', el: <Health /> },
  { id: 'connections', label: 'Connections', el: <Connections /> },
  { id: 'mapping', label: 'Identity Mapping', el: <Mapping /> },
  { id: 'manifest', label: 'Manifest', el: <Manifest /> },
  { id: 'provisioning', label: 'Provisioning', el: <Provisioning /> },
  { id: 'groups', label: 'Groups', el: <Groups /> },
  { id: 'preflight', label: 'Preflight', el: <Preflight /> },
  { id: 'migration-setup', label: 'Migration Setup', el: <MigrationSetup /> },
  { id: 'mailbox-move', label: 'Mailbox Moves', el: <MailboxMove /> },
  { id: 'permissions', label: 'Shared Mbx Perms', el: <Permissions /> },
  { id: 'file-move', label: 'OneDrive / SharePoint', el: <FileMove /> },
  { id: 'monitor', label: 'Monitoring', el: <Monitor /> },
  { id: 'reports', label: 'Reports', el: <Reports /> },
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
