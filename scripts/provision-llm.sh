#!/usr/bin/env bash
#
# テキスト LLM（ChatGPT 的なチャット）のプロビジョニングスクリプト。
# ComfyUI とは別の Pod で使う想定だが、Network Volume は同じものを共有する。
#
#   curl -fsSL <このファイルの raw URL> | bash
#
# 何度実行しても既にあるものはスキップするので、途中で落ちたら再実行すればよい。
#
# 入れるもの:
#   - Ollama       推論エンジン。OpenAI 互換 API も生やす
#   - Open WebUI   ChatGPT 風のブラウザ UI（SKIP_WEBUI=1 で省略可）
#   - モデル       LLM_MODEL_SET で選ぶ
#
# 環境変数:
#   OLLAMA_DIR      Ollama の展開先 (default: /workspace/ollama)
#   OLLAMA_MODELS   モデルの置き場   (default: /workspace/models/ollama)
#   LLM_MODEL_SET   starter | ja | coder | big | oss | all | none  (default: starter)
#   LLM_MODELS      任意のモデル名を空白区切りで（LLM_MODEL_SET より優先）
#   WEBUI_VENV      Open WebUI の venv (default: /workspace/venv-webui)
#   SKIP_WEBUI      1 にすると Open WebUI を入れない（API だけ使う場合）

set -euo pipefail

OLLAMA_DIR="${OLLAMA_DIR:-/workspace/ollama}"
OLLAMA_MODELS="${OLLAMA_MODELS:-/workspace/models/ollama}"
LLM_MODEL_SET="${LLM_MODEL_SET:-starter}"
LLM_MODELS="${LLM_MODELS:-}"
WEBUI_VENV="${WEBUI_VENV:-/workspace/venv-webui}"
SKIP_WEBUI="${SKIP_WEBUI:-0}"
OLLAMA_API="${OLLAMA_API:-127.0.0.1:11434}"

export OLLAMA_MODELS

# curl | bash だと BASH_SOURCE が無いので、その場合は空にしておく
SELF_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    SELF_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
fi

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------------------
# DNS
#
# コンテナ再生成のあと /etc/resolv.conf が空で上がってくることがある。
# provision.sh と同じ処理だが、こちらも curl | bash で単体実行されるため
# 意図的に自己完結させている。
# --------------------------------------------------------------------------
ensure_dns() {
    getent hosts ollama.com >/dev/null 2>&1 && return 0
    warn "名前解決に失敗している。/etc/resolv.conf を補修する。"
    printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf 2>/dev/null \
        || die "/etc/resolv.conf に書き込めない。Pod を再起動するか作り直すこと。"
    getent hosts ollama.com >/dev/null 2>&1 \
        || die "DNS を直せなかった。この Pod は捨てて作り直すのが早い。"
    log "DNS 復旧"
}

# --------------------------------------------------------------------------
# Ollama
#
# 公式のインストーラ（install.sh）は /usr/local に入れる。そこはコンテナ側なので
# Pod を編集・再生成すると消える。tarball を Network Volume に展開して、
# /workspace/ollama/bin/ollama を直接叩く形にしておけば作り直しても残る。
# --------------------------------------------------------------------------
OLLAMA_BIN="$OLLAMA_DIR/bin/ollama"

install_ollama() {
    if [[ -x "$OLLAMA_BIN" ]]; then
        log "skip (既にある): ollama $("$OLLAMA_BIN" --version 2>/dev/null | tail -1)"
        return 0
    fi

    local arch
    case "$(uname -m)" in
        x86_64)  arch=amd64 ;;
        aarch64) arch=arm64 ;;
        *) die "未対応のアーキテクチャ: $(uname -m)" ;;
    esac

    # 配布形式は途中で .tgz から .tar.zst に変わった（古い .tgz は 404 になる）。
    # 新しい方を先に見て、無ければ .tgz に落ちる。
    local base="https://ollama.com/download"
    local url="" fmt=""
    if curl -fsIL -o /dev/null "$base/ollama-linux-${arch}.tar.zst"; then
        url="$base/ollama-linux-${arch}.tar.zst"; fmt=zst
        ensure_zstd
    elif curl -fsIL -o /dev/null "$base/ollama-linux-${arch}.tgz"; then
        url="$base/ollama-linux-${arch}.tgz"; fmt=gz
    else
        die "Ollama の tarball が見つからない（$base/ollama-linux-${arch}.*）。配布形式が変わった可能性がある。"
    fi

    log "Ollama を $OLLAMA_DIR に展開する（約 1.5GB、数分かかる）"
    mkdir -p "$OLLAMA_DIR"
    local archive="$OLLAMA_DIR/ollama.part"
    rm -f "$archive"
    curl -fL --retry 3 --retry-delay 5 -o "$archive" "$url"

    if [[ "$fmt" == zst ]]; then
        zstd -dc "$archive" | tar -xf - -C "$OLLAMA_DIR"
    else
        tar -xzf "$archive" -C "$OLLAMA_DIR"
    fi
    rm -f "$archive"
    [[ -x "$OLLAMA_BIN" ]] || die "展開したが $OLLAMA_BIN が無い。"
}

# .tar.zst の展開には zstd が要る。RunPod のイメージには入っていないことが多い。
ensure_zstd() {
    command -v zstd >/dev/null 2>&1 && return 0
    log "zstd を導入する（.tar.zst の展開に必要）"
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq && apt-get install -y -qq zstd
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y -q zstd
    fi
    command -v zstd >/dev/null 2>&1 \
        || die "zstd を入れられなかった。手動で入れてから再実行のこと（apt-get install -y zstd）。"
}

# --------------------------------------------------------------------------
# モデル取得
#
# ollama pull はサーバが動いていないと失敗する。既に動いていればそれを使い、
# 動いていなければこのスクリプトの中だけで一時的に立てて、最後に落とす。
# --------------------------------------------------------------------------
TEMP_SERVER_PID=""

ensure_ollama_server() {
    if curl -fsS "http://$OLLAMA_API/api/version" >/dev/null 2>&1; then
        return 0
    fi
    log "モデル取得のため ollama serve を一時的に起動する"
    OLLAMA_HOST="$OLLAMA_API" "$OLLAMA_BIN" serve >/tmp/ollama-provision.log 2>&1 &
    TEMP_SERVER_PID=$!

    local i
    for i in $(seq 1 30); do
        curl -fsS "http://$OLLAMA_API/api/version" >/dev/null 2>&1 && return 0
        sleep 1
    done
    die "ollama serve が上がらない。/tmp/ollama-provision.log を見ること。"
}

stop_temp_server() {
    [[ -n "$TEMP_SERVER_PID" ]] || return 0
    kill "$TEMP_SERVER_PID" 2>/dev/null || true
    wait "$TEMP_SERVER_PID" 2>/dev/null || true
    TEMP_SERVER_PID=""
}
trap stop_temp_server EXIT

# --------------------------------------------------------------------------
# モデルセット
#
# 既定は 8B クラス 1 本だけ。16GB VRAM でも動いて日本語もそこそこ喋る。
# 大きいモデルは「足りない」と感じてから足せばよい（GPU 課金中に落とすので、
# 最初から欲張ると待ち時間がそのまま金額になる）。
# --------------------------------------------------------------------------
models_for_set() {
    case "$1" in
        none)    : ;;
        starter) echo "qwen3:8b" ;;
        ja)      echo "qwen3:14b gemma3:12b" ;;
        coder)   echo "qwen2.5-coder:14b" ;;
        big)     echo "qwen3:30b-a3b" ;;
        oss)     echo "gpt-oss:20b" ;;
        all)     echo "qwen3:8b qwen3:14b gemma3:12b qwen2.5-coder:14b qwen3:30b-a3b gpt-oss:20b" ;;
        *) die "LLM_MODEL_SET が不正: $1 (starter|ja|coder|big|oss|all|none)" ;;
    esac
}

pull_models() {
    local list
    if [[ -n "$LLM_MODELS" ]]; then
        list="$LLM_MODELS"
    else
        list="$(models_for_set "$LLM_MODEL_SET")"
    fi

    if [[ -z "${list// /}" ]]; then
        log "モデル取得をスキップ"
        return 0
    fi

    mkdir -p "$OLLAMA_MODELS"
    ensure_ollama_server

    local m
    for m in $list; do
        if OLLAMA_HOST="$OLLAMA_API" "$OLLAMA_BIN" list 2>/dev/null | awk '{print $1}' | grep -qx "$m"; then
            log "skip (既にある): $m"
            continue
        fi
        log "pull: $m"
        OLLAMA_HOST="$OLLAMA_API" "$OLLAMA_BIN" pull "$m" || warn "pull 失敗: $m"
    done

    stop_temp_server
}

# --------------------------------------------------------------------------
# Open WebUI
#
# ChatGPT 風の UI。pip で入るが依存が重い（数分〜十数分）。API だけ使うなら
# SKIP_WEBUI=1 で省略してよい。venv もデータも Network Volume に置く。
# --------------------------------------------------------------------------
install_webui() {
    if [[ "$SKIP_WEBUI" == "1" ]]; then
        log "SKIP_WEBUI=1: Open WebUI をスキップ"
        return 0
    fi

    if [[ -x "$WEBUI_VENV/bin/open-webui" ]]; then
        log "skip (既にある): Open WebUI"
        return 0
    fi

    # Open WebUI は Python 3.11 以上を要求する。コンテナの python が古いことがある。
    local py=""
    local candidate
    for candidate in python3.12 python3.11 python3 python; do
        command -v "$candidate" >/dev/null 2>&1 || continue
        if "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3,11) else 1)' 2>/dev/null; then
            py="$candidate"
            break
        fi
    done

    if [[ -z "$py" ]]; then
        warn "Python 3.11 以上が無いので Open WebUI は入れない。API だけで使うこと。"
        warn "（別 UI が要るなら Pod のテンプレートを Python 3.11+ のものに変える）"
        return 0
    fi

    log "Open WebUI を導入する（Network Volume 上なので 10 分前後かかる）"
    [[ -x "$WEBUI_VENV/bin/python" ]] || "$py" -m venv "$WEBUI_VENV"
    "$WEBUI_VENV/bin/python" -m pip install --no-input --upgrade pip
    "$WEBUI_VENV/bin/python" -m pip install --no-input open-webui \
        || { warn "Open WebUI の導入に失敗。API だけで使うこと。"; return 0; }
}

# --------------------------------------------------------------------------
main() {
    ensure_dns
    install_ollama
    pull_models
    install_webui

    # リポジトリを clone して実行した場合は短いコマンド名も置いていく
    if [[ -n "$SELF_DIR" && -x "$SELF_DIR/bootstrap.sh" ]]; then
        bash "$SELF_DIR/bootstrap.sh" >/dev/null
        log "短縮コマンドを /workspace/bin に置いた"
    fi

    log "完了"
    echo "  ollama      : $OLLAMA_BIN"
    echo "  モデル置き場 : $OLLAMA_MODELS"
    echo "  ディスク使用 : $(du -sh "$OLLAMA_MODELS" 2>/dev/null | cut -f1)"
    echo
    echo "起動はこれ:"
    echo "  /workspace/bin/llm"
}

main "$@"
