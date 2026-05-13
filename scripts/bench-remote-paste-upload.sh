#!/usr/bin/env bash
# Benchmark the two strategies RemotePasteBridge can use to ship a paste
# image to the remote host:
#
#   legacy:    `ssh HOST mkdir -p DIR`  then  `scp FILE HOST:PATH`
#              (two separate SSH sessions; one fork each on the remote)
#   one-shot:  `cat FILE | ssh HOST "mkdir -p DIR && cat > PATH"`
#              (one SSH session; what the Swift code does today)
#
# On hosts where remote-side fork dominates wall time (high load, no swap,
# fork-bound containers), the one-shot path roughly halves paste latency.
# Use this to prove the win on a new host before/after the RemotePasteBridge
# change, or to verify the slow link still fits a usable paste experience.
#
# Usage:
#   scripts/bench-remote-paste-upload.sh [iterations]
#
# Env:
#   HOST       SSH host alias to test against (default: $GHOSTTY_REMOTE_PASTE_HOST or "dev")
#   PAYLOAD    Path to a local file to upload (default: a 30 KB synthetic webp)
#   REMOTE_DIR Remote staging dir (default: ~/.tmux/paste-images-bench)

set -euo pipefail

iterations="${1:-3}"
host="${HOST:-${GHOSTTY_REMOTE_PASTE_HOST:-dev}}"
remote_dir="${REMOTE_DIR:-~/.tmux/paste-images-bench}"
payload="${PAYLOAD:-}"

cleanup_payload=false
if [[ -z "$payload" ]]; then
    payload="$(mktemp -t ghostty-bench-payload).webp"
    # Synthesize ~30 KB of pseudo-random bytes. Not a real webp, but the
    # upload path is content-agnostic and the size matters more than the
    # bytes for measuring SSH overhead.
    head -c 30000 /dev/urandom > "$payload"
    cleanup_payload=true
fi

if [[ ! -f "$payload" ]]; then
    echo "payload file not found: $payload" >&2
    exit 1
fi

payload_size=$(wc -c < "$payload" | tr -d ' ')
echo "host:      $host"
echo "payload:   $payload  ($payload_size bytes)"
echo "remote:    $remote_dir"
echo "iters:     $iterations"
echo

now() {
    # Sub-second timing. Prefer gdate when available (BSD date can't do %N).
    if command -v gdate >/dev/null 2>&1; then
        gdate +%s.%N
    else
        python3 -c 'import time; print(time.time())'
    fi
}

elapsed() {
    python3 -c "print(f'{$2 - $1:.3f}')"
}

bench_legacy() {
    local i tag t0 t1
    for ((i = 1; i <= iterations; i++)); do
        tag="bench-legacy-$$-$i"
        t0=$(now)
        ssh "$host" "mkdir -p $remote_dir" >/dev/null
        scp -q "$payload" "$host:$remote_dir/$tag"
        t1=$(now)
        printf "  legacy   #%-2d  %s s\n" "$i" "$(elapsed "$t0" "$t1")"
    done
}

bench_oneshot() {
    local i tag t0 t1
    for ((i = 1; i <= iterations; i++)); do
        tag="bench-oneshot-$$-$i"
        t0=$(now)
        # Atomic write: stream to .part, then rename. Mirrors the Swift
        # implementation in RemotePasteBridge.uploadDataOneShot.
        ssh "$host" "set -e; mkdir -p $remote_dir; cat > $remote_dir/$tag.part; mv $remote_dir/$tag.part $remote_dir/$tag" < "$payload"
        t1=$(now)
        printf "  one-shot #%-2d  %s s\n" "$i" "$(elapsed "$t0" "$t1")"
    done
}

echo "== legacy (ssh mkdir + scp) =="
bench_legacy
echo
echo "== one-shot (cat | ssh 'mkdir && cat > tmp && mv') =="
bench_oneshot

echo
echo "Cleaning up remote artifacts..."
ssh "$host" "rm -rf $remote_dir" >/dev/null 2>&1 || true
if "$cleanup_payload"; then
    rm -f "$payload"
fi
