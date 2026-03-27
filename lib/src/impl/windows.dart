import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pty/src/pty_core.dart';
import 'package:pty/src/pty_error.dart';
// import 'package:pty/src/util/win32_additional.dart';
import 'package:win32/win32.dart' as win32;

class _NamedPipe {
  _NamedPipe({bool nowait = false}) {
    using((arena) {
      final pipeName = r'\\.\pipe\dart-pty-pipe';
      final pPipeName = pipeName.toPcwstr(allocator: arena);

      final waitMode = nowait ? win32.PIPE_NOWAIT : win32.PIPE_WAIT;

      final namedPipe = win32.CreateNamedPipe(
        pPipeName,
        win32.PIPE_ACCESS_DUPLEX,
        waitMode | win32.PIPE_READMODE_MESSAGE | win32.PIPE_TYPE_MESSAGE,
        win32.PIPE_UNLIMITED_INSTANCES,
        4096,
        4096,
        0,
        nullptr,
      );

      if (!namedPipe.isValid) {
        throw PtyException('CreateNamedPipe failed: $namedPipe');
      }

      final namedPipeClient = win32.CreateFile(
        pPipeName,
        win32.GENERIC_READ | win32.GENERIC_WRITE,
        win32.FILE_SHARE_NONE, // no sharing
        null, // default security attributes
        win32.OPEN_EXISTING, // opens existing pipe
        win32.FILE_FLAGS_AND_ATTRIBUTES(0), // default attributes
        null, // no template file
      );

      if (namedPipeClient.error != win32.ERROR_SUCCESS) {
        throw PtyException(
          'CreateFile on named pipe failed: ${namedPipeClient.error}',
        );
      }

      readSide = namedPipe;
      writeSide = namedPipeClient.value;
    });
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
    return using((arena) {
      // create input pipe
      final phRead = arena<IntPtr>();
      final phWrite = arena<IntPtr>();

      final pipe2Result = win32.CreatePipe(
        phRead.cast<win32.HANDLE>(),
        phWrite.cast<win32.HANDLE>(),
        null,
        512,
      );
      if (!pipe2Result.value) {
        throw PtyException('CreatePipe failed: ${pipe2Result.error}');
      }
      final inputWriteSide = win32.HANDLE(Pointer.fromAddress(phWrite.value));
      final inputReadSide = win32.HANDLE(Pointer.fromAddress(phRead.value));

      // create output pipe
      final pipe1 = _NamedPipe(nowait: !blocking);
      final outputReadSide = pipe1.readSide;
      final outputWriteSide = pipe1.writeSide;

      // create pty
      final size = arena<win32.COORD>();
      size.ref.X = 80;
      size.ref.Y = 25;
      final hpty = win32.CreatePseudoConsole(
        size.ref,
        inputReadSide,
        outputWriteSide,
        0,
      );

      if (!hpty.isValid) {
        throw PtyException('CreatePseudoConsole failed.');
      }

      // Setup startup info
      final si = arena<win32.STARTUPINFOEX>();
      si.ref.StartupInfo.cb = sizeOf<win32.STARTUPINFOEX>();

      // Explicitly set stdio of the child process to NULL. This is required for
      // ConPTY to work properly.
      si.ref.StartupInfo.hStdInput = win32.HANDLE(nullptr);
      si.ref.StartupInfo.hStdOutput = win32.HANDLE(nullptr);
      si.ref.StartupInfo.hStdError = win32.HANDLE(nullptr);
      si.ref.StartupInfo.dwFlags = win32.STARTF_USESTDHANDLES;

      final bytesRequired = arena<IntPtr>();
      win32.InitializeProcThreadAttributeList(null, 1, bytesRequired);
      final lpAttributeListPtr = arena<Int8>(bytesRequired.value);
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
      final pPtyAttr = arena<IntPtr>();
      pPtyAttr.value = hpty;
      ret = win32.UpdateProcThreadAttribute(
        si.ref.lpAttributeList,
        0,
        win32.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        pPtyAttr.cast<Void>(),
        sizeOf<IntPtr>(),
        null,
        null,
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

      final pwstrCommandLine = '$commandBuffer'.toPwstr(allocator: arena);

      // build current directory
      win32.PCWSTR? pwstrCurrentDirectory;
      if (workingDirectory != null) {
        pwstrCurrentDirectory = workingDirectory.toPcwstr(allocator: arena);
      }
      // build environment
      Pointer<Utf16> pEnvironment = nullptr;
      if (environment != null && environment.isNotEmpty) {
        final buffer = StringBuffer();

        for (var env in environment.entries) {
          buffer.write(env.key);
          buffer.write('=');
          buffer.write(env.value);
          buffer.write('\u0000');
        }
        if (environment.entries.isEmpty) {
          buffer.write('\u0000');
        }
        buffer.write('\u0000');

        pEnvironment = buffer.toString().toNativeUtf16(allocator: arena);
      }

      // start the process.
      final pi = arena<win32.PROCESS_INFORMATION>();
      final cpResult = win32.CreateProcess(
        null,
        pwstrCommandLine,
        null,
        null,
        false,
        win32.EXTENDED_STARTUPINFO_PRESENT | win32.CREATE_UNICODE_ENVIRONMENT,
        //pEnvironment,
        null,
        pwstrCurrentDirectory,
        si.cast(),
        pi,
      );

      if (!cpResult.value) {
        throw PtyException('CreateProcess failed: ${cpResult.error}');
      }

      return PtyCoreWindows._(
        inputWriteSide,
        outputReadSide,
        hpty,
        pi.ref.hProcess,
      );
    });
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
    return using((arena) {
      final pReadlen = arena<Uint32>();
      final ret = win32.ReadFile(
        _outputReadSide,
        _buffer,
        _bufferSize,
        pReadlen,
        null,
      );

      final readlen = pReadlen.value;

      if (!ret.value || readlen <= 0) {
        return null;
      }

      return Uint8List.fromList(_buffer.asTypedList(readlen));
    });
  }

  @override
  int? exitCodeNonBlocking() {
    return using((arena) {
      final exitCodePtr = arena<Uint32>();
      final ret = win32.GetExitCodeProcess(_hProcess, exitCodePtr);

      final exitCode = exitCodePtr.value;

      const STILL_ACTIVE = 259;
      if (!ret.value || exitCode == STILL_ACTIVE) {
        return null;
      }

      return exitCode;
    });
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
    using((arena) {
      final size = arena<win32.COORD>();
      size.ref.X = width.toInt();
      size.ref.Y = height.toInt();
      try {
        win32.ResizePseudoConsole(_hPty, size.ref);
      } catch (e) {
        throw PtyException('ResizePseudoConsole failed.');
      }
    });
  }

  @override
  void write(List<int> data) {
    using((arena) {
      final buffer = arena<Uint8>(data.length);
      buffer.asTypedList(data.length).setAll(0, data);
      final written = arena<Uint32>();
      win32.WriteFile(_inputWriteSide, buffer, data.length, written, null);
    });
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
