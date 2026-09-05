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

## ライセンスについて

- **schnell = Apache-2.0**、**dev = 非商用**。この違いは重要。生成物を仕事で使う
  予定があるなら schnell か SDXL に寄せる
- CivitAI から落とすモデル / LoRA はそれぞれライセンスが違う。マージモデルは
  元モデルの制約を引き継ぐ

## 任意のモデルを足す

```bash
# CivitAI の LoRA
./scripts/download-models.sh --url "<URL>" --dir loras --name mylora.safetensors

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
