rem mixonoff <Video track> <OnVocal_audio> <offVocal_Audio>
@echo off
rem chcp 932 for Shift-JIS
chcp 932
setlocal EnableExtensions DisableDelayedExpansion
set "SCRIPT_DIR=%~dp0"

rem トラック名初期値
rem TRACKNAME_3、TRACKNAME_4 ... を追加すると、その番号の初期値になります。
set "TRACKNAME_1=オンボーカル"
set "TRACKNAME_2=オフボーカル"
set "TRACKNAME_LATER=トラック"

rem 出力ファイル名の接尾語
if "%OUTPUT_SUFFIX%"=="" set "OUTPUT_SUFFIX=_mixed"

rem フラグ：元の動画の音声を使用する場合は1、使用しない場合は0
set USE_VIDEO_AUDIO=

rem フラグ：MPC-BE 1.5 互換モード
set MPCBE15_COMPAT_MODE=0

rem 入力ファイル一覧から最初の mp4 を動画として使用
set "VIDEOFILE="
set "VIDEODIR="
set "VIDEONAME="
set /A AUDIO_COUNT=0

:parse_args
if "%~1"=="" goto parse_args_done
if "%VIDEOFILE%"=="" goto parse_video_arg_check
goto parse_audio_arg

:parse_video_arg_check
if /I "%~x1"==".mp4" goto parse_video_arg
goto parse_audio_arg

:parse_video_arg
set "VIDEOFILE=%~1"
set "VIDEODIR=%~dp1"
set "VIDEONAME=%~n1"
shift
goto parse_args

:parse_audio_arg
set /A AUDIO_COUNT+=1
set "AUDIOFILE_%AUDIO_COUNT%=%~1"
shift
goto parse_args

:parse_args_done
rem 入力引数の確認
if "%VIDEOFILE%"=="" goto USAGE

if "%USE_VIDEO_AUDIO%"=="" goto use_video_audio_prompt
goto use_video_audio_done

:use_video_audio_prompt
set /P "USE_VIDEO_AUDIO=元動画の音声を１トラック目に使用しますか？ 【0:使用しない 1:使用する [省略:0]】"

:use_video_audio_done
if "%USE_VIDEO_AUDIO%"=="" set "USE_VIDEO_AUDIO=0"

set "PUSHD_DONE=0"

pushd "%VIDEODIR%" || goto end
set "PUSHD_DONE=1"
set "ffmpeg=%SCRIPT_DIR%tools\ffmpeg.exe"
if exist "%ffmpeg%" goto ffmpeg_found
set "ffmpeg=%SCRIPT_DIR%ffmpeg.exe"
if exist "%ffmpeg%" goto ffmpeg_found
echo ffmpeg.exe が見つかりません。
echo "%SCRIPT_DIR%tools\ffmpeg.exe"
echo "%SCRIPT_DIR%ffmpeg.exe"
goto end

:ffmpeg_found
set "filename=%VIDEONAME%%OUTPUT_SUFFIX%.mp4"

set /A COUNTER=0
set /A ACOUNTER=1
set /A AUDIO_INDEX=1
set CMDOPTION1= -i "%VIDEOFILE%"
set CMDOPTION2= -map 0:v

if "%USE_VIDEO_AUDIO%"=="1" call :add_video_audio

:loop
if %AUDIO_INDEX% GTR %AUDIO_COUNT% goto normalend
call set "TRACKFILE=%%AUDIOFILE_%AUDIO_INDEX%%%"
if "%TRACKFILE%"=="" goto normalend
call :add_audio_track
set /A AUDIO_INDEX+=1
goto loop

:normalend
rem 実行コマンドを出力
echo "%ffmpeg%"%CMDOPTION1% -c:v copy -c:a copy%CMDOPTION2% "%filename%"
"%ffmpeg%"%CMDOPTION1% -c:v copy -c:a copy%CMDOPTION2% "%filename%"
goto end

:add_video_audio
rem 動画内音声を最初のトラックに設定
set "TRACKFILE=%VIDEOFILE%"
echo ===== ファイル名："%TRACKFILE%" =====
set /A TRACK_INDEX=COUNTER+1
call :read_track_name

if "%MPCBE15_COMPAT_MODE%"=="1" goto add_video_audio_compat
set CMDOPTION2=%CMDOPTION2% -map 0:a:0 -metadata:s:a:%COUNTER% title="%TRACKNAME%" -metadata:s:a:%COUNTER% handler_name="%TRACKNAME%"
goto add_video_audio_done

:add_video_audio_compat
set CMDOPTION2=%CMDOPTION2% -map 0:a:0 -metadata:s:a:%COUNTER% title="%TRACKNAME%" -metadata:s:a:%COUNTER% handler_name="%TRACK_INDEX%"

:add_video_audio_done
set /A COUNTER+=1
exit /b

:add_audio_track
echo ===== ファイル名："%TRACKFILE%" =====
set /A TRACK_INDEX=COUNTER+1
call :read_track_name
set CMDOPTION1=%CMDOPTION1% -i "%TRACKFILE%"

if "%MPCBE15_COMPAT_MODE%"=="1" goto add_audio_track_compat
set CMDOPTION2=%CMDOPTION2% -map %ACOUNTER%:a -metadata:s:a:%COUNTER% title="%TRACKNAME%" -metadata:s:a:%COUNTER% handler_name="%TRACKNAME%"
goto add_audio_track_done

:add_audio_track_compat
set CMDOPTION2=%CMDOPTION2% -map %ACOUNTER%:a -metadata:s:a:%COUNTER% title="%TRACKNAME%" -metadata:s:a:%COUNTER% handler_name="%TRACK_INDEX%"

:add_audio_track_done
set /A ACOUNTER+=1
set /A COUNTER+=1
exit /b

:read_track_name
call :get_track_name_default
if "%TRACKNAME_DEFAULT%"=="" set "TRACKNAME_DEFAULT=%TRACKNAME_LATER%"

set "TRACKNAME_WORK="
set /P "TRACKNAME_WORK= トラック名を入力 略 %TRACKNAME_DEFAULT%："
if "%TRACKNAME_WORK%"=="" set "TRACKNAME_WORK=%TRACKNAME_DEFAULT%"
set "TRACKNAME=%TRACKNAME_WORK%"
exit /b

:get_track_name_default
set "TRACKNAME_DEFAULT="
call set "TRACKNAME_DEFAULT=%%TRACKNAME_%TRACK_INDEX%%%"
if "%TRACKNAME_DEFAULT%"=="" goto get_track_name_default_fallback
exit /b

:get_track_name_default_fallback
if "%TRACK_INDEX%"=="1" goto get_track_name_default_1
if "%TRACK_INDEX%"=="2" goto get_track_name_default_2
exit /b

:get_track_name_default_1
set "TRACKNAME_DEFAULT=%TRACKNAME_1%"
if "%TRACKNAME_DEFAULT%"=="" set "TRACKNAME_DEFAULT=オンボーカル"
exit /b

:get_track_name_default_2
set "TRACKNAME_DEFAULT=%TRACKNAME_2%"
if "%TRACKNAME_DEFAULT%"=="" set "TRACKNAME_DEFAULT=オフボーカル"
exit /b

:end
if "%PUSHD_DONE%"=="1" popd
pause
endlocal
exit /b

:USAGE
echo .mp4 の動画ファイルが見つかりません。
echo "<Video track> <1st_audio> <2nd_Audio> ..."
pause
endlocal
exit /b
