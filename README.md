
# ffmpegMp4Mix - Simple Video and Audio Merging Tool

## Overview
This batch script allows you to easily merge video and audio files while assigning track names to each audio track.  
By using `ffmpeg`, it ensures that track names are correctly displayed in recent media players like MPC-BE.

## Target Audience
- Users familiar with basic Windows operations (e.g., extracting files, changing Explorer settings).
- This guide assumes you have **file extensions displayed** in Windows Explorer.

## System Requirements
- Windows 10 or Windows 11 (recommended).

## Download and Installation

### Download
1. Download the latest version of this script from GitHub release:  
   [GitHub Link](https://github.com/bee7813993/ffmpegMp4Mix/releases)
2. Download `ffmpeg` from the official website:  
   [https://ffmpeg.org/download.html](https://ffmpeg.org/download.html)  
   - Extract the downloaded `ffmpeg` files and locate the `ffmpeg.exe` file.

### Installation
1. Extract the `ffmpegMp4Mix_XXXXXXXX.zip` to a folder of your choice.
2. Copy the `ffmpeg.exe` file into the same folder.
3. Ensure the following files are present:
   ```
   ffmpeg.exe
   mixtrack_ffmpeg.bat
   makesendto.bat
   ...
   ```
4. Double-click `makesendto.bat` in the extracted folder.
   - This will add `mixtrack_ffmpeg` to the Windows **Send To** context menu.

## How to Use

### Steps
1. **Prepare the files to merge**  
   Place the video and audio files in the same folder.  
   Use numbers at the beginning of file names for easier sorting. Example:  
   ```
   01_video.mp4
   02_audio1.m4a
   03_audio2.m4a
   ```

2. **Select the files**  
   Select all video and audio files, right-click, and choose **Send To → mixtrack_ffmpeg**.

3. **Enter Handling of audio tracks in original video files**  
   A command prompt will appear, prompting you to enter 0 or 1:  
   0 :The audio track in the original video file will be the first track in the finished video.  
   1 :The audio track in the original video file will not be used as the first track of the finished video.
   - **Press Enter without input** 0 will be selected.

3. **Enter track names**  
   A command prompt will appear, prompting you to enter track names:  
   - **Press Enter without input** to use default track names.

4. **Verify the output**  
   Once processing is complete, a new file named `original_video_name_mixed.mp4` will be created in the same folder.

### Verification
- Confirm that track names are displayed correctly in the following places:
  - OSD (On-Screen Display) in MPC-BE
  - Audio track selection in the right-click menu
  - Audio language button on the control bar

## Customization

You can customize the behavior of the batch script by editing the following options in `mixtrack_ffmpeg.bat`:

### Use the original video's audio
- By default, you will be asked whether you want the audio in the video to be the first track of the finished video.
- By setting USE_VIDEO_AUDIO, you will always be asked without being asked.
  ```bat
  set USE_VIDEO_AUDIO=1
  ```
- **`0`**: Do not make the video's audio the first track  
- **`1`**: Make the video's audio the first track  

### MPC-BE 1.5 Compatibility Mode
- Prevents duplicate track names in MPC-BE 1.5:
  ```bat
  set MPCBE15_COMPAT_MODE=1
  ```
  - **`0`**: Ensures proper display in MPC-BE 1.6+ and 1.4 or earlier.  
  - **`1`**: Prevents duplicate track names in MPC-BE 1.5.  
  
  > In compatibility mode, track names will not be displayed in MPC-BE 1.4 nor "YUKARI" Version 2017.5.12(This is the latest version as of 2024.)

### Default Track Names
- Change the default track names used when no input is provided:
  ```bat
  set TRACKNAME_1=On Vocal
  set TRACKNAME_2=Off Vocal
  set TRACKNAME_LATER=Track
  ```

## Notes
- File names containing the following characters may cause errors:
  - `*`, `?`, `"`, `<`, `>`, etc.
- File names with parentheses `()` or spaces are supported.

## Conclusion
This tool is ideal for those who have used `L-SMASH Muxer` or similar tools to merge video and audio.  
Compared to GUI tools, this batch script provides a faster and more streamlined workflow. Give it a try!

