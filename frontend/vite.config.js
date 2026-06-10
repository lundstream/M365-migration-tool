import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// During `npm run dev`, proxy API calls to the Pode backend on localhost.
// In production, Pode serves the built files from frontend/dist and same-origin
// /api works without a proxy.
export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      '/api': 'http://127.0.0.1:8080',
    },
  },
})
