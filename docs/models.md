# モデル選定

## まず入れるもの: FLUX.1-schnell (fp8)

`MODEL_SET=starter` で入る。

- **ライセンス Apache-2.0**。商用利用も含めて制約がない
- **4 step** で絵になる。SDXL の 20–30 step、FLUX dev の 20 step と比べて
  1 枚あたりの GPU 時間が圧倒的に短い＝一番安い
- fp8 版は約 17GB。24GB VRAM なら余裕、16GB でも動く

設定の注意: **steps=4, cfg=1.0**。ComfyUI のデフォルト（steps=20, cfg=8）のままだと
まともな絵にならない。ここで躓く人が多い。

## 次の選択肢

| モデル | サイズ | ライセンス | いつ使うか |
| --- | --- | --- | --- |
| SDXL base 1.0 | 約 7GB | CreativeML Open RAIL++-M | LoRA / ControlNet の資産が圧倒的に多い。既存の LoRA を使いたいとき |
| FLUX.1-dev (fp8) | 約 17GB | 非商用（FLUX.1-dev Non-Commercial License） | schnell より品質が要るとき。**商用不可なので用途に注意** |
| SD 1.5 系 | 約 2GB | 各種 | 軽さが正義のとき。今から始めるなら優先度は低い |

取得:

```bash
./scripts/download-models.sh sdxl
./scripts/download-models.sh flux-dev
```

## 検閲のかかっていないモデル（NSFW 対応）

素の SDXL / FLUX は露骨な表現を出しにくいよう学習されている（プロンプトを工夫しても
崩れた絵になる）。それを外したコミュニティ製の追加学習モデルがあり、いずれも
SDXL 系なので既存のワークフローや ControlNet がそのまま使える。

| セット | モデル | サイズ | 特徴 |
| --- | --- | --- | --- |
| `uncensored` | Illustrious-XL v1.0 | 約 6.9GB | 現行の主流ベース。danbooru タグで細かく制御できる |
| `pony` | Pony Diffusion V6 XL | 約 6.9GB | 定番。LoRA の資産が圧倒的に多いが、やや古い |

```bash
./scripts/download-models.sh uncensored
```

`all` には含めていない（用途が違ううえ、まとめて落とすと重いため）。ComfyUI 側に
出力フィルタの類は無いので、モデルを差し替えれば挙動もそのまま変わる。

### プロンプトの癖

FLUX や SDXL base のつもりで自然文を書いても出ない。**どちらもタグベース**。

- **Illustrious**: danbooru タグを並べる。`masterpiece, best quality, 1girl, ...`。
  steps 28–30、CFG 5–7、解像度 1024x1024 前後
- **Pony V6**: 先頭に `score_9, score_8_up, score_7_up` を付けるのが前提。
  付けないと極端に品質が落ちる。CLIP skip 2、CFG 7 前後
- どちらもネガティブに `worst quality, low quality` 系を入れる

### 他のモデルを足す

| モデル | 入手先 | 備考 |
| --- | --- | --- |
| NoobAI-XL v1.1 | `Laxhar/noobai-XL-1.1`（HF） | Illustrious をさらに学習したもの。v-pred 版は ComfyUI 側の設定が要る |
| 実写系（Realistic Vision ほか） | CivitAI | SD1.5 / SDXL でそれぞれ別物。用途で選ぶ |
| キャラ / 画風 LoRA | CivitAI | `--dir loras` で入れる |

Hugging Face から:

```bash
./scripts/download-models.sh --url \
  "https://huggingface.co/Laxhar/noobai-XL-1.1/resolve/main/NoobAI-XL-v1.1.safetensors" \
  --dir checkpoints
```

CivitAI は 2024 年以降ダウンロードにログインが必要になった。アカウント設定で
API キーを作り、`CIVITAI_TOKEN` を渡す。

```bash
CIVITAI_TOKEN=xxxx ./scripts/download-models.sh --url \
  "https://civitai.com/api/download/models/<version-id>" \
  --dir checkpoints --name mymodel.safetensors
```

トークンを渡し忘れると、safetensors ではなくログインページの HTML が数 KB 落ちてくる。
「読み込めない」ときはまずファイルサイズを見ること（`ls -lh`）。

### 注意

- **ライセンスは元モデルを引き継ぐ。** Illustrious / NoobAI は Fair AI Public
  License 1.0-SD、Pony V6 は CreativeML Open RAIL++-M 系。商用利用の条件は
  それぞれ違うので、仕事で使うなら配布元の記載を確認する
- 実在の人物を性的に描写した画像の生成・公開は、日本でも名誉毀損や肖像権侵害に
  なり得る。児童ポルノに当たる出力は生成した時点で違法
- 生成物の置き場所は `/workspace/ComfyUI/output`。Pod を共有したり、プロキシ URL を
  他人に渡したりすれば当然そこも見える

## ライセンスについて

- **schnell = Apache-2.0**、**dev = 非商用**。この違いは重要。生成物を仕事で使う
  予定があるなら schnell か SDXL に寄せる
- CivitAI から落とすモデル / LoRA はそれぞれライセンスが違う。マージモデルは
  元モデルの制約を引き継ぐ

## 任意のモデルを足す

```bash
# CivitAI の LoRA（CIVITAI_TOKEN が要る。上の節を参照）
CIVITAI_TOKEN=xxxx ./scripts/download-models.sh --url "<URL>" --dir loras --name mylora.safetensors

# ControlNet
./scripts/download-models.sh --url "<URL>" --dir controlnet
```

`--dir` は `models/` 配下のサブディレクトリ名（`checkpoints`, `vae`, `loras`,
`controlnet`, `upscale_models`, `unet`, `clip` など）。

Hugging Face の gated モデル（black-forest-labs 本家など）は、HF 側で利用規約に
同意したうえで `HF_TOKEN` を渡す。

## テキスト LLM

このページは画像モデルの話。ChatGPT 的なテキスト LLM は Ollama を
`/workspace/ollama`、モデルを `/workspace/models/ollama` に置いて同じ Network Volume に
相乗りさせている。モデル選定と VRAM の目安は [llm.md](llm.md) を参照。

画像生成と同時に動かすと VRAM を食い合うので、「画像生成の Pod」と「LLM の Pod」を
用途ごとに立て、Volume だけ共有する。
