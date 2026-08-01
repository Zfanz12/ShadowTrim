#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <fstream>
#include <shlobj.h>

#include "flutter_window.h"
#include "utils.h"

// Windows Native Unhandled Exception Filter for C/C++ DLL / process crashes
LONG WINAPI NativeCrashHandler(EXCEPTION_POINTERS* ExceptionInfo) {
  wchar_t docPath[MAX_PATH];
  if (SUCCEEDED(SHGetFolderPathW(NULL, CSIDL_MYDOCUMENTS, NULL, 0, docPath))) {
    std::wstring logDir = std::wstring(docPath) + L"\\ShadowTrim\\logs";
    CreateDirectoryW(logDir.c_str(), NULL);
    std::wstring logFile = logDir + L"\\native_crash.log";
    std::ofstream ofs(logFile, std::ios::app);
    if (ofs.is_open()) {
      SYSTEMTIME st;
      GetLocalTime(&st);
      
      DWORD code = ExceptionInfo->ExceptionRecord->ExceptionCode;
      std::string exceptionName = "UNKNOWN_EXCEPTION";
      if (code == 0xc0000005) exceptionName = "STATUS_ACCESS_VIOLATION";
      else if (code == 0xc000001d) exceptionName = "STATUS_ILLEGAL_INSTRUCTION";
      else if (code == 0xc000008e) exceptionName = "STATUS_FLOAT_DIVIDE_BY_ZERO";
      else if (code == 0xc00000fd) exceptionName = "STATUS_STACK_OVERFLOW";
      else if (code == 0xc0000006) exceptionName = "STATUS_IN_PAGE_ERROR";

      // Resolve crashing module name & offset
      std::string moduleName = "Unknown Module";
      uintptr_t offset = 0;
      HMODULE hModule = NULL;
      if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                             (LPCWSTR)ExceptionInfo->ExceptionRecord->ExceptionAddress, &hModule)) {
        char modPath[MAX_PATH];
        if (GetModuleFileNameA(hModule, modPath, MAX_PATH)) {
          moduleName = modPath;
          offset = (uintptr_t)ExceptionInfo->ExceptionRecord->ExceptionAddress - (uintptr_t)hModule;
        }
      }

      // Memory Status
      MEMORYSTATUSEX memStatus;
      memStatus.dwLength = sizeof(memStatus);
      GlobalMemoryStatusEx(&memStatus);

      ofs << "\n================================================================================\n"
          << "[" << st.wYear << "-" << st.wMonth << "-" << st.wDay << " "
          << st.wHour << ":" << st.wMinute << ":" << st.wSecond << "] "
          << "[NATIVE C/C++ CRASH EXCEPTION DETECTED]\n"
          << "Exception Code   : 0x" << std::hex << code << " (" << exceptionName << ")\n"
          << "Exception Address: 0x" << std::hex << (uintptr_t)ExceptionInfo->ExceptionRecord->ExceptionAddress << "\n"
          << "Thread ID        : " << std::dec << GetCurrentThreadId() << "\n"
          << "Module           : " << moduleName << "\n"
          << "Module Offset    : 0x" << std::hex << offset << "\n";

      if (code == 0xc0000005 && ExceptionInfo->ExceptionRecord->NumberParameters >= 2) {
        ULONG_PTR accessType = ExceptionInfo->ExceptionRecord->ExceptionInformation[0];
        ULONG_PTR targetAddr = ExceptionInfo->ExceptionRecord->ExceptionInformation[1];
        std::string op = (accessType == 0) ? "READ" : (accessType == 1) ? "WRITE" : "EXECUTE DEP";
        ofs << "Access Violation : Attempted to " << op << " memory address 0x" << std::hex << targetAddr << "\n";
      }

      ofs << "System RAM       : " << std::dec << (memStatus.ullAvailPhys / (1024 * 1024)) << " MB available out of "
          << (memStatus.ullTotalPhys / (1024 * 1024)) << " MB (Load: " << memStatus.dwMemoryLoad << "%)\n";

#if defined(_M_X64) || defined(__x86_64__)
      if (ExceptionInfo->ContextRecord) {
        PCONTEXT ctx = ExceptionInfo->ContextRecord;
        ofs << "CPU Registers (x64):\n"
            << "  RIP: 0x" << std::hex << ctx->Rip << "  RSP: 0x" << ctx->Rsp << "  RBP: 0x" << ctx->Rbp << "\n"
            << "  RAX: 0x" << ctx->Rax << "  RBX: 0x" << ctx->Rbx << "  RCX: 0x" << ctx->Rcx << "\n"
            << "  RDX: 0x" << ctx->Rdx << "  RSI: 0x" << ctx->Rsi << "  RDI: 0x" << ctx->Rdi << "\n"
            << "  R8 : 0x" << ctx->R8  << "  R9 : 0x" << ctx->R9  << "  R10: 0x" << ctx->R10 << "\n";
      }
#endif
      ofs << "--------------------------------------------------------------------------------\n";
      ofs.close();
    }
  }
  return EXCEPTION_CONTINUE_SEARCH;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Register Windows Native Exception Filter to capture C/C++ level crashes
  ::SetUnhandledExceptionFilter(NativeCrashHandler);

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Center the window on screen with a bigger default size
  int windowWidth = 1280;
  int windowHeight = 960;
  int screenWidth = ::GetSystemMetrics(SM_CXSCREEN);
  int screenHeight = ::GetSystemMetrics(SM_CYSCREEN);
  Win32Window::Point origin((screenWidth - windowWidth) / 2, (screenHeight - windowHeight) / 2);
  Win32Window::Size size(windowWidth, windowHeight);
  if (!window.Create(L"ShadowTrim", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
