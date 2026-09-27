# Windows privacy and endpoint inventory

Status: W0 source of truth. Beta transports remain local-only until real beta authorities and hosts are configured. This inventory must be updated before enabling any remote endpoint.

| Capability | Beta default | Permitted endpoint and fields | Purpose | Recipient / retention | Content boundary |
| --- | --- | --- | --- | --- | --- |
| Model setup | Disabled until a pinned model is selected | One fixed HTTPS model URL; request carries ordinary HTTP metadata only. Response is checked against a committed size and SHA-256. | Install the local speech model after explicit disclosure. | Host/CDN and retention are pending selection. | No device ID, email, license, audio, transcript, language choice, vocabulary, clipboard, app, or derived content. |
| Activation | Local test authority only | Production-compatible `POST /v1/activate` body has exactly `device` and `email`; release uses the existing `/v1/devices/release` contract. | Issue or release a license after an explicit user action. | Production recipient/retention remain as disclosed by the current release; beta authority is separate. | No audio, transcript, vocabulary, clipboard, app contents, risk data, usage count, or diagnostics. |
| Product events | Local sink only | Only `trial_started`, `activation_requested`, and `paywall_shown`, with the existing fixed non-content allowlist and opt-out. | Funnel measurement after policy/public documentation is ready. | Disabled for closed beta. | No content-derived, device, email, license-key, timing, performance, or general diagnostic fields. |
| Update check | Local/CI fixture only | A fixed HTTPS signed-envelope URL after the user clicks Check. `User-Agent: Witness`; no cookies. | Fetch signed metadata for the Windows x64 beta channel. | Real host/CDN and retention pending. | No email, license, device ID, content, model data, or diagnostics in URL, headers, or body. |
| Update package | Local/CI fixture only | Fixed/allowlisted HTTPS URL from a verified Ed25519 manifest; redirects must stay on the allowlist; exact signed size and SHA-256. | Download a user-confirmed full Velopack package. | Real host/CDN and retention pending. | Same prohibition as update check. |
| Checkout | Disabled | Stub-only until Windows commercial terms are approved. | Open a browser only after explicit consent. | Not configured. | No automatic call-home and no Mac-only purchase URL in the beta. |

General diagnostics, transcripts, clipboard snapshots, vocabulary, application contents, risk fragments, raw device UUIDs, and audio stay local. Product audio is memory-only. CI uploads only build/package outputs and technical summaries made from synthetic scenarios; it must never upload recordings, transcriptions, clipboard contents, real vocabulary, crash dumps, or content-derived traces.

Windows certificate-chain and SmartScreen checks can create operating-system network traffic independently of Witness. That behavior must be described separately once the code-signing provider is selected.
