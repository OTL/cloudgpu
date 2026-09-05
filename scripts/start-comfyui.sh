#!/usr/bin/env bash
#
# ComfyUI を起動する（Pod 内で実行）。
#
#   bash /workspace/cloudgpu/scripts/start-comfyui.sh
#
# Pod を作り直すたびに踏む地雷を全部踏み抜いてから起動する:
#
#   - DNS が壊れた状態で立ち上がることがある      -> resolv.conf を補修
#   - コンテナ再生成で pip パッケージが消える      -> venv を Network Volume に置く
#   - proxy.runpod.net 経由だと ComfyUI が 403     -> --enable-cors-header
#
# 環境変数:
#   PORT          待ち受けポート (default: 8188)
#   COMFYUI_DIR   ComfyUI のパス (default: /workspace/ComfyUI)
#   VENV_DIR      venv のパス   (default: /workspace/venv)
#   FOREGROUND    1 にすると tmux を使わず前面で実行
#   REINSTALL     1 にすると venv の依存を入れ直す
#   SELF_UPDATE   0 にすると起動前の git pull をスキップ

set -euo pipefail

PORT="${PORT:-8188}"
COMFYUI_DIR="${COMFYUI_DIR:-/workspace/ComfyUI}"
VENV_DIR="${VENV_DIR:-/workspace/venv}"
FOREGROUND="${FOREGROUND:-0}"
REINSTALL="${REINSTALL:-0}"
SELF_UPDATE="${SELF_UPDATE:-1}"
SESSION=comfy

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
REPO_DIR="$(cd "$(dirname "$SELF")/.." && pwd)"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# 自己更新
#
# Pod を作り直すたびに手で git pull して bootstrap し直すのが面倒なので、起動前に
# ここでやる。スクリプト自身が書き換わった場合、bash は実行中のファイルを
# 読み進めるため途中から別の内容を読んでしまう。更新されたら exec で入り直す。
# --------------------------------------------------------------------------
self_update() {
    [[ "$SELF_UPDATE" == "1" ]] || return 0
    [[ -d "$REPO_DIR/.git" ]] || return 0

    local before after
    before="$(cksum < "$SELF")"

    if ! git -C "$REPO_DIR" pull --ff-only --quiet 2>/dev/null; then
        warn "git pull に失敗した（オフライン / ローカル変更あり）。今あるもので起動する。"
        return 0
    fi

    # 短縮コマンドの追加・改名に追従する
    [[ -x "$REPO_DIR/scripts/bootstrap.sh" ]] \
        && bash "$REPO_DIR/scripts/bootstrap.sh" >/dev/null 2>&1

    after="$(cksum < "$SELF")"
    if [[ "$before" != "$after" ]]; then
        log "起動スクリプトが更新された。読み込み直す。"
        SELF_UPDATE=0 exec bash "$SELF" "$@"
    fi
}

# --------------------------------------------------------------------------
# DNS
#
# コンテナが作り直されたあと /etc/resolv.conf が空で上がってくることがある。
# その状態だと pip も git も名前解決できずに落ちる。
# --------------------------------------------------------------------------
ensure_dns() {
    if getent hosts pypi.org >/dev/null 2>&1; then
        return 0
    fi
    warn "名前解決に失敗している。/etc/resolv.conf を補修する。"
    if ! printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf 2>/dev/null; then
        die "/etc/resolv.conf に書き込めない。Pod を再起動するか作り直すこと。"
    fi
    getent hosts pypi.org >/dev/null 2>&1 \
        || die "DNS を直せなかった。この Pod は捨てて作り直すのが早い。"
    log "DNS 復旧"
}

# --------------------------------------------------------------------------
# venv
#
# コンテナのファイルシステムは Pod を編集・再生成すると消える。site-packages も
# 一緒に消えるので、venv は Network Volume 側に置く。
# torch はコンテナイメージに CUDA 版が入っているため --system-site-packages で
# 共有する（venv 側に入れ直すと数 GB のダウンロードになる）。
# --------------------------------------------------------------------------
ensure_venv() {
    [[ -f "$COMFYUI_DIR/main.py" ]] \
        || die "ComfyUI が $COMFYUI_DIR に無い。先に provision.sh を実行すること。"

    if [[ ! -x "$VENV_DIR/bin/python" ]]; then
        log "venv を作る: $VENV_DIR"
        python -m venv --system-site-packages "$VENV_DIR"
        REINSTALL=1
    fi

    # 依存が欠けていないか一番落ちやすいところで確認する
    if [[ "$REINSTALL" != "1" ]] \
        && ! "$VENV_DIR/bin/python" -c "import sqlalchemy, aiohttp, torch" >/dev/null 2>&1
    then
        warn "venv の依存が欠けている。入れ直す。"
        REINSTALL=1
    fi

    if [[ "$REINSTALL" == "1" ]]; then
        log "依存を導入する（Network Volume 上なので展開に 5〜15 分かかる）"
        "$VENV_DIR/bin/python" -m pip install --no-input \
            -r "$COMFYUI_DIR/requirements.txt"
    fi
}

# --------------------------------------------------------------------------
# 公開 URL
# --------------------------------------------------------------------------
public_url() {
    [[ -n "${RUNPOD_POD_ID:-}" ]] || return 1
    echo "https://${RUNPOD_POD_ID}-${PORT}.proxy.runpod.net"
}

# --------------------------------------------------------------------------
# 起動
#
# --enable-cors-header が無いと ComfyUI の origin_only_middleware が
# 'Sec-Fetch-Site: cross-site' のリクエストを 403 で弾く。RunPod のプロキシ越しに
# 別タブから開くとこれに該当するため、本文の無い 403 が返って原因が分かりにくい。
# --------------------------------------------------------------------------
build_command() {
    local -a cmd=(
        "$VENV_DIR/bin/python" main.py
        --listen 0.0.0.0
        --port "$PORT"
    )
    local url
    if url="$(public_url)"; then
        cmd+=(--enable-cors-header "$url")
    else
        warn "RUNPOD_POD_ID が無いのでオリジンを特定できない。CORS を '*' で開ける。"
        cmd+=(--enable-cors-header)
    fi
    printf '%q ' "${cmd[@]}"
}

main() {
    ensure_dns
    self_update "$@"
    ensure_venv

    local cmd
    cmd="$(build_command)"

    if [[ "$FOREGROUND" == "1" ]] || ! command -v tmux >/dev/null 2>&1; then
        log "起動（前面）"
        cd "$COMFYUI_DIR"
        eval "exec $cmd"
    fi

    if tmux has-session -t "$SESSION" 2>/dev/null; then
        warn "tmux セッション '$SESSION' が既にある。中で動いているものを確認すること。"
        echo "  tmux attach -t $SESSION"
        exit 1
    fi

    log "起動（tmux セッション '$SESSION'）"
    tmux new-session -d -s "$SESSION" -c "$COMFYUI_DIR" "$cmd"

    local url
    if url="$(public_url)"; then
        echo
        echo "  URL   : $url"
    else
        echo
        echo "  URL   : https://<pod-id>-${PORT}.proxy.runpod.net"
    fi
    echo "  ログ  : tmux attach -t $SESSION   (抜けるのは Ctrl+B → D)"
    echo "  停止  : tmux kill-session -t $SESSION"
    echo
    echo "起動完了まで 30 秒ほどかかる。'Starting server' が出てからブラウザで開くこと。"
}

main "$@"
