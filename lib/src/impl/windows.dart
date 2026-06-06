import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pty2/src/pty_core.dart';
import 'package:pty2/src/pty_error.dart';
import 'package:win32/win32.dart' as win32;

class PtyCoreWindows implements PtyCore {
  factory PtyCoreWindows.start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool blocking = false,
  }) {
    // create input pipe
    final hInputReadPipe = calloc<IntPtr>();
    final hInputWritePipe = calloc<IntPtr>();
    final pipe2 = win32.CreatePipe(
      hInputReadPipe.cast<win32.HANDLE>(),
      hInputWritePipe.cast<win32.HANDLE>(),
      null,
      0,
    );

    if (pipe2.error != win32.ERROR_SUCCESS) {
      throw PtyException('CreatePipe failed: ${win32.GetLastError()}');
    }

    // create output pipe
    final hOutReadPipe = calloc<IntPtr>();
    final hOutWritePipe = calloc<IntPtr>();
    final pipe1 = win32.CreatePipe(
      hOutReadPipe.cast<win32.HANDLE>(),
      hOutWritePipe.cast<win32.HANDLE>(),
      null,
      0,
    );

    if (pipe1.error != win32.ERROR_SUCCESS) {
      throw PtyException('CreatePipe failed: ${win32.GetLastError()}');
    }

    // create pty
    final size = calloc<win32.COORD>().ref;
    size.X = 80;
    size.Y = 25;
    final hpConPty = win32.CreatePseudoConsole(
      size,
      win32.HANDLE(Pointer.fromAddress(hInputReadPipe.value)),
      win32.HANDLE(Pointer.fromAddress(hOutWritePipe.value)),
      0,
    );

    if (!hpConPty.isValid) {
      throw PtyException('CreatePseudoConsole failed.');
    }

    // setup startup info
    final si = calloc<win32.STARTUPINFOEX>();
    si.ref.StartupInfo.cb = sizeOf<win32.STARTUPINFOEX>();

    final bytesRequired = calloc<IntPtr>();
    win32.InitializeProcThreadAttributeList(null, 1, bytesRequired);
    final lpAttributeListPtr = calloc<Int8>(bytesRequired.value);
    si.ref.lpAttributeList = win32.LPPROC_THREAD_ATTRIBUTE_LIST(
      lpAttributeListPtr,
    );

    var ret = win32.InitializeProcThreadAttributeList(
      si.ref.lpAttributeList,
      1,
      bytesRequired,
    );

    if (!ret.value) {
      throw PtyException('InitializeProcThreadAttributeList failed.');
    }

    // use pty
    ret = win32.UpdateProcThreadAttribute(
      si.ref.lpAttributeList,
      0,
      win32.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
      Pointer.fromAddress(hpConPty),
      sizeOf<IntPtr>(),
      nullptr,
      nullptr,
    );

    if (!ret.value) {
      throw PtyException('UpdateProcThreadAttribute failed.');
    }

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

      // print('cfu test: $envMap');

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

    // start the process.
    final pi = calloc<win32.PROCESS_INFORMATION>();
    ret = win32.CreateProcess(
      null,
      pwstrCommandLine,
      null,
      null,
      false,
      win32.EXTENDED_STARTUPINFO_PRESENT | win32.CREATE_UNICODE_ENVIRONMENT,
      pEnvironment,
      pwstrCurrentDirectory,
      si.cast(),
      pi,
    );

    if (!ret.value) {
      throw PtyException('CreateProcess failed: ${win32.GetLastError()}');
    }

    final inputWriteHandle = win32.HANDLE(
      Pointer.fromAddress(hInputWritePipe.value),
    );
    final outputReadHandle = win32.HANDLE(
      Pointer.fromAddress(hOutReadPipe.value),
    );

    for (final addr in [
      hInputReadPipe,
      hInputWritePipe,
      hOutReadPipe,
      hOutWritePipe,
    ]) {
      calloc.free(addr);
    }

    return PtyCoreWindows._(
      inputWriteHandle,
      outputReadHandle,
      hpConPty,
      pi.ref.hProcess,
    );
  }

  PtyCoreWindows._(
    this._inputWriteSide,
    this._outputReadSide,
    this._hPty,
    this._hProcess,
  );

  final win32.HANDLE _inputWriteSide;
  final win32.HANDLE _outputReadSide;
  final win32.HPCON _hPty;
  final win32.HANDLE _hProcess;

  static const _bufferSize = 4096;
  final _buffer = calloc<Uint8>(_bufferSize + 1);

  @override
  Uint8List? read() {
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
    if (readlen < 0) {
      // print('win32 read: ${(readLen: readlen)}');
      return null;
    }

    switch (ret.error) {
      case win32.ERROR_SUCCESS:
      case win32.ERROR_MORE_DATA:
        return Uint8List.fromList(_buffer.asTypedList(readlen));
      default:
        // print('win32 read: ${(error: ret.error)}');
        return null;
    }
  }

  @override
  int? exitCodeNonBlocking() {
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
    return using((arena) {
      final pHandles = arena<IntPtr>(1);
      pHandles[0] = _hProcess.address;
      const infinite = 0xFFFFFFFF;
      win32.MsgWaitForMultipleObjects(
        1,
        pHandles.cast<Pointer<Pointer>>(),
        true,
        infinite,
        win32.QS_ALLEVENTS,
      );

      final exitCodePtr = arena<Uint32>();
      win32.GetExitCodeProcess(_hProcess, exitCodePtr);
      return exitCodePtr.value;
    });
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    final ret = win32.TerminateProcess(_hProcess, 0);
    win32.ClosePseudoConsole(_hPty);
    return ret.value;
  }

  @override
  void resize(int width, int height) {
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
