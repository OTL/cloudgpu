# テキスト LLM（ChatGPT 的な使い方）

画像生成（ComfyUI）と同じ Network Volume に、Ollama + Open WebUI を相乗りさせる。
ブラウザで開けば ChatGPT 風のチャット画面になり、同時に OpenAI 互換の API も生える。

## 先に: 本当に自前で動かすべきか

正直なところ、**「ただ賢いチャットが使いたい」だけなら商用 API のほうが安い。**
GPU Pod は動かしている間ずっと時間課金なので、返事を待っている時間も、
考えている時間も、席を外している時間も課金される。

自前で動かす価値があるのはこのあたり。

- 社外に出せないデータを食わせたい（入力がネットワークの外に出ない）
- 大量のテキストを一括処理したい（トークン課金だと高い、時間課金だと安い）
- モデルを差し替えて挙動を比べたい / fine-tune したモデルを動かしたい
- 拒否の調整が入っていないモデルを使いたい（後述の uncensored / abliterated）

逆に「1 日に数十回チャットする」程度なら、素直に商用 API を使ったほうが安い。
このドキュメントはそれを分かったうえで自前で動かす人向け。

## セットアップ

Pod は ComfyUI とは**別に立てる**。画像生成と LLM を同じ GPU に載せると
VRAM が足りなくなるため。Network Volume は同じものを指定してよい。

1. Pod を作る（[runpod-setup.md](runpod-setup.md) の手順 2 と同じ。Template は
   PyTorch 系の素のもので構わない）
2. HTTP ポートは ComfyUI と同じ **8188** をそのまま使う（Open WebUI の既定を
   8188 にしてあるので、ポートを足す必要がない。足すとコンテナが作り直されるため
   避けたい）。別のポートにしたければ `PORT=8080 /workspace/bin/llm` のように指定する
3. web terminal で

   ```bash
   curl -fsSL https://raw.githubusercontent.com/OTL/cloudgpu/main/scripts/provision-llm.sh | bash
   ```

   環境変数 `LLM_MODEL_SET`（既定 `starter`）で取るモデルを選べる。
   `SKIP_WEBUI=1` を付けると UI を入れず API だけになる。

4. 起動する

   ```bash
   /workspace/bin/llm
   ```

5. 表示された `https://<pod-id>-8188.proxy.runpod.net` を開く

   **初回アクセスで作ったアカウントが管理者になる。** プロキシ URL は Pod ID さえ
   分かれば誰でも叩けるので、立ち上げたら自分が真っ先にアカウントを作ること。

6. 終わったら Pod を **terminate**。`/workspace/ollama`、`/workspace/models/ollama`、
   `/workspace/openwebui`（チャット履歴）は Volume に残るので、次回は
   `/workspace/bin/llm` を叩けば会話履歴ごと再開できる

## モデル選定

VRAM に載り切るかどうかが全て。載らないと CPU に溢れて 10 倍以上遅くなる。
Ollama の既定は 4bit 量子化なので、**必要 VRAM ≒ パラメータ数(B) × 0.6 GB + 文脈分**
くらいで見ておくとよい。

| モデル | サイズ | 必要 VRAM の目安 | 用途 |
| --- | --- | --- | --- |
| `qwen3:8b` | 約 5GB | 16GB〜 | 既定。日本語もそこそこ喋る。まずこれ |
| `gemma3:12b` | 約 8GB | 16GB〜 | 日本語の自然さが良い。画像入力も可 |
| `qwen3:14b` | 約 9GB | 24GB〜 | 8b で物足りないとき |
| `qwen2.5-coder:14b` | 約 9GB | 24GB〜 | コード補完・生成 |
| `qwen3:30b-a3b` | 約 18GB | 24GB〜 | MoE。30B 級だが動くのは 3B 分なので速い。**コスパが良い** |
| `gpt-oss:20b` | 約 14GB | 24GB〜 | Apache-2.0。ライセンスがはっきりしている |
| 70B 級 | 40GB+ | 48GB〜 | A100 / H100 が要る。単価が跳ねるので目的を絞って |

取得:

```bash
/workspace/bin/llm-models big                 # セットで取る
/workspace/bin/llm-models --model qwen3:32b   # 個別に取る
```

セットの中身は [`scripts/pull-llm-models.sh`](../scripts/pull-llm-models.sh) を参照。
Ollama のモデル一覧は https://ollama.com/library にある。

### 検閲の弱いモデル（uncensored / abliterated）

商用 API や公式モデルは、安全側に倒しすぎて無害な依頼まで断ることがある
（創作、医療・法律の一般知識、セキュリティの解説、翻訳など）。ローカルで動かす
利点のひとつがここで、拒否の調整を外したモデルを選べる。

| セット | モデル | サイズ | 備考 |
| --- | --- | --- | --- |
| `uncensored` | `huihui_ai/qwen3-abliterated:8b` | 約 5GB | 16GB VRAM 以上。日本語もそこそこ |
| `uncensored-big` | `huihui_ai/qwen3-abliterated:30b-a3b` | 約 18GB | MoE。24GB VRAM で速い |

```bash
/workspace/bin/llm-models uncensored
```

`all` にはこれらを含めていない（用途が違ううえ、まとめて落とすと重いため）。

**abliteration とは。** モデルの内部表現から「拒否の方向」に対応する成分を
特定して差し引く手法。追加学習ではないので、元モデルの知識や日本語力はほぼ
そのまま残る。ただし副作用として指示追従がやや不安定になり、ベンチマークの
スコアも数 % 落ちるのが普通。**常用するなら素の `qwen3:8b` のほうが賢い。**
用途に応じて使い分けるのが現実的。

その他の選択肢:

| モデル | 備考 |
| --- | --- |
| `dolphin3:8b` | Llama 3.1 ベース。「alignment 抜き」を売りにした系譜の最新版。日本語は弱め |
| `huihui_ai/gemma3-abliterated:12b` / `:27b` | 日本語の自然さ重視ならこちら |
| `huihui_ai/qwen2.5-coder-abliterate:14b` | コード用 |
| `wizard-vicuna-uncensored`, `llama2-uncensored` | 古い。今から選ぶ理由は薄い |

注意点:

- **ライセンスは元モデルを引き継ぐ。** Qwen3 は Apache-2.0、Gemma は Gemma 利用規約、
  Llama 系は Llama ライセンス。「uncensored 版だから自由」ということはない
- `huihui_ai/*` はコミュニティのアップロード。公式ライブラリ（`ollama.com/library/*`）
  ではないので、中身の検証は自分で行うこと
- 拒否が減るぶん、事実確認をしないまま断定的に答える傾向も強くなる。出力を
  そのまま信用しない
- 生成物の扱いは自分の責任範囲。ローカルで動かしていても、公開すれば
  公開した内容の責任は生じる

### 速度の感覚

24GB の 4090 で 8B クラスなら 40〜60 tok/s 程度、体感は商用 API と大差ない。
30B の MoE でも 30 tok/s 前後は出る。**遅くなったらまず VRAM 溢れを疑う**
（`nvidia-smi` で使用量を見る。100% 近くに張り付いていたら小さいモデルに落とす）。

## API として使う

Ollama は OpenAI 互換のエンドポイントを持っているので、既存の SDK の
`base_url` を差し替えるだけで動く。

```bash
# Pod の中から
curl http://127.0.0.1:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3:8b","messages":[{"role":"user","content":"こんにちは"}]}'
```

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:11434/v1", api_key="dummy")
r = client.chat.completions.create(
    model="qwen3:8b",
    messages=[{"role": "user", "content": "こんにちは"}],
)
print(r.choices[0].message.content)
```

外（自分のノート PC やアプリ）から叩きたいときは `EXPOSE_API=1` を付けて起動する。

```bash
EXPOSE_API=1 /workspace/bin/llm
# -> https://<pod-id>-11434.proxy.runpod.net/v1
```

このとき Pod の HTTP ポートに `11434` を追加しておくこと。
**Ollama には認証が無い。** URL を知られた時点で誰でも叩けるので、公開したまま
放置しない（terminate すれば URL ごと消える）。

## コストを抑える運用

基本は [cost-control.md](cost-control.md) と同じ（stop ではなく terminate）。
LLM 固有の話だけ書いておく。

- **モデルのダウンロードも GPU 課金中に走る。** 30B 級は 20GB 近くあるので、
  初回は安い GPU で `llm-models` だけ回して terminate し、本番は速い GPU で
  作り直す手がある（Volume にモデルが残るので 2 回目は待たない）
- `OLLAMA_KEEP_ALIVE` は既定 30 分。放っておくとモデルが VRAM に居座るが、
  GPU 課金は載っていようがいまいが同じなので、そのままでよい
- バッチ処理（大量のテキストを流す）は時間課金と相性が良い。逆に
  対話でぽつぽつ叩くのが中心なら、商用 API のほうが安いという最初の話に戻る
- 画像生成と同時に立てない。どうしても両方使いたいなら Pod を 2 つ立てて
  同じ Volume を共有する（Network Volume は複数 Pod から同時にマウントできる）

## vLLM を使う場合

同時アクセスが多い、あるいはスループットを絞り出したいなら vLLM のほうが速い。
逆に「ひとりで対話する」だけなら Ollama で十分で、モデルの入れ替えも楽。

```bash
/workspace/venv-llm/bin/pip install vllm
/workspace/venv-llm/bin/vllm serve Qwen/Qwen3-8B --port 8000
```

こちらも OpenAI 互換 API を喋る。モデルは Hugging Face から取るので
`HF_HOME=/workspace/hf` を指定して Volume 側にキャッシュさせること
（指定しないとコンテナ側に落ちて、Pod を作り直すたびに消える）。
