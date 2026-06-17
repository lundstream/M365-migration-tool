import { Component } from 'react'

// Catches render errors in a tab so a single component failure shows a message
// instead of a blank white page, and lets the user recover without a full reload.
export class ErrorBoundary extends Component {
  constructor(props) {
    super(props)
    this.state = { error: null }
  }

  static getDerivedStateFromError(error) {
    return { error }
  }

  componentDidUpdate(prevProps) {
    // Reset the error when switching tabs.
    if (prevProps.resetKey !== this.props.resetKey && this.state.error) {
      this.setState({ error: null })
    }
  }

  render() {
    if (this.state.error) {
      return (
        <div className="card" style={{ borderColor: '#d93025' }}>
          <h3 style={{ marginTop: 0, color: '#d93025' }}>Something went wrong rendering this view</h3>
          <p className="muted small">{String(this.state.error?.message ?? this.state.error)}</p>
          <button className="btn" onClick={() => this.setState({ error: null })}>Try again</button>
        </div>
      )
    }
    return this.props.children
  }
}
