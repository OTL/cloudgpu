#!/usr/bin/env bash
#
# 生成物を Pod からローカルへ回収する（ローカルマシンで実行）。
# terminate する前に必ずこれを走らせること。Pod のディスクは消える。
#
#   ./fetch-outputs.sh root@203.0.113.10 -p 12345
#   ./fetch-outputs.sh root@203.0.113.10 -p 12345 ~/Pictures/comfy
#
# 接続情報は RunPod コンソールの Pod > Connect > SSH に出ている。
# 転送後に Pod 側を消したい場合は --clean を付ける。

set -euo pipefail

REMOTE_DIR="${REMOTE_DIR:-/workspace/ComfyUI/output/}"
CLEAN=0
SSH_PORT=22
HOST=""
LOCAL_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--port) SSH_PORT="$2"; shift 2 ;;
        --clean)   CLEAN=1; shift ;;
        -h|--help)
            sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            if [[ -z "$HOST" ]]; then HOST="$1"
            elif [[ -z "$LOCAL_DIR" ]]; then LOCAL_DIR="$1"
            else echo "不明な引数: $1" >&2; exit 1
            fi
            shift ;;
    esac
done

[[ -n "$HOST" ]] || { echo "usage: fetch-outputs.sh <user@host> [-p PORT] [LOCAL_DIR] [--clean]" >&2; exit 1; }
LOCAL_DIR="${LOCAL_DIR:-./outputs}"

mkdir -p "$LOCAL_DIR"

command -v rsync >/dev/null 2>&1 || { echo "rsync が必要" >&2; exit 1; }

echo "==> $HOST:$REMOTE_DIR -> $LOCAL_DIR"
rsync -avh --progress -e "ssh -p $SSH_PORT" "$HOST:$REMOTE_DIR" "$LOCAL_DIR/"

if [[ "$CLEAN" == "1" ]]; then
    echo "==> Pod 側の $REMOTE_DIR を空にする"
    ssh -p "$SSH_PORT" "$HOST" "find '${REMOTE_DIR%/}' -mindepth 1 -delete"
fi

echo "完了。Pod を terminate してよい。"
