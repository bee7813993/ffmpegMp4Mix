rem mixonoff <Video track> <OnVocal_audio> <offVocal_Audio> 
@echo off
rem chcp 932 for SJIS
chcp 65001

rem トラック名初期値
set TRACKNAME_1=オンボーカル
set TRACKNAME_2=オフボーカル
set TRACKNAME_LATER=トラック

rem フラグ：元の動画の音声を使用する場合は1、使用しない場合は0
set USE_VIDEO_AUDIO=

rem フラグ：MPC-BE 1.5 互換モード
set MPCBE15_COMPAT_MODE=0

rem 最初の引数を一旦変数に格納 (クオートで囲む)
set "VIDEOFILE=%~1"

rem 入力引数の確認をクオートで囲んだ変数に基づいて実施
if "%VIDEOFILE%"=="" goto USAGE

if "%USE_VIDEO_AUDIO%"=="" (
    SET /P USE_VIDEO_AUDIO=元動画の音声を１トラック目に使用しますか？ 【0:使用しない 1:使用する [省略:0]】
)
if "%USE_VIDEO_AUDIO%"=="" (
    SET USE_VIDEO_AUDIO=0
)

pushd "%~dp1"
set ffmpeg="%~dp0\ffmpeg.exe"
set filename=%~n1_mixed.mp4

set COUNTER=0
set CMDOPTION1=
set CMDOPTION2=

if "%~x1" == ".mp4" (
    rem %VIDEOFILE% にそのままファイルパスを格納 (既にクオート済み)
) else (
    GOTO end
)

rem 展開時にクオートを追加
setlocal disabledelayedexpansion
set CMDOPTION1= -i "%VIDEOFILE%"
set /a ACOUNTER=COUNTER
setlocal enabledelayedexpansion

rem 動画音声を使用する場合の処理
if "%USE_VIDEO_AUDIO%"=="1" (
    rem 動画内音声を最初のトラックに設定
    set "TRACKFILE=%VIDEOFILE%"
    echo ===== ファイル名：!TRACKFILE! =====
    SET /P TRACKNAME_WORK= トラック名を入力 略 %TRACKNAME_1%：
    IF "!TRACKNAME_WORK!" EQU "" (
        SET TRACKNAME_WORK=%TRACKNAME_1%
    )
    SET TRACKNAME=!TRACKNAME_WORK!
    rem フラグに基づいて CMDOPTION2 を設定
    if "%MPCBE15_COMPAT_MODE%"=="1" (
        set CMDOPTION2= -map 0:v -map 0:a:0 -metadata:s:a:0 title="!TRACKNAME!" -metadata:s:a:0 handler_name="1"
    ) else (
        set CMDOPTION2= -map 0:v -map 0:a:0 -metadata:s:a:0 title="!TRACKNAME!" -metadata:s:a:0 handler_name="!TRACKNAME!"
    )
    SET /A ACOUNTER=%COUNTER%+1
    SET /A COUNTER+=1
) else (
    rem 動画内音声をスキップ (映像のみ使用)
    set CMDOPTION2= -map 0:v
    SET /A ACOUNTER=%COUNTER%+1
)

:loop
setlocal disabledelayedexpansion
rem トラックファイルのパスを処理
set "TRACKFILE=%~2"
if "%TRACKFILE%"=="" goto nomalend
shift

setlocal enabledelayedexpansion

echo ===== ファイル名：!TRACKFILE! =====

rem トラック名入力処理
if %COUNTER% EQU 0 (
    SET TRACKNAME_WORK=
    SET /P TRACKNAME_WORK= トラック名を入力 略 %TRACKNAME_1%：
    IF "!TRACKNAME_WORK!" EQU "" (
        SET TRACKNAME_WORK=%TRACKNAME_1%
    )
    SET TRACKNAME=!TRACKNAME_WORK!
) else if %COUNTER% EQU 1 (
    SET TRACKNAME_WORK=
    SET /P TRACKNAME_WORK= トラック名を入力 略 %TRACKNAME_2%：
    IF "!TRACKNAME_WORK!" EQU "" (
        SET TRACKNAME_WORK=%TRACKNAME_2%
    )
    SET TRACKNAME=!TRACKNAME_WORK!
) else (
    SET TRACKNAME_WORK=
    SET /P TRACKNAME_WORK= トラック名を入力 略 %TRACKNAME_LATER%：
    IF "!TRACKNAME_WORK!" EQU "" (
        SET TRACKNAME_WORK=%TRACKNAME_LATER%
    )
    SET TRACKNAME=!TRACKNAME_WORK!
)

:setval
rem トラック番号を計算（COUNTERに+1して1ベースに）
set /A TRACK_INDEX=COUNTER+1

rem フラグに基づいて CMDOPTION2 を設定
if "%MPCBE15_COMPAT_MODE%"=="1" (
    set CMDOPTION2=%CMDOPTION2% -map %ACOUNTER%:a -metadata:s:a:%COUNTER% title="!TRACKNAME!" -metadata:s:a:%COUNTER% handler_name="%TRACK_INDEX%"
) else (
    set CMDOPTION2=%CMDOPTION2% -map %ACOUNTER%:a -metadata:s:a:%COUNTER% title="!TRACKNAME!" -metadata:s:a:%COUNTER% handler_name="!TRACKNAME!"
)

setlocal disabledelayedexpansion
rem 次の音声トラックを追加
set CMDOPTION1=%CMDOPTION1% -i "%TRACKFILE%"
SET /A ACOUNTER+=1
SET /A COUNTER+=1

goto loop

:nomalend
setlocal disabledelayedexpansion
rem 実行コマンドを出力
echo %ffmpeg% %CMDOPTION1% -c:v copy -c:a copy %CMDOPTION2% "%filename%"
%ffmpeg% %CMDOPTION1% -c:v copy -c:a copy %CMDOPTION2% "%filename%"

:end
popd
pause
exit /b

:USAGE
echo 選択したファイルが1つ以下しかありません。
echo "%~2  <Video track> <1st_audio> <2nd_Audio> ..."
pause
endlocal
exit /b
