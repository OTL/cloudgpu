# cloudgpu

RunPod 上に「使うときだけ立ち上げる」画像生成環境（ComfyUI）を最小コストで構築するための
手順書とプロビジョニングスクリプト。将来的にローカル LLM（vLLM / Ollama）も同じ
Network Volume に相乗りさせる前提で構成している。

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

## 短縮コマンド

`provision.sh` を実行すると `/workspace/bin` に短い名前が置かれる。`/workspace` は
Network Volume なので Pod を作り直しても残る。

| コマンド | 内容 |
| --- | --- |
| `/workspace/bin/comfy` | ComfyUI を起動 |
| `/workspace/bin/comfy-models starter` | モデルを取得 |
| `/workspace/bin/comfy-get <user@host>` | 生成物をローカルへ回収 |

`comfy` は起動前に自分でリポジトリを `git pull` して `bootstrap.sh` を回すので、
スクリプトを更新したあとに手で pull し直す必要はない。オフラインや衝突で pull に
失敗した場合は警告を出して、手元にあるもので起動する（`SELF_UPDATE=0` で無効化）。

毎回このパスを打つのが面倒なら PATH を通す。

```bash
. /workspace/bin/rc
```

以降そのシェルでは `comfy` / `comfy-models` / `comfy-log` / `comfy-stop` だけで済む。
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
| [docs/models.md](docs/models.md) | 入れるモデルの選定とライセンス |
| [docs/cost-control.md](docs/cost-control.md) | 課金を抑えるための運用ルール |
| [docs/troubleshooting.md](docs/troubleshooting.md) | よくある詰まりどころ |

## スクリプト

| ファイル | 内容 |
| --- | --- |
| [scripts/provision.sh](scripts/provision.sh) | 初回セットアップ（venv、カスタムノード、モデル取得） |
| [scripts/bootstrap.sh](scripts/bootstrap.sh) | `/workspace/bin` に短縮コマンドを置く（provision.sh から自動実行） |
| [scripts/start-comfyui.sh](scripts/start-comfyui.sh) | ComfyUI の起動（DNS 補修、依存の確認、CORS 対応込み） |
| [scripts/download-models.sh](scripts/download-models.sh) | モデルだけを個別に追加取得 |
| [scripts/fetch-outputs.sh](scripts/fetch-outputs.sh) | 生成物をローカルへ回収 |
