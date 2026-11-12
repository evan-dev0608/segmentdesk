#include <windows.h>
#include <shlobj.h>
#include <fcntl.h>
#include <io.h>

#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <string>
#include <string_view>

namespace {
namespace fs = std::filesystem;

bool QueueImport(const std::string& payload) {
  PWSTR local = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &local))) {
    return false;
  }
  const auto inbox = fs::path(local) / L"SegmentDesk" / L"browser-inbox";
  CoTaskMemFree(local);
  std::error_code error;
  fs::create_directories(inbox, error);
  if (error) return false;

  wchar_t temp[MAX_PATH];
  if (!GetTempFileNameW(inbox.c_str(), L"imp", 0, temp)) return false;
  FILE* file = nullptr;
  if (_wfopen_s(&file, temp, L"wb") != 0) {
    DeleteFileW(temp);
    return false;
  }
  const bool written = fwrite(payload.data(), 1, payload.size(), file) == payload.size();
  const bool closed = fclose(file) == 0;
  const auto target = fs::path(temp).replace_extension(L".json");
  if (written && closed && MoveFileW(temp, target.c_str())) return true;
  DeleteFileW(temp);
  return false;
}

bool OpenClient() {
  const HWND window = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"SegmentDesk");
  if (window) {
    ShowWindowAsync(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
    SetForegroundWindow(window);
    return true;
  }
  wchar_t path[MAX_PATH];
  const DWORD length = GetModuleFileNameW(nullptr, path, MAX_PATH);
  if (!length || length == MAX_PATH) return false;
  const auto directory = fs::path(path).parent_path();
  const auto executable = directory / L"stream_download.exe";
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  if (!CreateProcessW(executable.c_str(), nullptr, nullptr, nullptr, FALSE, 0,
                      nullptr, directory.c_str(), &startup, &process)) {
    return false;
  }
  WaitForInputIdle(process.hProcess, 5000);
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  return true;
}

void Reply(bool ok) {
  const std::string_view response = ok ? R"({"ok":true})" : R"({"ok":false})";
  const auto size = static_cast<uint32_t>(response.size());
  fwrite(&size, sizeof(size), 1, stdout);
  fwrite(response.data(), 1, response.size(), stdout);
  fflush(stdout);
}
}  // namespace

int wmain(int argc, wchar_t** argv) {
  if (argc < 2 || std::wstring_view(argv[1]) !=
                      L"chrome-extension://iajjbecglndbfohapjpnffdmoahjljeh/") {
    return 1;
  }
  _setmode(_fileno(stdin), _O_BINARY);
  _setmode(_fileno(stdout), _O_BINARY);
  uint32_t size = 0;
  if (fread(&size, sizeof(size), 1, stdin) != 1 || size == 0 || size > 32768) {
    Reply(false);
    return 1;
  }
  std::string payload(size, '\0');
  if (fread(payload.data(), 1, size, stdin) != size) {
    Reply(false);
    return 1;
  }
  const HANDLE mutex = CreateMutexW(nullptr, FALSE, L"Local\\SegmentDeskBrowserImport");
  if (!mutex) {
    Reply(false);
    return 1;
  }
  const DWORD wait = WaitForSingleObject(mutex, 8000);
  bool ok = false;
  if (wait == WAIT_OBJECT_0 || wait == WAIT_ABANDONED) {
    ok = OpenClient() && QueueImport(payload);
    ReleaseMutex(mutex);
  }
  CloseHandle(mutex);
  Reply(ok);
  return ok ? 0 : 1;
}
