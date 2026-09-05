# cloudgpu

RunPod 上に「使うときだけ立ち上げる」生成 AI 環境を最小コストで構築するための
手順書とプロビジョニングスクリプト。

- **画像生成**: ComfyUI（[docs/runpod-setup.md](docs/runpod-setup.md)）
- **テキスト LLM**: Ollama + Open WebUI で ChatGPT 風のチャットと OpenAI 互換 API
  （[docs/llm.md](docs/llm.md)）

どちらも同じ Network Volume に相乗りさせる。ただし VRAM を食い合うので、
実際には用途ごとに Pod を立てて Volume だけ共有する。

## 設計方針

1. **モデルも Python の依存も Network Volume に置く。** Pod のディスクには置かない。
   モデルを置くと起動のたびに数十 GB を再ダウンロードすることになり、その待ち時間も
   GPU 課金対象。pip パッケージも同じで、コンテナは Pod を編集すると作り直されて
   site-packages ごと消える。だから venv は `/workspace/venv` に置く。
2. **Pod は stop せず terminate する。** 停止中の Pod ボリュームは Network Volume より
   数倍高い。永続させたいものは全部 `/workspace`（= Network Volume）に寄せる。
3. **プロビジョニングはスクリプト 1 本に集約する。** Pod を作り直すのが怖くなくなるほど、
   terminate する習慣がつき、結果的に一番安くなる。

## コスト感（2026 年時点の目安・変動するので必ずコンソールで確認）

| 項目 | 選択肢 | 目安 |
| --- | --- | --- |
| GPU（標準） | RTX 4090 24GB / Community | 約 $0.3–0.5 /h |
| GPU（節約） | RTX A4000 16GB / A5000 24GB | 約 $0.17–0.3 /h |
| GPU（さらに節約） | 上記の Spot / Interruptible | 標準の 5〜7 割 |
| ストレージ | Network Volume 100GB | 約 $7 /月（Pod 停止中も課金） |

1 日 2 時間 × 週 3 回で **月 $15〜25** 程度。

## クイックスタート

1. [docs/runpod-setup.md](docs/runpod-setup.md) の手順で Network Volume と Pod を作る
2. Pod 作成時の環境変数に以下を設定する

   ```
   PROVISIONING_SCRIPT=https://raw.githubusercontent.com/OTL/cloudgpu/main/scripts/provision.sh
   MODEL_SET=starter
   ```

3. Pod の web terminal で起動する

   ```bash
   /workspace/bin/comfy
   ```

4. 表示された `https://<pod-id>-8188.proxy.runpod.net` を開く
5. 終わったら成果物を回収して **terminate**

テキスト LLM を使いたい場合は別の Pod を立てて [docs/llm.md](docs/llm.md) の手順を踏む。

```bash
curl -fsSL https://raw.githubusercontent.com/OTL/cloudgpu/main/scripts/provision-llm.sh | bash
/workspace/bin/llm
```

## 短縮コマンド

`provision.sh` を実行すると `/workspace/bin` に短い名前が置かれる。`/workspace` は
Network Volume なので Pod を作り直しても残る。

| コマンド | 内容 |
| --- | --- |
| `/workspace/bin/comfy` | ComfyUI を起動 |
| `/workspace/bin/comfy-models starter` | モデルを取得 |
| `/workspace/bin/comfy-get <user@host>` | 生成物をローカルへ回収 |
| `/workspace/bin/llm` | テキスト LLM（Ollama + Open WebUI）を起動 |
| `/workspace/bin/llm-models starter` | LLM のモデルを取得 |
| `/workspace/bin/llm-setup` | LLM 側の初回セットアップ |

毎回このパスを打つのが面倒なら PATH を通す。

```bash
. /workspace/bin/rc
```

以降そのシェルでは `comfy` / `comfy-models` / `comfy-log` / `comfy-stop`、
LLM 側は `llm` / `llm-models` / `llm-log` / `llm-stop` だけで済む。
`rc` はコンテナ側の PATH をいじるだけなので、Pod を編集・再生成したあとは
読み込み直すこと（`/workspace/bin` の中身自体は残っている）。

テンプレートが `PROVISIONING_SCRIPT` に対応していない場合は、Pod の web terminal で
直接叩いてもよい。

```bash
curl -fsSL https://raw.githubusercontent.com/OTL/cloudgpu/main/scripts/provision.sh | bash
```

## ドキュメント

| ファイル | 内容 |
| --- | --- |
| [docs/runpod-setup.md](docs/runpod-setup.md) | Network Volume と Pod の作成手順 |
| [docs/models.md](docs/models.md) | 画像モデルの選定とライセンス |
| [docs/llm.md](docs/llm.md) | テキスト LLM（Ollama + Open WebUI）の導入と運用 |
| [docs/cost-control.md](docs/cost-control.md) | 課金を抑えるための運用ルール |
| [docs/troubleshooting.md](docs/troubleshooting.md) | よくある詰まりどころ |

## ワークフロー

[workflows/](workflows) に設定済みの ComfyUI ワークフローを置いてある。`provision.sh`
実行時に ComfyUI 側へコピーされるので、UI のサイドバー（Workflows）から選んで
プロンプトを書き換えるだけで生成できる。

| ファイル | 内容 |
| --- | --- |
| [workflows/illustrious.json](workflows/illustrious.json) | Illustrious-XL v1.0 用（`MODEL_SET=uncensored`） |
| [workflows/pony.json](workflows/pony.json) | Pony Diffusion V6 XL 用（`MODEL_SET=pony`） |

## スクリプト

| ファイル | 内容 |
| --- | --- |
| [scripts/provision.sh](scripts/provision.sh) | 初回セットアップ（venv、カスタムノード、モデル取得） |
| [scripts/bootstrap.sh](scripts/bootstrap.sh) | `/workspace/bin` に短縮コマンドを置く（provision.sh から自動実行） |
| [scripts/start-comfyui.sh](scripts/start-comfyui.sh) | ComfyUI の起動（DNS 補修、依存の確認、CORS 対応込み） |
| [scripts/download-models.sh](scripts/download-models.sh) | モデルだけを個別に追加取得 |
| [scripts/fetch-outputs.sh](scripts/fetch-outputs.sh) | 生成物をローカルへ回収 |
| [scripts/provision-llm.sh](scripts/provision-llm.sh) | LLM 側の初回セットアップ（Ollama、Open WebUI、モデル取得） |
| [scripts/start-llm.sh](scripts/start-llm.sh) | Ollama + Open WebUI の起動 |
| [scripts/pull-llm-models.sh](scripts/pull-llm-models.sh) | LLM のモデルだけを個別に追加取得 |
