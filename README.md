# pty

> [!WARNING]  
> Moved to https://github.com/jtmcdole/termui/tree/main/packages/pty2

Pty for Dart and Flutter. Provides the ability to create processes with pseudo terminal file descriptors.

## Status

I'm hacking to keep this working for my needs.

## Usage

A simple usage example:

```dart
import 'package:pty2/pty.dart';

void main() async {
  final pty = PseudoTerminal.start('bash', []);

  pty.write('ls\n');

  pty.out.listen((data) {
    print(data);
  });

  print(await pty.exitCode);
}
```
