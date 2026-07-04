import 'dart:io';

import 'package:pty2/src/impl/unix.dart';
import 'package:pty2/src/impl/windows.dart';
import 'package:pty2/src/pty.dart';
import 'package:pty2/src/pty_core.dart';

export 'src/pty.dart';

abstract class PseudoTerminal {
  /// Internal testing flag to allow non-blocking PTY on Windows.
  /// If [blocking] is [true], the PseudoTerminal starts in blocking mode
  /// (better suited for flutter release mode), otherwise in polling mode
  /// (better suited for flutter debug mode).
  ///
  /// The [raw] flag puts the terminal into raw mode on Unix. By default, Unix
  /// pseudo-terminals operate in canonical mode with ECHO enabled. This means
  /// the kernel buffers input line-by-line and physically echoes characters back.
  /// If you are transferring binary data, streaming high-throughput buffers, or
  /// do not want the kernel to mangle line endings and echo data, set [raw] to true.
  static PseudoTerminal start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool ackProcessed = false,
    bool raw = false,
    // bool includeParentEnvironment = true,
    // bool runInShell = false,
    // ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    late PtyCore core;

    if (Platform.isWindows) {
      core = PtyCoreWindows.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
      );
    } else {
      //add '-l' as argument for the shell to perform a login
      arguments = List<String>.generate(
        arguments.length + 1,
        (index) => index == 0 ? '-l' : arguments[index - 1],
      );

      core = PtyCoreUnix.start(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        raw: raw,
      );
    }

    return BlockingPseudoTerminal(core, ackProcessed)..init();
  }

  void init();
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]);

  Future<int> get exitCode;

  // int get pid {
  //   return _core.pid;
  // }

  void write(String input);

  Stream<String> get out;

  void ackProcessed();

  void resize(int width, int height);
}
