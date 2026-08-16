# A lab for Fulcrum's JSON log viewer.
#
# Every resource here emits a shape the viewer has to survive. Several are
# deliberately hostile: a detector that only handles well-formed JSON will
# swallow lines, hide stack traces, or run away consuming the buffer.
#
#   tilt up --port 10360 -f ~/Projects/fulcrum-jsonlab/Tiltfile

# 1. Compact single-line objects, the shape a CloudWatch EMF blob takes.
#    ~500 bytes on one line: unreadable raw, should collapse to a summary.
local_resource(
    'json-oneline',
    serve_cmd='''while true; do
      echo "{\\"_aws\\":{\\"Timestamp\\":1786497237169,\\"CloudWatchMetrics\\":[{\\"Namespace\\":\\"LAB/Database\\",\\"Dimensions\\":[[\\"Service\\",\\"Environment\\"]],\\"Metrics\\":[{\\"Name\\":\\"DbQueryDuration\\",\\"Unit\\":\\"Milliseconds\\"},{\\"Name\\":\\"DbQueryCount\\",\\"Unit\\":\\"Count\\"}]}]},\\"Service\\":\\"lab-service\\",\\"Environment\\":\\"development\\",\\"DbQueryDuration\\":0.48,\\"DbQueryCount\\":1,\\"DbQueryError\\":0,\\"QueryName\\":\\"unnamed\\",\\"TenantId\\":\\"lab-master\\"}"
      sleep 7
    done''',
)

# 2. Pretty-printed across lines, opener is exactly "{".
#    The header above it is a SEPARATE record and must not be swallowed.
local_resource(
    'json-pretty',
    serve_cmd='''while true; do
      echo "[$(date +%H:%M:%S)] INFO (lab-pretty): job finished"
      echo "{"
      echo "  \\"status\\": \\"success\\","
      echo "  \\"attempts\\": 3,"
      echo "  \\"data\\": {"
      echo "    \\"jobName\\": \\"metrics-collection\\","
      echo "    \\"durationMs\\": 842.5"
      echo "  }"
      echo "}"
      sleep 9
    done''',
)

# 3. pino-style: a labelled opener, and the header carrying the correlation id
#    sits ABOVE the block. Searching "statusCode" must return the header too —
#    this is the exact case the record grouping exists for.
local_resource(
    'json-pino',
    serve_cmd='''while true; do
      echo "[$(date '+%Y-%m-%d %H:%M:%S').011] INFO (lab-auth-service): 181d1af2-d9c7-41cf-96bb-c38699834cca POST /token/refresh completed in 13ms"
      echo "    req: {"
      echo "      \\"method\\": \\"POST\\","
      echo "      \\"url\\": \\"/auth/token/refresh\\""
      echo "    }"
      echo "    correlationId: \\"181d1af2-d9c7-41cf-96bb-c38699834cca\\""
      echo "    res: {"
      echo "      \\"statusCode\\": 200,"
      echo "      \\"headers\\": {}"
      echo "    }"
      echo "    responseTime: 13"
      sleep 11
    done''',
)

# 4. Hostile: braces inside strings, escaped quotes, and a backslash before a
#    quote. A naive depth counter opens a block here and eats the rest.
local_resource(
    'json-tricky',
    serve_cmd='''while true; do
      echo "{\\"note\\":\\"an unbalanced { brace inside a string\\",\\"path\\":\\"C:\\\\\\\\tmp\\\\\\\\\\",\\"ok\\":true}"
      echo "msg: \\"a bare { in ordinary text should not open a block\\""
      echo "{\\"emoji\\":\\"✅ 中文 \\\\u00e9\\",\\"nested\\":{\\"deep\\":{\\"deeper\\":[1,2,{\\"x\\":null}]}}}"
      sleep 13
    done''',
)

# 5. Invalid and truncated. None of these should render as a tree, and none
#    should hide the lines around them.
local_resource(
    'json-invalid',
    serve_cmd='''while true; do
      echo "[$(date +%H:%M:%S)] ERROR (lab-broken): write interrupted"
      echo "{\\"status\\":\\"partial\\","
      echo "{\\"trailing\\":\\"comma\\",}"
      echo "{unquoted: key, value: undefined}"
      echo "{\\"unterminated\\":\\"string"
      sleep 17
    done''',
)

# 6. A Node stack trace whose first line ends in "{". Collapsing this behind a
#    disclosure triangle would hide exactly what a developer needs to read.
local_resource(
    'json-stacktrace',
    serve_cmd='''while true; do
      echo "[$(date +%H:%M:%S)] ERROR (lab-crash): unhandled rejection"
      echo "    at async <anonymous> (/app/api/src/routes/test-runs.routes.ts:95:20) {"
      echo "  code: 'ERR_INVALID_STATE',"
      echo "  detail: 'run already finalized',"
      echo "  statusCode: 409"
      echo "}"
      sleep 19
    done''',
)

# 7. Big numbers and deep nesting. 13-digit timestamps must not render as
#    scientific notation; the depth cap must reject the pathological case
#    without taking the app down.
local_resource(
    'json-numbers',
    serve_cmd='''while true; do
      echo "{\\"ms\\":1786497237169,\\"ns\\":9007199254740992,\\"ratio\\":0.000001234,\\"neg\\":-42,\\"zero\\":0,\\"exp\\":1.2e5}"
      python3 -c "print('{\\"deep\\":' * 60 + 'null' + '}' * 60)"
      sleep 23
    done''',
)

# 8. An unclosed opener that never closes. The detector must give up rather
#    than consuming every line that follows it forever.
local_resource(
    'json-unclosed',
    serve_cmd='''while true; do
      echo "orphan: {"
      echo "  \\"this\\": \\"block never closes\\""
      for i in $(seq 1 6); do echo "ordinary line $i after an unclosed opener"; done
      sleep 29
    done''',
)
