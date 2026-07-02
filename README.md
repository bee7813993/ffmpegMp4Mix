# ffmpegMp4Mix

ffmpegMp4Mix is a Windows tool for combining one video file and multiple audio files into a single MP4 while assigning names to each audio track.

It uses `ffmpeg` to create MP4 files whose audio track names are easier to identify in players such as MPC-BE.

## Features

- Launch from Windows **Send To** or by dragging files onto the entry files
- Uses the first `.mp4` file found as the video, even when it is not first in the received order
- Configure default track names
- Optionally use the source video's audio as the first track
- Configure the output file suffix
- CLI batch workflow is also available

GUI only:

- GUI workflow for selecting a video and audio tracks
- View and edit track names, and choose from candidates
- Add, delete, and reorder tracks

Features under `GUI only` are available only in the GUI. The CLI uses file order and interactive prompts instead.

## Which file should I use?

| Purpose | File |
|---|---|
| Check and adjust tracks in a window | `mixtrack_ffmpeg_gui` |
| Finish quickly with fewer steps | `mixtrack_ffmpeg` |

If file extensions are hidden in Explorer, `.bat` and `.vbs` are not shown.
When dragging files directly, drop them onto `mixtrack_ffmpeg_gui` or `mixtrack_ffmpeg` in the root folder.

## Screenshots

### GUI

![GUI example](docs/images/gui-main.png)

### CLI

![CLI example](docs/images/cli-example.png)

## Folder Layout

The root folder contains the drag-and-drop entry files. Internal files are kept in `tools`.

```text
ffmpegMp4Mix\
  mixtrack_ffmpeg.bat        CLI entry file
  mixtrack_ffmpeg_gui.vbs    GUI entry file
  README_ja.md
  README.md
  tools\
    ffmpeg.exe
    ffprobe.exe
    ffplay.exe
    mixtrack_ffmpeg_gui.ps1
    mixtrack_ffmpeg_gui.settings.json
    makesendto.bat
    removesendto.bat
```

`ffplay.exe` and `ffprobe.exe` are not required, but it is fine to keep them with `ffmpeg.exe`.

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.x
- `ffmpeg.exe`

## Installation

1. Download `ffmpegMp4Mix_XXXXXXXX.zip` from GitHub Releases.
   [GitHub Releases](https://github.com/bee7813993/ffmpegMp4Mix/releases)

2. Extract the ZIP file to any folder.

3. Download `ffmpeg` for Windows.
   [ffmpeg.org](https://ffmpeg.org/download.html)

4. Copy `ffmpeg.exe` into the `tools` folder.

5. To use Windows **Send To**, run `tools\makesendto`.

After registration, select files in Explorer and choose **Right click → Send To → mixtrack_ffmpeg_gui** or **mixtrack_ffmpeg**.

To remove the Send To shortcuts, run `tools\removesendto`.

## GUI Usage

The GUI lets you check track names and order before running `ffmpeg`.

### Prepare Files

Place the video file and audio files you want to combine in the same folder.

File order matters. Adding numbers to the beginning of file names makes them easier to sort in Explorer and easier to pass in the intended order.

Example:

```text
01_video.mp4
02_audio1.m4a
03_audio2.m4a
```

### Launch from Send To

1. Select the video and audio files.
2. Choose **Right click → Send To → mixtrack_ffmpeg_gui**.
3. The track list is shown.
4. Edit track names, order, and output path as needed.
5. Press **OK** to run `ffmpeg`.

When launched from Send To, the received file order is used as the initial track order. In the GUI, you can reorder tracks before running.

### Launch by itself

Double-click `mixtrack_ffmpeg_gui` to open the GUI without input files.

- Use **Browse...** in the video field to select the video file.
- Use **+ Add** to add audio files.
- Drag and drop audio or video files onto the track list.
- Drag and drop a video file onto the video field to replace it.

If the video field is empty and multiple files are dropped onto the track list, the first `.mp4` file is assigned to the video field and the remaining files are added as audio tracks.

### Edit Track Names

- Type directly into a track name cell.
- Click a track name cell to open registered track name candidates.
- With the keyboard, press `Alt + Up`, `Alt + Down`, or `F4` on a track name cell to open candidates.
- Names not in the candidate list can still be typed directly.

### Reorder Tracks

- Drag and drop rows to reorder tracks.
- Use **↑ Up** / **↓ Down** to move tracks.
- Drag and drop an `.mp4` track row onto the video field to swap it with the main video.

### Keyboard Workflow

The GUI is arranged so you can proceed with `Tab`, text input, and `Enter` after launch.

## CLI Usage

The CLI is useful when you want to finish quickly with fewer operations and do not need to adjust tracks in a window.

### Prepare Files

Place the video file and audio files you want to combine in the same folder.

File order is especially important in the CLI because there is no screen for reordering tracks before execution.
Adding numbers to the beginning of file names makes them easier to sort in Explorer and easier to pass to `mixtrack_ffmpeg` in the intended order.

Example:

```text
01_video.mp4
02_audio1.m4a
03_audio2.m4a
```

### Launch

- Select files and choose **Send To → mixtrack_ffmpeg**
- Drag and drop files onto `mixtrack_ffmpeg`

The first `.mp4` file found is used as the video.
All other files are added as audio tracks.

File order matters. Audio tracks are added in the order passed to `mixtrack_ffmpeg`.

### Prompts

1. Choose whether to use the source video's audio as the first track.

   ```text
   0: Do not use it
   1: Use it
   Enter only: 0
   ```

2. Enter each audio track name.

   Press `Enter` without input to use the default track name.

3. When complete, `source_video_name_mixed.mp4` is created in the same folder as the video.

## Settings

### GUI Settings

Use the GUI **Settings** button to change:

- Default track names by track number
- Track name candidates
- Default name for later tracks
- Output file suffix

GUI settings are saved to `tools\mixtrack_ffmpeg_gui.settings.json`.

On first launch, the GUI reads `TRACKNAME_1`, `TRACKNAME_2`, `TRACKNAME_3` ..., `TRACKNAME_LATER`, and `OUTPUT_SUFFIX` from `mixtrack_ffmpeg.bat` as defaults.

### CLI Settings

Edit `mixtrack_ffmpeg.bat` to change CLI defaults.

#### Use the Source Video's Audio

Set `USE_VIDEO_AUDIO` if you want to skip the prompt.

```bat
set USE_VIDEO_AUDIO=1
```

Values:

- `0`: Do not use the source video's audio as the first track
- `1`: Use the source video's audio as the first track
- Empty: Ask at runtime

#### Default Track Names

```bat
set "TRACKNAME_1=On Vocal"
set "TRACKNAME_2=Off Vocal"
set "TRACKNAME_3=Singer 1 Solo"
set "TRACKNAME_4=Singer 2 Solo"
set "TRACKNAME_LATER=Track"
```

- Add `TRACKNAME_3`, `TRACKNAME_4`, and so on to define defaults for those track numbers.
- Tracks without a numbered default use `TRACKNAME_LATER`.

#### Output File Suffix

```bat
set "OUTPUT_SUFFIX=_mixed"
```

For example, `_with_audio` creates `source_video_name_with_audio.mp4`.

If the `OUTPUT_SUFFIX` environment variable is already set, that value is used first.

#### MPC-BE 1.5 Compatibility Mode

Use this if track names are displayed twice in MPC-BE 1.5.

```bat
set MPCBE15_COMPAT_MODE=1
```

- `0`: Normal mode
- `1`: Compatibility mode for MPC-BE 1.5

In compatibility mode, track names may not be displayed in MPC-BE 1.4 or some other players.

## Verifying the Output

Check the following in MPC-BE or another player:

- OSD during playback
- Audio track selection in the right-click menu
- Audio language button on the control bar

## Troubleshooting

### ffmpeg.exe Was Not Found

Make sure `tools\ffmpeg.exe` exists.
The CLI first checks `tools\ffmpeg.exe`, then checks `ffmpeg.exe` in the root folder.

### No .mp4 Video File Was Found

Make sure the selected files include a `.mp4` file.
The first `.mp4` file found is used as the video.

### Send To Points to an Old Folder

If you moved the ffmpegMp4Mix folder, run `tools\removesendto` to delete the old shortcuts, then run `tools\makesendto` again.

### CLI Text Looks Garbled

`mixtrack_ffmpeg.bat` uses Shift-JIS / `chcp 932` for better stability in Windows Command Prompt.
Text may look garbled in PowerShell or some terminal apps, but it is intended to be readable in the normal Command Prompt.

### Track Names Are Not Shown in the Player

Display behavior depends on the player.
If names are duplicated in MPC-BE 1.5, try `MPCBE15_COMPAT_MODE=1`.

## Notes

- The output format is MP4.
- Video and audio streams are normally copied without re-encoding.
- File names containing characters that are awkward on Windows, such as `*`, `?`, `"`, `<`, or `>`, may not work correctly.
- File names containing parentheses `()` or spaces are supported.

## Background

This tool is intended for users who previously used tools such as `L-SMASH Muxer` to combine video and audio, and want a simple way to create MP4 files with named audio tracks.
