# よくある詰まりどころ

実際に RunPod で一通り立ち上げたときに踏んだ順に並べてある。上 4 つは
`start-comfyui.sh` が自動で面倒を見るので、手で `python main.py` を叩いたときだけ関係する。

## ブラウザで開くと 403（アクセスが拒否されました）

**ComfyUI 自身が返している。** RunPod のプロキシや権限の問題ではない。

ComfyUI の `server.py` には CSRF 対策のミドルウェアがあり、
`Sec-Fetch-Site: cross-site` が付いたリクエストを問答無用で 403 にする。
別タブ（RunPod のコンソールなど）のリンクから `proxy.runpod.net` に飛ぶと
ブラウザがこのヘッダを付けるため、これに該当する。本文が空の 403 なので
ブラウザ側の権限エラーに見えてしまい、原因が分かりにくい。

`--enable-cors-header` を付けて起動すると、このミドルウェアの代わりに
CORS ミドルウェアが入り、判定自体が無くなる。

```bash
/workspace/venv/bin/python main.py --listen 0.0.0.0 --port 8188 \
  --enable-cors-header "https://<pod-id>-8188.proxy.runpod.net"
```

Pod の中から挙動を確認できる。修正前は 403、修正後は 200 が返る。

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
  -H 'Sec-Fetch-Site: cross-site' http://127.0.0.1:8188/
```

## `ModuleNotFoundError`（前は動いていたのに）

Pod を編集・再起動するとコンテナが作り直され、`pip install` したものが消える。
永続するのは `/workspace` だけ。ホスト名（`root@xxxxxxxx`）が変わっていたら
コンテナが別物になった証拠。

venv を Network Volume 側に作れば再発しない。

```bash
python -m venv --system-site-packages /workspace/venv
/workspace/venv/bin/python -m pip install -r /workspace/ComfyUI/requirements.txt
```

`--system-site-packages` が要点。torch はコンテナイメージに CUDA 版が入っているので、
これを付けておけば venv 側に数 GB を再ダウンロードせずに済む。

## `Temporary failure in name resolution`

コンテナが作り直されたあと `/etc/resolv.conf` が空で上がってくることがある。

```bash
cat /etc/resolv.conf
getent hosts pypi.org

printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf
```

書き込めない場合はコンソールから Stop → Start。それでも直らないならその Pod は
捨てて作り直したほうが早い（`/workspace` は引き継げる）。

## `Installing collected packages:` から進まない

固まっているように見えて、たいてい進んでいる。venv が Network Volume 上にあるため
wheel の展開が遅い。**5〜15 分**かかる。別のシェルで確認できる。

```bash
du -sh /workspace/venv
```

数字が増えていれば正常。まったく変わらないなら `Ctrl+C` して同じコマンドを再実行する。
ダウンロード済みの wheel は pip のキャッシュに残っているので 2 回目は展開だけになる。

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

## CivitAI から落としたファイルが読み込めない

`CIVITAI_TOKEN` を渡していないと、safetensors ではなくログインページの HTML が
数 KB 落ちてくる。拡張子は `.safetensors` のままなので気付きにくい。

```bash
ls -lh /workspace/ComfyUI/models/checkpoints
head -c 100 <疑わしいファイル>
```

数 GB あるはずのファイルが数 KB なら中身は HTML。消して、CivitAI のアカウント設定で
作った API キーを渡して取り直す。

```bash
CIVITAI_TOKEN=xxxx ./scripts/download-models.sh --url "<URL>" --dir checkpoints --name x.safetensors
```

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

## raw.githubusercontent.com が 404 を返す

このリポジトリを private のままにしていると、`raw.githubusercontent.com` は
認証なしのリクエストに 404 を返す。public にするか、トークンを付けて取得する。

```bash
curl -fsSL -H "Authorization: token <PAT>" \
  https://raw.githubusercontent.com/OTL/cloudgpu/main/scripts/provision.sh | bash
```

RunPod の `PROVISIONING_SCRIPT` 環境変数を使う場合は public でなければならない。
RunPod 側が URL を叩くだけで、認証を挟む手段がないため。

## モデルの URL が 404 になる

Hugging Face 側でリポジトリ名やファイル名が変わることがある。provision.sh に
書いてある URL はあくまでその時点のもの。404 になったら該当リポジトリの
`Files and versions` タブで実ファイル名を確認し、`--url` モードで取得する。

```bash
./scripts/download-models.sh --url "<正しい URL>" --dir checkpoints
```

恒久的に直す場合は `scripts/provision.sh` の `models_*` 関数を書き換える。

---

以下はテキスト LLM（Ollama + Open WebUI）側。詳細は [llm.md](llm.md) を参照。

## LLM の返事が異様に遅い（数 tok/s）

VRAM に載り切らず CPU に溢れている。

```bash
nvidia-smi
/workspace/ollama/bin/ollama ps
```

`ollama ps` の PROCESSOR 列に `100% GPU` 以外（`CPU` や `x%/y% CPU/GPU`）が出ていたら
これに該当する。小さいモデルか、より量子化の強いタグに落とす。

```bash
/workspace/bin/llm-models --model qwen3:8b
```

`nvidia-smi` 自体が無い / GPU が見えない場合は CPU only の Pod を引いている。

## Open WebUI が起動しない・ブラウザで開けない

順に切り分ける。

```bash
tmux attach -t llm          # Ctrl+B → N でウィンドウ切替、Ctrl+B → D で抜ける
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8188/
curl -s http://127.0.0.1:11434/api/version
```

- ローカルで 200 が返るのにブラウザで開けない → Pod の HTTP ポートに `8188` が
  登録されていない。`Edit Pod` で追加できるが**コンテナが作り直される**
- ComfyUI が同じ Pod で動いていると 8188 がぶつかる。用途ごとに Pod を分けること
- そもそも UI のウィンドウが無い → Open WebUI が入っていない
  （`ls /workspace/venv-webui/bin/open-webui`）。Python 3.11 未満の Pod だと
  provision-llm.sh は導入をスキップする。API だけで使うか、Pod を作り直す
- 初回起動は 1 分ほどかかる。真っ白でも少し待つ

## Open WebUI にログインできない / パスワードを忘れた

アカウントは `/workspace/openwebui/webui.db` に入っている。作り直すなら:

```bash
mv /workspace/openwebui/webui.db /workspace/openwebui/webui.db.bak
```

チャット履歴も一緒に消える。**プロキシ URL は Pod ID さえ分かれば誰でも叩ける**ので、
`WEBUI_AUTH=False` で認証を切ったまま放置しないこと。

## Ollama の tarball が `curl: (22) ... 404`

Ollama の配布形式は途中で `.tgz` から `.tar.zst` に変わり、古い `.tgz` の URL は
404 を返すようになった。`provision-llm.sh` は `.tar.zst` を先に見て、展開に必要な
`zstd` が無ければ apt で入れる。それでも 404 になるなら手で確認する。

```bash
curl -sIL -o /dev/null -w '%{http_code}\n' https://ollama.com/download/ollama-linux-amd64.tar.zst
```

手で入れるなら（`/workspace` に置くのが要点。`/usr/local` はコンテナ再生成で消える）:

```bash
apt-get update && apt-get install -y zstd
mkdir -p /workspace/ollama
curl -fL https://ollama.com/download/ollama-linux-amd64.tar.zst \
  | zstd -d | tar -xf - -C /workspace/ollama
/workspace/ollama/bin/ollama --version
```

## Pod を作り直したら ollama コマンドが無い

`/usr/local/bin/ollama` はコンテナ側なので消える。このリポジトリの
provision-llm.sh は `/workspace/ollama`（Network Volume）に展開しているので、
そちらを直接叩く。

```bash
/workspace/ollama/bin/ollama list
. /workspace/bin/rc     # PATH を通せば llm / llm-models で済む
```

## `Error: model requires more system memory than is available`

`OLLAMA_MODELS` が Volume を指していないと、コンテナディスク（20GB 程度）を
食い潰して落ちることもある。確認:

```bash
echo "$OLLAMA_MODELS"
du -sh /workspace/models/ollama
df -h /workspace /
```

`start-llm.sh` 経由で起動していれば `/workspace/models/ollama` が設定される。
手で `ollama serve` を叩くとコンテナ側の `~/.ollama` に落ちるので注意。
