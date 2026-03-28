import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pty/src/pty_core.dart';
import 'package:pty/src/pty_error.dart';
import 'package:win32/win32.dart' as win32;

class _NamedPipe {
  _NamedPipe({bool nowait = false}) {
    final pipeName = r'\\.\pipe\mypipe'.toPcwstr();

    final waitMode = nowait ? win32.PIPE_NOWAIT : win32.PIPE_WAIT;

    final namedPipe = win32.CreateNamedPipe(
      pipeName,
      win32.PIPE_ACCESS_DUPLEX,
      waitMode | win32.PIPE_READMODE_MESSAGE | win32.PIPE_TYPE_MESSAGE,
      win32.PIPE_UNLIMITED_INSTANCES,
      4096,
      4096,
      0,
      nullptr,
    );

    if (namedPipe == win32.INVALID_HANDLE_VALUE) {
      throw PtyException('CreateNamedPipe failed: ${win32.GetLastError()}');
    }

    final namedPipeClient = win32.CreateFile(
      pipeName,
      win32.GENERIC_READ | win32.GENERIC_WRITE,
      win32.FILE_SHARE_NONE, // no sharing
      nullptr, // default security attributes
      win32.OPEN_EXISTING, // opens existing pipe ,
      win32.FILE_FLAGS_AND_ATTRIBUTES(0), // default attributes
      null, // no template file
    );

    if (namedPipeClient.error != win32.ERROR_SUCCESS) {
      throw PtyException('CreateFile on named pipe failed');
    }

    readSide = namedPipe;
    writeSide = namedPipeClient.value;
  }

  late final win32.HANDLE readSide;
  late final win32.HANDLE writeSide;
}

class PtyCoreWindows implements PtyCore {
  factory PtyCoreWindows.start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool blocking = false,
  }) {
    // create input pipe
    final hReadPipe = calloc<IntPtr>();
    final hWritePipe = calloc<IntPtr>();
    final pipe2 = win32.CreatePipe(
      hReadPipe.cast<win32.HANDLE>(),
      hWritePipe.cast<win32.HANDLE>(),
      null,
      512,
    );

    if (pipe2 == win32.INVALID_HANDLE_VALUE) {
      throw PtyException('CreatePipe failed: ${win32.GetLastError()}');
    }

    // create output pipe
    final pipe1 = _NamedPipe(nowait: !blocking);
    final outputReadSide = pipe1.readSide;
    final outputWriteSide = pipe1.writeSide;

    // final pipe2 = _NamedPipe(nowait: false);
    // final inputWriteSide = pipe2.writeSide;
    // final inputReadSide = pipe2.readSide;

    // create pty
    final size = calloc<win32.COORD>().ref;
    size.X = 80;
    size.Y = 25;
    final hpConPty = win32.CreatePseudoConsole(
      size,
      win32.HANDLE(Pointer.fromAddress(hReadPipe.value)),
      outputWriteSide,
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

    if (ret == win32.FALSE) {
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

    if (ret == win32.FALSE) {
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
    // Pointer<Utf16> pEnvironment = nullptr;
    // if (environment != null && environment.isNotEmpty) {
    //   final buffer = StringBuffer();
    //   for (var env in environment.entries) {
    //     buffer.write(env.key);
    //     buffer.write('=');
    //     buffer.write(env.value);
    //     buffer.write('\u0000');
    //   }
    //   if (environment.entries.isEmpty) {
    //     buffer.write('\u0000');
    //   }
    //   buffer.write('\u0000');

    //   pEnvironment = buffer.toString().toNativeUtf16();
    // }

    // start the process.
    final pi = calloc<win32.PROCESS_INFORMATION>();
    ret = win32.CreateProcess(
      null,
      pwstrCommandLine,
      null,
      null,
      false,
      win32.EXTENDED_STARTUPINFO_PRESENT,
      null,
      pwstrCurrentDirectory,
      si.cast(),
      pi,
    );

    if (ret == 0) {
      throw PtyException('CreateProcess failed: ${win32.GetLastError()}');
    }

    return PtyCoreWindows._(
      win32.HANDLE(Pointer.fromAddress(hWritePipe.value)),
      outputReadSide,
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
      nullptr,
    );

    final readlen = pReadlen.value;
    if (!ret.value || readlen <= 0) {
      return null;
    }
    return Uint8List.fromList(_buffer.asTypedList(readlen));
  }

  @override
  int? exitCodeNonBlocking() {
    final exitCodePtr = calloc<Uint32>();
    final ret = win32.GetExitCodeProcess(_hProcess, exitCodePtr);

    final exitCode = exitCodePtr.value;
    calloc.free(exitCodePtr);

    const STILL_ACTIVE = 259;
    if (ret == 0 || exitCode == STILL_ACTIVE) {
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
    return ret != 0;
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

// void rawWait(int hProcess) {
//   // final status = allocate<Int32>();
//   // unistd.waitpid(pid, status, 0);
//   final count = 1;
//   final pids = calloc<IntPtr>(count);
//   final infinite = 0xFFFFFFFF;
//   pids.elementAt(0).value = hProcess;
//   win32.MsgWaitForMultipleObjects(count, pids, 1, infinite, win32.QS_ALLEVENTS);
// }
