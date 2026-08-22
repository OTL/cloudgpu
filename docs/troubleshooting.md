# よくある詰まりどころ

## 生成した絵がノイズ / 崩れる（FLUX schnell）

steps と cfg がデフォルトのまま。**steps=4, cfg=1.0** にする。
schnell は蒸留モデルなので、CFG を効かせるとかえって壊れる。

## モデルがドロップダウンに出ない

ComfyUI 起動後にダウンロードしたモデルは自動では認識されない。

1. ブラウザで `R`（Refresh Node Definitions）
2. だめなら ComfyUI を再起動

```bash
pkill -f "python.*main.py" && sleep 2
cd /workspace/ComfyUI && python main.py --listen 0.0.0.0 --port 8188
```

（テンプレートによっては supervisor 管理なので `supervisorctl restart comfyui`）

## 次に Pod を作ったらモデルが消えている

`/workspace` の外に置いていた可能性が高い。確認:

```bash
df -h /workspace
ls -la /workspace/ComfyUI/models/checkpoints
```

Pod 作成時に Network Volume を選び忘れると `/workspace` はただのコンテナディスクに
なり、terminate で消える。provision.sh はこの状態を検出して警告を出す。

## CUDA out of memory

- VRAM 16GB で FLUX を動かすなら fp8 版を使う（fp16 は載らない）
- ComfyUI の起動オプションに `--lowvram` を足す
- 解像度を下げる。FLUX は 1024x1024 が基準、それ以上は VRAM を急に食う
- バッチサイズを 1 に

## ダウンロードが遅い / 途中で切れる

`aria2c` が入っていれば並列で速い。provision.sh は自動で使う。
入っていなければ:

```bash
apt-get update && apt-get install -y aria2
```

途中で切れても provision.sh は `.part` に落としてから mv しているので、
再実行すれば続きから取得する。

## 401 / 403 でモデルが落ちてこない

gated リポジトリ。Hugging Face の該当ページで規約に同意し、`HF_TOKEN` を設定する。

```bash
HF_TOKEN=hf_xxx ./scripts/download-models.sh flux-dev
```

## Pod に SSH できない

RunPod の SSH は 2 種類ある。

- **Basic SSH**（`Connect` に出る `ssh root@... -p ...`）: 公開鍵をアカウント設定に
  登録している必要がある
- **web terminal**: ブラウザから直接。鍵不要

`fetch-outputs.sh` は前者を使う。鍵の登録が面倒なら、ComfyUI の UI から
画像を個別にダウンロードしてもよい。

## Spot Pod が落とされた

想定内。Network Volume 上のデータは残っているので、同じ Volume で Pod を
作り直せば続きから再開できる。生成中だったジョブのキューは消える。

## モデルの URL が 404 になる

Hugging Face 側でリポジトリ名やファイル名が変わることがある。provision.sh に
書いてある URL はあくまでその時点のもの。404 になったら該当リポジトリの
`Files and versions` タブで実ファイル名を確認し、`--url` モードで取得する。

```bash
./scripts/download-models.sh --url "<正しい URL>" --dir checkpoints
```

恒久的に直す場合は `scripts/provision.sh` の `models_*` 関数を書き換える。
