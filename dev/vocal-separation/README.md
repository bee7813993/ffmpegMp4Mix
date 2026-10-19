# ボーカル分離の検証スクリプト

`dev/vocal-separation-feasibility.md` の計測に使ったスクリプト。実装時に分離品質を再確認するためのメモとして置いてある。製品には含めない。

スクリプトは次のフォルダ配置を前提にしている（調査時はスクラッチパッドに作った）。

```text
<作業フォルダ>\
  scripts\            このフォルダの .py
  sep\
    venv\             uv venv --python 3.12 → torch/torchaudio (cu128) → audio-separator[gpu] audioread → onnxruntime-gpu==1.23.2
    models\           UVR の models からコピーした .onnx/.pth と、audio-separator --download_model_only で取った .ckpt/.yaml
```

| スクリプト | 用途 |
|---|---|
| `compare.py <曲> <出力先> [--cpu] [--only key,...]` | 基準モデルと Roformer 系モデルを順に実行し、処理時間を `times.json` に記録。ffmpeg でリデュース（−12 dB）と 2 段構成のミックスも作る |
| `cpu_run.py <曲> <出力先> <モデル>...` | `torch.cuda.is_available` を偽にして CPU のみの時間を測る（`CUDA_VISIBLE_DEVICES=` では Roformer の読み込みが失敗する） |
| `sdr2.py <オンボーカル> <オフボーカル> <出力先>` | 公式のオン/オフボーカルを正解にして各出力の SDR を出す。オフボーカルのずれとゲインは自動で合わせる |
| `match.py <A> <B>` | 2 つの出力の一致度（B を A に最適ゲインで合わせた残差、dB）。PyTorch 版と C++ 版の比較用 |
| `subtract.py <mix> <target> <other.flac> [target.flac]` | `other = mix − target`。BSRoformer.cpp はターゲット 1 本しか出さないので伴奏側を作る |
| `nulltest.py <mix> <part>...` | `mix ≈ Σ part` かどうか（ずれとゲイン付き）を確かめる |

GUI が使うモデル（GGUF）の置き場は `%LOCALAPPDATA%\PitaTrack\models`。標準（登録済み）のモデルは Kim と anvuew の 2 つだけで、ファイルがなければ初回に GitHub Releases `separation-models-20261019` からダウンロードされる（ファイル名と SHA256 は `tools/mixtrack_ffmpeg_gui.ps1` の `$Script:SeparationModels`）。それ以外のモデル（下の表のものなど）は一覧に出ないので、使うときは GGUF をこのフォルダーに手で置く。未登録の .gguf も置けば一覧に出る。同名の `.json` に `{"label": "表示名", "short": "短い名前", "role": "vocals か lead", "stem": 0}` を書くと表示名と用途を指定できる（`stem` は複数ステムを出すモデルでボーカル／リードが何番目か。`bs_roformer-cli` は `<名前>_stem_N.wav` に分けて出すので、その番号を使う）。

2026-10-19 に変換して置いたモデル（元は PyTorch の ckpt。`BSRoformer.cpp/scripts/convert_to_gguf.py --dtype q8_0`）:

| GGUF | 元 | 用途 | PyTorch 版との一致（40 秒クリップ） |
|---|---|---|---|
| `kim_ft2_unwa_vocals-Q8_0.gguf` | MelBand Roformer Kim FT2 by unwa | vocals | 28.4 dB |
| `bs_roformer_leap_xe_unwa_vocals-Q8_0.gguf` | BS-Roformer Leap Xe (voc) by unwa（HF pcunwa/BS-Roformer-Leap） | vocals | PyTorch 版なし。Kim の出力と 19.3 dB 一致 |
| `karaoke_mel_gabox-Q8_0.gguf` | MelBand Roformer Karaoke by Gabox | lead | 30.6 dB |
| `karaoke_mel_becruily-Q8_0.gguf` | MelBand Roformer Karaoke by becruily（2 ステム、stem 0 がリード） | lead | 29.9 dB |

BSRoformer.cpp は `bs_roformer-cli.exe model.gguf in.wav out.wav [--overlap N]`（入力は 44.1 kHz WAV）。GGUF への変換は同リポジトリの `scripts/convert_to_gguf.py --ckpt … --config … --out … --dtype q8_0`（依存: torch numpy pyyaml librosa einops gguf）。

## プロトタイプの動作確認に使ったスクリプト（PowerShell、BOM 付き UTF-8 で保存）

| スクリプト | 用途 |
|---|---|
| `headless_test.ps1 -SourceFile <音源> [-Karaoke] [-TwoStage] [-AllCandidates] [-Reduce] [-VocalsOnly] [-VocalModel kim] [-LeadModel anvuew]` | GUI を出さずに `Invoke-Separation` を呼び、モデル一覧・実行計画・生成ファイル・時間を出す。GUI スクリプトの関数定義だけを読み込む（パスはスクリプト内に直書き） |
| `gui_test.ps1 -VideoFile <動画> -ShotDir <保存先> [-Karaoke] [-Reduce] [-AllCandidates] [-NoTwoStage] [-SettingsShot] [-CloseInsteadOfAdopt]` | UI Automation で GUI を起動し「元動画の音声を1トラック目に使用」→「ボーカル分離」→「実行」→結果リストでトラック名の候補メニュー・3 秒プレビュー・行の切り替え・ボーカル量の変更・「保存...」→「採用したトラックを追加」→「保存」→「閉じる」まで操作して画面を保存する。同名の別の PitaTrack が開いていてもプロセス ID で区別する。画面は `PrintWindow` で撮るので他のウィンドウが手前にあってもよい。所有ダイアログは UIA でオーナーの子に見えることも最上位に見えることもあるので両方探す |
| `mpc_test.ps1 -VideoFile <mp4> -ShotDir <保存先>` | MPC-BE で開き、A キーで音声トラックを切り替えながら画面を保存する |
| `download_test.ps1 [-Keys kim,anvuew]` | 標準モデルをフォルダーから一時的に外し、GitHub Releases からのダウンロード・SHA256 照合・ライセンス文の配置を確かめる |
| `msix_test.ps1 -VideoFile <動画> -ShotDir <保存先> [-Karaoke] [-SkipSeparation]` | Store 版（`dev\build_msix.ps1 -Register -DevIdentity` で登録した PitaTrack.Dev）を AppExecutionAlias から起動して UI Automation で一周する。A: 設定 → ライセンスの本文、モデルの一覧、「モデルフォルダーを開く」が開くフォルダー。B: 標準モデルを WMI 経由で退避して初回ダウンロード→分離→プレビュー→閉じる、置いた GGUF（と同名 .json）が一覧に出るか、ダウンロードが実フォルダーと LocalCache のどちらに落ちたか。`-SkipSeparation` で A だけ |
| `zip_test.ps1 -GuiScript <tools\mixtrack_ffmpeg_gui.ps1> -VideoFile <動画> -ShotDir <保存先>` | ZIP 版の流れ。`toolsfmpeg.exe` も `toolssroformer` もない状態で GUI を開き、setup.ps1 のダウンロード画面で Release の ffmpeg を取得 → 分離エンジンの初回ダウンロード → 分離 まで通す（出力を作らないよう、動画はコピーを渡す） |
