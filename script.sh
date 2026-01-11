#!/usr/bin/env bash
set -euo pipefail

# ---------
# CONFIG
# ---------
DATASET="${DATASET:-hotpotqa}"
SPLIT="${SPLIT:-validation}"

# Build index size (bigger is better, but slower). Matches your intended setup.
INDEX_MAX_EXAMPLES="${INDEX_MAX_EXAMPLES:-200}"

# Eval size (keep moderate for iteration).
EVAL_MAX_EXAMPLES="${EVAL_MAX_EXAMPLES:-50}"

# If your CLI supports these flags, set them here and they will be used:
# TOP_K_LIST="5 10"
# MAX_HOPS_LIST="1 2"
TOP_K_LIST="${TOP_K_LIST:-5 10}"
MAX_HOPS_LIST="${MAX_HOPS_LIST:-1 2}"

# Optional: different retriever settings if your CLI supports flags (bm25/faiss)
BM25_K_LIST="${BM25_K_LIST:-20}"
FAISS_K_LIST="${FAISS_K_LIST:-20}"

# Optional: different embedding models if your CLI supports --embed-model
EMBED_MODELS="${EMBED_MODELS:-sentence-transformers/all-MiniLM-L6-v2}"

# ---------
# Helpers
# ---------

ts() { date +"%Y%m%d_%H%M%S"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1"; exit 1; }
}

# Move outputs produced by the CLI from ./runs into a unique run folder
collect_run_artifacts() {
  local dest="$1"
  mkdir -p "$dest"

  # Save run metadata
  python -V > "$dest/python_version.txt" 2>&1 || true
  pip freeze > "$dest/pip_freeze.txt" 2>&1 || true

  # Collect known outputs if they exist
  if [[ -f runs/results.csv ]]; then mv runs/results.csv "$dest/"; fi
  if [[ -f runs/trulens_leaderboard.csv ]]; then mv runs/trulens_leaderboard.csv "$dest/"; fi
  if [[ -f runs/traces.jsonl ]]; then mv runs/traces.jsonl "$dest/"; fi
  if [[ -f runs/index_meta.json ]]; then cp runs/index_meta.json "$dest/"; fi

  # If something else is generated in runs/, preserve it too
  shopt -s nullglob
  for f in runs/*; do
    # Skip if already moved
    [[ -e "$f" ]] || continue
    mv "$f" "$dest/" || true
  done
  shopt -u nullglob
}

# Try to run a benchmark with optional flags that may or may not exist.
# If a flag is unsupported, your CLI will fail; you can remove those blocks.
run_benchmark_one() {
  local run_dir="$1"; shift
  local cmd="$*"

  mkdir -p "$run_dir"
  echo "$cmd" > "$run_dir/run_cmd.txt"

  echo "==> Running: $cmd"
  # Clean runs/ to avoid mixing outputs
  rm -f runs/results.csv runs/trulens_leaderboard.csv runs/traces.jsonl 2>/dev/null || true

  eval "$cmd"

  collect_run_artifacts "$run_dir"
  echo "==> Saved to: $run_dir"
}

# ---------
# Sanity checks
# ---------
need_cmd python
mkdir -p runs

# ---------
# 0) Build index ONCE for the suite
# ---------
INDEX_TAG="idx${INDEX_MAX_EXAMPLES}_${DATASET}_${SPLIT}_$(ts)"
INDEX_DIR="runs/${INDEX_TAG}"
mkdir -p "$INDEX_DIR"
echo "python -m otel_native_eval.cli build-index --dataset ${DATASET} --split ${SPLIT} --max-examples ${INDEX_MAX_EXAMPLES}" > "$INDEX_DIR/run_cmd.txt"

echo "==> Building index..."
rm -f runs/index_meta.json 2>/dev/null || true
python -m otel_native_eval.cli build-index --dataset "${DATASET}" --split "${SPLIT}" --max-examples "${INDEX_MAX_EXAMPLES}"
collect_run_artifacts "$INDEX_DIR"

# ---------
# 1) Benchmark suite
#    - baseline (your current)
#    - top_k sweep
#    - max_hops sweep
#    - (optional) retriever k sweep
#    - (optional) embed model sweep
#
# IMPORTANT:
# If your CLI does not support flags like --top-k, --max-hops, --bm25-k, --faiss-k, --embed-model,
# remove those extra flags below and keep only the baseline run.
# ---------

BASE_TAG="eval${EVAL_MAX_EXAMPLES}_${DATASET}_${SPLIT}_$(ts)"

# 1A) Baseline (no extra flags, always works)
run_benchmark_one "runs/${BASE_TAG}__baseline" \
  "python -m otel_native_eval.cli run-benchmark --dataset ${DATASET} --split ${SPLIT} --max-examples ${EVAL_MAX_EXAMPLES}"

# 1B) top_k sweep (only if supported)
for TOPK in ${TOP_K_LIST}; do
  run_benchmark_one "runs/${BASE_TAG}__topk_${TOPK}" \
    "python -m otel_native_eval.cli run-benchmark --dataset ${DATASET} --split ${SPLIT} --max-examples ${EVAL_MAX_EXAMPLES} --top-k ${TOPK}"
done

# 1C) max_hops sweep (only if supported)
for HOPS in ${MAX_HOPS_LIST}; do
  run_benchmark_one "runs/${BASE_TAG}__hops_${HOPS}" \
    "python -m otel_native_eval.cli run-benchmark --dataset ${DATASET} --split ${SPLIT} --max-examples ${EVAL_MAX_EXAMPLES} --max-hops ${HOPS}"
done

# 1D) retriever k sweep (only if supported)
for BM25K in ${BM25_K_LIST}; do
  for FAISSK in ${FAISS_K_LIST}; do
    run_benchmark_one "runs/${BASE_TAG}__bm25_${BM25K}__faiss_${FAISSK}" \
      "python -m otel_native_eval.cli run-benchmark --dataset ${DATASET} --split ${SPLIT} --max-examples ${EVAL_MAX_EXAMPLES} --bm25-k ${BM25K} --faiss-k ${FAISSK}"
  done
done

# 1E) embedding model sweep (only if supported)
for EMB in ${EMBED_MODELS}; do
  # Replace slashes for folder safety
  SAFE_EMB="${EMB//\//_}"
  run_benchmark_one "runs/${BASE_TAG}__embed_${SAFE_EMB}" \
    "python -m otel_native_eval.cli run-benchmark --dataset ${DATASET} --split ${SPLIT} --max-examples ${EVAL_MAX_EXAMPLES} --embed-model ${EMB}"
done

echo "✅ Suite complete. All runs saved under: runs/${BASE_TAG}*"

