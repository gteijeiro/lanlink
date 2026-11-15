#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"
#include <string>

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  HANDLE instance_mutex = ::CreateMutexW(nullptr, FALSE, L"Local\\LanLink.MainProcess");
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = nullptr;
    for (int attempt = 0; attempt < 60 && !existing; ++attempt) {
      existing = ::FindWindowW(L"LANLINK_RUNNER_WIN32_WINDOW", nullptr);
      if (!existing) ::Sleep(50);
    }
    if (existing) {
      std::string payload;
      for (const auto& argument : GetCommandLineArguments()) { payload += argument + "\n"; }
      if (!payload.empty() && payload.size() < 65536) {
        COPYDATASTRUCT data{};
        data.dwData = 0x4c4c5348;
        data.cbData = static_cast<DWORD>(payload.size() + 1);
        data.lpData = payload.data();
        DWORD_PTR reply = 0;
        ::SendMessageTimeoutW(existing, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG, 3000, &reply);
      }
      ::ShowWindow(existing, SW_RESTORE); ::SetForegroundWindow(existing);
    }
    if (instance_mutex) ::CloseHandle(instance_mutex);
    ::CoUninitialize();
    return existing ? EXIT_SUCCESS : EXIT_FAILURE;
  }
  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"lanlink", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  if (instance_mutex) ::CloseHandle(instance_mutex);
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
