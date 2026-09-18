import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'
import SearchableSelectEnhancer from './components/SearchableSelectEnhancer.tsx'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
    <SearchableSelectEnhancer />
  </StrictMode>,
)
