# Witness for Windows closed beta — privacy notice (draft)

Status: **internal legal draft, 2026-09-30. Not approved for public release.**
Before an external beta, replace the controller/contact placeholders, name the
actual beta activation host and processor, verify their regions and retention,
and obtain legal review. This document is intentionally separate from the
published Mac policy: the Windows beta has separate license and update
authorities, no checkout and no transmitted product events. The update code is
implemented, but the real feed/CDN facts below remain placeholders.

## 1. Controller and contact

Controller: **[insert the legal name and postal address from the current
Impressum before external distribution]**, Czech business ID (IČO) 17328691.

Privacy and data-rights contact: **[insert the published support/privacy email]**.
The current public Impressum remains available at
<https://witnessmac.com/impressum> but is not a substitute for completing this
offline notice before distribution.

## 2. The short version

Speech recognition runs on this PC. Witness does not upload audio, dictated or
cleaned text, vocabulary, recent history, clipboard contents, application
contents, risk fragments, speech timing, performance measurements or general
diagnostics. Audio is held in memory and is not written to a recording file by
Witness.

The closed beta can make only the requests listed below. Development and
ordinary CI builds leave beta activation unconfigured. Product events are
local-only in the beta even when the preference labelled “Share three
non-content product events” is on.

| Request | Trigger | Data | Recipient and purpose | Retention |
| --- | --- | --- | --- | --- |
| Speech-model download | You accept the visible model disclosure and start the download | Requested model URL, IP address, request time and `Witness-Windows-Beta/0.1.0` User-Agent as ordinary HTTPS metadata | Hugging Face and its CDN, to deliver the pinned model file | Witness receives no request log. Provider retention follows the provider policy and must be rechecked before distribution |
| Beta activation | You press **Send me a beta key**, and only in a build compiled with the private beta endpoint | The email address you entered and a 32-character derived device identifier | **[insert beta host/operator/processor]**, to issue one signed beta key | **[insert the beta retention period; recommended: until beta closure or earlier deletion]** |
| Release beta device | You press **Remove from this PC** in a configured build | The derived device identifier and the signed key already issued | The same beta activation service, to release the device slot | The slot is deleted or marked released under the beta retention policy |
| Update check | You press **Check for updates** in a build compiled with the isolated Windows beta feed | Fixed manifest URL, IP address, request time and `Witness/0.1.0` User-Agent as ordinary HTTPS metadata | **[insert Windows beta update-feed host/operator/processor]**, to return signed metadata for this Windows x64 beta channel | **[insert connection-log retention and region]** |
| Update package | After a signed newer version is shown, you press **Download** | Signed package URL, IP address, request time and the same fixed User-Agent as ordinary HTTPS metadata | **[insert package/CDN host/operator/processors]**, to deliver the exact full package | **[insert connection-log retention and regions]** |

There is no Windows checkout in this beta. The app does not open the Mac
payment links. Ordinary development and CI builds have no update endpoint.
An externally distributed configured build remains blocked until the update
feed/CDN recipients, regions and retention placeholders above are completed.

## 3. Local processing and local files

Recognition, cleanup, language selection, risk checks, review, insertion and
the session dictionary run locally. Witness stores only the following
non-content product state under `%LOCALAPPDATA%\Witness\`:

- `settings.json`: onboarding completion, ordered language codes, shortcut
  mode, audio-input selection and the product-event preference;
- `license.json`: installation time, a random unlinkable installation ID,
  first successful dictation time, furthest locally observed time and an
  optional signed license key;
- the verified speech model.

Recent dictated text and session vocabulary are kept only in memory and are
cleared when Witness exits. Review audio is retained only for the current
flagged review and is released when the review closes or a newer phrase starts.
Windows itself may use paging or create a crash dump independently of Witness;
the product promise is that Witness does not deliberately persist this content.

Local files remain until the user removes them. Update, uninstall and reinstall
leave `%LOCALAPPDATA%\Witness` in place. Uninstall does not call the activation
service and does not release a remote device slot. Session vocabulary, recent
history and review audio are RAM-only and therefore clear on updater restart.

## 4. Activation data, field by field

The activation request is exactly:

```json
{"device":"<32 lowercase hex characters>","email":"<address entered by the user>"}
```

The release request is exactly:

```json
{"device":"<32 lowercase hex characters>","key":"LD1.…"}
```

The device identifier is the first 128 bits of a SHA-256 digest over a
Windows-specific namespace and the normalized SMBIOS system UUID. The raw UUID
is discarded in memory, is not stored and is not sent. Missing, zero or
placeholder UUIDs disable activation; Witness does not create a shared fallback
identifier.

The service uses the email address to identify the beta entitlement and deliver
or reissue a transactional key. It must not use the address for marketing
without separate consent. The key is verified on this PC against a compiled-in
Windows beta public key. Normal license checks are offline and never call the
service.

The activation transport uses HTTPS, no cookies, no redirects, JSON only, an
8 KiB response limit and a fixed `Witness` User-Agent. The endpoint is compiled
at build time; there is no user setting that can redirect the email address.

## 5. Product events and diagnostics

The client can construct only `trial_started`, `activation_requested` and
`paywall_shown`, with app version, the coarse `windows-10.0` family, a random
install ID and, for the paywall, one fixed reason. In the closed beta the sink
performs no network or disk I/O. The preference is already present so a future
public build cannot add transmission without a visible control, but enabling a
transport also requires updating this notice before that build is released.

There is no automatic crash-report or diagnostic upload. CI artifacts may
contain executables, packages, checksums, technical summaries and screenshots
made from hard-coded synthetic state. They must not contain recordings, real
dictation, clipboard contents, vocabulary, application contents or crash dumps.

## 6. Manual updates

Witness does not check at launch, on a timer, when Settings closes or when the
network returns. A check begins only when you press the button. The signed
manifest contains version/build, channel, platform, architecture, minimum OS,
product major, plain-text release notes, exact package URL, byte length and
SHA-256. Witness verifies the separate Windows update signature before reading
those fields, then verifies the full package during download and again just
before apply. It does not send an email address, license key, device/install
identifier, language choice, model state or dictated content.

Installation requires a separate confirmation and waits while recording,
recognition, insertion or audio replay is active. A downloaded pending package
is not applied automatically at the next launch. The installer, updater and
app still require Windows code signing before external distribution.

## 7. Legal bases, recipients and transfers

Subject to legal review, the intended bases are:

- model delivery and beta activation: steps requested by the tester and
  performance of the closed-beta agreement (GDPR Article 6(1)(b));
- short-lived abuse counters at the activation edge: the controller’s
  legitimate interest in service security (Article 6(1)(f));
- any future optional product-event transmission: consent (Article 6(1)(a)),
  which must be as easy to withdraw as to give.

Hugging Face/CDN and the future beta activation provider receive ordinary
connection metadata such as IP address and request time. Before distribution,
this section must name all processors, their regions, any transfer outside the
EEA, and the transfer safeguard. Do not infer those facts from the production
Mac service.

## 8. Your rights

Depending on the circumstances, you may request access, correction, erasure,
restriction, portability or object to processing. You may withdraw consent at
any time without affecting earlier lawful processing. You may complain to the
competent data-protection authority. Contact the controller using the completed
address in section 1.

Deleting activation data means that no further key can be issued for that
address. A key already stored locally continues to verify offline until it
expires or is removed.

## 9. Children and changes

The beta is not directed at children. A new category of network data, recipient
or purpose must be documented here and in
`Windows/PRIVACY_ENDPOINT_INVENTORY.md` before a build containing that change
is distributed.

## Drafting references

- GDPR Article 13: <https://eur-lex.europa.eu/eli/reg/2016/679/oj>
- European Commission overview of data-subject information and rights:
  <https://commission.europa.eu/law/law-topic/data-protection/information-individuals_en>
- European Commission guidance on consent and legal bases:
  <https://commission.europa.eu/law/law-topic/data-protection/information-business-and-organisations/legal-grounds-processing-data_en>

---

# Witness für Windows – geschlossene Beta: Datenschutzhinweis (Entwurf)

Status: **interner Rechtsentwurf vom 30.09.2026, nicht für eine öffentliche
Veröffentlichung freigegeben.** Vor einer externen Beta sind Verantwortlicher,
Kontakt, tatsächlicher Beta-Host, Auftragsverarbeiter, Regionen,
Übermittlungsgrundlagen und Aufbewahrungsfristen einzutragen und rechtlich zu
prüfen.

Spracherkennung, Bereinigung, Sprachwahl, Risikoprüfung, Review und Einfügen
laufen auf diesem PC. Witness lädt weder Audio noch Diktattext, Wortschatz,
Verlauf, Zwischenablage, Anwendungsinhalte, Risikofragmente, Zeiten,
Leistungswerte oder allgemeine Diagnosen hoch. Audio bleibt im Arbeitsspeicher
und wird von Witness nicht als Aufnahme gespeichert.

Nach ausdrücklicher Aktion sind nur folgende Verbindungen vorgesehen:

- Download des angezeigten und kryptografisch geprüften Sprachmodells von
  Hugging Face/CDN; dabei fallen übliche HTTPS-Metadaten wie IP, URL, Zeitpunkt
  und User-Agent an.
- In einem speziell konfigurierten Beta-Build: Aktivierung mit genau der
  eingegebenen E-Mail-Adresse und einer abgeleiteten 32-stelligen Gerätekennung.
- Beim Entfernen: dieselbe Kennung und der bereits ausgestellte signierte
  Schlüssel, um den Beta-Geräteplatz freizugeben.

**[Verantwortlichen, Postanschrift, Datenschutzkontakt, Beta-Host,
Auftragsverarbeiter und Fristen vor externer Verteilung eintragen.]**

Die Gerätekennung ist ein Windows-spezifischer Einweg-Hash der normalisierten
SMBIOS-System-UUID. Die rohe UUID wird weder gespeichert noch gesendet. Die
Lizenzprüfung erfolgt nach Annahme eines Schlüssels vollständig offline.

Produkt-Ereignisse werden in der geschlossenen Beta nicht übertragen und nicht
auf Datenträger geschrieben. Es gibt keinen Windows-Checkout, keinen
automatischen Diagnose-Upload. Update-Prüfung und Download erfolgen nur nach
getrennten Klicks, nur in einem fest konfigurierten Build und ohne Lizenz-,
Geräte- oder Inhaltsdaten. Update, Deinstallation und Neuinstallation lassen
`%LOCALAPPDATA%\Witness` bestehen; das Sitzungswörterbuch bleibt dagegen nur im
RAM und wird beim Neustart gelöscht. Feed/CDN, Regionen und Speicherfristen
müssen vor einer externen Beta noch eingesetzt und rechtlich geprüft werden.

Je nach Voraussetzungen bestehen Rechte auf Auskunft, Berichtigung, Löschung,
Einschränkung, Datenübertragbarkeit und Widerspruch sowie ein Beschwerderecht
bei der zuständigen Aufsichtsbehörde. Eine Einwilligung kann jederzeit mit
Wirkung für die Zukunft widerrufen werden. Die ausführlichen Felder,
Speicherorte, vorgesehenen Rechtsgrundlagen und offenen Pflichtangaben stehen
in der englischen Fassung dieses gemeinsamen Entwurfs und müssen vor der
externen Beta vollständig deutsch gegengeprüft werden.
