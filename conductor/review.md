# Plan - Review and Correct `lib/src/impl/windows.dart` for win32 6.0.0

This plan addresses memory leaks, incorrect API usage, and syntax errors in the Windows implementation of the PTY library, following the update to `win32` 6.0.0 and `dart:ffi` 2.2.0.

## Objective
Update `lib/src/impl/windows.dart` to be fully compliant with `win32` 6.0.0 standards, focusing on `Win32Result` handling, strongly typed handles, and deterministic memory management.

## Key Files & Context
- `lib/src/impl/windows.dart`: The core implementation for Windows PTY support.

## Implementation Steps

### 1. Update `_NamedPipe` Implementation
- Change `CreateNamedPipe` handling to account for `Win32Result<HANDLE>`.
- Use `namedPipe.value` for the handle and `namedPipe.error` for error reporting.
- Fix `CreateFile` parameter for `hTemplateFile` from `null` to `win32.HANDLE.NULL`.
- Ensure `readSide` and `writeSide` are assigned from the `.value` property of the `Win32Result`.

### 2. Refactor `PtyCoreWindows.start` for Memory Safety
- Use `using((arena) { ... })` to manage all temporary native allocations.
- Replace `calloc` calls with `arena<T>()` or `arena.allocate<T>()`.
- Remove the manual `freeme` list and the invalid `?pwstrCurrentDirectory` syntax.
- Fix `HANDLE` construction: use `win32.HANDLE(phWrite.value)` instead of `Pointer.fromAddress`.
- Update `CreatePipe`, `CreatePseudoConsole`, and `CreateProcess` to handle `Win32Result`.
- Fix `si.ref.StartupInfo.hStdInput` etc. to use `win32.HANDLE.NULL`.

### 3. Correct `PtyCoreWindows` Methods
- **`read()`**: Ensure `pReadlen` is handled correctly (it currently uses `calloc` and `free`, which is fine, but `arena` is cleaner).
- **`exitCodeBlocking()`**: Fix `_hProcess.address` (handles are extension types on `int` now). Ensure `pid` is freed.
- **`kill()`**: Fix `TerminateProcess` second argument (use `0` instead of `nullptr.address`).
- **`resize()`**: Ensure `COORD` is passed correctly according to `win32` 6.0.0.

### 4. General Cleanup
- Replace `nullptr` with `win32.HANDLE.NULL` where appropriate for handle parameters.
- Verify `BOOL` return values are treated as `bool`.

## Verification & Testing
- Run `analyze_files` to check for type errors and linting issues.
- Run existing PTY tests on Windows to ensure functional correctness.
- Verify no memory leaks using a heap profiler if possible, or by inspection of `arena` usage.
