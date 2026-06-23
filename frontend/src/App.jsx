import { useMemo, useState } from 'react'
import './App.css'
import { Health } from './components/Health'
import { Connections } from './components/Connections'
import { Mapping } from './components/Mapping'
import { Provisioning } from './components/Provisioning'
import { Preflight } from './components/Preflight'
import { MigrationSetup } from './components/MigrationSetup'
import { MailboxMove } from './components/MailboxMove'
import { MailboxCopy } from './components/MailboxCopy'
import { FileMove } from './components/FileMove'
import { Monitor } from './components/Monitor'
import { Reports } from './components/Reports'
import { Manifest } from './components/Manifest'
import { Groups } from './components/Groups'
import { Permissions } from './components/Permissions'
import { Handover } from './components/Handover'
import { ErrorBoundary } from './components/ErrorBoundary'

// Left-to-right migration flow: each numbered step has sub-steps (Step N.M).
const STEPS = [
  { label: 'Setup', children: [
    { id: 'health', label: 'Health', el: <Health /> },
    { id: 'connections', label: 'Connections', el: <Connections /> },
  ] },
  { label: 'Inventory & map', children: [
    { id: 'manifest', label: 'Manifest (snapshot)', el: <Manifest /> },
    { id: 'mapping', label: 'Identity mapping', el: <Mapping /> },
    { id: 'groups', label: 'Groups', el: <Groups /> },
  ] },
  { label: 'Provision target', children: [
    { id: 'provisioning', label: 'Provision MailUsers', el: <Provisioning /> },
    { id: 'migration-setup', label: 'Migration setup', el: <MigrationSetup /> },
  ] },
  { label: 'Validate', children: [
    { id: 'preflight', label: 'Preflight', el: <Preflight /> },
  ] },
  { label: 'Migrate', children: [
    { id: 'mailbox-copy', label: 'Mailbox copy (Graph)', el: <MailboxCopy /> },
    { id: 'mailbox-move', label: 'Mailbox moves (native)', el: <MailboxMove /> },
    { id: 'permissions', label: 'Shared mbx permissions', el: <Permissions /> },
    { id: 'file-move', label: 'OneDrive / SharePoint', el: <FileMove /> },
  ] },
  { label: 'Monitor & report', children: [
    { id: 'monitor', label: 'Monitoring', el: <Monitor /> },
    { id: 'reports', label: 'Reports', el: <Reports /> },
  ] },
  { label: 'Handover', children: [
    { id: 'handover', label: 'Report & manuals', el: <Handover /> },
  ] },
]

function App() {
  const [step, setStep] = useState(0)
  const [child, setChild] = useState(0)

  const active = STEPS[step].children[child]
  const stepNo = step + 1

  // Flat lookup not needed; render the active child element.
  const subNav = useMemo(() => STEPS[step].children, [step])

  function goStep(i) { setStep(i); setChild(0) }

  return (
    <div className="shell">
      <header className="app-header">
        <h1>M365 Cross-Tenant Migration Tool</h1>
        <p className="sub">Follow the steps left → right. Mutating actions are gated and audited.</p>
      </header>

      {/* Step nav (left = first, right = last) */}
      <nav className="steps">
        {STEPS.map((s, i) => (
          <button key={s.label} className={`step ${i === step ? 'active' : ''}`} onClick={() => goStep(i)}>
            <span className="step-no">{i + 1}</span>
            <span className="step-label">{s.label}</span>
          </button>
        ))}
      </nav>

      {/* Sub-step nav (Step N.M) */}
      <nav className="substeps">
        {subNav.map((c, j) => (
          <button key={c.id} className={`tab ${j === child ? 'active' : ''}`} onClick={() => setChild(j)}>
            {stepNo}.{j + 1} {c.label}
          </button>
        ))}
      </nav>

      <main className="content">
        <ErrorBoundary resetKey={active.id}>{active.el}</ErrorBoundary>
      </main>
    </div>
  )
}

export default App
