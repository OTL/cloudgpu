#!/usr/bin/env bash
#
# 短いコマンド名を /workspace/bin に置く（Pod 内で 1 回だけ実行）。
#
#   bash /workspace/cloudgpu/scripts/bootstrap.sh
#
# 以降はこれで済む:
#
#   /workspace/bin/comfy            ComfyUI を起動
#   . /workspace/bin/rc             PATH を通す。以降は comfy だけで動く
#
# /workspace は Network Volume なので、Pod を作り直しても消えない。
# 消えるのはコンテナ側（PATH と ~/.bashrc）だけなので、再生成のあとに
# 通したくなったら `. /workspace/bin/rc` を叩き直す。

set -euo pipefail

BIN_DIR="${BIN_DIR:-/workspace/bin}"
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

log() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }

mkdir -p "$BIN_DIR"

# コマンド名 -> 実体
link() {
    ln -sfn "$SCRIPT_DIR/$2" "$BIN_DIR/$1"
    log "$BIN_DIR/$1 -> $2"
}

link comfy        start-comfyui.sh
link comfy-models download-models.sh
link comfy-setup  provision.sh
link comfy-get    fetch-outputs.sh

cat > "$BIN_DIR/rc" <<'RC'
# . /workspace/bin/rc
# コンテナが作り直されるたびに読み込み直すこと。
export PATH="/workspace/bin:$PATH"
alias comfy-log='tmux attach -t comfy'
alias comfy-stop='tmux kill-session -t comfy'
cd /workspace
RC
log "$BIN_DIR/rc"

cat <<MSG

使い方:

  /workspace/bin/comfy          そのまま起動する（PATH を通さなくてよい）

  . /workspace/bin/rc           PATH を通す。以降このシェルでは:
    comfy                         起動
    comfy-models starter          モデル取得
    comfy-log                     ログを見る (抜けるのは Ctrl+B -> D)
    comfy-stop                    停止

コンテナを作り直したあとは rc を読み込み直すこと。
MSG
