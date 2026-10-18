// ぴたトラック Store 版（MSIX）の右クリックメニュー（IExplorerCommand）
//   AppxManifest.xml の com:SurrogateServer から dllhost.exe に読み込まれ、
//   desktop4:FileExplorerContextMenus で、すべてのファイルの右クリックに次の 2 つを出す。
//     「ぴたトラックでまとめる」          → PitaTrack.exe <ファイル...>（GUI 版）
//     「ぴたトラック (CLI版) でまとめる」 → PitaTrack.exe /cli <ファイル...>
//   選んだファイルに動画・音声の拡張子のものがなければ、項目を出さない。
//   渡すのは動画・音声のファイルだけ（どの順番で選んでも、PitaTrack 側で最初の mp4 を動画として扱う）。
//   ファイルの種類の動詞（uap3:Verb）は、ぴたトラックを既定のアプリにしないと右クリックに出ないため、この方式にしている。
#include <windows.h>
#include <shobjidl_core.h>
#include <shlwapi.h>
#include <new>
#include <string>
#include <vector>

// {B77F4B20-9C3F-452F-BB9A-3541E9779F23}
static const CLSID CLSID_PitaTrackGui = { 0xb77f4b20, 0x9c3f, 0x452f, { 0xbb, 0x9a, 0x35, 0x41, 0xe9, 0x77, 0x9f, 0x23 } };
// {84F0A3D3-3D4C-48B3-A617-A7E9D4B974E1}
static const CLSID CLSID_PitaTrackCli = { 0x84f0a3d3, 0x3d4c, 0x48b3, { 0xa6, 0x17, 0xa7, 0xe9, 0xd4, 0xb9, 0x74, 0xe1 } };

static HMODULE g_module = nullptr;
static LONG g_objects = 0;

// GUI 版の「Media files」のファイル選択（mixtrack_ffmpeg_gui.ps1）と同じ拡張子
static const wchar_t* const kMediaExtensions[] = {
    L".mp4", L".m4a", L".aac", L".mp3", L".wav", L".flac", L".ogg"
};

// この DLL と同じフォルダー（パッケージの一番上）にある PitaTrack.exe
static std::wstring LauncherPath()
{
    wchar_t path[MAX_PATH * 4];
    DWORD length = GetModuleFileNameW(g_module, path, ARRAYSIZE(path));
    if (length == 0 || length >= ARRAYSIZE(path))
    {
        return L"";
    }
    PathRemoveFileSpecW(path);
    return std::wstring(path) + L"\\PitaTrack.exe";
}

static bool IsMediaFile(const std::wstring& path)
{
    const wchar_t* extension = PathFindExtensionW(path.c_str());
    for (const wchar_t* candidate : kMediaExtensions)
    {
        if (_wcsicmp(extension, candidate) == 0)
        {
            return true;
        }
    }
    return false;
}

// 選ばれた項目のうち、動画・音声のファイルのパス（フォルダーやファイルシステム外の項目は除く）
static std::vector<std::wstring> GetMediaPaths(IShellItemArray* items)
{
    std::vector<std::wstring> paths;
    DWORD count = 0;
    if (items == nullptr || FAILED(items->GetCount(&count)))
    {
        return paths;
    }
    for (DWORD i = 0; i < count; i++)
    {
        IShellItem* item = nullptr;
        if (FAILED(items->GetItemAt(i, &item)))
        {
            continue;
        }
        SFGAOF attributes = 0;
        PWSTR path = nullptr;
        if (SUCCEEDED(item->GetAttributes(SFGAO_FOLDER, &attributes)) && (attributes & SFGAO_FOLDER) == 0 &&
            SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path)))
        {
            if (IsMediaFile(path))
            {
                paths.push_back(path);
            }
            CoTaskMemFree(path);
        }
        item->Release();
    }
    return paths;
}

class PitaTrackCommand : public IExplorerCommand
{
public:
    explicit PitaTrackCommand(bool cli) : m_refs(1), m_cli(cli)
    {
        InterlockedIncrement(&g_objects);
    }

    // IUnknown
    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override
    {
        if (ppv == nullptr)
        {
            return E_POINTER;
        }
        if (riid == IID_IUnknown || riid == IID_IExplorerCommand)
        {
            *ppv = static_cast<IExplorerCommand*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }

    IFACEMETHODIMP_(ULONG) AddRef() override
    {
        return InterlockedIncrement(&m_refs);
    }

    IFACEMETHODIMP_(ULONG) Release() override
    {
        ULONG count = InterlockedDecrement(&m_refs);
        if (count == 0)
        {
            delete this;
        }
        return count;
    }

    // IExplorerCommand
    IFACEMETHODIMP GetTitle(IShellItemArray*, LPWSTR* name) override
    {
        return SHStrDupW(m_cli ? L"ぴたトラック (CLI版) でまとめる" : L"ぴたトラックでまとめる", name);
    }

    IFACEMETHODIMP GetIcon(IShellItemArray*, LPWSTR* icon) override
    {
        std::wstring resource = LauncherPath() + L",0";
        return SHStrDupW(resource.c_str(), icon);
    }

    IFACEMETHODIMP GetToolTip(IShellItemArray*, LPWSTR* tip) override
    {
        *tip = nullptr;
        return E_NOTIMPL;
    }

    IFACEMETHODIMP GetCanonicalName(GUID* guid) override
    {
        *guid = m_cli ? CLSID_PitaTrackCli : CLSID_PitaTrackGui;
        return S_OK;
    }

    IFACEMETHODIMP GetState(IShellItemArray* items, BOOL, EXPCMDSTATE* state) override
    {
        *state = GetMediaPaths(items).empty() ? ECS_HIDDEN : ECS_ENABLED;
        return S_OK;
    }

    IFACEMETHODIMP Invoke(IShellItemArray* items, IBindCtx*) override
    {
        std::vector<std::wstring> paths = GetMediaPaths(items);
        if (paths.empty())
        {
            return S_OK;
        }

        std::wstring exe = LauncherPath();
        std::wstring commandLine = L"\"" + exe + L"\"";
        if (m_cli)
        {
            commandLine += L" /cli";
        }
        for (const std::wstring& path : paths)
        {
            // ファイルのパスには " を使えないので、囲むだけでよい
            commandLine += L" \"" + path + L"\"";
        }

        std::vector<wchar_t> buffer(commandLine.begin(), commandLine.end());
        buffer.push_back(L'\0');
        STARTUPINFOW startup = { sizeof(startup) };
        PROCESS_INFORMATION process = {};
        AllowSetForegroundWindow(ASFW_ANY);
        if (!CreateProcessW(exe.c_str(), buffer.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &startup, &process))
        {
            return HRESULT_FROM_WIN32(GetLastError());
        }
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        return S_OK;
    }

    IFACEMETHODIMP GetFlags(EXPCMDFLAGS* flags) override
    {
        *flags = ECF_DEFAULT;
        return S_OK;
    }

    IFACEMETHODIMP EnumSubCommands(IEnumExplorerCommand** commands) override
    {
        *commands = nullptr;
        return E_NOTIMPL;
    }

private:
    ~PitaTrackCommand()
    {
        InterlockedDecrement(&g_objects);
    }

    LONG m_refs;
    bool m_cli;
};

class PitaTrackClassFactory : public IClassFactory
{
public:
    explicit PitaTrackClassFactory(bool cli) : m_refs(1), m_cli(cli)
    {
        InterlockedIncrement(&g_objects);
    }

    IFACEMETHODIMP QueryInterface(REFIID riid, void** ppv) override
    {
        if (ppv == nullptr)
        {
            return E_POINTER;
        }
        if (riid == IID_IUnknown || riid == IID_IClassFactory)
        {
            *ppv = static_cast<IClassFactory*>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }

    IFACEMETHODIMP_(ULONG) AddRef() override
    {
        return InterlockedIncrement(&m_refs);
    }

    IFACEMETHODIMP_(ULONG) Release() override
    {
        ULONG count = InterlockedDecrement(&m_refs);
        if (count == 0)
        {
            delete this;
        }
        return count;
    }

    IFACEMETHODIMP CreateInstance(IUnknown* outer, REFIID riid, void** ppv) override
    {
        *ppv = nullptr;
        if (outer != nullptr)
        {
            return CLASS_E_NOAGGREGATION;
        }
        PitaTrackCommand* command = new (std::nothrow) PitaTrackCommand(m_cli);
        if (command == nullptr)
        {
            return E_OUTOFMEMORY;
        }
        HRESULT hr = command->QueryInterface(riid, ppv);
        command->Release();
        return hr;
    }

    IFACEMETHODIMP LockServer(BOOL lock) override
    {
        if (lock)
        {
            InterlockedIncrement(&g_objects);
        }
        else
        {
            InterlockedDecrement(&g_objects);
        }
        return S_OK;
    }

private:
    ~PitaTrackClassFactory()
    {
        InterlockedDecrement(&g_objects);
    }

    LONG m_refs;
    bool m_cli;
};

BOOL APIENTRY DllMain(HMODULE module, DWORD reason, LPVOID)
{
    if (reason == DLL_PROCESS_ATTACH)
    {
        g_module = module;
        DisableThreadLibraryCalls(module);
    }
    return TRUE;
}

STDAPI DllGetClassObject(REFCLSID clsid, REFIID riid, LPVOID* ppv)
{
    if (ppv == nullptr)
    {
        return E_POINTER;
    }
    *ppv = nullptr;
    bool cli;
    if (IsEqualCLSID(clsid, CLSID_PitaTrackGui))
    {
        cli = false;
    }
    else if (IsEqualCLSID(clsid, CLSID_PitaTrackCli))
    {
        cli = true;
    }
    else
    {
        return CLASS_E_CLASSNOTAVAILABLE;
    }

    PitaTrackClassFactory* factory = new (std::nothrow) PitaTrackClassFactory(cli);
    if (factory == nullptr)
    {
        return E_OUTOFMEMORY;
    }
    HRESULT hr = factory->QueryInterface(riid, ppv);
    factory->Release();
    return hr;
}

STDAPI DllCanUnloadNow()
{
    return g_objects == 0 ? S_OK : S_FALSE;
}
