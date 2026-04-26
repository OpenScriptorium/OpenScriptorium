#!/bin/bash
# Detect Modal preempt+auto-retry on running encode jobs and, if found, kill the
# doomed retry and relaunch with the current (preempt-safe) modal_encode.py.
#
# Reads baselines from tmp/modal_baselines.txt (one line per slug: "<slug> <header_count>").
# A preempt is signalled by a NEW "Modal encode" header in the local log
# beyond what the baseline expects.
#
# Usage: scripts/eval/check_modal_preempt.sh [slug ...]
# Default slugs: qwen3_06b bge_m3

set -e
cd "$(dirname "$0")/../.."

if [ $# -gt 0 ]; then
  slugs=("$@")
else
  slugs=(qwen3_06b bge_m3)
fi

# Per-slug HF model id for relaunches. macOS bash 3.2 has no associative
# arrays, so we use a case statement.
slug_to_model() {
  case "$1" in
    qwen3_06b) echo "Qwen/Qwen3-Embedding-0.6B" ;;
    bge_m3)    echo "BAAI/bge-m3" ;;
    *) echo "" ;;
  esac
}

baseline_file="tmp/modal_baselines.txt"
touch "$baseline_file"

get_baseline() {
  local slug=$1
  grep "^${slug} " "$baseline_file" 2>/dev/null | awk '{print $2}' | tail -1
}

set_baseline() {
  local slug=$1
  local headers=$2
  grep -v "^${slug} " "$baseline_file" > "${baseline_file}.tmp" 2>/dev/null || true
  echo "${slug} ${headers}" >> "${baseline_file}.tmp"
  mv "${baseline_file}.tmp" "$baseline_file"
}

for slug in "${slugs[@]}"; do
  log="tmp/modal_${slug}.log"
  [ -f "$log" ] || { echo "${slug}: no log file, skipping"; continue; }

  cur_headers=$(grep -c 'Modal encode' "$log" || true)
  baseline=$(get_baseline "$slug")
  baseline=${baseline:-1}  # initial expected = 1 (one header per fresh launch)
  last_progress=$(tail -c 600 "$log" | tr '\r' '\n' | grep 'encoded ' | tail -1)
  done_marker=$(grep -c 'DONE:' "$log" || true)

  echo "[$slug] headers=${cur_headers}  baseline=${baseline}  done=${done_marker}"
  echo "  last: ${last_progress:-<none>}"

  if [ "$done_marker" -ge 1 ]; then
    echo "  → DONE, no action"
    continue
  fi

  if [ "$cur_headers" -gt "$baseline" ]; then
    echo "  ⚠ PREEMPT DETECTED — killing doomed retry and relaunching with preempt-safe code"

    # Stop the modal app for this slug
    app_id=$(grep -oE 'ap-[A-Za-z0-9]+' "$log" | tail -1)
    if [ -n "$app_id" ]; then
      ./scripts/train_embeddings/venv/bin/modal app stop "$app_id" --yes 2>&1 || true
    fi

    # Relaunch with the local (preempt-safe) modal_encode.py
    : > "$log"
    model=$(slug_to_model "$slug")
    MODEL="$model" SLUG="$slug" BATCH_SIZE=64 \
      nohup ./scripts/train_embeddings/venv/bin/modal run --detach \
        scripts/train_embeddings/modal_encode.py >> "$log" 2>&1 &
    echo "  relaunched as pid $!"
    set_baseline "$slug" 1
  else
    set_baseline "$slug" "$cur_headers"
  fi
done
