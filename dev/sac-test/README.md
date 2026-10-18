# スマート アプリ コントロール（SAC）の試験

Hyper-V の Windows 11 仮想マシンで SAC を「オン」にして、ぴたトラックが動くかを試すための道具です。SAC は Windows を新しくインストールした PC でしか使えないので、仮想マシンに新しく入れて試します。

| ファイル | どこで実行するか | 内容 |
|---|---|---|
| `New-SacTestVM.ps1` | ホスト（管理者の PowerShell） | 仮想マシンを作る（第 2 世代、セキュア ブート、TPM、ISO、ゲスト サービス） |
| `Copy-SacTestKit.ps1` | ホスト（管理者の PowerShell） | 試験スクリプトを仮想マシンの `C:\sactest` にコピーする |
| `Invoke-SacTest.ps1` | 仮想マシンの中（普通の PowerShell） | 試験をして、`C:\sactest\report-*.txt` に結果をまとめる |

## 手順

### 1. 仮想マシンを作る（ホスト）

管理者の PowerShell で、リポジトリのフォルダーから実行します。ISO を省略すると `J:\Git\WindowsISO` の一番新しい .iso を使います。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File dev\sac-test\New-SacTestVM.ps1
```

- 置き場所を J ドライブにするときは `-VMPath J:\Hyper-V` を付けます。
- 仮想マシン接続の画面が開いたら「起動」を押し、"Press any key to boot from CD or DVD" が出たらすぐ何かキーを押します。

### 2. Windows 11 を入れる（仮想マシンの画面）

- プロダクト キーは「持っていません」で進めてかまいません。
- Microsoft アカウントでサインインしておくと、後で Store 版を試すときにそのまま使えます。
- 初期設定が終わったら、Windows Update まで済ませます。
- 「Windows セキュリティ → アプリとブラウザー コントロール → スマート アプリ コントロールの設定」が「評価」になっていることを確かめます。

### 3. 試験スクリプトを入れて、評価モードで 1 回試す

ホストの管理者の PowerShell で実行します。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File dev\sac-test\Copy-SacTestKit.ps1
Checkpoint-VM -Name PitaTrack-SAC -SnapshotName 'SAC評価'
```

仮想マシンの中の PowerShell（管理者でなくてよい）で実行します。ぴたトラックと ffmpeg（約 110MB）をダウンロードするので、数分かかります。途中で画面がいくつか開き、自動で閉じます。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\sactest\Invoke-SacTest.ps1
```

試験するのは、既定では PR #5 のブランチ（`claude/dazzling-chebyshev-451c67`）です。マージしたあとは `-RepoRef main` を付けます。

### 4. SAC をオンにして、もう 1 回試す

1. 仮想マシンの「Windows セキュリティ → アプリとブラウザー コントロール → スマート アプリ コントロールの設定」で「オン」を選びます。
2. 仮想マシンの管理者のコマンドプロンプトで `citool.exe -lp` を実行し、Friendly Name が `VerifiedAndReputableDesktop`、Is Currently Enforced が `true` であることを確かめます。
3. ホストでチェックポイントを作ります: `Checkpoint-VM -Name PitaTrack-SAC -SnapshotName 'SACオン'`
4. 3 と同じコマンドで、仮想マシンの中で試験スクリプトを実行します。

SAC の項目がすでに「オフ」になっていた、または「オン」を選べなかったときは、Microsoft の試験用の手順で強制的にオンにします（[Test your app with Smart App Control](https://learn.microsoft.com/en-us/windows/apps/develop/smart-app-control/test-your-app-with-smart-app-control) の「Configure Smart App Control by using the Registry」）。「SAC評価」のチェックポイントに戻してからやり直してください。

### 5. 結果を渡す

`C:\sactest\report-Eval-*.txt` と `C:\sactest\report-On-*.txt` を、拡張セッションのコピーと貼り付けでホストに移すか、メモ帳で開いて中身を貼ってください。

- 報告書の「イベント ログ」が「読めませんでした」になっていたときは、仮想マシンの**管理者の** PowerShell で次を実行し、できた `logs-*.txt` も渡してください。

  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -File C:\sactest\Invoke-SacTest.ps1 -LogsOnly
  ```

- T1（setup.bat）で SAC の通知が出たら、そのスクリーンショットもあると助かります。

## 試験の内容

| 番号 | 内容 | 分かること |
|---|---|---|
| T1 | ダウンロードした印（MOTW）を付けた setup.bat を開く | ZIP 版のインストールが SAC で止まるか |
| T2 | gyan.dev の ffmpeg.exe（署名なし）を起動する（印あり / 印なし） | ダウンロードした ffmpeg が止められるか（クラウドでの評判しだい） |
| T3 | `-File` で実行した PowerShell の言語モード、Add-Type、WinForms | PowerShell が制限モードにならないか |
| T3b | ぴたトラックの GUI スクリプト（印を外したもの）: 読み込み、自動調整、画面を開く | PowerShell 版のぴたトラックが SAC の下で動くか |
| T4 | ffmpeg で、ぴたトラックと同じ形の MP4 にまとめる | ffmpeg の書き出しまで動くか |

- 試験スクリプト自体は、PowerShell が制限モードになっても最後まで動くよう、.NET を直接呼ばずにコマンドレットだけで書いています。
- ホストで試しに動かすときは、ダウンロードせずに済む `-RepoZipPath`、`-FfmpegExePath`、作業フォルダーの `-Root`、飛ばす試験の `-Skip T1,Window` を使えます。
- 試験用の音声は 90 秒にしています。60 秒では自動調整が例外（Index was outside the bounds of the array）になりました。これは短い音声で起きるぴたトラック側の不具合で、SAC とは関係ありません。

## この試験では分からないこと

Store が署名した版（PitaTrack.exe、右クリックの DLL、同梱の ffmpeg）が SAC を通るかは、この試験では分かりません。自分で署名したパッケージは SAC に信頼されないためです。Partner Center で「非公開」の対象ユーザーとして提出し、認定されたものをこの仮想マシンに Store から入れて確かめます。
