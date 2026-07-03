import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pty2/src/pty_core.dart';
import 'package:win32/win32.dart' as win32;

class PtyCoreWindows implements PtyCore {
  factory PtyCoreWindows.start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool blocking = false,
  }) {
    // build command line
    final commandBuffer = StringBuffer();
    commandBuffer.write(executable);
    if (arguments.isNotEmpty) {
      for (var argument in arguments) {
        commandBuffer.write(' ');
        commandBuffer.write(argument);
      }
    }

    final pwstrCommandLine = '$commandBuffer'.toPwstr();

    // build current directory
    win32.PCWSTR? pwstrCurrentDirectory;
    if (workingDirectory != null) {
      pwstrCurrentDirectory = workingDirectory.toPcwstr();
    }

    //// build environment
    Pointer<Utf16>? pEnvironment;
    if (environment != null && environment.isNotEmpty) {
      final envMap = {...WinEnv().getEnvironment(), ...environment};

      final buffer = StringBuffer();
      for (final MapEntry(:key, :value) in envMap.entries) {
        buffer.write(key);
        buffer.write('=');
        buffer.write(value);
        buffer.writeCharCode(0);
      }
      buffer.write('\u0000');

      pEnvironment = '$buffer'.toNativeUtf16();
    }

    var useConPTY = true;
    try {
      if (!stdin.hasTerminal) {
        useConPTY = false;
      }
    } catch (_) {
      useConPTY = false;
    }
    win32.HPCON? hpConPty;
    win32.HANDLE? inputWriteHandle;
    win32.HANDLE? outputReadHandle;
    win32.HANDLE? inputReadHandle;
    win32.HANDLE? outputWriteHandle;
    win32.HANDLE? hProcess;

    // create pipes (non-inheritable for ConPTY, identical to master)
    final hInputReadPipe = calloc<IntPtr>();
    final hInputWritePipe = calloc<IntPtr>();
    var pipe1 = win32.CreatePipe(
      hInputReadPipe.cast<win32.HANDLE>(),
      hInputWritePipe.cast<win32.HANDLE>(),
      nullptr,
      0,
    );

    final hOutReadPipe = calloc<IntPtr>();
    final hOutWritePipe = calloc<IntPtr>();
    var pipe2 = win32.CreatePipe(
      hOutReadPipe.cast<win32.HANDLE>(),
      hOutWritePipe.cast<win32.HANDLE>(),
      nullptr,
      0,
    );

    if (pipe1.error != win32.ERROR_SUCCESS ||
        pipe2.error != win32.ERROR_SUCCESS) {
      useConPTY = false;
    }

    // create pty
    if (useConPTY) {
      final size = calloc<win32.COORD>().ref;
      size.X = 80;
      size.Y = 25;

      try {
        final ptyHandle = win32.CreatePseudoConsole(
          size,
          win32.HANDLE(Pointer.fromAddress(hInputReadPipe.value)),
          win32.HANDLE(Pointer.fromAddress(hOutWritePipe.value)),
          0,
        );

        if (!ptyHandle.isValid) {
          useConPTY = false;
        } else {
          hpConPty = ptyHandle;
        }
      } catch (_) {
        useConPTY = false;
      }
    }

    final pi = calloc<win32.PROCESS_INFORMATION>();

    if (useConPTY && hpConPty != null) {
      // setup startup info for ConPTY
      final si = calloc<win32.STARTUPINFOEX>();
      si.ref.StartupInfo.cb = sizeOf<win32.STARTUPINFOEX>();

      final bytesRequired = calloc<IntPtr>();
      win32.InitializeProcThreadAttributeList(null, 1, bytesRequired);
      final lpAttributeListPtr = calloc<Int8>(bytesRequired.value);
      si.ref.lpAttributeList = win32.LPPROC_THREAD_ATTRIBUTE_LIST(
        lpAttributeListPtr,
      );
      win32.InitializeProcThreadAttributeList(
        si.ref.lpAttributeList,
        1,
        bytesRequired,
      );

      var ret = win32.UpdateProcThreadAttribute(
        si.ref.lpAttributeList,
        0,
        win32.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        Pointer.fromAddress(
          hpConPty,
        ), // <--- DIRECT HPCON (identical to master)
        sizeOf<IntPtr>(),
        nullptr,
        nullptr,
      );

      if (ret.value) {
        // Spawn process (bInheritHandles = false, identical to master)
        final piRet = win32.CreateProcess(
          null,
          pwstrCommandLine,
          null,
          null,
          false, // <--- inherit handles is false!
          win32.EXTENDED_STARTUPINFO_PRESENT | win32.CREATE_UNICODE_ENVIRONMENT,
          pEnvironment,
          pwstrCurrentDirectory,
          si.cast(),
          pi,
        );

        if (piRet.value) {
          // Check if process crashed immediately (typical for conhost/ConPTY initialization failure in sandbox)
          win32.WaitForSingleObject(pi.ref.hProcess, 30);
          final exitCodePtr = calloc<Uint32>();
          win32.GetExitCodeProcess(pi.ref.hProcess, exitCodePtr);

          if (exitCodePtr.value == 3221225794) {
            // 0xC0000142 STATUS_DLL_INIT_FAILED
            // ignore: avoid_print
            print(
              'PtyCoreWindows: ConPTY failed to initialize (exit code 0xC0000142). Falling back to legacy pipes.',
            );
            useConPTY = false;
            win32.CloseHandle(pi.ref.hProcess);
            win32.CloseHandle(pi.ref.hThread);
            win32.ClosePseudoConsole(hpConPty);
            hpConPty = null;
          } else {
            // ignore: avoid_print
            print('PtyCoreWindows: Using ConPTY engine.');
            hProcess = win32.HANDLE(
              Pointer.fromAddress(pi.ref.hProcess.address),
            );
            win32.CloseHandle(pi.ref.hThread);

            inputWriteHandle = win32.HANDLE(
              Pointer.fromAddress(hInputWritePipe.value),
            );
            outputReadHandle = win32.HANDLE(
              Pointer.fromAddress(hOutReadPipe.value),
            );
            inputReadHandle = win32.HANDLE(
              Pointer.fromAddress(hInputReadPipe.value),
            );
            outputWriteHandle = win32.HANDLE(
              Pointer.fromAddress(hOutWritePipe.value),
            );
          }
          calloc.free(exitCodePtr);
        } else {
          useConPTY = false;
        }
      } else {
        useConPTY = false;
      }

      calloc.free(bytesRequired);
      calloc.free(lpAttributeListPtr);
      calloc.free(si);
    }

    if (!useConPTY) {
      // Clean up the ConPTY-side pipes
      win32.CloseHandle(
        win32.HANDLE(Pointer.fromAddress(hInputReadPipe.value)),
      );
      win32.CloseHandle(
        win32.HANDLE(Pointer.fromAddress(hInputWritePipe.value)),
      );
      win32.CloseHandle(win32.HANDLE(Pointer.fromAddress(hOutReadPipe.value)));
      win32.CloseHandle(win32.HANDLE(Pointer.fromAddress(hOutWritePipe.value)));

      // Set up security attributes for legacy pipes to allow inheritance
      final saLegacy = calloc<win32.SECURITY_ATTRIBUTES>();
      saLegacy.ref.nLength = sizeOf<win32.SECURITY_ATTRIBUTES>();
      saLegacy.ref.lpSecurityDescriptor = nullptr;
      saLegacy.ref.bInheritHandle = true;

      // Re-create pipes for legacy redirection
      win32.CreatePipe(
        hInputReadPipe.cast<win32.HANDLE>(),
        hInputWritePipe.cast<win32.HANDLE>(),
        saLegacy,
        0,
      );
      win32.CreatePipe(
        hOutReadPipe.cast<win32.HANDLE>(),
        hOutWritePipe.cast<win32.HANDLE>(),
        saLegacy,
        0,
      );

      // Disable inheritance on our side of the pipe handles
      const handleFlagInherit = 1;
      win32.SetHandleInformation(
        win32.HANDLE(Pointer.fromAddress(hInputWritePipe.value)),
        handleFlagInherit,
        win32.HANDLE_FLAGS(0),
      );
      win32.SetHandleInformation(
        win32.HANDLE(Pointer.fromAddress(hOutReadPipe.value)),
        handleFlagInherit,
        win32.HANDLE_FLAGS(0),
      );

      // Setup legacy STARTUPINFO
      final siLegacy = calloc<win32.STARTUPINFO>();
      siLegacy.ref.cb = sizeOf<win32.STARTUPINFO>();
      siLegacy.ref.dwFlags = win32.STARTF_USESTDHANDLES;
      siLegacy.ref.hStdInput = win32.HANDLE(
        Pointer.fromAddress(hInputReadPipe.value),
      );
      siLegacy.ref.hStdOutput = win32.HANDLE(
        Pointer.fromAddress(hOutWritePipe.value),
      );
      siLegacy.ref.hStdError = win32.HANDLE(
        Pointer.fromAddress(hOutWritePipe.value),
      );

      final piLegacyRet = win32.CreateProcess(
        null,
        pwstrCommandLine,
        null,
        null,
        true, // inherit handles
        win32.CREATE_UNICODE_ENVIRONMENT | win32.CREATE_NO_WINDOW,
        pEnvironment,
        pwstrCurrentDirectory,
        siLegacy.cast(),
        pi,
      );

      if (!piLegacyRet.value) {
        win32.CloseHandle(
          win32.HANDLE(Pointer.fromAddress(hInputReadPipe.value)),
        );
        win32.CloseHandle(
          win32.HANDLE(Pointer.fromAddress(hInputWritePipe.value)),
        );
        win32.CloseHandle(
          win32.HANDLE(Pointer.fromAddress(hOutReadPipe.value)),
        );
        win32.CloseHandle(
          win32.HANDLE(Pointer.fromAddress(hOutWritePipe.value)),
        );

        for (final addr in [
          hInputReadPipe,
          hInputWritePipe,
          hOutReadPipe,
          hOutWritePipe,
        ]) {
          calloc.free(addr);
        }
        calloc.free(saLegacy);
        calloc.free(pi);
        calloc.free(siLegacy);

        return PtyCoreWindows._failed();
      }

      hProcess = win32.HANDLE(Pointer.fromAddress(pi.ref.hProcess.address));
      win32.CloseHandle(pi.ref.hThread);

      // Close the child side handles in the parent process
      win32.CloseHandle(
        win32.HANDLE(Pointer.fromAddress(hInputReadPipe.value)),
      );
      win32.CloseHandle(win32.HANDLE(Pointer.fromAddress(hOutWritePipe.value)));

      inputWriteHandle = win32.HANDLE(
        Pointer.fromAddress(hInputWritePipe.value),
      );
      outputReadHandle = win32.HANDLE(Pointer.fromAddress(hOutReadPipe.value));
      inputReadHandle = win32.HANDLE(nullptr);
      outputWriteHandle = win32.HANDLE(nullptr);

      calloc.free(siLegacy);
      calloc.free(saLegacy);
    }

    for (final addr in [
      hInputReadPipe,
      hInputWritePipe,
      hOutReadPipe,
      hOutWritePipe,
    ]) {
      calloc.free(addr);
    }
    calloc.free(pi);

    return PtyCoreWindows._(
      inputWriteHandle!,
      outputReadHandle!,
      inputReadHandle!,
      outputWriteHandle!,
      hpConPty,
      hProcess!,
    );
  }

  PtyCoreWindows._(
    this._inputWriteSide,
    this._outputReadSide,
    this._inputReadSide,
    this._outputWriteSide,
    this._hPty,
    this._hProcess,
  ) : _failed = false;

  PtyCoreWindows._failed()
    : _inputWriteSide = win32.HANDLE(nullptr),
      _outputReadSide = win32.HANDLE(nullptr),
      _inputReadSide = win32.HANDLE(nullptr),
      _outputWriteSide = win32.HANDLE(nullptr),
      _hPty = null,
      _hProcess = win32.HANDLE(nullptr),
      _failed = true;

  final win32.HANDLE _inputWriteSide;
  final win32.HANDLE _outputReadSide;
  final win32.HANDLE _inputReadSide;
  final win32.HANDLE _outputWriteSide;
  final win32.HPCON? _hPty;
  final win32.HANDLE _hProcess;
  final bool _failed;

  static const _bufferSize = 4096;
  final _buffer = calloc<Uint8>(_bufferSize + 1);

  @override
  Uint8List? read() {
    if (_failed) return null;
    final pReadlen = calloc<Uint32>();
    final ret = win32.ReadFile(
      _outputReadSide,
      _buffer,
      _bufferSize,
      pReadlen,
      null,
    );

    final readlen = pReadlen.value;
    win32.free(pReadlen);
    if (ret.value || ret.error == win32.ERROR_MORE_DATA) {
      if (readlen > 0) {
        return Uint8List.fromList(_buffer.asTypedList(readlen));
      }
    }
    return null;
  }

  @override
  int? exitCodeNonBlocking() {
    if (_failed) return 1;
    final exitCodePtr = calloc<Uint32>();
    final ret = win32.GetExitCodeProcess(_hProcess, exitCodePtr);

    final exitCode = exitCodePtr.value;
    calloc.free(exitCodePtr);

    const stillActive = 259;
    if (!ret.value || exitCode == stillActive) {
      return null;
    }

    return exitCode;
  }

  @override
  int exitCodeBlocking() {
    if (_failed) return 1;
    const infinite = 0xFFFFFFFF;
    win32.WaitForSingleObject(_hProcess, infinite);

    return using((arena) {
      final exitCodePtr = arena<Uint32>();
      win32.GetExitCodeProcess(_hProcess, exitCodePtr);
      return exitCodePtr.value;
    });
  }

  bool _killed = false;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (_failed || _killed) return true;
    _killed = true;
    final ret = win32.TerminateProcess(_hProcess, 0);
    if (_hPty != null) {
      win32.ClosePseudoConsole(_hPty);
      win32.CloseHandle(_inputReadSide);
      win32.CloseHandle(_outputWriteSide);
    }
    return ret.value;
  }

  @override
  void resize(int width, int height) {
    if (_failed) return;
    if (_hPty == null) return;
    final size = calloc<win32.COORD>();
    size.ref.X = width;
    size.ref.Y = height;
    win32.ResizePseudoConsole(_hPty, size.ref);
    calloc.free(size);
  }

  // @override
  // int get pid {
  //   return _hProcess;
  // }

  @override
  void write(List<int> data) {
    if (_failed) return;
    final buffer = calloc<Uint8>(data.length);
    buffer.asTypedList(data.length).setAll(0, data);
    final written = calloc<Uint32>();
    win32.WriteFile(_inputWriteSide, buffer, data.length, written, nullptr);
    calloc.free(buffer);
    calloc.free(written);
  }
}

typedef GetEnvironmentStringsNative = Pointer<Utf16> Function();
typedef GetEnvironmentStringsDart = Pointer<Utf16> Function();
typedef FreeEnvironmentStringsNative =
    Int32 Function(Pointer<Utf16> lpszEnvironmentBlock);
typedef FreeEnvironmentStringsDart =
    int Function(Pointer<Utf16> lpszEnvironmentBlock);

class WinEnv {
  static final kernel32 = DynamicLibrary.open('kernel32.dll');

  static final getEnvironmentStringsW = kernel32
      .lookupFunction<GetEnvironmentStringsNative, GetEnvironmentStringsDart>(
        'GetEnvironmentStringsW',
      );

  static final freeEnvironmentStringsW = kernel32
      .lookupFunction<FreeEnvironmentStringsNative, FreeEnvironmentStringsDart>(
        'FreeEnvironmentStringsW',
      );

  Map<String, String> getEnvironment() {
    final wstrings = getEnvironmentStringsW();

    try {
      final strings = win32.PWSTR(wstrings).toDartStringList(32 * 1024);
      var map = <String, String>{};
      for (var string in strings) {
        if (string.startsWith('=')) continue;
        final int separatorIndex = string.indexOf(
          '=',
          1,
        ); // Start at 1 to skip leading '='
        if (separatorIndex != -1) {
          final k = string.substring(0, separatorIndex);
          final v = string.substring(separatorIndex + 1);
          map[k] = v;
        }
      }

      return map;
    } finally {
      freeEnvironmentStringsW(wstrings);
    }
  }
}
