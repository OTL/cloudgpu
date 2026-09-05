#!/usr/bin/env bash
#
# モデルだけを後から追加取得する（Pod 内で実行）。
# 中身は provision.sh の薄いラッパー。カスタムノードには触らない。
#
#   ./download-models.sh sdxl
#   ./download-models.sh flux-dev
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
  download-models.sh <starter|sdxl|flux-dev|all>
  download-models.sh --url <URL> --dir <models 配下のサブディレクトリ> --name <ファイル名>
USAGE
}

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

if [[ "$1" != "--url" ]]; then
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
