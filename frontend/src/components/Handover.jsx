export function Handover() {
  return (
    <section>
      <div className="panel-head"><h2>Handover</h2></div>
      <p className="muted">
        Final deliverables for the customer: a project report of what was done, and the
        Swedish end-user guides for switching tenant. Run this once all migrations are complete.
      </p>

      <div className="card" style={{ marginBottom: '1rem' }}>
        <h3 style={{ marginTop: 0, fontSize: '1rem' }}>Project report</h3>
        <p className="muted small">
          Executive summary, reconciliation (intended vs completed), runs, and failures —
          generated as a customer-ready PDF (rendered via headless Edge/Chrome).
        </p>
        <div className="btn-row">
          <a className="btn" href="/api/project/report/html" target="_blank" rel="noreferrer">Preview (HTML)</a>
          <a className="btn primary" href="/api/project/report/pdf">Download PDF</a>
        </div>
      </div>

      <div className="card">
        <h3 style={{ marginTop: 0, fontSize: '1rem' }}>End-user manuals (Swedish)</h3>
        <p className="muted small">
          Hand these to end users — how to switch to the new tenant on each device.
        </p>
        <div className="btn-row">
          <span className="chip">Dator (Windows/Mac):</span>
          <a className="btn" href="/api/project/manual/desktop.html" target="_blank" rel="noreferrer">HTML</a>
          <a className="btn" href="/api/project/manual/desktop.pdf">PDF</a>
        </div>
        <div className="btn-row">
          <span className="chip">Mobil (iPhone/Android):</span>
          <a className="btn" href="/api/project/manual/mobile.html" target="_blank" rel="noreferrer">HTML</a>
          <a className="btn" href="/api/project/manual/mobile.pdf">PDF</a>
        </div>
      </div>
    </section>
  )
}
