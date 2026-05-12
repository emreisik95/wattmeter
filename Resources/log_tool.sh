#!/bin/sh
# Wattmeter tool attribution wrapper. Invoked by Claude Code Pre/PostToolUse hooks.
# $1 = "pre" or "post"; stdin = JSON event payload.
# Appends one JSONL line to ~/.claude/wattmeter_tools.jsonl. Fail-closed: always exit 0.
phase="${1:-unknown}"
out="$HOME/.claude/wattmeter_tools.jsonl"
ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
payload=$(cat 2>/dev/null || printf '')
mkdir -p "$HOME/.claude" 2>/dev/null || exit 0
tool=""
if command -v jq >/dev/null 2>&1; then
    tool=$(printf '%s' "$payload" | jq -rc '.tool_name // .tool // empty' 2>/dev/null || printf '')
fi
esc_payload=$(printf '%s' "$payload" | tr -d '\n\r' | sed 's/\\/\\\\/g; s/"/\\"/g')
esc_tool=$(printf '%s' "$tool" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf '{"ts":"%s","phase":"%s","tool":"%s","raw":"%s"}\n' \
    "$ts" "$phase" "$esc_tool" "$esc_payload" >> "$out" 2>/dev/null
exit 0
