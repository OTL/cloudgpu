#!/usr/bin/env bash
#
# テキスト LLM（Ollama + Open WebUI）を起動する（Pod 内で実行）。
#
#   bash /workspace/cloudgpu/scripts/start-llm.sh
#
# tmux セッション 'llm' の中に 2 枚のウィンドウを開く:
#   api  ollama serve      推論本体 + OpenAI 互換 API
#   ui   open-webui serve  ChatGPT 風のブラウザ UI
#
# 環境変数:
#   PORT          Open WebUI のポート (default: 8080)
#   OLLAMA_DIR    Ollama の展開先     (default: /workspace/ollama)
#   OLLAMA_MODELS モデルの置き場       (default: /workspace/models/ollama)
#   WEBUI_VENV    Open WebUI の venv  (default: /workspace/venv-webui)
#   EXPOSE_API    1 にすると API を 0.0.0.0 で待ち受ける（外から叩く場合）
#   NO_WEBUI      1 にすると UI を起動しない（API だけ使う場合）
#   FOREGROUND    1 にすると tmux を使わず ollama serve を前面で実行

set -euo pipefail

PORT="${PORT:-8080}"
OLLAMA_DIR="${OLLAMA_DIR:-/workspace/ollama}"
OLLAMA_MODELS="${OLLAMA_MODELS:-/workspace/models/ollama}"
WEBUI_VENV="${WEBUI_VENV:-/workspace/venv-webui}"
WEBUI_DATA="${WEBUI_DATA:-/workspace/openwebui}"
EXPOSE_API="${EXPOSE_API:-0}"
NO_WEBUI="${NO_WEBUI:-0}"
FOREGROUND="${FOREGROUND:-0}"
API_PORT="${API_PORT:-11434}"
SESSION=llm

OLLAMA_BIN="$OLLAMA_DIR/bin/ollama"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# DNS（コンテナ再生成のあと resolv.conf が空で上がってくることがある）
# --------------------------------------------------------------------------
ensure_dns() {
    getent hosts ollama.com >/dev/null 2>&1 && return 0
    warn "名前解決に失敗している。/etc/resolv.conf を補修する。"
    printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf 2>/dev/null \
        || die "/etc/resolv.conf に書き込めない。Pod を再起動するか作り直すこと。"
    log "DNS 復旧"
}

# --------------------------------------------------------------------------
# 事前確認
#
# ollama も venv も /workspace（Network Volume）にあるので、Pod を作り直しても
# 残っている。消えていたら provision-llm.sh からやり直す。
# --------------------------------------------------------------------------
ensure_ollama() {
    [[ -x "$OLLAMA_BIN" ]] \
        || die "ollama が $OLLAMA_BIN に無い。先に provision-llm.sh を実行すること。"

    if ! command -v nvidia-smi >/dev/null 2>&1; then
        warn "nvidia-smi が無い。GPU が見えていないと CPU で動いて実用にならない。"
    fi

    if [[ -z "$(ls -A "$OLLAMA_MODELS/manifests" 2>/dev/null)" ]]; then
        warn "モデルがまだ無い。別シェルで /workspace/bin/llm-models starter を実行すること。"
    fi
}

public_url() {
    local port="$1"
    [[ -n "${RUNPOD_POD_ID:-}" ]] || return 1
    echo "https://${RUNPOD_POD_ID}-${port}.proxy.runpod.net"
}

api_host() {
    if [[ "$EXPOSE_API" == "1" ]]; then
        echo "0.0.0.0:$API_PORT"
    else
        echo "127.0.0.1:$API_PORT"
    fi
}

# --------------------------------------------------------------------------
# 起動
# --------------------------------------------------------------------------
have_webui() {
    [[ "$NO_WEBUI" != "1" && -x "$WEBUI_VENV/bin/open-webui" ]]
}

start_api() {
    local host; host="$(api_host)"
    printf '%q ' env "OLLAMA_HOST=$host" "OLLAMA_MODELS=$OLLAMA_MODELS" \
        "OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE:-30m}" "$OLLAMA_BIN" serve
}

start_ui() {
    printf '%q ' env \
        "DATA_DIR=$WEBUI_DATA" \
        "OLLAMA_BASE_URL=http://127.0.0.1:$API_PORT" \
        "WEBUI_AUTH=${WEBUI_AUTH:-True}" \
        "ENABLE_OPENAI_API=${ENABLE_OPENAI_API:-False}" \
        "$WEBUI_VENV/bin/open-webui" serve --host 0.0.0.0 --port "$PORT"
}

main() {
    ensure_dns
    ensure_ollama
    mkdir -p "$OLLAMA_MODELS" "$WEBUI_DATA"

    if [[ "$FOREGROUND" == "1" ]] || ! command -v tmux >/dev/null 2>&1; then
        log "ollama serve を前面で起動（UI は起動しない）"
        eval "exec $(start_api)"
    fi

    if tmux has-session -t "$SESSION" 2>/dev/null; then
        warn "tmux セッション '$SESSION' が既にある。中で動いているものを確認すること。"
        echo "  tmux attach -t $SESSION"
        exit 1
    fi

    log "起動（tmux セッション '$SESSION'）"
    tmux new-session -d -s "$SESSION" -n api -c /workspace "$(start_api)"

    if have_webui; then
        # API が上がる前に UI を出すと接続エラーの画面になるので少し待つ
        local i
        for i in $(seq 1 30); do
            curl -fsS "http://127.0.0.1:$API_PORT/api/version" >/dev/null 2>&1 && break
            sleep 1
        done
        tmux new-window -t "$SESSION" -n ui -c /workspace "$(start_ui)"
    elif [[ "$NO_WEBUI" != "1" ]]; then
        warn "Open WebUI が入っていない。API だけで動かす。"
    fi

    echo
    if have_webui; then
        local url
        if url="$(public_url "$PORT")"; then
            echo "  UI    : $url"
        else
            echo "  UI    : https://<pod-id>-${PORT}.proxy.runpod.net"
        fi
        echo "          初回アクセスで作ったアカウントが管理者になる。先に自分で作ること。"
    fi
    if [[ "$EXPOSE_API" == "1" ]]; then
        echo "  API   : $(public_url "$API_PORT" || echo "https://<pod-id>-${API_PORT}.proxy.runpod.net")/v1  (OpenAI 互換)"
    else
        echo "  API   : http://127.0.0.1:${API_PORT}/v1  (Pod 内から。外に出すなら EXPOSE_API=1)"
    fi
    echo "  ログ  : tmux attach -t $SESSION   (ウィンドウ切替 Ctrl+B → N、抜けるのは Ctrl+B → D)"
    echo "  停止  : tmux kill-session -t $SESSION"
    echo
    echo "UI は初回起動に 1 分ほどかかる。RunPod の Pod に $PORT が HTTP ポートとして"
    echo "登録されていないとプロキシ URL は開けない（Edit Pod で追加できるが、コンテナは"
    echo "作り直しになる）。"
}

main "$@"
