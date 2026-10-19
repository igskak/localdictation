# Phase 9.1 synthetic starting baseline

Recorded on 2026-10-19 with the Phase 9 implementation before changes to
production cleanup. The examples below are invented text, not user dictation.
`<br>` denotes a newline. Lexical comparison uses the existing word scanner,
case-folded; it is a diagnostic, not the phase's eventual surface-equivalence
release gate. All six examples preserve that sequence in legacy Conservative
and are idempotent when Conservative is applied twice.

| Language | Raw | Legacy Conservative | Phase 9 Clean |
| --- | --- | --- | --- |
| EN | shopping: first, apples, second, pears | Shopping: first, apples, second, pears. | Shopping:<br>1., Apples,<br>2., Pears. |
| DE | betrag 20 % und 25 € | Betrag 20 % und 25 € | Betrag 20 % und 25 € |
| RU | покупки: во - первых яблоки, во - вторых груши | Покупки: во - первых яблоки, во - вторых груши. | Покупки: во - первых яблоки, во - вторых груши. |
| UK | покупки: по - перше яблука, по - друге груші | Покупки: по - перше яблука, по - друге груші. | Покупки: по - перше яблука, по - друге груші. |
| EN | meet at 12 : 30 | Meet at 12: 30. | Meet at 12: 30. |
| EN | the first version arrives on Tuesday | The first version arrives on Tuesday. | The first version arrives on Tuesday. |

The list output shows the comma handling defect; the time output demonstrates
that existing spacing does not canonicalize a complete time. This is a small
synthetic regression baseline, not a corpus, precision measurement, timing-gap
test, preference study, or evidence to enable a production structural policy.
