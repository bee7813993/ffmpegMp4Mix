// ぴたトラックの起動用 exe（PitaTrack.exe）
// コンソールを出さずに PowerShell の画面を開く小さな exe。
//   ZIP 版: tools\setup.ps1 がインストール時にこの PC の C# コンパイラーで作る（VBScript を使わずに済む）
//   Store 版（MSIX）: dev\build_msix.ps1 でビルドしてパッケージに入れる
// 引数:
//   なし・ファイル指定  : GUI（tools\mixtrack_ffmpeg_gui.ps1）を開く
//   /cli ファイル...    : CLI 版（mixtrack_ffmpeg.bat）を新しいコンソールで開く（Store 版の右クリックから）
//   /uninstall          : アンインストール（tools\setup.ps1 -Uninstall。ZIP 版のみ）
// ZIP 版の setup.ps1 は CodeDom（C# 5）でビルドするので、新しい書き方は使わない。
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

static class PitaTrackLauncher
{
    const uint CREATE_NEW_CONSOLE = 0x00000010;
    const uint CREATE_NO_WINDOW = 0x08000000;
    const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    const int APPMODEL_ERROR_NO_PACKAGE = 15700;
    // ProcThreadAttributeValue(ProcThreadAttributeDesktopAppPolicy, FALSE, TRUE, FALSE)
    static readonly IntPtr PROC_THREAD_ATTRIBUTE_DESKTOP_APP_POLICY = new IntPtr(0x00020012);
    // 起動するプロセスをパッケージの中で動かし（OVERRIDE）、その子（ffmpeg など）も中で動かす（DISABLE_PROCESS_TREE）
    const int DESKTOP_APP_BREAKAWAY_DISABLE_PROCESS_TREE = 0x02;
    const int DESKTOP_APP_BREAKAWAY_OVERRIDE = 0x04;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct STARTUPINFO
    {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX
    {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [DllImport("user32.dll")]
    static extern bool AllowSetForegroundWindow(int processId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern int GetCurrentPackageFullName(ref int packageFullNameLength, StringBuilder packageFullName);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool InitializeProcThreadAttributeList(IntPtr attributeList, int attributeCount, int flags, ref IntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool UpdateProcThreadAttribute(IntPtr attributeList, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previousValue, IntPtr returnSize);

    [DllImport("kernel32.dll")]
    static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool CreateProcess(string applicationName, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes,
        bool inheritHandles, uint creationFlags, IntPtr environment, string currentDirectory, ref STARTUPINFOEX startupInfo, out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    [STAThread]
    static int Main(string[] args)
    {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string tools = Path.Combine(root, "tools");
        if (args.Length > 0 && string.Equals(args[0], "/cli", StringComparison.OrdinalIgnoreCase))
        {
            return StartCli(root, args);
        }

        string script = Path.Combine(tools, "mixtrack_ffmpeg_gui.ps1");
        string options = "";
        int first = 0;
        if (args.Length > 0 && string.Equals(args[0], "/uninstall", StringComparison.OrdinalIgnoreCase))
        {
            script = Path.Combine(tools, "setup.ps1");
            options = " -Uninstall";
            first = 1;
        }

        if (!File.Exists(script))
        {
            ShowError("ぴたトラックに必要なファイルが見つかりません。\r\n\r\n" + script);
            return 1;
        }

        string powershell = Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe");
        StringBuilder line = new StringBuilder(Quote(powershell));
        line.Append(" -NoProfile -STA -ExecutionPolicy Bypass -File ").Append(Quote(script)).Append(options);
        for (int i = first; i < args.Length; i++)
        {
            line.Append(' ').Append(Quote(args[i]));
        }
        return Start(powershell, line, root, CREATE_NO_WINDOW);
    }

    // CLI 版の bat を新しいコンソールで開く
    static int StartCli(string root, string[] args)
    {
        string batch = Path.Combine(root, "mixtrack_ffmpeg.bat");
        if (!File.Exists(batch))
        {
            ShowError("ぴたトラックに必要なファイルが見つかりません。\r\n\r\n" + batch);
            return 1;
        }

        // cmd /c は、全体を囲んだ " を外してから実行する
        string cmd = Path.Combine(Environment.SystemDirectory, "cmd.exe");
        StringBuilder line = new StringBuilder(Quote(cmd));
        line.Append(" /d /c \"\"").Append(batch).Append('"');
        for (int i = 1; i < args.Length; i++)
        {
            line.Append(" \"").Append(args[i]).Append('"');
        }
        line.Append('"');
        return Start(cmd, line, root, CREATE_NEW_CONSOLE);
    }

    static int Start(string application, StringBuilder commandLine, string directory, uint creationFlags)
    {
        bool packaged = IsPackaged();
        // Store 版（パッケージの中）で動いていることを、設定の保存先を決めるために PowerShell へ伝える（子に引き継がれる）
        if (packaged)
        {
            Environment.SetEnvironmentVariable("PITATRACK_PACKAGED", "1");
        }

        STARTUPINFOEX startup = new STARTUPINFOEX();
        startup.StartupInfo.cb = Marshal.SizeOf(packaged ? typeof(STARTUPINFOEX) : typeof(STARTUPINFO));
        IntPtr attributeList = IntPtr.Zero;
        IntPtr policy = IntPtr.Zero;
        try
        {
            // パッケージのアプリが起動した Windows のプログラム（powershell.exe など）は、
            // 指定しないとパッケージの外で動き、設定の書き込みがパッケージ専用の場所に振り替えられない
            if (packaged)
            {
                IntPtr size = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref size);
                attributeList = Marshal.AllocHGlobal(size);
                policy = Marshal.AllocHGlobal(4);
                Marshal.WriteInt32(policy, DESKTOP_APP_BREAKAWAY_OVERRIDE | DESKTOP_APP_BREAKAWAY_DISABLE_PROCESS_TREE);
                if (!InitializeProcThreadAttributeList(attributeList, 1, 0, ref size) ||
                    !UpdateProcThreadAttribute(attributeList, 0, PROC_THREAD_ATTRIBUTE_DESKTOP_APP_POLICY, policy, new IntPtr(4), IntPtr.Zero, IntPtr.Zero))
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                startup.lpAttributeList = attributeList;
                creationFlags |= EXTENDED_STARTUPINFO_PRESENT;
            }

            // 開いた画面が前面に出るようにする
            AllowSetForegroundWindow(-1);
            PROCESS_INFORMATION process;
            if (!CreateProcess(application, commandLine, IntPtr.Zero, IntPtr.Zero, false, creationFlags, IntPtr.Zero, directory, ref startup, out process))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
            return 0;
        }
        catch (Exception ex)
        {
            ShowError("ぴたトラックを開けませんでした。\r\n\r\n" + ex.Message +
                "\r\n\r\nぴたトラックは Windows に入っている PowerShell を使います。S モードの Windows や、" +
                "PowerShell の実行が制限されている PC では使えません。");
            return 1;
        }
        finally
        {
            if (attributeList != IntPtr.Zero)
            {
                DeleteProcThreadAttributeList(attributeList);
                Marshal.FreeHGlobal(attributeList);
            }
            if (policy != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(policy);
            }
        }
    }

    static bool IsPackaged()
    {
        int length = 0;
        return GetCurrentPackageFullName(ref length, null) != APPMODEL_ERROR_NO_PACKAGE;
    }

    static void ShowError(string message)
    {
        MessageBox.Show(message, "ぴたトラック", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }

    // CommandLineToArgvW の規則で引数を囲む
    static string Quote(string value)
    {
        if (value.Length > 0 && value.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0)
        {
            return value;
        }

        StringBuilder result = new StringBuilder("\"");
        int backslashes = 0;
        foreach (char c in value)
        {
            if (c == '\\')
            {
                backslashes++;
                continue;
            }
            result.Append('\\', c == '"' ? backslashes * 2 + 1 : backslashes);
            result.Append(c);
            backslashes = 0;
        }
        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }
}
