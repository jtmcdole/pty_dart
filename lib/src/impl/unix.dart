import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:pty2/src/pty_core.dart';
import 'package:pty2/src/pty_error.dart';
import 'package:pty2/src/util/unix_const.dart';
import 'package:pty2/src/util/unix_ffi.dart';

void _setNonblock(int fd) {
  var flag = unix.fcntl(fd, consts.F_GETFL);

  flag |= consts.O_NONBLOCK;

  final ret = unix.fcntl3(fd, consts.F_SETFL, flag);
  if (ret == -1) {
    unix.perror(nullptr);
    // throw PtyError('fcntl3 failed.');
  }
}

class PtyCoreUnix implements PtyCore {
  factory PtyCoreUnix.start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool blocking = false,
  }) {
    var effectiveEnv = <String, String>{};

    effectiveEnv['TERM'] = 'xterm-256color';
    // Without this, tools like "vi" produce sequences that are not UTF-8 friendly
    effectiveEnv['LANG'] = 'en_US.UTF-8';

    var envValuesToCopy = [
      'LOGNAME',
      'USER',
      'DISPLAY',
      'LC_TYPE',
      'HOME',
      'PATH',
    ];

    for (var entry in Platform.environment.entries) {
      if (envValuesToCopy.contains(entry.key)) {
        effectiveEnv[entry.key] = entry.value;
      }
    }

    if (environment != null) {
      for (var entry in environment.entries) {
        effectiveEnv[entry.key] = entry.value;
      }
    }

    final pPtm = calloc<Int32>();
    pPtm.value = -1;

    final sz = calloc<winsize>();
    sz.ref.ws_col = 80;
    sz.ref.ws_row = 20;

    final pid = unix.forkpty(pPtm, nullptr, nullptr, sz);
    calloc.free(sz);

    var ptm = pPtm.value;
    calloc.free(pPtm);

    if (pid < 0) {
      throw PtyException('fork failed.');
    } else if (pid == 0) {
      // set working directory
      if (workingDirectory != null) {
        unix.chdir(workingDirectory.toNativeUtf8());
      }

      // build argv
      final argv = calloc<Pointer<Utf8>>(arguments.length + 2);
      (argv + 0).value = executable.toNativeUtf8();
      (argv + arguments.length + 1).value = nullptr;
      for (var i = 0; i < arguments.length; i++) {
        (argv + i + 1).value = arguments[i].toNativeUtf8();
      }

      //build env
      final env = calloc<Pointer<Utf8>>(effectiveEnv.length + 1);
      (env + effectiveEnv.length).value = nullptr;
      var cnt = 0;
      for (var entry in effectiveEnv.entries) {
        final envVal = '${entry.key}=${entry.value}';
        (env + cnt).value = envVal.toNativeUtf8();
        cnt++;
      }

      var resolvedExecutable = executable;
      if (!resolvedExecutable.contains('/')) {
        final pathEnv = effectiveEnv['PATH'] ?? Platform.environment['PATH'] ?? '';
        for (final dir in pathEnv.split(':')) {
          if (dir.isEmpty) continue;
          final testPath = '$dir/$executable';
          if (File(testPath).existsSync()) {
            resolvedExecutable = testPath;
            break;
          }
        }
      }

      unix.execve(resolvedExecutable.toNativeUtf8(), argv, env);
      unix.exit(1);
    } else {
      unix.setsid();

      if (!blocking) {
        _setNonblock(ptm);
      }

      return PtyCoreUnix._(pid, ptm);
    }

    throw PtyException('unreachable');
  }

  PtyCoreUnix._(this._pid, this._ptm) {
    // final devname = unix.ptsname(_ptm);
    // _pts = unix.open(devname, consts.O_RDWR);
  }

  final int _pid;
  final int _ptm;
  // late final int _pts;

  static const _bufferSize = 81920;
  final _buffer = calloc<Int8>(_bufferSize + 1).address;

  @override
  Uint8List? read() {
    final buffer = Pointer.fromAddress(_buffer);
    final readlen = unix.read(_ptm, buffer.cast(), _bufferSize);

    if (readlen <= 0) {
      return null;
    }

    return buffer.cast<Uint8>().asTypedList(readlen);
  }

  @override
  int? exitCodeNonBlocking() {
    final statusPointer = calloc<Int32>();
    final pid = unix.waitpid(_pid, statusPointer, consts.WNOHANG);

    final status = statusPointer.value;
    calloc.free(statusPointer);

    if (pid == 0) {
      return null;
    }

    if ((status & 0x7F) != 0) {
      // killed by signal
      return 128 + (status & 0x7F);
    }
    return (status & 0xFF00) >> 8;
  }

  @override
  int exitCodeBlocking() {
    final statusPointer = calloc<Int32>();
    unix.waitpid(_pid, statusPointer, 0);

    final status = statusPointer.value;
    calloc.free(statusPointer);

    if ((status & 0x7F) != 0) {
      // killed by signal
      return 128 + (status & 0x7F);
    }
    return (status & 0xFF00) >> 8;
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    return unix.kill(_pid, consts.SIGKILL) == 0;
  }

  @override
  void resize(int width, int height) {
    final sz = calloc<winsize>();
    sz.ref.ws_col = width;
    sz.ref.ws_row = height;

    final ret = unix.ioctl(_ptm, consts.TIOCSWINSZ, sz.cast<Void>());
    calloc.free(sz);

    if (ret == -1) {
      // print(_ptm);
      // print(unix.errno.value);
      unix.perror(nullptr);
    }
  }

  // @override
  // int get pid {
  //   return _pid;
  // }

  @override
  void write(List<int> data) {
    final buf = calloc<Int8>(data.length);
    buf.asTypedList(data.length).setAll(0, data);
    unix.write(_ptm, buf.cast(), data.length);
    calloc.free(buf);
  }
}
