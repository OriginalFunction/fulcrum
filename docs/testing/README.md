# Test fixtures

## `generate-log-corpus.swift` — the log corpus

`Tests/FulcrumKitTests/Fixtures/log-corpus.jsonl` is **generated, not captured**.

```sh
swift docs/testing/generate-log-corpus.swift Tests/FulcrumKitTests/Fixtures/log-corpus.jsonl
```

It is the fixture `SeverityScanner` is validated against: 3,428 lines of tilt
JSONL from a fictional microservice project, reproducing the emitter formats,
severity-token columns, ANSI byte layouts, embedded JSON and false-positive
shapes that a real `tilt logs --json` dump contains. The generator is
deterministic — same source, byte-identical output, so regenerating an
unchanged generator produces a zero-line diff.

**Add new shapes to the generator, never to the `.jsonl`.** A hand-edit to the
fixture is silently discarded by the next regeneration, and there is no record
of what was meant. Add the shape to the emitter that would produce it (or add
an emitter), re-run the script, and re-derive the counts pinned by doc comments
in `LogCorpusTests.swift` and `SeverityScannerTests.swift` — those comments
state measured numbers, and this project has already had to fix three separate
cases of a comment claiming a number the code did not produce.

If the new shape *should* be flagged, add it to `expectedCorpusFlags` in
`SeverityScannerTests.swift`. If it should *not*, adding it and watching the
corpus test stay green is exactly the precision evidence the fixture exists for.

Measured on the current corpus:

| | |
|---|---|
| lines → rows | 3,428 → 2,854 (147 JSON blocks) |
| flagged `>= .error` | 46, zero false positives |
| flagged `.warning` | 10 |
| ANSI escape lines / SGR 31 red | 356 / 30 |
| `ERROR`/`FATAL` substring / word-boundary | 25 / 19 |
| stack-frame lines (`    at ` or `\tat ` prefix) | 212 |
| `statusCode` fields | 22 — all 200 or 304, **zero** 5xx |
| pino `"level":50` records | 3 |

Why it is generated: it used to be a verbatim capture from one developer's
running project. No credentials survived that capture, but the file carried a
commercial product's internal hostnames, service names, tenant slugs, live
record ids, API route shapes and database table names — and this repository is
public. The rules key on structure, never on anyone's names, so a synthesis
keeps every test meaningful.

## `capture-log-corpus.sh`

Captures a reference sample from **your own** running tilt instance, to a temp
file. Read-only, and it refuses to write under `Fixtures/`.

This is how the shapes in the generator were learned, and it is how you learn a
new one — a real emitter's exact ANSI byte layout is not guessable. Its output
is a working file, not a fixture: it still contains your project's hostnames,
service names, record ids and table names. Do not commit it.

## `jsonlab.Tiltfile`

Eight resources, each emitting a log shape the JSON viewer has to survive.
Several are deliberately hostile — a detector that only handles well-formed
JSON will swallow lines, hide stack traces, or run away consuming the buffer.

```sh
mkdir -p ~/Projects/fulcrum-jsonlab
cp docs/testing/jsonlab.Tiltfile ~/Projects/fulcrum-jsonlab/Tiltfile
cd ~/Projects/fulcrum-jsonlab && tilt up --port 10360 --stream
```

Measured against the shipped detector on 2026-08-14 (404 captured lines):

| resource | lines → rows | blocks (parsed) | expected |
|---|---|---|---|
| `json-oneline` | 19 → 19 | 16 (16) | compact `_aws` blobs collapse |
| `json-pretty` | 111 → 27 | 12 (12) | multi-line objects collapse, header stays its own row |
| `json-pino` | 113 → 53 | 20 (20) | labelled `res: {` blocks collapse |
| `json-tricky` | 30 → 30 | 9 (9) | braces inside strings never open a block |
| `json-numbers` | 13 → 13 | 10 (10) | 13-digit ints, 60-deep nesting |
| `json-invalid` | 38 → 38 | **0** | malformed JSON is never a block |
| `json-stacktrace` | 39 → 39 | **0** | a stack trace is never collapsed out of sight |
| `json-unclosed` | 35 → 35 | **0** | a runaway opener consumes nothing |

Every resource flattens back to its exact input count: no line is ever lost.
The three zero-block rows are the point — each is a construct that *looks*
like JSON to a naive brace counter.
