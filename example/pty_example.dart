import 'package:pty/pty.dart';

void main() async {
  // final pty = PseudoTerminal.start('pwsh.exe', [
  //   '-ExecutionPolicy',
  //   'Bypass',
  //   '-File',
  //   r'C:\Users\john\AppData\Roaming\npm\gemini.ps1',
  // ]);

  final pty = PseudoTerminal.start(
    r'C:\Program Files\PowerShell\7\pwsh.exe',
    [],
  );
  pty.out.listen(
    (data) {
      print('hmmm: $data');
    },
    onDone: () {
      print('done');
    },
    onError: (e) {
      print('sup, err? $e');
    },
  );

  pty.write('dir\r\n');

  await Future.delayed(Duration(seconds: 5));

  print((await pty.exitCode).toRadixString(16));
}
