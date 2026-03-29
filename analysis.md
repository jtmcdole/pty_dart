# PTY Implementation Analysis Report

## 1. Architecture Overview

The `pty_dart` library provides a high-level abstraction for Pseudo-Terminals (PTYs) across Windows and Unix-like systems.

### Core Components
- **`PseudoTerminal`**: The public abstract class and factory for starting PTYs.
- **`PtyCore`**: The low-level interface for platform-specific implementations.
- **`PtyCoreWindows` / `PtyCoreUnix`**: Concrete implementations using FFI to interact with OS-level PTY APIs (ConPTY on Windows, `forkpty` on Unix).
- **`PollingPseudoTerminal`**: A non-blocking implementation that uses a `Timer` and polling strategy.
- **`BlockingPseudoTerminal`**: A performant implementation that uses a separate `Isolate` to perform blocking reads, keeping the main event loop free.

---

## 2. Data Flow Analysis

### Input (Main Thread -> PTY)
1. `pty.write(String)` is called.
2. Data is encoded using `utf8.encode`.
3. `core.write(List<int>)` is called.
4. On Windows, this uses `WriteFile` to the input pipe. On Unix, it uses `write` to the master FD.

### Output (PTY -> Main Thread)
1. **Blocking Mode (Isolate)**:
   - An Isolate runs a loop calling `core.read()`.
   - On Windows, `core.read()` calls `ReadFile` which blocks until data is available.
   - Read data is sent back to the main thread via a `SendPort`.
   - **Critical Bug Found**: The isolate currently uses `utf8.decoder` and sends `String` objects, but the main thread's `StreamController` expects `Uint8List`. This results in a runtime type mismatch.

2. **Polling Mode**:
   - The main thread runs a polling loop with increasing delays.
   - It calls `core.read()` (non-blocking).
   - Collected `Uint8List` chunks are added to the output stream.

---

## 3. Deep Dive: Windows Implementation (`PtyCoreWindows`)

The Windows implementation utilizes the **ConPTY (Pseudo Console)** API, which is the modern way to handle terminals on Windows.

### Pipe Setup
- **Input Pipe**: Created using `CreatePipe`. This is a standard anonymous pipe.
- **Output Pipe**: Created using a custom `_NamedPipe` class.
- **Problem**: The `_NamedPipe` uses a hardcoded name `r'\\.\pipe\mypipe'`. This is a **critical flaw**; if multiple PTY instances are started, they will conflict over the same named pipe, leading to data corruption or "missing data" as different PTYs read from the same pipe instance.

### Pipe Modes
The implementation uses `PIPE_TYPE_MESSAGE` and `PIPE_READMODE_MESSAGE`.
- **Performance Impact**: PTY data is a stream of bytes, not discrete messages. Using message mode for stream data is inappropriate and can lead to issues if the OS tries to enforce message boundaries or if a single "message" exceeds buffer sizes.
- **Recommendation**: Switch to `PIPE_TYPE_BYTE` and `PIPE_READMODE_BYTE`.

---

## 4. Stability and Performance Issues

### Critical Memory Leaks (Windows)
1. **`read()` Leak**: In `PtyCoreWindows.read()`, a `pReadlen` pointer (`calloc<Uint32>()`) is allocated on **every single read call** but never freed. This will cause significant memory growth over time.
2. **`start()` Leaks**: `PtyCoreWindows.start` allocates several buffers (`hReadPipe`, `hWritePipe`, `si`, `pi`, command line strings) using `calloc` that are never freed. While these are per-instance, they add up.

### Handle Leaks (Windows)
The `kill()` method only closes the PTY handle (`hPty`). It fails to close:
- `_inputWriteSide` (Handle to the input pipe)
- `_outputReadSide` (Handle to the output pipe)
- `_hProcess` (Handle to the child process)

Leaking these handles will eventually exhaust system resources if PTYs are frequently started and stopped.

### Polling Overhead
`PollingPseudoTerminal` uses a complex back-off strategy with `Future.delayed`. This is inefficient compared to the `BlockingPseudoTerminal` isolate-based approach. The delays (up to 100ms) can make the terminal feel sluggish.

### Buffer Size
The pipe buffer size in `CreateNamedPipe` is set to `4096`. For high-output applications (like `cat`ing a large file), this might be too small, causing ConPTY to block frequently.

---

## 5. Recommendations for Improvement

### Stability
- **Unique Pipe Names**: Use a unique name for each PTY instance (e.g., `\\.\pipe\pty_${pid}_${counter}`) to prevent instance collisions.
- **Fix Leaks**: Use `using` blocks or explicit `calloc.free()` for all FFI allocations.
- **Close All Handles**: Implement a proper `close()` or `dispose()` mechanism that ensures all Windows handles are closed.
- **Fix Isolate Type Mismatch**: Remove `utf8.decoder` from the isolate and pass raw `Uint8List` back to the main thread.

### Performance
- **Byte Mode Pipes**: Change named pipes to `PIPE_TYPE_BYTE`.
- **Remove `PIPE_NOWAIT`**: `PIPE_NOWAIT` is deprecated. Use overlapped I/O or keep blocking reads within the isolate.
- **Optimize `read()`**: Reuse the `pReadlen` pointer instead of allocating it every time.

### Correctness
- **Pipe Buffer**: The recent change from 512 to 0 for the input pipe buffer (`CreatePipe`) is likely correct (using system default), but the output pipe (Named Pipe) should have a healthy buffer (e.g., 64KB) to avoid back-pressure on ConPTY.
