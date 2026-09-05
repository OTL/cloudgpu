#!/usr/bin/env bash
#
# モデルだけを後から追加取得する（Pod 内で実行）。
# 中身は provision.sh の薄いラッパー。カスタムノードには触らない。
#
#   ./download-models.sh sdxl
#   ./download-models.sh flux-dev
#   ./download-models.sh uncensored
#   HF_TOKEN=hf_xxx ./download-models.sh flux-dev
#
# 任意の URL を直接指定することもできる:
#   ./download-models.sh --url <URL> --dir loras --name mylora.safetensors

set -euo pipefail

# symlink（/workspace/bin/comfy-models）から呼ばれても実体の隣を指すようにする
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

usage() {
    cat <<'USAGE'
usage:
  download-models.sh <starter|sdxl|flux-dev|uncensored|pony|all>
  download-models.sh --url <URL> --dir <models 配下のサブディレクトリ> --name <ファイル名>

セット:
  starter     FLUX.1-schnell fp8 + RealESRGAN     まずこれ
  sdxl        SDXL base 1.0 + VAE                 LoRA / ControlNet の資産が多い
  flux-dev    FLUX.1-dev fp8                      品質重視。商用不可
  uncensored  Illustrious-XL v1.0 + VAE           検閲なし（NSFW 可）。SDXL 系
  pony        Pony Diffusion V6 XL + VAE          同上。LoRA の資産が多い

  all は uncensored / pony を含まない。
  CivitAI から取るときは CIVITAI_TOKEN を設定して --url を使う。
USAGE
}

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

if [[ "$1" != "--url" ]]; then
    case "$1" in
        -h|--help) usage; exit 0 ;;
    esac
    exec env MODEL_SET="$1" SKIP_NODES=1 SKIP_DEPS=1 bash "$HERE/provision.sh"
fi

# --- 任意 URL モード -------------------------------------------------------
url="" subdir="" name=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)  url="$2";    shift 2 ;;
        --dir)  subdir="$2"; shift 2 ;;
        --name) name="$2";   shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "不明な引数: $1" >&2; usage; exit 1 ;;
    esac
done

[[ -n "$url" && -n "$subdir" ]] || { usage; exit 1; }
[[ -n "$name" ]] || name="$(basename "${url%%\?*}")"

COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"
dest_dir="$COMFYUI_DIR/models/$subdir"
mkdir -p "$dest_dir"

if [[ -s "$dest_dir/$name" ]]; then
    echo "既にある: $dest_dir/$name"
    exit 0
fi

declare -a auth=()
if [[ -n "${HF_TOKEN:-}" && "$url" == *huggingface.co* ]]; then
    auth=("Authorization: Bearer ${HF_TOKEN}")
elif [[ -n "${CIVITAI_TOKEN:-}" && "$url" == *civitai.com* ]]; then
    auth=("Authorization: Bearer ${CIVITAI_TOKEN}")
fi

if command -v aria2c >/dev/null 2>&1; then
    aria2c --console-log-level=warn -c -x8 -s8 -k1M "${auth[@]/#/--header=}" \
        -d "$dest_dir" -o "$name.part" "$url"
else
    curl -fL --retry 3 --retry-delay 5 -C - "${auth[@]/#/-H}" \
        -o "$dest_dir/$name.part" "$url"
fi

mv "$dest_dir/$name.part" "$dest_dir/$name"
echo "保存した: $dest_dir/$name"
