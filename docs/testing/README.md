# Test fixtures

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
