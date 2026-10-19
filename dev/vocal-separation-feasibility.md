# ボーカル分離機能の実現可能性調査（2026-10-19）

1 つの音源から「ボーカルカット」「ボーカルリデュース」「コーラスを残してボーカルカット」などの音声トラックを作る機能を PitaTrack に追加できるかを調べた。要求品質は UVR の `UVR-MDX-NET Inst HQ`（ボーカルカット）と `6_HP-Karaoke-UVR`（コーラス残し）以上。

## 結論

- **実現できる。** 要求品質を上回るモデルが公開されていて、Python を同梱せずに ffmpeg と同じ「外部 CLI を呼ぶ」形で動かせる。
- 推奨構成
  - 実行エンジン: **BSRoformer.cpp**（MIT、C++/ggml）。Windows Vulkan 版は zip で 22 MB（exe + dll 4 個）。NVIDIA/AMD/Intel の GPU で動き、`BSR_FORCE_CPU=1` で CPU のみでも動く。
  - ボーカルカット / リデュース: **Kim Mel-Roformer**（MIT）。q8 量子化で 252 MB。
  - コーラス残し: **BS-Roformer Karaoke**（anvuew = GPL-3.0、または frazer & becruily = ライセンス未記載）。q8 で 53 MB。
  - C++ 版の出力は PyTorch 版と 26〜30 dB で一致し、曲 B での SDR も同じ値。8 bit 量子化と C++ 移植による品質低下は見えない。
- 品質（公開ベンチマーク MVSEP、SDR が高いほど良い）
  - ボーカルカット: Inst HQ 4 の伴奏 16.0 dB に対し Kim は 17.4 dB。手元の曲 B でも Roformer 系 > MDX-Net の順位は同じ。
  - コーラス残し: 6_HP-Karaoke のリード 6.35 dB に対し BS-Roformer Karaoke は 10.1〜10.2 dB。「コーラス+伴奏」側も 11.7 → 15.5 dB。手元ではコーラス入りの正解音源がないので聴き比べで確認する。
- 速度（この PC: Ryzen 9 9900X / RTX 3080、3 分 57 秒の曲）: Kim は GPU（Vulkan）で 11 秒、CPU のみだと C++ 版で 7.7 分（PyTorch 版なら 3.4 分）。カラオケモデルは GPU で約 50 秒、PyTorch 版を CPU で動かすと 17 分かかったので、GPU のない PC では「時間がかかる」案内が要る。
- 残る課題は **カラオケモデルのライセンス**（GPL か未記載）と **BSRoformer.cpp がまだ v0.1.0** であること。

## 1. 作れる出力と作り方

分離モデルは「ボーカル」1 本を推定し、伴奏側は `元音源 − ボーカル` で作る（PyTorch 版の実装も同じ）。この性質を使うと、1 回の推論から複数の出力が作れる。

| 出力 | 作り方 | 使うモデル |
|---|---|---|
| ボーカルカット | `mix − vocals` | Kim |
| ボーカルリデュース（−X dB） | `mix − vocals × (1 − 10^(−X/20))` ＝ 伴奏 + ボーカル × 10^(−X/20) | Kim（同じ推論結果を再利用） |
| コーラスを残してボーカルカット | `mix − lead` | BS-Roformer Karaoke |
| リードだけリデュース | `mix − lead × (1 − 10^(−X/20))` | BS-Roformer Karaoke（同上） |
| ボーカルのみ / リードのみ | 推論結果そのまま | Kim / Karaoke |
| コーラス成分のみ | Kim の `vocals` に Karaoke を掛けて `vocals − lead` | Kim → Karaoke の 2 段 |

2 段構成（Kim の伴奏 + コーラス成分）は python-audio-separator の作者が勧めている方法で、伴奏の質を Kim に揃えられる。聴き比べ用に出力してある（`3e_…二段.flac`）。

## 2. モデルの比較

### 2.1 公開ベンチマーク（MVSEP）

ボーカルカット（multisong leaderboard、SDR dB: ボーカル / 伴奏）

| モデル | ボーカル | 伴奏 | 重みのライセンス |
|---|---|---|---|
| **基準** UVR-MDX-NET Inst HQ 3 | 9.38 | 15.68 | UVR（MIT 扱い、クレジット要） |
| **基準** Inst HQ 4 | 9.71 | 16.01 | 同上 |
| Inst HQ 5 | 9.45 | 15.76 | 同上 |
| MDX23C-InstVoc HQ | 10.17 | 16.48 | 未記載 |
| BS-Roformer viperx 1297 | 10.96 | 17.27 | **未記載** |
| **Kim Mel-Roformer** | 11.07 | 17.38 | **MIT** |
| becruily deux | 11.37 | 17.55 | CC-BY-NC-4.0 |
| unwa BS-Roformer Leap Xe | 11.79 | 18.10 | 未記載 |

コーラス残し（lead/back vocals leaderboard、SDR dB: リード / コーラス+伴奏）

| モデル | リード | コーラス+伴奏 | 重みのライセンス |
|---|---|---|---|
| **基準** 6_HP-Karaoke-UVR | 6.35 | 11.72 | UVR |
| 5_HP-Karaoke-UVR | 6.58 | 11.94 | UVR |
| UVR-MDX-NET Karaoke（1 / 2） | 6.41 / 4.72 | 11.80 / 10.11 | UVR |
| Mel-Roformer Karaoke aufr33 & viperx | 9.33 | 14.72 | 未記載 |
| becruily Mel Karaoke | 9.61 | 15.00 | 未記載 |
| **BS-Roformer Karaoke frazer & becruily** | 10.06〜10.10 | 15.45〜15.49 | **未記載** |
| **BS-Roformer Karaoke anvuew** | 10.16〜10.23 | 15.54〜15.61 | **GPL-3.0** |

出典: https://mvsep.com/quality_checker/multisong_leaderboard 、https://de.mvsep.com/quality_checker/leaderboard/lead_back_vocals/ 、HuggingFace の各モデルページ（ライセンスは API の metadata で確認）。

### 2.2 手元での計測

公開リポジトリなので曲名は書かず、曲 A / 曲 B と呼ぶ。

#### 曲 A（Suno で作ったデュエット曲、3 分 57 秒）

正解データがないので聴き比べ用。スクラッチパッドの聴き比べフォルダー（曲 A）に次の名前で置いた（FLAC、スクラッチパッドなので消える前に必要ならコピー）。

| 番号 | 内容 |
|---|---|
| 1a / 1b | ボーカルカット 基準（Inst HQ 4 / HQ 3） |
| 1c / 1d | ボーカルカット BS-Roformer 1297 / Kim Mel-Roformer |
| 1e | ボーカルカット Kim の C++ 版（q8、Vulkan） |
| 2a / 2b | ボーカルリデュース −12 dB（Kim / BS-Roformer） |
| 3a | コーラス残し 基準（6_HP-Karaoke） |
| 3b / 3c / 3d | コーラス残し BS-Roformer Karaoke frazer-becruily / anvuew、Mel-Roformer Karaoke aufr33-viperx |
| 3e | コーラス残し 2 段構成（Kim の伴奏 + コーラス成分） |
| 3f | コーラス残し anvuew の C++ 版（q8、Vulkan） |
| 4a | リードだけ −12 dB（frazer-becruily） |
| 9a〜9d | 抜いたリード（6_HP / frazer-becruily / anvuew）、コーラス成分のみ |

デュエット曲は「どちらがリードか」の正解がないため、カラオケモデルの数値比較には向かない。C++ 版（anvuew q8）の出力は PyTorch 版と 29 dB 一致した。

同じ素材フォルダーにある `_vXX` 付きの音源は Suno のステムを加工して合わせ直したものなので、分離の検証には使っていない。

#### 曲 B（市販曲。オンボーカル / オフボーカルの公式音源、3 分 24 秒）

公式のオンボーカルとオフボーカル（どちらも m4a）。オフボーカルを 228 サンプル（5.2 ms）ずらしゲイン 0.923 を掛けると `オン ≈ オフ + ボーカル` になる。オフボーカルにコーラスは入っていない（Kim で測ったボーカル成分は全体の −38 dB）ので、ボーカルカットの正解として使った。コーラス残しの正解にはならない（カラオケモデルがコーラスを残すほど、オフボーカルとの差は大きくなる）。

ただし、ボーカルのない区間だけで測っても各モデルの伴奏 SDR が 11.2〜11.8 dB で頭打ちになるので、公式オフボーカルは「オンボーカル − ボーカル」とマスタリング（リミッター等）の分だけ違う。**絶対値は参考にならず、順位の比較に使う。**

SDR（dB、高いほど良い。推定側のゲインは最適値に合わせてから計算）:

| モデル | ボーカル | 伴奏 |
|---|---|---|
| **基準** Inst HQ 3 | 7.00 | 9.22 |
| **基準** Inst HQ 4 | 6.96 | 9.20 |
| BS-Roformer 1297 | 7.72 | 9.45 |
| Kim Mel-Roformer（PyTorch） | 7.76 | 9.48 |
| **Kim q8（BSRoformer.cpp、Vulkan）** | 7.77 | 9.49 |
| Kim q8、overlap 4 | 7.78 | 9.50 |
| 6_HP-Karaoke（基準、参考） | 5.27 | 7.23 |
| BS-Roformer Karaoke anvuew（PyTorch / C++ q8、参考） | 5.22 / 5.24 | 7.31 / 7.32 |
| BS-Roformer Karaoke frazer-becruily（PyTorch / C++ q8、参考） | 4.75 / 4.95 | 6.92 / 7.08 |

- ボーカルカットは Roformer 系（Kim、BS-Roformer）が基準の MDX-Net を上回り、公開ベンチと同じ順位。差が小さく見えるのは上記の頭打ちのため。
- C++ 版（q8）は PyTorch 版と同じ値。波形の一致度は Kim 26 dB（overlap 1）/ 28 dB（overlap 4）、anvuew 30 dB、frazer-becruily 20 dB。
- カラオケモデルの行は「コーラスを残す」モデルをコーラスなしの正解と比べているので、品質の順位は表せない（参考値）。

聴き比べ用にスクラッチパッドの聴き比べフォルダー（曲 B）にも同じ番号付けで出力を置いた（`0_公式オフボーカル.flac` が正解）。

### 2.3 ライセンスまとめ

| もの | ライセンス | 配布時の扱い |
|---|---|---|
| BSRoformer.cpp（exe/dll） | MIT | 同梱可。ggml も MIT |
| Kim Mel-Roformer の重み | MIT（HF metadata） | 同梱・ダウンロードどちらも可 |
| BS-Roformer Karaoke anvuew | GPL-3.0 | アプリ本体（Apache-2.0）とは別ファイルとして初回利用時にダウンロードするのが安全。同梱するなら GPL の表示と「ソース」提供の整理が要る |
| BS-Roformer Karaoke frazer & becruily | 未記載（= 全権利留保） | 作者に許諾を取るまで配布不可 |
| UVR のモデル（Inst HQ、6_HP） | MIT 扱い（README でクレジット要請、モデル repo に LICENSE なし） | BSRoformer.cpp では動かない（別アーキテクチャ） |
| python-audio-separator | MIT | 検証にのみ使用 |

## 3. 実行方式の比較

| 方式 | サイズ | GPU | 対応モデル | 成熟度 | 判定 |
|---|---|---|---|---|---|
| **BSRoformer.cpp**（外部 CLI） | 22 MB（Vulkan）/ 0.7 MB（CPU）/ 133〜232 MB（CUDA） | Vulkan で NVIDIA/AMD/Intel、CUDA、CPU | BS-Roformer、Mel-Band Roformer（GGUF） | v0.1.0（2026-06）、★42 | **採用候補** |
| python-audio-separator（PyTorch） | CPU 版 0.6〜1 GB、CUDA 版 2.5 GB 超 | CUDA。DirectML は Roformer 非対応 | 全部（VR / MDX / Roformer / Demucs） | 安定、MIT | 検証用。配布には重すぎる。Store では Python の実行時ダウンロードが policy 10.2.2 に抵触しうる |
| ONNX Runtime + DirectML（C# 内蔵） | 数十 MB | DirectML | UVR MDX-Net は実績あり。Roformer は STFT を外に出した ONNX 化が必要で未確立 | — | 将来の C# 版で MDX-Net を動かす選択肢 |
| UVR 本体 | 1.75 GB | — | 全部 | GUI のみ、CLI なし | 不可 |
| stems.cpp | 数十 MB | Vulkan / CUDA / CPU | Kim Mel-Roformer、HTDemucs、MDX | v0.1.5（2026-10）、★2 | カラオケモデル非対応 |

### 3.1 BSRoformer.cpp の実測

- 使い方: `bs_roformer-cli.exe model.gguf in.wav out.wav [--chunk-size N] [--overlap N]`。入力は 44.1 kHz WAV のみ（ffmpeg で変換）、出力は推定したステム 1 本の WAV。進捗は標準出力に `%` で出る。
- GGUF への変換はリポジトリの `scripts/convert_to_gguf.py`（PyTorch が要る。配布側で一度やればよい、1 モデル 1 分弱）。Kim は 913 MB → q8 で 252 MB、カラオケモデルは 204 MB → 53 MB。
  - 注意: 作者が HuggingFace（chenmozhijin/BSRoformer-GGUF）に置いている `BSRoformer-anvuew-Q8_0.gguf` は anvuew の**ボーカル抽出モデル**（anvuew/BS-RoFormer）で、カラオケモデルではない。最初これを使って PyTorch 版と 6〜8 dB しか一致せず気づいた。カラオケ用は `karaoke_bs_roformer_anvuew.ckpt` を自分で変換する。
- PyTorch 版との一致（最適ゲインを合わせた残差）: Kim 26 dB（overlap 1）/ 28 dB（overlap 4）、anvuew karaoke 29〜30 dB、frazer-becruily 20 dB。残りの差はチャンク境界の取り方と 8 bit 量子化。曲 B の SDR は PyTorch 版と同じ値（2.2 の表）。
- 速度（RTX 3080、Vulkan）: 曲 A（3 分 57 秒）で Kim q8 11 秒（推論 9.5 秒）、anvuew karaoke q8 51 秒。曲 B（3 分 24 秒）で Kim 8 秒、Kim overlap 4 で 29 秒、anvuew 45 秒、frazer-becruily 53 秒。PyTorch CUDA 版より速い。
- CPU のみ（`cpu` ビルド、3 分 57 秒の曲）: Kim q8 462 秒。PyTorch の CPU 版（204 秒）より遅いので、GPU のない PC 向けには ggml 側のスレッド数や AVX 対応ビルドの確認が要る。
- メモリ: Kim は compute buffer 541 MB、カラオケモデルは 1.28 GB（チャンク 960000 サンプル）。

### 3.2 速度まとめ（3 分 57 秒の曲、起動とモデル読み込み込み）

| モデル | PyTorch CUDA | PyTorch CPU（12 スレッド） | BSRoformer.cpp Vulkan | BSRoformer.cpp CPU |
|---|---|---|---|---|
| Inst HQ 4（基準） | 18 s | 48 s（ONNX Runtime） | — | — |
| 6_HP-Karaoke（基準） | 25 s | 83 s | — | — |
| Kim Mel-Roformer | 20 s | 204 s | 11 s | 462 s |
| BS-Roformer 1297 | 112 s | — | — | — |
| BS-Roformer Karaoke anvuew | 69 s | 1033 s（他処理と並行） | 51 s | — |
| BS-Roformer Karaoke frazer-becruily | 78 s | — | 53 s（曲 B 3:24） | — |
| Mel-Roformer Karaoke aufr33-viperx | 52 s | — | — | — |

Kim の PyTorch 版は overlap 1、BS-Roformer 系は overlap 4 の設定で、どちらも C++ 版も同じ値を使った。

## 4. PitaTrack への組み込み案

1. **GUI**: トラック一覧に「分離して追加…」ボタン。元音源（動画の音声でも音声ファイルでも）を選び、作る種類をチェック（ボーカルカット / ボーカルリデュース（dB 指定）/ コーラス残し / リードだけリデュース / ボーカルのみ）。進捗はステータス欄に `%` を表示（既存の自動調整と同じ `DoEvents` 方式か、`Process` の非同期読み取り）。
2. **処理**: `ffmpeg -ar 44100 -c:a pcm_f32le` で一時 WAV → `bs_roformer-cli` → 差分とミックスは ffmpeg（`amix=weights=1 -1:normalize=0` など。負の weight が使えるかは要確認。使えなければ WAV の float を直接引く小さな C# ヘルパー）→ `ffmpeg -c:a aac` で m4a → トラック行として追加。トラック名は候補から自動（例: Off Vocal、コーラス入り Off Vocal）。
3. **配布**:
   - ZIP 版: `setup` が ffmpeg と同様に BSRoformer.cpp の Vulkan zip（22 MB）を GitHub Releases からダウンロード・SHA256 確認。モデルは初回利用時にダウンロード（Kim 252 MB、Karaoke 56 MB）。
   - Store 版: exe/dll はパッケージに同梱。モデルは Windows ML の指針どおり初回起動時にアプリローカルへダウンロードし SHA256 確認（25 GB 制限内なので同梱も可）。
   - GPU がない PC では自動的に CPU で動く（Vulkan 版は CPU にフォールバック。`BSR_FORCE_CPU=1` でも強制できる）。Kim は CPU でも実用範囲、カラオケモデルは「数分〜十数分かかる」旨を表示。
4. **ライセンス表示**: 設定ダイアログの「ライセンス」に BSRoformer.cpp（MIT）、ggml（MIT）、Kim Mel-Roformer（MIT）、カラオケモデル（決まったもの）を追加。

## 5. 未確認・リスク

- カラオケモデルのライセンス。anvuew（GPL-3.0）は「別ファイルで初回ダウンロード」なら Apache-2.0 の本体と分けられるが、Store の審査での説明が要る。frazer & becruily は作者（becruily）に HuggingFace で許諾を頼む価値がある。どちらも無理なら、コーラス残しは UVR の MDX-Net Karaoke 2（ONNX、別エンジンが要る）か、Mel-Roformer Karaoke（未記載）になる。
- BSRoformer.cpp は v0.1.0。BS-Roformer 対応は 2026-06 から。エラー時の終了コード、長い曲（10 分超）のメモリ、Vulkan ドライバが古い PC での挙動は未確認。
- AMD GPU: この PC の Radeon 内蔵 GPU（Ryzen 9 9900X の 2 CU、AMD 純正ドライバー）を `GGML_VK_VISIBLE_DEVICES=1` で選ぶと Vulkan 版はそのまま動いた。ただし 5 分で 34 % と CPU より遅く、途中で打ち切った。小さな内蔵 GPU では CPU と同程度以下と考えて、ディスクリート GPU 以外は「時間がかかる」扱いにする。Intel GPU と、ドライバーが古い PC での挙動は未確認。
- Smart App Control 環境で未署名の `bs_roformer-cli.exe` が動くか（LGPL ffmpeg と同じ問題。Store 署名で解決）。
- 2 段構成（Kim → Karaoke）の品質は聴き比べでの確認待ち。

## 6. 次のステップ

1. 聴き比べで Kim / BS-Roformer Karaoke の音を確認し、採用モデルを決める。
2. カラオケモデルのライセンスを確認（anvuew の GPL 運用、becruily への許諾依頼）。
3. プロトタイプ: PowerShell から `bs_roformer-cli` を呼び、差分・リデュース・m4a 化までを関数にする。
4. GUI に「分離して追加」を組み込み、setup / MSIX に Vulkan zip の取得を追加。

## 7. プロトタイプ（同日実装）

`tools/mixtrack_ffmpeg_gui.ps1` に「分離して追加」を入れた（約 800 行追加、`# ---- ボーカル分離 ----` の節）。

- 配置: `tools\bsroformer\bs_roformer-cli.exe` と ggml の dll（`.gitignore` 済み）。exe がなければ GitHub Releases v0.1.0 の Vulkan zip をダウンロードして SHA256 を確認し展開する（`Request-BsRoformer`）。モデルは当初 `tools\bsroformer\models\*.gguf` に手で置く前提だったが、現在は `%LOCALAPPDATA%\PitaTrack\models` に初回ダウンロードする（後述）。
- 処理（`Invoke-Separation`）: ffmpeg で 44.1 kHz ステレオ float WAV に変換 → `bs_roformer-cli` を `Start-Process` で隠し実行し、標準出力の `%` をファイル越しに読んで進捗表示 → ffmpeg の `amerge,pan` で `mix − stem × k` を作り AAC（設定の再エンコードビットレート）で書き出す。`amix` の負の重みは符号が落ちるので使えない。ピークが 0 dBFS を超えやすいので `alimiter=limit=0.98:level=false:latency=true` を通す（`latency=true` で遅れなし）。
- 出力: 元音源と同じフォルダーに `<名前>_offvocal_kim.m4a` / `_vocal-8dB_kim.m4a` / `_karaoke_anvuew_2stage.m4a` など（モデル名入り）。トラック名は設定のひな形から付ける（既定は「オフボーカル」「ボーカル -8dB」「コーラス入りオフボーカル」「ボーカルのみ」。後述）。
- 操作の流れ（ユーザーの指摘で変更。2026-10-19）: 元の音源を先にトラックとして置き（「+ 追加」やドロップ、または「元動画の音声を1トラック目に使用」）、その行を選んで **「ボーカル分離」** を押す。作ったトラックは元のトラックの**下に、同じオフセットで**差し込まれる（`Add-TrackRow -Index`、`Add-SeparatedTracksToGrid -InsertIndex -OffsetMs`）。自動調整は掛けない（元と同じずれなので不要）。
- 画面（`Show-SeparationDialog`）: 元のトラック（表示のみ）、作るトラック 4 種（リデュースは dB 指定）、モデル、進捗バー、中止。処理中はダイアログ内で進む。
- 結果の面（ユーザーの提案で追加。2026-10-19）: 実行が終わると同じダイアログが結果リストに切り替わる。採用チェック・トラック名（編集可）・ファイル名の一覧で、先頭に「（元の音源）」を比較用に並べる。▶ 再生 / ■ 停止 / 位置バーでプレビューでき、再生中に別の行を選ぶと同じ位置のままそのトラックに切り替わる（A/B 比較）。再生は WPF の `System.Windows.Media.MediaPlayer`（PresentationCore、Media Foundation）で、読み込み完了は `NaturalDuration.HasTimeSpan` をタイマーで見て位置合わせしてから再生する。生成物は `%TEMP%\PitaTrack_sep_results_<guid>` に書き出し（`Invoke-Separation -OutputDir`。作業用 WAV も `work\` に残す）、「採用したトラックを追加」で採用行のファイルだけを元のファイルと同じフォルダーへ移してから一覧に差し込む。採用しないトラックは「保存...」で任意の場所にコピーして残せる。残りはダイアログを閉じるときに一時フォルダーごと消す。
- リデュースの量はプレビュー中に変えられる（ユーザーの要望。2026-10-19）: リデュースの行を選ぶと「ボーカル量」のスライダー（−20〜40 dB）が出る。プレビューは同じモデルの伴奏（オフボーカル）とボーカルのみの 2 ファイルを MediaPlayer 2 本で同時に鳴らし、音量で量を変える（リデュースを選ぶとこの 2 つは隠しトラックとして必ず作る）。採用・保存のときに量が変わっていれば、`work\` の WAV から正確な係数で作り直す（`Get-SeparationReduceGains`）。
- マイナスの dB はボーカル強調（画面には書かない隠し機能。入力欄とスライダーが −20 まで動く）。スライダーの横には音量比の目安「（約25%）」「（約2.0倍）」を出す。ボーカルを足すとリミッターが効きすぎるので、出力 = 10^(dB/20) × 元音源 + (1 − 10^(dB/20)) × ボーカル として伴奏側を下げる（バランスは同じで全体が小さくなる）。トラック名は「ボーカル +6dB」、ファイル名は `_vocal+6dB_kim.m4a`。
- 派生トラックの一般形は `MixGain × 元音源 + StemGain × ステム`（`New-SeparationDerivedTrack -MixGain -StemGain`。オフボーカルとコーラス残しは 1 と −1）。
- 結果の面でファイル操作（作り直し・移動・コピー）をしている間は `$setResultBusy` でボタンを無効にする（`DoEvents` で画面が動くため、二重に押されると壊れる）。
- モデルの選択: 「ボーカル」「リードボーカル」のコンボボックス。一覧は `$Script:SeparationModels`（標準の Kim と anvuew だけ。2026-10-19 にユーザーの指摘で、配れないモデルは一覧から外し「おすすめ」表記もやめた）に、モデルフォルダーにある未登録の .gguf を足したもの（名前に karaoke / kara / lead があればリード扱い）。標準モデルのファイルがなければ「（初回にダウンロード）」。
- トラック名: 設定ダイアログの「ボーカル分離で作るトラックの初期名」（ボーカルカット／リデュース／コーラス残し／ボーカルのみ）をひな形にする。`{model}` はモデルの短い名前、`{db}` はリデュース量（-8 / +6）に置き換え（`Expand-SeparationTitleTemplate`）。候補をまとめて作るときにひな形に `{model}` がなければ名前の後ろに（モデル名）を付ける。結果画面のトラック名セルはクリックで候補メニュー（設定のトラック名候補＋今回の初期名）、入力時は補完（メイン画面と同じ方式）。リデュースの既定は 8 dB、トップ画面の単位ラベルは「dB 下げる（結果画面で調節可）」。
- モデルフォルダーは **`%LOCALAPPDATA%\PitaTrack\models`**（2026-10-19 に `tools\bsroformer\models` から移動。Store 版はインストール先が読み取り専用なので、ユーザーが自分で置ける場所にした）。ダイアログの「モデルフォルダーを開く」でエクスプローラーが開き、戻ってくると一覧を読み直す（`Activated` イベント）。同名の `.json`（`{"label": "表示名", "short": "トラック名に使う短い名前", "role": "vocals か lead"}`）があれば表示名・用途を上書きする（`Read-SeparationModelSidecar`）。
  - 注意（MSIX）: パッケージ版はファイルシステム仮想化で `%LOCALAPPDATA%` への書き込みが `Packages\<id>\LocalCache\Local` に逸れる。エクスプローラーで開く場所と一致させるには、マニフェストで `desktop6:FileSystemWriteVirtualization` を `disabled` にするか、アプリ側でも LocalCache のパスを使う。→ main の Store 版（2026-10-19、PR #5〜#12）は仮想化をそのまま使い、設定を `%LOCALAPPDATA%\PitaTrack` に書いて LocalCache に振り替えさせている（アンインストールで消える。起動用 exe が `PITATRACK_PACKAGED=1` を渡し、PowerShell と子プロセスもパッケージ内で動く）。モデルも同じ場所に置き、「モデルフォルダーを開く」だけ LocalCache の実パス（`%LOCALAPPDATA%\Packages\<パッケージ>\LocalCache\Local\PitaTrack\models`）を開くようにする。
  - 複数のステムを出すモデル（becruily のカラオケなど `num_stems: 2`）は `bs_roformer-cli` が `<名前>_stem_N.wav` に分けて出すので、`.json` の `stem` でボーカル／リードの番号を指定する（`Invoke-BsRoformerCli -StemIndex`）。
  - 追加で変換して置いたモデル（2026-10-19）: Kim FT2 by unwa（ボーカル）、BS-Roformer Leap Xe by unwa（ボーカル、公開中で最高スコア）、Mel Karaoke by gabox / becruily（リード）。いずれもライセンス未記載なので自分で使う分に留める。一覧は `dev/vocal-separation/README.md`。
  - ユーザーが追加できるのは BSRoformer.cpp が読める BS-Roformer / Mel-Band Roformer の GGUF だけ。配布されているのは PyTorch の ckpt が多く、GGUF への変換には Python と torch が要るので、実用上は「こちらが変換して配布する一覧から選ぶ」が主になる。Store の審査上、モデルはデータなのでユーザーが置くのも初回ダウンロードも問題ない（実行コードのダウンロードは不可）。選んだモデルと dB、2 段方式のオン/オフは設定ファイルの `Separation` に保存して次回の既定にする（「全モデルで候補を作る」は一回限りの操作なので保存しない）。
- 確認（2026-10-19）: 曲 B の動画で「全モデルで候補を作る」＋コーラス残し（2 段）を GUI から実行し、5 トラック（オフボーカル Kim / 1297、コーラス入り frazer / anvuew / Mel aufr33 の 2 段。手で置いたモデルも一覧にあった時点）が 208 秒で追加・保存できた。
- コーラス残しの既定は **2 段方式**（聴き比べでの判断。2026-10-19）: Kim でボーカルを取り出し、そのステムにカラオケモデルを掛けてリードを推定し、`元音源 − リード`（＝ Kim の伴奏 + コーラス成分）を出す。チェックを外すと元音源に直接カラオケモデルを掛ける。既定モデルは当初 Kim と frazer-becruily（コンボボックスに「おすすめ」と表示）だったが、配布の決定（後述）で Kim と anvuew に変え、「おすすめ」表記もやめた。
- 「全モデルで候補を作る」: ボーカルカットとコーラス残しを、ファイルのある全モデルで 1 トラックずつ作る（トラック名にモデル名を付ける）。曲ごとに向くモデルが違うので、保存した MP4 を MPC-BE で聴き比べて不要なトラックを消す使い方を想定。実行は `Get-SeparationRunPlan` が「モデル × 入力（元音源 / ボーカルステム）」の重複を除いて並べる。
- CLI 版には入れていない（操作方法が決まっていないため）。
- `Start-Process -PassThru` は終了前に `.Handle` に触らないと `ExitCode` が取れない（`Invoke-SeparationProcess` にコメントあり）。
- 確認: 曲 B の動画（3 分 31 秒）を元に GUI から「ボーカルカット」「コーラス残し」を作り保存するまでを UI Automation で通した（分離 58 秒、RTX 3080）。`offvocal + vocals ≈ 元音源`（AAC 込みで 22 dB）、保存した MP4 は MPC-BE 1.9.1 でトラック名付きで切り替えられた。
- 配布（2026-10-19 決定・リリース作成済み https://github.com/bee7813993/ffmpegMp4Mix/releases/tag/separation-models-20261019 ）: ライセンスが明確な **Kim（MIT）と anvuew（GPL-3.0）** を標準モデルにし、GitHub Releases `separation-models-20261019` に GGUF（q8）・`*.LICENSE.txt`（全文と入手元、変換の注記）・`models.json`・`SHA256SUMS` を置いて、初めて使うときにダウンロードする（`Request-SeparationModel` → `Install-SeparationModel`。確認メッセージに作者・ライセンス・入手元を出し、SHA256 を照合、ライセンス文も隣に置く）。既定のリード用モデルは anvuew に変更（frazer-becruily は許諾がないと配れないため「おすすめ」から外した）。コンボボックスではファイルのないモデルを「（初回にダウンロード）」「（未配置）」で区別する。README（日英）に使い方・モデル・ライセンスの節を追加。
- Store 版（MSIX）への組み込み（2026-10-19、同日に別の PR）: Store の規約で実行ファイルはあとからダウンロードできず、インストール先にも書き込めないので、`dev\build_msix.ps1` が BSRoformer.cpp の Windows Vulkan 版 zip（GUI の `$Script:BsRoformerUrl` / `$Script:BsRoformerSha256` を読む）を `dist\bsroformer-cache` にダウンロードして SHA256 を照合し、exe と dll を `tools\bsroformer` に、BSRoformer.cpp と ggml の MIT License（zip には入っていないので別に取得）を `licenses\BSRoformer.cpp` に入れる。`msix\licenses-README.txt` に両者とモデル（Kim = MIT、anvuew = GPL-3.0、初回ダウンロード）の項を足した。GUI は `PITATRACK_PACKAGED=1` のとき `Request-BsRoformer` でダウンロードせず、exe がなければ「この版には入っていない」と出す。「モデルフォルダーを開く」と置き場の案内は `Get-SeparationModelsRealDir`（LocalCache の実パス。パッケージ ファミリー名は kernel32 の `GetCurrentPackageFamilyName` を Add-Type の `PitaTrackPackage` で呼ぶ）。
  - exe と ggml の dll は MSVC ビルドで msvcp140 / vcruntime140 / vcomp140 を使う（`dumpbin /dependents` で確認）。パッケージの中で動くプロセスは依存パッケージから dll を読むので、マニフェストに `Microsoft.VCLibs.140.00.UWPDesktop` への依存を足した（Store が一緒に入れる）。ZIP 版は作者の zip をそのまま使うので、VC++ 再頒布可能パッケージが入っていない PC では `bs_roformer-cli.exe` が起動しない（未対応。別途）。
  - 同梱の LGPL 版 ffmpeg（`ffmpeg-9.0.2-pitatrack1`）は `--disable-everything` の最小構成で、分離が使う wav・ipod のマルチプレクサーと amerge・pan・alimiter のフィルターが入っておらず、最初の変換で `Unable to choose an output format for '...mix.wav'` になった（PR #13 の確認は gyan.dev のフルビルドで行っていた。PR #8 以降 `setup.ps1` も同じ LGPL 版を落とすので、ZIP 版の新規インストールでも同じ）。`dev/ffmpeg-lgpl/configure-options.txt` に足して `PITATRACK_BUILD=2` にし、`test_pitatrack_usage.ps1` に分離の確認（節 4）を追加。Docker で作った `ffmpeg-9.0.2-pitatrack2` で 116/116 OK。Release を作って `build_msix.ps1` と `setup.ps1` の URL と SHA256 を更新するのは別の作業。
  - 確認（2026-10-19、`build_msix.ps1 -Register -DevIdentity -FfmpegDir <手元の pitatrack2>` で登録した PitaTrack.Dev を、AppExecutionAlias から UI Automation で操作。素材は 2 分のサンプル動画）: エンジンのダウンロード確認は出ず、Kim と anvuew の初回ダウンロード（SHA256 照合、ライセンス文も隣に）→ 2 段方式のコーラス残しとオフボーカルの 2 トラックが 48 秒で結果一覧に出てプレビュー再生でき、置いた GGUF と同名 .json は「MSIX test custom」として一覧に出た。`bs_roformer-cli.exe` は PitaTrack.Dev の ID で動き、msvcp140 / vcruntime140 / vcomp140 は `Microsoft.VCLibs.140.00.UWPDesktop` のフォルダーから読み込まれた（マニフェストの依存が効いている）。設定 → ライセンスに BSRoformer.cpp / ggml とモデルの項が出る。
  - 開発者モードで登録した署名なしのパッケージでは `%LOCALAPPDATA%\PitaTrack\models` への書き込みは振り替えられず実フォルダーに落ちた（パッケージ ID を持つプロセスから WMI で確認。Store から入れた版では未確認）。「モデルフォルダーを開く」を常に LocalCache にすると、実フォルダーが既にあるとき LocalCache 側が作られず Documents が開いたので、小さなファイルを書いてどちらに落ちたかを調べる方式にした。この PC では Claude のツールプロセス自体が Claude（MSIX）の仮想化の中で動き、`%LOCALAPPDATA%` が合成ビューに見えるので、実フォルダーの確認は WMI（`CIM_DataFile`、`Win32_Process.Create`）で行った（前に「置いた」追加モデルは Claude 側の LocalCache にだけある）。
- 残り: CLI 版、becruily への許諾依頼。

## 付録: 検証に使ったもの

- python-audio-separator 0.47.0、PyTorch 2.11.0+cu128、onnxruntime-gpu 1.23.2（1.31 は CUDA 13 用で動かず）。
- UVR 5.6 のモデル（`%LOCALAPPDATA%\Programs\Ultimate Vocal Remover\models`）: Inst HQ 3 / 4、6_HP-Karaoke。
- BSRoformer.cpp v0.1.0 Windows Vulkan / x64-msvc。GGUF は Kim、frazer-becruily、anvuew karaoke を手元で q8_0 に変換（作者変換の anvuew Q8_0 はボーカル抽出モデルだったため不使用）。
- SDR の計算は推定側に最適ゲインを掛けてから行った（audio-separator は出力をピーク 0.9 に正規化するため）。
- 計測スクリプトは `dev/vocal-separation/` に置いた。
