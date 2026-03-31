import 'package:pty/pty.dart';

void main() async {
  final pty = PseudoTerminal.start(
    'pwsh.exe',
    [],
    environment: {'codefu': '1234'},
    blocking: true,
  );

  pty.resize(120, 40);

  // pty.write('dir\r\n');
  pty.write('echo \$env:codefu\r\n');

  pty.out.listen((data) {
    print(data);
  });

  await Future.delayed(const Duration(seconds: 1));
  pty.kill();

  print(await pty.exitCode);
}
