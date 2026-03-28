import 'package:pty/pty.dart';

void main() async {
  final pty = PseudoTerminal.start('cmd', []);

  pty.write('dir\r\n');

  pty.out.listen((data) {
    print(String.fromCharCodes(data));
  });

  await Future.delayed(const Duration(seconds: 1));
  pty.kill();

  print(await pty.exitCode);
}
