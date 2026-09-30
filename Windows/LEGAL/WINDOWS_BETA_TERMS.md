# Witness for Windows closed beta — terms (draft)

Status: **internal legal draft, 2026-09-30. Not approved for public release or
sale.** Complete the provider/contact fields and obtain legal review before an
external tester receives the build. These terms intentionally do not reuse the
Mac checkout promise: Windows commercial eligibility, price, device sharing
with Mac and paid update rights remain undecided.

## 1. Provider and scope

Provider: **[insert the legal name, postal address and contact details from the
current Impressum before external distribution]**, Czech business ID (IČO)
17328691.

These terms govern an invitation-only, pre-release Windows x64 build of
Witness. The beta is for evaluation and defect reporting. It is not a public
offer, a sale, a paid subscription or proof that an existing Mac purchase also
covers Windows.

## 2. Beta licence

The provider grants the invited tester a personal, revocable, non-exclusive,
non-transferable right to install and use the beta on the computers and during
the period stated in the invitation or signed beta key. The tester must not
sell, sublicense, publish, share or use a beta key to evade a device limit.

The beta key is signed by a Windows-only beta authority and is separate from
the production Mac licence authority. It does not create a paid entitlement or
promise access to a future public Windows release. Removing a key locally does
not always release the server-side device slot when the service is offline; the
app reports that case.

Mandatory statutory rights and open-source licences remain unaffected. Reverse
engineering is not restricted where applicable law expressly permits it.

## 3. What the beta does

Witness records from the selected microphone while the configured shortcut is
active, recognizes speech locally, applies conservative local processing and
attempts to insert the result into the field that was active when recording
started. It may instead retain or protectively copy a result when the target
cannot be verified. It refuses known protected fields.

Audio is memory-only in product code. The speech model is downloaded once after
the visible disclosure, verified and then reused offline. Activation is an
explicit action. The licence itself is verified offline.

System requirement for this beta: x64 Windows 11 build 26100 or newer. Windows
10 and Windows ARM64 are not supported in this slice. Physical microphone,
GPU, application-compatibility, accessibility and SmartScreen coverage remains
part of beta testing and is not represented as universally verified.

## 4. Pre-release limitations

The beta may contain defects, change incompatibly, fail to recognize speech,
fail to insert text, or lose beta-only state. The tester must check important
text before relying on it and keep independent copies of important settings or
documents. Witness is not intended for emergency, medical, legal, financial or
other safety-critical dictation without human verification.

The provider may replace, suspend or end a beta build or beta activation
service. A signed key already accepted by the app is checked locally, but a
dated key still expires on its stated date and a key can stop covering a newer
major version under its signed entitlement.

## 5. Feedback and content

Feedback is optional unless a separate testing agreement says otherwise. Do
not include real dictated content, recordings, clipboard contents, customer
data, credentials or other confidential material in a bug report. Use the
synthetic reproduction fields supplied in the beta bug template.

The tester grants the provider permission to use submitted non-confidential
feedback to diagnose and improve Witness without payment. This does not grant
the provider rights in the tester’s dictated content; Witness does not request
that content.

## 6. Privacy and network use

The bundled `WINDOWS_BETA_PRIVACY.md` draft describes every intended network
request and local data category. No audio, transcript, vocabulary, clipboard
or application content is sent. A configured activation request contains only
the email address entered by the tester and a derived device identifier.

The closed beta has no checkout and must not open the production Mac payment
links. Product events are local-only. W7 update networking is outside this
draft until a fixed signed Windows beta feed and its privacy disclosure exist.

## 7. Updates and ending participation

The tester should install only packages and updates supplied through the beta
channel and should verify the provided checksum until Windows code signing is
available. The provider may require an update to continue testing.

The tester can stop using the beta at any time and remove the application.
Local data under `%LOCALAPPDATA%\Witness\` may remain after uninstall until the
W7 uninstall policy is verified; it can be removed separately after preserving
any key the tester still needs. Deleting activation records from the service
may prevent reissue of a key.

## 8. Warranty and liability

The beta is supplied free of charge for testing, on a pre-release basis and
without a promise that every feature will work on every computer or
application. Nothing in these terms excludes or limits liability, guarantees
or remedies that cannot lawfully be excluded, including mandatory consumer
rights. Subject to those rules, the tester accepts the ordinary risk of using
unfinished software and is responsible for reviewing generated text before it
is used.

## 9. Law and priority

Subject to mandatory rules protecting the tester, Czech law is intended to
govern this beta relationship. A separate signed testing agreement or the
invitation controls where it expressly conflicts with this draft. Open-source
licence terms control the corresponding third-party components.

Before these terms are used for a paid Windows product, add the actual offer,
price, term, renewal/cancellation rules, delivery, update coverage, device
rights, withdrawal information and contract confirmation. German consumer
requirements for immediate digital delivery must be implemented in the
checkout flow rather than copied from the Mac product without verification.

## Drafting references

- German Civil Code §312f(3), confirmation of express consent and loss of the
  withdrawal right for immediate digital delivery:
  <https://www.gesetze-im-internet.de/bgb/__312f.html>
- GDPR text: <https://eur-lex.europa.eu/eli/reg/2016/679/oj>

---

# Witness für Windows – Bedingungen der geschlossenen Beta (Entwurf)

Status: **interner Rechtsentwurf vom 30.09.2026, nicht für Veröffentlichung
oder Verkauf freigegeben.** Anbieter- und Kontaktdaten sind zu ergänzen und die
Fassung ist vor externer Verteilung rechtlich zu prüfen.

Diese Bedingungen betreffen ausschließlich eine eingeladene, kostenlose
Vorabversion für Windows x64. Sie sind kein öffentliches Angebot, kein Kauf,
kein Abonnement und keine Zusage, dass eine Mac-Lizenz auch Windows umfasst.

Der eingeladene Tester erhält für den in Einladung oder Beta-Schlüssel
genannten Zeitraum ein persönliches, widerrufliches, nicht ausschließliches
und nicht übertragbares Nutzungsrecht. Beta-Build und Schlüssel dürfen nicht
verkauft, unterlizenziert, veröffentlicht oder zur Umgehung eines Gerätelimits
geteilt werden. Die Windows-Beta verwendet eine eigene Signatur-Autorität; ein
Beta-Schlüssel begründet keinen bezahlten Anspruch auf eine spätere öffentliche
Windows-Version.

Witness verarbeitet Sprache lokal und versucht, den geprüften Text in das beim
Aufnahmestart aktive Feld einzufügen. Erkennung oder Einfügen können fehlschlagen.
Wichtiger Text ist durch den Tester zu prüfen. Die Vorabversion ist nicht für
ungeprüfte sicherheitskritische, medizinische, rechtliche oder finanzielle
Diktate bestimmt.

Audio bleibt im Produktcode im Arbeitsspeicher. Die Datenschutzhinweise in
`WINDOWS_BETA_PRIVACY.md` beschreiben die vorgesehenen Verbindungen. Audio,
Transkript, Wortschatz, Zwischenablage und Anwendungsinhalte werden nicht
gesendet. Es gibt in dieser Beta keinen Checkout und keine Nutzung der
Mac-Zahlungslinks; Produkt-Ereignisse bleiben lokal.

Fehlerberichte dürfen keine echten Diktate, Aufnahmen, Zugangsdaten,
Zwischenablage-, Kunden- oder sonstigen vertraulichen Inhalte enthalten.
Nicht vertrauliches freiwilliges Feedback darf der Anbieter unentgeltlich zur
Fehlerbehebung und Produktverbesserung verwenden.

Die Teilnahme kann jederzeit beendet und die App entfernt werden. Lokale Daten
unter `%LOCALAPPDATA%\Witness\` können bis zur in W7 geprüften
Deinstallationsregel bestehen bleiben. Der Anbieter kann eine Beta-Version oder
den Beta-Aktivierungsdienst ändern, aussetzen oder beenden.

Die kostenlose Vorabversion wird zu Testzwecken bereitgestellt. Zwingende
gesetzliche Rechte, Haftung und Rechtsbehelfe werden nicht ausgeschlossen oder
beschränkt. Vorbehaltlich zwingender Schutzvorschriften soll tschechisches Recht
gelten. Vor einer kostenpflichtigen Windows-Version sind Angebot, Preis,
Laufzeit, Kündigung, Lieferung, Update- und Geräterechte,
Widerrufsinformationen und Vertragsbestätigung neu und konkret zu regeln.
