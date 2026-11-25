#!/usr/bin/env bash
# codex-run.sh <role> <prompt-file> <out-file> [workdir]
#   role: recon | review | exec | verify
# Prints only a one-line status. Full Codex transcript goes to a log file that CC must not read
# unless the run failed.
set -uo pipefail

role="${1:-}"; prompt="${2:-}"; out="${3:-}"; wd="${4:-$PWD}"
if [ -z "$role" ] || [ -z "$prompt" ] || [ -z "$out" ]; then
  echo "usage: codex-run.sh <recon|review|exec|verify> <prompt-file> <out-file> [workdir]" >&2; exit 2
fi
MODEL="${CODEX_COLLAB_MODEL:-gpt-6.2-astra}"
case "$role" in
  recon)  sandbox=read-only;       effort=high  ;;
  review) sandbox=read-only;       effort=xhigh ;;
  exec)   sandbox=workspace-write; effort=xhigh ;;
  verify) sandbox=workspace-write; effort=high  ;;
  *) echo "unknown role: $role" >&2; exit 2 ;;
esac
effort="${CODEX_COLLAB_EFFORT:-$effort}"
[ -f "$prompt" ] || { echo "prompt file not found: $prompt" >&2; exit 2; }
[ -d "$wd" ] || { echo "workdir not found: $wd" >&2; exit 2; }

outdir="$(cd "$(dirname "$out")" 2>/dev/null && pwd)" || { mkdir -p "$(dirname "$out")"; outdir="$(cd "$(dirname "$out")" && pwd)"; }
out="$outdir/$(basename "$out")"
logdir="$outdir/logs"; mkdir -p "$logdir"
log="$logdir/$(basename "$out" .md).log"
rm -f "$out"

# The verifier may run tests but must not edit tracked files: snapshot git state before/after.
snap() { git -C "$wd" status --porcelain 2>/dev/null | grep -v '\.codex-collab/' || true; }
[ "$role" = verify ] && before="$(snap)"

start=$(date +%s)
codex exec \
  -m "$MODEL" \
  -c model_reasoning_effort="$effort" \
  -s "$sandbox" \
  -C "$wd" \
  -o "$out" \
  - < "$prompt" > "$log" 2>&1
rc=$?
secs=$(( $(date +%s) - start ))

if [ $rc -ne 0 ] || [ ! -s "$out" ]; then
  echo "FAILED role=$role rc=$rc ${secs}s log=$log  (last lines below)"
  tail -n 15 "$log"
  exit 1
fi

warn=""
if [ "$role" = verify ]; then
  after="$(snap)"
  [ "$before" != "$after" ] && warn=" WARNING=verifier-changed-worktree(run: git -C $wd status)"
fi
words=$(wc -w < "$out" | tr -d ' ')
echo "OK role=$role model=$MODEL effort=$effort ${secs}s words=$words out=$out$warn"
