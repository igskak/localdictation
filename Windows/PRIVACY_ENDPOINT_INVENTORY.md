# Windows privacy and endpoint inventory

Status: W3 source of truth. Activation, events, updates and checkout remain local-only until real beta authorities and hosts are configured. Model setup is the only configured remote capability.

| Capability | Beta default | Permitted endpoint and fields | Purpose | Recipient / retention | Content boundary |
| --- | --- | --- | --- | --- | --- |
| Model setup | Local inspection first; download starts only after the user accepts the visible disclosure | Fixed `GET https://huggingface.co/ggerganov/whisper.cpp/resolve/98aa99a0a9db05ae2342309f5096248665f7cba3/ggml-large-v3-turbo-q5_0.bin`; redirects are limited to HTTPS `huggingface.co` and `*.hf.co`; fixed `User-Agent: Witness-Windows-Beta/0.1.0`, no cookies or custom identifiers. Response must match 574,041,195 bytes and SHA-256 `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2`. | Install the local speech model once, then reuse it offline. | Hugging Face and its CDN subprocessors receive ordinary connection metadata such as IP, request time, URL and User-Agent; their retention is governed by their service policy and must be repeated in the beta privacy draft. | No device ID, email, license, audio, transcript, selected language, vocabulary, clipboard, application content, risk fragment, timing, diagnostics, or content-derived field. |
| Activation | Local test authority only; no endpoint compiled into the beta configuration yet | Production-compatible HTTPS `POST /v1/activate` body has exactly `device` and `email`; `/v1/devices/release` has exactly `device` and the signed key the service already issued. Fixed `User-Agent: Witness`, JSON only, no cookies, no automatic redirects, 8 KiB response limit. | Issue or release a license after an explicit user action. | Production recipient/retention remain as disclosed by the current release; the Windows beta authority and configuration stay separate. | No audio, transcript, vocabulary, clipboard, app contents, risk data, usage count, raw hardware UUID, or diagnostics. |
| Product events | Local sink only | Only `trial_started`, `activation_requested`, and `paywall_shown`, with the existing fixed non-content allowlist and opt-out. | Funnel measurement after policy/public documentation is ready. | Disabled for closed beta. | No content-derived, device, email, license-key, timing, performance, or general diagnostic fields. |
| Update check | Local/CI fixture only | A fixed HTTPS signed-envelope URL after the user clicks Check. `User-Agent: Witness`; no cookies. | Fetch signed metadata for the Windows x64 beta channel. | Real host/CDN and retention pending. | No email, license, device ID, content, model data, or diagnostics in URL, headers, or body. |
| Update package | Local/CI fixture only | Fixed/allowlisted HTTPS URL from a verified Ed25519 manifest; redirects must stay on the allowlist; exact signed size and SHA-256. | Download a user-confirmed full Velopack package. | Real host/CDN and retention pending. | Same prohibition as update check. |
| Checkout | Disabled | Stub-only until Windows commercial terms are approved. | Open a browser only after explicit consent. | Not configured. | No automatic call-home and no Mac-only purchase URL in the beta. |

General diagnostics, transcripts, clipboard snapshots, vocabulary, application contents, risk fragments, raw device UUIDs, and audio stay local. Product audio is memory-only. CI uploads only build/package outputs and technical summaries made from synthetic scenarios; it must never upload recordings, transcriptions, clipboard contents, real vocabulary, crash dumps, or content-derived traces.

## W5 local state allowlist

`%LOCALAPPDATA%\Witness\settings.json` is the only W5 settings file. Its fixed,
versioned shape contains exactly: onboarding completion, ordered selected
language codes, hold/toggle activation mode, audio-input selection kind and an
optional opaque Windows endpoint ID, and the product-event sharing toggle. The
version-one document migrates with the disclosed sharing default enabled; the
file is replaced atomically. It does
not serialize transcripts, recent history, glossary terms, clipboard state,
risk evidence, audio, application identity or diagnostics.

The session glossary and latest ten eligible results are RAM-only and are
cleared on process exit. Protected-field refusals never enter history. Review
audio exists only for a flagged, playable review and is released when review
closes or a newer phrase starts.

## W6 local licensing state allowlist

`%LOCALAPPDATA%\Witness\license.json` is atomically replaced and contains
exactly five fields: installation time, an unlinkable installation UUID, first
successful dictation time, furthest locally observed time and an optional
signed LD1 token. The token already contains the email and derived device ID
that the activation service issued it for; neither value is duplicated into
additional files. The raw SMBIOS UUID is normalized and hashed in memory with a
Windows-specific product namespace, then discarded. Missing and placeholder
firmware UUIDs disable activation rather than producing a shared or unstable
identifier.

Windows certificate-chain and SmartScreen checks can create operating-system network traffic independently of Witness. That behavior must be described separately once the code-signing provider is selected.
