#include "shadowtrim_core.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <string>
#include <vector>
#include <sstream>
#include <iostream>

namespace {

// Helper to convert UTF-8 string to std::wstring (UTF-16) for Windows Unicode APIs
std::wstring Utf8ToWide(const char* utf8_str) {
    if (!utf8_str || utf8_str[0] == '\0') {
        return L"";
    }
    int len = MultiByteToWideChar(CP_UTF8, 0, utf8_str, -1, NULL, 0);
    if (len <= 0) {
        return L"";
    }
    std::wstring wide(len, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8_str, -1, &wide[0], len);
    // Remove the null terminator from string size if included
    if (!wide.empty() && wide.back() == L'\0') {
        wide.pop_back();
    }
    return wide;
}

// Helper to convert wide string to UTF-8
std::string WideToUtf8(const wchar_t* wide_str) {
    if (!wide_str || wide_str[0] == L'\0') {
        return "";
    }
    int len = WideCharToMultiByte(CP_UTF8, 0, wide_str, -1, NULL, 0, NULL, NULL);
    if (len <= 0) {
        return "";
    }
    std::string utf8(len, '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide_str, -1, &utf8[0], len, NULL, NULL);
    if (!utf8.empty() && utf8.back() == '\0') {
        utf8.pop_back();
    }
    return utf8;
}

} // namespace

extern "C" {

SHADOWTRIM_API int32_t shadowtrim_init(void) {
    // Perform any native initialization if needed
    return 1;
}

SHADOWTRIM_API int32_t shadowtrim_get_version(void) {
    return 100; // 1.0.0
}

SHADOWTRIM_API int32_t shadowtrim_restore_timestamps(const char* src_path_utf8, const char* dst_path_utf8) {
    if (!src_path_utf8 || !dst_path_utf8) {
        return 0;
    }

    std::wstring src_wide = Utf8ToWide(src_path_utf8);
    std::wstring dst_wide = Utf8ToWide(dst_path_utf8);

    if (src_wide.empty() || dst_wide.empty()) {
        return 0;
    }

    // Open source file to read timestamps
    HANDLE hSrc = CreateFileW(
        src_wide.c_str(),
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL
    );

    if (hSrc == INVALID_HANDLE_VALUE) {
        return 0;
    }

    FILETIME creationTime = {0};
    FILETIME lastAccessTime = {0};
    FILETIME lastWriteTime = {0};

    BOOL readSuccess = GetFileTime(hSrc, &creationTime, &lastAccessTime, &lastWriteTime);
    CloseHandle(hSrc);

    if (!readSuccess) {
        return 0;
    }

    // Open target file to set timestamps
    HANDLE hDst = CreateFileW(
        dst_wide.c_str(),
        GENERIC_READ | GENERIC_WRITE | FILE_WRITE_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL,
        NULL
    );

    if (hDst == INVALID_HANDLE_VALUE) {
        return 0;
    }

    BOOL writeSuccess = SetFileTime(hDst, &creationTime, &lastAccessTime, &lastWriteTime);
    CloseHandle(hDst);

    return writeSuccess ? 1 : 0;
}

SHADOWTRIM_API int32_t shadowtrim_execute_process(
    const char* executable_utf8,
    const char* arguments_utf8,
    char* out_buffer,
    int32_t out_buffer_size,
    int32_t* exit_code
) {
    if (!executable_utf8 || !arguments_utf8) {
        if (exit_code) *exit_code = -1;
        return 0;
    }

    std::wstring exe_wide = Utf8ToWide(executable_utf8);
    std::wstring args_wide = Utf8ToWide(arguments_utf8);

    // Prepare command line: "<exe>" <args>
    std::wstring cmdLine = L"\"" + exe_wide + L"\" " + args_wide;

    SECURITY_ATTRIBUTES sa;
    sa.nLength = sizeof(SECURITY_ATTRIBUTES);
    sa.bInheritHandle = TRUE;
    sa.lpSecurityDescriptor = NULL;

    HANDLE hReadPipe = NULL;
    HANDLE hWritePipe = NULL;

    // Create a pipe for child process stdout & stderr
    if (!CreatePipe(&hReadPipe, &hWritePipe, &sa, 0)) {
        if (exit_code) *exit_code = -2;
        return 0;
    }

    // Ensure read handle is not inherited
    SetHandleInformation(hReadPipe, HANDLE_FLAG_INHERIT, 0);

    STARTUPINFOW si;
    ZeroMemory(&si, sizeof(STARTUPINFOW));
    si.cb = sizeof(STARTUPINFOW);
    si.hStdError = hWritePipe;
    si.hStdOutput = hWritePipe;
    si.dwFlags |= STARTF_USESTDHANDLES;

    PROCESS_INFORMATION pi;
    ZeroMemory(&pi, sizeof(PROCESS_INFORMATION));

    // Vector to pass mutable command line buffer to CreateProcessW
    std::vector<wchar_t> cmdLineBuffer(cmdLine.begin(), cmdLine.end());
    cmdLineBuffer.push_back(L'\0');

    // Create child process with HIGH_PRIORITY_CLASS and CREATE_NO_WINDOW
    BOOL success = CreateProcessW(
        NULL,
        cmdLineBuffer.data(),
        NULL,
        NULL,
        TRUE,
        CREATE_NO_WINDOW | HIGH_PRIORITY_CLASS,
        NULL,
        NULL,
        &si,
        &pi
    );

    // Close write end in parent process so read can hit EOF
    CloseHandle(hWritePipe);

    if (!success) {
        CloseHandle(hReadPipe);
        if (exit_code) *exit_code = -3;
        return 0;
    }

    // Read pipe output
    std::string capturedOutput;
    DWORD bytesRead = 0;
    char buffer[4096];

    while (ReadFile(hReadPipe, buffer, sizeof(buffer) - 1, &bytesRead, NULL) && bytesRead > 0) {
        capturedOutput.append(buffer, bytesRead);
    }

    CloseHandle(hReadPipe);

    // Wait for process to exit
    WaitForSingleObject(pi.hProcess, INFINITE);

    DWORD procExitCode = 0;
    GetExitCodeProcess(pi.hProcess, &procExitCode);

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);

    if (exit_code) {
        *exit_code = static_cast<int32_t>(procExitCode);
    }

    // Copy captured output to user buffer if provided
    if (out_buffer && out_buffer_size > 0) {
        size_t copyLen = (capturedOutput.size() < static_cast<size_t>(out_buffer_size - 1))
            ? capturedOutput.size()
            : static_cast<size_t>(out_buffer_size - 1);
        memcpy(out_buffer, capturedOutput.data(), copyLen);
        out_buffer[copyLen] = '\0';
    }

    return 1;
}

SHADOWTRIM_API int32_t shadowtrim_fast_trim(
    const char* ffmpeg_path_utf8,
    const char* input_path_utf8,
    const char* output_path_utf8,
    const char* start_time_utf8,
    const char* end_time_utf8,
    char* err_buffer,
    int32_t err_buffer_size
) {
    if (!ffmpeg_path_utf8 || !input_path_utf8 || !output_path_utf8 || !start_time_utf8 || !end_time_utf8) {
        return -1;
    }

    // Format arguments: -y -i "<input>" -ss <start> -to <end> -c copy -map 0 "<output>"
    std::ostringstream oss;
    oss << "-y -i \"" << input_path_utf8 << "\" "
        << "-ss " << start_time_utf8 << " "
        << "-to " << end_time_utf8 << " "
        << "-c copy -map 0 \"" << output_path_utf8 << "\"";

    std::string args = oss.str();
    int32_t exitCode = 0;

    int32_t launched = shadowtrim_execute_process(
        ffmpeg_path_utf8,
        args.c_str(),
        err_buffer,
        err_buffer_size,
        &exitCode
    );

    if (!launched || exitCode != 0) {
        return exitCode != 0 ? exitCode : -1;
    }

    // Instantly preserve metadata timestamp using Win32 API
    shadowtrim_restore_timestamps(input_path_utf8, output_path_utf8);

    return 0;
}

SHADOWTRIM_API int32_t shadowtrim_recycle_file(const char* file_path_utf8) {
    if (!file_path_utf8 || file_path_utf8[0] == '\0') {
        return 0;
    }

    std::wstring pathWide = Utf8ToWide(file_path_utf8);
    if (pathWide.empty()) {
        return 0;
    }

    // Normalize forward slashes to backslashes (required by Windows Shell)
    for (size_t i = 0; i < pathWide.length(); ++i) {
        if (pathWide[i] == L'/') {
            pathWide[i] = L'\\';
        }
    }

    // Resolve full absolute path
    wchar_t fullPath[MAX_PATH * 2] = {0};
    DWORD len = GetFullPathNameW(pathWide.c_str(), MAX_PATH * 2, fullPath, NULL);
    if (len == 0) {
        wcsncpy_s(fullPath, MAX_PATH * 2, pathWide.c_str(), pathWide.length());
        len = static_cast<DWORD>(pathWide.length());
    }

    // SHFileOperationW requires double-null-terminated string (path\0\0)
    std::vector<wchar_t> doubleNullBuffer(len + 2, L'\0');
    memcpy(doubleNullBuffer.data(), fullPath, len * sizeof(wchar_t));
    doubleNullBuffer[len] = L'\0';
    doubleNullBuffer[len + 1] = L'\0';

    SHFILEOPSTRUCTW fileOp = {0};
    fileOp.wFunc = FO_DELETE;
    fileOp.pFrom = doubleNullBuffer.data();
    fileOp.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_NOERRORUI | FOF_SILENT;

    int result = SHFileOperationW(&fileOp);
    if (result == 0 && !fileOp.fAnyOperationsAborted) {
        return 1;
    }

    // Fallback: DeleteFileW if recycle bin is unavailable on the drive
    if (DeleteFileW(fullPath)) {
        return 1;
    }

    return 0;
}

} // extern "C"

#else

// Non-Windows fallback stub
extern "C" {
SHADOWTRIM_API int32_t shadowtrim_init(void) { return 1; }
SHADOWTRIM_API int32_t shadowtrim_get_version(void) { return 100; }
SHADOWTRIM_API int32_t shadowtrim_restore_timestamps(const char* src_path_utf8, const char* dst_path_utf8) { return 0; }
SHADOWTRIM_API int32_t shadowtrim_execute_process(const char* executable_utf8, const char* arguments_utf8, char* out_buffer, int32_t out_buffer_size, int32_t* exit_code) { return 0; }
SHADOWTRIM_API int32_t shadowtrim_fast_trim(const char* ffmpeg_path_utf8, const char* input_path_utf8, const char* output_path_utf8, const char* start_time_utf8, const char* end_time_utf8, char* err_buffer, int32_t err_buffer_size) { return -1; }
SHADOWTRIM_API int32_t shadowtrim_recycle_file(const char* file_path_utf8) { return 0; }
}

#endif
