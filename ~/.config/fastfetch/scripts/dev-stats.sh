#!/usr/bin/env bash

CACHE_DIR="/tmp/fastfetch_dev_cache"
mkdir -p "$CACHE_DIR"

GH_USER="realDarkCode"
WAKATIME_API_KEY="YOUR_WAKATIME_API_KEY"

# ---------------------------------------------------------
# Generic background cache refresher
# ---------------------------------------------------------

refresh_background() {
    local cache="$1"
    local max_age="$2"
    shift 2

    local lock="${cache}.lock"

    # Don't start another refresh if one is already running
    (
        flock -n 9 || exit 0

        "$@" > "${cache}.tmp" 2>/dev/null

        # Only replace cache if we actually got something
        if [ -s "${cache}.tmp" ]; then
            mv -f "${cache}.tmp" "$cache"
        else
            rm -f "${cache}.tmp"
        fi

    ) 9>"$lock" &
}

# ---------------------------------------------------------
# GitHub
# ---------------------------------------------------------

fetch_github_commit() {
    python3 -c '
import urllib.request
import json
import sys
from datetime import datetime, timezone

user = sys.argv[1]

url = f"https://api.github.com/users/{user}/events/public"

req = urllib.request.Request(
    url,
    headers={"User-Agent": "Fastfetch-Script"}
)

try:
    with urllib.request.urlopen(req, timeout=2.5) as resp:
        events = json.loads(resp.read().decode())

    for ev in events:
        if ev.get("type") == "PushEvent":

            repo = ev["repo"]["name"].split("/")[-1]

            created_str = ev["created_at"]
            created = datetime.fromisoformat(
                created_str.replace("Z", "+00:00")
            )

            now = datetime.now(timezone.utc)
            diff = int((now - created).total_seconds())

            if diff < 60:
                rel = f"{diff}s ago"
            elif diff < 3600:
                rel = f"{diff // 60}m ago"
            elif diff < 86400:
                rel = f"{diff // 3600}h ago"
            else:
                rel = f"{diff // 86400}d ago"

            print(f"{repo} ({rel})")
            sys.exit(0)

    print("No recent pushes")

except Exception:
    print("N/A")
' "$GH_USER"
}

get_github_commit() {
    local cache="$CACHE_DIR/gh_commit.txt"
    local max_age=600

    # Start background refresh if cache is missing/stale
    if [ ! -f "$cache" ] || \
       [ $(($(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0))) -gt "$max_age" ]; then

        refresh_background \
            "$cache" \
            "$max_age" \
            fetch_github_commit
    fi

    # Return immediately using existing cache
    cat "$cache" 2>/dev/null || echo "N/A"
}

# ---------------------------------------------------------
# WakaTime
# ---------------------------------------------------------

fetch_wakatime_stats() {

    # Prefer wakatime-cli
    if command -v wakatime-cli &>/dev/null; then
        local today
        today=$(wakatime-cli --today 2>/dev/null)

        if [ -n "$today" ]; then
            echo "$today"
            return
        fi
    fi

    # API fallback
    if [ -n "$WAKATIME_API_KEY" ] &&
       [ "$WAKATIME_API_KEY" != "YOUR_WAKATIME_API_KEY" ]; then

        local auth
        auth=$(printf '%s' "$WAKATIME_API_KEY" | base64 -w 0)

        local res
        res=$(curl -s \
            --max-time 2 \
            -H "Authorization: Basic $auth" \
            "https://wakatime.com/api/v1/users/current/summaries?range=Today" \
            2>/dev/null)

        local time_text
        time_text=$(echo "$res" |
            grep -o '"text": "[^"]*"' |
            head -n 1 |
            cut -d'"' -f4)

        echo "${time_text:-0 mins}"
        return
    fi

    echo "0 mins"
}

get_wakatime_stats() {
    local cache="$CACHE_DIR/wakatime_stats.txt"
    local max_age=900

    # Start background refresh if cache is missing/stale
    if [ ! -f "$cache" ] || \
       [ $(($(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0))) -gt "$max_age" ]; then

        refresh_background \
            "$cache" \
            "$max_age" \
            fetch_wakatime_stats
    fi

    # Return immediately using existing cache
    cat "$cache" 2>/dev/null || echo "0 mins"
}

# ---------------------------------------------------------
# Fastfetch interface
# ---------------------------------------------------------

case "$1" in
    gh-commit)
        get_github_commit
        ;;

    waka-stats)
        get_wakatime_stats
        ;;
esac