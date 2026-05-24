# scripts/_claude-pretty.jq
# Converts claude --output-format stream-json events into one human-readable
# line per significant event. Used by spawn-worker.sh to produce live, tail-able
# worker logs.
#
# Run as: jq -r --unbuffered -f scripts/_claude-pretty.jq

def short(n):
  tostring | if length > n then .[0:n] + "…" else . end;

# Render an assistant or user-tool message content block.
# Returns `empty` for block types we don't want to surface (keeps log focused).
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
end
