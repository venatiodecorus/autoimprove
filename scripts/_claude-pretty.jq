# scripts/_claude-pretty.jq
# Converts claude --output-format stream-json events into one human-readable
# line per significant event. Used by spawn-worker.sh to produce live,
# tail-able worker logs.
#
# Run as: jq -R -r --unbuffered -f scripts/_claude-pretty.jq
#
# -R reads input as raw strings (one per line). We then try-parse each line
# as JSON. This matters because sbx prints its own plain-text status lines
# (image-pull progress, "✓ Created sandbox", etc.) to stdout BEFORE claude
# starts streaming, and we need to pass those through instead of crashing
# (a crashed jq closes the pipe and SIGPIPEs sbx with exit 141).

def short(n):
  tostring | if length > n then .[0:n] + "…" else . end;

def block:
  if .type == "text" then
    "  • " + ((.text // "") | gsub("\n"; " ") | short(280))
  elif .type == "tool_use" then
    "  → " + (.name // "?") + ": " + ((.input // {}) | tostring | short(220))
  elif .type == "tool_result" then
    "  ← " + ((.content // "") | tostring | gsub("\n"; " ↵ ") | short(220))
  else
    empty
  end;

def render_event:
  if .type == "system" then
    (if .subtype == "init" then
       "[init] session=\(.session_id // "?")  model=\(.model // "?")"
     else empty end)
  elif .type == "assistant" then
    ((.message.content // []) | map(block) | .[])
  elif .type == "user" and ((.message.content // null) | type) == "array" then
    ((.message.content // []) | map(block) | .[])
  elif .type == "result" then
    "[done] subtype=\(.subtype // "?")  cost=$\(.total_cost_usd // 0)  turns=\(.num_turns // "?")  ms=\(.duration_ms // 0)"
  else
    empty
  end;

# Per input line: try to parse as JSON. If it parses, render the event;
# if it doesn't, emit the raw line with a "[raw]" prefix so sbx-level
# status messages stay visible without crashing the pipeline.
#
# NOTE: must use `try…catch null` here, NOT `fromjson?`. The `?` postfix
# emits empty on error, which would propagate as no value and silently
# drop the line. `try…catch null` gives us an explicit null we can test.
. as $raw
| ( try ($raw | fromjson) catch null ) as $j
| if $j == null then
    if ($raw | length) == 0 then empty
    else "[raw] " + $raw end
  else
    $j | render_event
  end
