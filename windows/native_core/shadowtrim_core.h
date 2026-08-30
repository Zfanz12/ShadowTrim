#ifndef SHADOWTRIM_CORE_H
#define SHADOWTRIM_CORE_H

#include <stdint.h>

#ifdef _WIN32
  #ifdef SHADOWTRIM_EXPORTS
    #define SHADOWTRIM_API __declspec(dllexport)
  #else
    #define SHADOWTRIM_API __declspec(dllimport)
  #endif
#else
  #define SHADOWTRIM_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Initialize the ShadowTrim native C++ engine.
 * @return 1 on success, 0 on failure.
 */
SHADOWTRIM_API int32_t shadowtrim_init(void);

/**
 * Returns the version of the native core engine.
 * E.g., 100 for 1.0.0.
 */
SHADOWTRIM_API int32_t shadowtrim_get_version(void);

/**
 * Instantly restores creation time, last access time, and last write time
 * from source file to destination file using native Win32 kernel APIs (GetFileTime / SetFileTime).
 * Operates in < 0.01 ms with zero subprocess or shell overhead.
 *
 * @param src_path_utf8 UTF-8 encoded path to original source file.
 * @param dst_path_utf8 UTF-8 encoded path to trimmed output file.
 * @return 1 on success, 0 on failure.
 */
SHADOWTRIM_API int32_t shadowtrim_restore_timestamps(const char* src_path_utf8, const char* dst_path_utf8);

/**
 * Executes a process natively via Win32 CreateProcessW with HIGH_PRIORITY_CLASS
 * and pipes stdout/stderr directly into a memory buffer without command shells.
 *
 * @param executable_utf8 Path to executable (e.g. ffmpeg.exe or ffprobe.exe).
 * @param arguments_utf8 Command line arguments.
 * @param out_buffer Output buffer to receive stdout/stderr text.
 * @param out_buffer_size Maximum size of out_buffer in bytes.
 * @param exit_code Pointer to receive the process exit code.
 * @return 1 if process was launched and completed, 0 on launch error.
 */
SHADOWTRIM_API int32_t shadowtrim_execute_process(
    const char* executable_utf8,
    const char* arguments_utf8,
    char* out_buffer,
    int32_t out_buffer_size,
    int32_t* exit_code);

/**
 * High-speed lossless trim execution wrapper.
 * Directly runs FFmpeg with stream copy (-c copy) and immediately restores
 * original file timestamps upon completion natively in C++.
 *
 * @param ffmpeg_path_utf8 Path to ffmpeg executable.
 * @param input_path_utf8 Input video file path.
 * @param output_path_utf8 Output video file path.
 * @param start_time_utf8 Start cut time (HH:MM:SS or seconds).
 * @param end_time_utf8 End cut time (HH:MM:SS or seconds).
 * @param err_buffer Buffer to receive error log if failed.
 * @param err_buffer_size Size of err_buffer.
 * @return 0 on success, or FFmpeg exit code / negative error code on failure.
 */
SHADOWTRIM_API int32_t shadowtrim_fast_trim(
    const char* ffmpeg_path_utf8,
    const char* input_path_utf8,
    const char* output_path_utf8,
    const char* start_time_utf8,
    const char* end_time_utf8,
    char* err_buffer,
    int32_t err_buffer_size);

/**
 * Moves a file safely to the Windows Recycle Bin using native Win32 SHFileOperationW
 * in < 1 ms with zero PowerShell overhead.
 *
 * @param file_path_utf8 UTF-8 encoded file path.
 * @return 1 on success, 0 on failure.
 */
SHADOWTRIM_API int32_t shadowtrim_recycle_file(const char* file_path_utf8);

#ifdef __cplusplus
}
#endif

#endif // SHADOWTRIM_CORE_H
