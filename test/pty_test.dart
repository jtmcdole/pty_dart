import 'dart:io';

import 'package:pty2/pty.dart';
import 'package:test/test.dart';

void main() {
  test('Can instantiate and kill PseudoTerminal', () async {
    final pty = PseudoTerminal.start(_getShell(), [], blocking: true);
    pty.kill();
    await pty.exitCode;
  });

  test('Can read exit code', () async {
    final pty = PseudoTerminal.start(_getShell(), [], blocking: true);

    if (Platform.isWindows) {
      pty.write('exit 3\r\n');
    } else {
      pty.write('exit 3\r');
    }

    expect(await pty.exitCode, anyOf(0, 3));
  });

  test('echo test', () async {
    final pty = PseudoTerminal.start(_getShell(), [], blocking: true);

    if (Platform.isWindows) {
      pty.write('echo hello world\r\n');
      pty.write('exit 0\r\n');
    } else {
      pty.write('echo hello world\r');
      pty.write('exit 0\r');
    }

    final output = await pty.out.toList();
    final fullOutput = output.join('');

    expect(fullOutput, contains('hello world'));

    await pty.exitCode;
  });

  test('Polling - Can read exit code', () async {
    final pty = PseudoTerminal.start(_getShell(), [], blocking: false);

    if (Platform.isWindows) {
      pty.write('exit 3\r\n');
    } else {
      pty.write('exit 3\r');
    }

    expect(await pty.exitCode, anyOf(0, 3));
  });

  test('Resize terminal', () async {
    final pty = PseudoTerminal.start(_getShell(), [], blocking: true);
    pty.resize(100, 100);
    pty.kill();
    await pty.exitCode;
  });

  test('Execve failure path', () async {
    final pty = PseudoTerminal.start(
      'invalid_non_existent_executable',
      [],
      blocking: true,
    );
    expect(await pty.exitCode, anyOf(0, 1));
  });
}

String _getShell() {
  if (Platform.isWindows) {
    return 'cmd';
  }
  return 'sh';
}
