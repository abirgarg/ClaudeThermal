#!/bin/sh
# ClaudeThermal status line bridge.
#
# Claude Code runs this as its status line command and pipes session info as JSON
# on stdin, including your plan usage ("rate_limits"). We save only that usage
# block to ~/.claude/thermal/usage.json for the ClaudeThermal menu bar app.
#
# No credentials, no network: this script only reads stdin and writes one file.
#
# Several Claude Code sessions may run at once, and an idle one can carry stale
# numbers. So each window keeps the freshest reading: a later reset time means a
# newer window, and within one window usage never goes down.

JQ=/usr/bin/jq
[ -x "$JQ" ] || JQ=$(command -v jq) || exit 0

input=$(cat)
dir="$HOME/.claude/thermal"
file="$dir/usage.json"

# Only write when Claude Code actually sent plan limits (API-key sessions don't).
if printf '%s' "$input" | "$JQ" -e '.rate_limits.five_hour or .rate_limits.seven_day' >/dev/null 2>&1; then
  mkdir -p "$dir"
  old=$("$JQ" -c 'if type == "object" then . else {} end' "$file" 2>/dev/null) || old='{}'
  [ -n "$old" ] || old='{}'
  printf '%s' "$input" \
    | "$JQ" -c --argjson now "$(date +%s)" --argjson old "$old" '
        def newest(n; o):
          if n == null then o
          elif o == null then n
          elif (n.resets_at // 0) > (o.resets_at // 0) then n
          elif (n.resets_at // 0) < (o.resets_at // 0) then o
          elif (n.used_percentage // 0) >= (o.used_percentage // 0) then n
          else o end;
        { written_at: $now,
          five_hour: newest(.rate_limits.five_hour; $old.five_hour),
          seven_day: newest(.rate_limits.seven_day; $old.seven_day) }' \
        > "$dir/usage.json.tmp.$$" 2>/dev/null \
    && mv -f "$dir/usage.json.tmp.$$" "$file" \
    || rm -f "$dir/usage.json.tmp.$$"
fi

# The status line text Claude Code shows: "5h 37% · 7d 12%"
printf '%s' "$input" | "$JQ" -r '
  [ (.rate_limits.five_hour.used_percentage // empty | "5h \(round)%"),
    (.rate_limits.seven_day.used_percentage // empty | "7d \(round)%") ] | join(" · ")
' 2>/dev/null
