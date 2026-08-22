#!/usr/bin/env bash
#
# ComfyUI プロビジョニングスクリプト（RunPod Pod 起動時に 1 回だけ走らせる想定）
#
# ai-dock 系テンプレートの PROVISIONING_SCRIPT に URL を渡すか、
# web terminal で直接:
#   curl -fsSL <このファイルの raw URL> | bash
#
# 何度実行しても既存ファイルはスキップするので、途中で落ちたら再実行すればよい。
#
# 環境変数:
#   COMFYUI_DIR   ComfyUI のパス（未設定なら自動検出）
#   VENV_DIR      venv のパス (default: /workspace/venv)
#   SKIP_DEPS     1 にすると venv の作成と依存の導入をスキップ
#   MODEL_SET     starter | sdxl | flux-dev | all | none   (default: starter)
#   HF_TOKEN      Hugging Face のトークン（gated モデルを取る場合のみ）
#   SKIP_NODES    1 にするとカスタムノードの導入をスキップ

set -euo pipefail

MODEL_SET="${MODEL_SET:-starter}"
SKIP_NODES="${SKIP_NODES:-0}"
VENV_DIR="${VENV_DIR:-/workspace/venv}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# DNS
#
# コンテナ再生成のあと /etc/resolv.conf が空で上がってくることがある。その状態だと
# git も pip も名前解決に失敗する。start-comfyui.sh にも同じ関数があるが、この
# スクリプトは curl | bash で単体実行されるため意図的に自己完結させている。
# --------------------------------------------------------------------------
ensure_dns() {
    getent hosts pypi.org >/dev/null 2>&1 && return 0
    warn "名前解決に失敗している。/etc/resolv.conf を補修する。"
    printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf 2>/dev/null \
        || die "/etc/resolv.conf に書き込めない。Pod を再起動するか作り直すこと。"
    getent hosts pypi.org >/dev/null 2>&1 \
        || die "DNS を直せなかった。この Pod は捨てて作り直すのが早い。"
    log "DNS 復旧"
}

ensure_dns

# --------------------------------------------------------------------------
# ComfyUI の場所を決める
# --------------------------------------------------------------------------
detect_comfyui_dir() {
    if [[ -n "${COMFYUI_DIR:-}" ]]; then
        echo "$COMFYUI_DIR"
        return
    fi
    local candidate
    for candidate in \
        /workspace/ComfyUI \
        /workspace/comfyui \
        /opt/ComfyUI \
        /ComfyUI \
        "$HOME/ComfyUI"
    do
        if [[ -f "$candidate/main.py" ]]; then
            echo "$candidate"
            return
        fi
    done
    # 見つからなければ Network Volume 上に新規 clone する
    echo /workspace/ComfyUI
}

COMFYUI_DIR="$(detect_comfyui_dir)"

if [[ ! -f "$COMFYUI_DIR/main.py" ]]; then
    log "ComfyUI が見つからないので $COMFYUI_DIR に clone する"
    mkdir -p "$(dirname "$COMFYUI_DIR")"
    git clone --depth 1 https://github.com/comfyanonymous/ComfyUI.git "$COMFYUI_DIR"
fi

case "$COMFYUI_DIR" in
    /workspace/*) : ;;
    *) warn "ComfyUI が $COMFYUI_DIR にある（Network Volume の外）。Pod を terminate すると消える。" ;;
esac

log "ComfyUI: $COMFYUI_DIR"

MODELS_DIR="$COMFYUI_DIR/models"
NODES_DIR="$COMFYUI_DIR/custom_nodes"
mkdir -p "$NODES_DIR" \
    "$MODELS_DIR"/{checkpoints,vae,loras,controlnet,upscale_models,clip,unet,clip_vision}

# --------------------------------------------------------------------------
# venv
#
# コンテナのファイルシステムは Pod を編集・再生成すると消える。site-packages に
# 入れた依存も道連れになるので、venv は Network Volume 側に置く。torch は
# コンテナイメージの CUDA 版を --system-site-packages で共有する（venv に入れ直すと
# 数 GB のダウンロードになる）。
# --------------------------------------------------------------------------
SKIP_DEPS="${SKIP_DEPS:-0}"

if [[ "$SKIP_DEPS" == "1" ]]; then
    # モデルを足すだけのときは venv に触らない（download-models.sh がこの経路）
    PY_BIN="$VENV_DIR/bin/python"
    [[ -x "$PY_BIN" ]] || PY_BIN="$(command -v python)"
else
    if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        log "venv を作る: $VENV_DIR"
        python -m venv --system-site-packages "$VENV_DIR"
    fi
    PY_BIN="$VENV_DIR/bin/python"

    log "ComfyUI の依存を導入する（Network Volume 上なので展開に 5〜15 分かかる）"
    "$PY_BIN" -m pip install --no-input -r "$COMFYUI_DIR/requirements.txt"
fi

# --------------------------------------------------------------------------
# ダウンローダ
# --------------------------------------------------------------------------
DOWNLOADER=""
if command -v aria2c >/dev/null 2>&1; then
    DOWNLOADER=aria2c
elif command -v curl >/dev/null 2>&1; then
    DOWNLOADER=curl
else
    die "aria2c も curl も無い。どちらかを入れてから再実行のこと。"
fi

# fetch <url> <dest-dir> <filename>
fetch() {
    local url="$1" dir="$2" name="$3"
    local dest="$dir/$name"

    if [[ -s "$dest" ]]; then
        log "skip (既にある): $name"
        return 0
    fi

    log "download: $name"
    mkdir -p "$dir"

    local -a auth=()
    if [[ -n "${HF_TOKEN:-}" && "$url" == *huggingface.co* ]]; then
        auth=("Authorization: Bearer ${HF_TOKEN}")
    fi

    # 途中で失敗しても中途半端なファイルを残さないよう .part に落としてから mv
    if [[ "$DOWNLOADER" == aria2c ]]; then
        aria2c --console-log-level=warn -c -x8 -s8 -k1M \
            "${auth[@]/#/--header=}" \
            -d "$dir" -o "$name.part" "$url"
    else
        curl -fL --retry 3 --retry-delay 5 -C - \
            "${auth[@]/#/-H}" \
            -o "$dest.part" "$url"
    fi

    mv "$dest.part" "$dest"
}

# --------------------------------------------------------------------------
# カスタムノード
# --------------------------------------------------------------------------
NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager.git"
    "https://github.com/pythongosssss/ComfyUI-Custom-Scripts.git"
    "https://github.com/rgthree/rgthree-comfy.git"
    "https://github.com/cubiq/ComfyUI_essentials.git"
)

install_nodes() {
    local repo name dir
    for repo in "${NODES[@]}"; do
        name="$(basename "$repo" .git)"
        dir="$NODES_DIR/$name"
        if [[ -d "$dir/.git" ]]; then
            log "skip (既にある): $name"
            continue
        fi
        log "custom node: $name"
        git clone --depth 1 "$repo" "$dir" || { warn "clone 失敗: $name"; continue; }
        if [[ -f "$dir/requirements.txt" ]]; then
            "$PY_BIN" -m pip install --no-input -r "$dir/requirements.txt" \
                || warn "依存の導入に失敗: $name"
        fi
    done
}

# --------------------------------------------------------------------------
# モデルセット
#
# 「安く始める」ために既定は starter（FLUX.1-schnell fp8）だけにしてある。
# schnell は 4 step で絵が出るので、同じ枚数を出すのに必要な GPU 時間が一番短い。
# --------------------------------------------------------------------------
HF=https://huggingface.co

models_starter() {
    fetch "$HF/Comfy-Org/flux1-schnell/resolve/main/flux1-schnell-fp8.safetensors" \
        "$MODELS_DIR/checkpoints" "flux1-schnell-fp8.safetensors"
    fetch "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.1.0/RealESRGAN_x4plus.pth" \
        "$MODELS_DIR/upscale_models" "RealESRGAN_x4plus.pth"
}

models_sdxl() {
    fetch "$HF/stabilityai/stable-diffusion-xl-base-1.0/resolve/main/sd_xl_base_1.0.safetensors" \
        "$MODELS_DIR/checkpoints" "sd_xl_base_1.0.safetensors"
    fetch "$HF/madebyollin/sdxl-vae-fp16-fix/resolve/main/sdxl_vae.safetensors" \
        "$MODELS_DIR/vae" "sdxl_vae_fp16_fix.safetensors"
}

# 約 17GB。starter に慣れて品質を上げたくなってから取る。
models_flux_dev() {
    fetch "$HF/Comfy-Org/flux1-dev/resolve/main/flux1-dev-fp8.safetensors" \
        "$MODELS_DIR/checkpoints" "flux1-dev-fp8.safetensors"
}

download_models() {
    case "$MODEL_SET" in
        none)     log "MODEL_SET=none: モデル取得をスキップ" ;;
        starter)  models_starter ;;
        sdxl)     models_sdxl ;;
        flux-dev) models_flux_dev ;;
        all)      models_starter; models_sdxl; models_flux_dev ;;
        *)        die "MODEL_SET が不正: $MODEL_SET (starter|sdxl|flux-dev|all|none)" ;;
    esac
}

# --------------------------------------------------------------------------
main() {
    if [[ "$SKIP_NODES" == "1" ]]; then
        log "SKIP_NODES=1: カスタムノードをスキップ"
    else
        install_nodes
    fi

    download_models

    log "完了"
    echo "  ComfyUI     : $COMFYUI_DIR"
    echo "  checkpoints : $(ls -1 "$MODELS_DIR/checkpoints" 2>/dev/null | tr '\n' ' ')"
    echo "  ディスク使用 : $(du -sh "$MODELS_DIR" 2>/dev/null | cut -f1)"
    echo
    echo "起動は start-comfyui.sh から行うこと（CORS と DNS の面倒を見てくれる）:"
    echo "  bash /workspace/cloudgpu/scripts/start-comfyui.sh"
    echo
    echo "既に ComfyUI が動いている場合、新しいノード / モデルを認識させるには"
    echo "一度再起動すること。"
}

main "$@"
