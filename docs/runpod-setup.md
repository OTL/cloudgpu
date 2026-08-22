# RunPod セットアップ手順

所要時間は 30 分程度（モデルのダウンロード待ちを除く）。

## 0. 課金の上限を先に決める

アカウントを作ったら、**何より先に** Billing でクレジットを少額（$10 程度）だけ
チャージする。RunPod はプリペイド式なので、チャージ額がそのまま損失の上限になる。
オートリチャージは最初はオフにしておくこと。

## 1. Network Volume を作る（Pod より先）

`Storage` → `New Network Volume`。

| 設定 | 推奨 | 理由 |
| --- | --- | --- |
| Region | 使いたい GPU の在庫が多いところ | **後から変更できない**。Volume のあるリージョンにしか Pod を作れなくなる |
| Size | 100 GB | FLUX schnell fp8 が約 17GB、SDXL が約 7GB。LoRA を集め出すとすぐ埋まる |

リージョン選びが唯一の後戻りしづらい決断。先に `Pods` → `Deploy` の画面で
RTX 4090 の在庫があるリージョンを確認してから戻ってくるとよい。

容量は後から増やせる（減らせない）ので、迷ったら 50GB で始めてもよい。

## 2. Pod をデプロイする

`Pods` → `Deploy`。

| 設定 | 値 |
| --- | --- |
| Network Volume | 手順 1 で作ったものを選択（`/workspace` にマウントされる） |
| GPU | RTX 4090 (24GB)。節約するなら A5000 / A4000 (16GB) |
| Cloud | Community（Secure より安い） |
| Pricing | まずは On-Demand。慣れたら Spot |
| Template | `ComfyUI`（公式）または `ai-dock / comfyui` |
| Container Disk | 20GB 程度で足りる（モデルは Volume 側に置くため） |

### 環境変数

`Edit Template` → `Environment Variables` に追加する。

| Key | Value |
| --- | --- |
| `PROVISIONING_SCRIPT` | `https://raw.githubusercontent.com/OTL/cloudgpu/main/scripts/provision.sh` |
| `MODEL_SET` | `starter` |
| `HF_TOKEN` | （gated モデルを使うときだけ） |

`PROVISIONING_SCRIPT` は ai-dock 系テンプレートの機能。対応していないテンプレートの
場合は Pod 起動後に web terminal で以下を実行する。

```bash
curl -fsSL https://raw.githubusercontent.com/OTL/cloudgpu/main/scripts/provision.sh | bash
```

## 3. ComfyUI に繋ぐ

Pod のカードの `Connect` → HTTP Service の **8188** を開く。
`https://<pod-id>-8188.proxy.runpod.net` のような URL になる。

初回はコンテナ起動 + プロビジョニングで 5〜15 分かかる。ログは
`Connect` → `Logs`、あるいは web terminal で確認できる。

> プロビジョニング中に ComfyUI が先に起動していると、新しく落としたモデルが
> ドロップダウンに出ないことがある。その場合は ComfyUI を再起動するか、
> ブラウザで `R` キー（Refresh Node Definitions）を押す。

## 4. 最初の 1 枚

1. `Workflow` → `Browse Templates` → `Image Generation`
2. Load Checkpoint に `flux1-schnell-fp8.safetensors` を選ぶ
3. FLUX schnell は **steps=4, cfg=1.0** が前提。デフォルトの steps=20 / cfg=8 のままだと
   絵が崩れるので必ず変える
4. `Queue Prompt`

## 5. 終了時（重要）

```bash
# ローカルから
./scripts/fetch-outputs.sh root@<ip> -p <port>
```

回収したら Pod を **Terminate**。Stop ではない。理由は
[cost-control.md](cost-control.md) を参照。

`/workspace` 配下（モデル、カスタムノード、ワークフロー JSON）は Network Volume に
残るので、次回は同じ Volume を指定して Pod を作り直せばそのまま再開できる。
