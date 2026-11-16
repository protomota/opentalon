import { useState } from 'react'
import { ArrowUpRight, Coffee, Headset, Mail } from 'lucide-react'
import { action } from './model'
import { Modal } from './Modal'
import productMark from '../assets/protomota-logo.png'
import logo from '../assets/opentalon-logo-black.svg'
import wordmark from '../assets/opentalon-wordmark.png'

export function ProtomotaProductPill() {
  const [error, setError] = useState('')
  return (
    <>
      <button
        className="protomota-product-pill"
        aria-label="A Protomota Product — visit protomota.com"
        onClick={() => {
          setError('')
          void action('open_company_website').catch((error: Error) => setError(error.message))
        }}
      >
        <img src={productMark} alt="" />A Protomota Product
      </button>
      {error && (
        <p className="error-text" role="alert">
          {error}
        </p>
      )}
    </>
  )
}
export function ProductIdentity() {
  const [error, setError] = useState('')
  function openSupport(kind: 'coffee' | 'setup') {
    setError('')
    void action('open_support_link', { kind }).catch((error: Error) => setError(error.message))
  }
  return (
    <section className="about-section">
      <div className="about-identity">
        <span className="logo-tile">
          <img src={logo} alt="" />
        </span>
        <div>
          <span className="logo-type about-logo-type">
            <img src={wordmark} alt="OpenTalon" />
          </span>
          <span>0.1.0 · Made by Protomota</span>
        </div>
      </div>
      <p>A little room for the things you’re working on.</p>
      <div className="product-support-card product-newsletter-card">
        <Mail size={25} strokeWidth={1.4} aria-hidden="true" />
        <div>
          <h3>One newsletter. All of Protomota.</h3>
          <p>Product updates and notes from the things I’m building. Join only if you want to.</p>
          <button
            className="secondary-button"
            aria-label="Join the Protomota newsletter — opens in your browser"
            onClick={() => {
              setError('')
              void action('open_newsletter').catch((error: Error) => setError(error.message))
            }}
          >
            <Mail size={15} />
            Join the Protomota newsletter
            <ArrowUpRight size={14} />
          </button>
        </div>
      </div>
      <div className="product-support-panels">
        <div className="product-support-card">
          <Coffee size={25} strokeWidth={1.4} aria-hidden="true" />
          <h3>
            Made for ideas.
            <br />
            Fueled by coffee.
          </h3>
          <p>Enjoying OpenTalon? A coffee is a small way to support the person behind it.</p>
          <button
            className="secondary-button"
            aria-label="Buy me a coffee — opens in your browser"
            onClick={() => openSupport('coffee')}
          >
            <Coffee size={15} />
            Buy me a coffee
            <ArrowUpRight size={14} />
          </button>
          <p className="support-note">Tips are optional. Every feature stays free.</p>
        </div>
        <div className="product-support-card setup-support-card">
          <Headset size={25} strokeWidth={1.4} aria-hidden="true" />
          <h3>Need help with OpenTalon?</h3>
          <p>Open a support ticket or return to an existing conversation.</p>
          <button className="secondary-button" onClick={() => openSupport('setup')}>
            Get App Help
            <ArrowUpRight size={14} />
          </button>
        </div>
      </div>
      {error && (
        <p className="error-text" role="alert">
          {error}
        </p>
      )}
      <ProtomotaProductPill />
    </section>
  )
}
export function AboutDialog({ onClose }: { onClose: () => void }) {
  return (
    <Modal title="About OpenTalon" className="about-modal" onClose={onClose}>
      <ProductIdentity />
      <div className="modal-footer">
        <button className="primary-button" onClick={onClose}>
          Done
        </button>
      </div>
    </Modal>
  )
}
