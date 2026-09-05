#!/usr/bin/env bash
#
# LLM のモデルだけを後から追加取得する（Pod 内で実行）。
# 中身は provision-llm.sh の薄いラッパー。Open WebUI には触らない。
#
#   ./pull-llm-models.sh big
#   ./pull-llm-models.sh --model qwen3:32b
#
# ollama serve が既に動いていればそれを使い、動いていなければ一時的に立てる。

set -euo pipefail

# symlink（/workspace/bin/llm-models）から呼ばれても実体の隣を指すようにする
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

usage() {
    cat <<'USAGE'
usage:
  pull-llm-models.sh <starter|ja|coder|big|oss|all>
  pull-llm-models.sh --model <ollama のモデル名> [--model ...]

セット:
  starter  qwen3:8b                          16GB VRAM 以上。まずこれ
  ja       qwen3:14b gemma3:12b              日本語重視。24GB VRAM 向け
  coder    qwen2.5-coder:14b                 コード用
  big      qwen3:30b-a3b                     MoE。24GB でも速い
  oss      gpt-oss:20b                       Apache-2.0
USAGE
}

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

if [[ "$1" != "--model" ]]; then
    case "$1" in
        -h|--help) usage; exit 0 ;;
    esac
    exec env LLM_MODEL_SET="$1" SKIP_WEBUI=1 bash "$HERE/provision-llm.sh"
fi

models=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) models+=("$2"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "不明な引数: $1" >&2; usage; exit 1 ;;
    esac
done

exec env LLM_MODELS="${models[*]}" SKIP_WEBUI=1 bash "$HERE/provision-llm.sh"
