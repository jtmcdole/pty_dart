import 'package:pty/pty.dart';

void main() async {
  // final pty = PseudoTerminal.start('pwsh.exe', [
  //   '-ExecutionPolicy',
  //   'Bypass',
  //   '-File',
  //   r'C:\Users\john\AppData\Roaming\npm\gemini.ps1',
  // ]);

  final pty = PseudoTerminal.start('cmd.exe', []);
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

  await Future.delayed(Duration(seconds: 5));

  print((await pty.exitCode).toRadixString(16));
}
