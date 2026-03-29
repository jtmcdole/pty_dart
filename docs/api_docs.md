# Pty Library API Reference

This document lists the public API for the `pty` library.

## PseudoTerminal (abstract class)

The main interface for interacting with a pseudo-terminal.

### Static Methods

#### `PseudoTerminal.start`
```dart
static PseudoTerminal start(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool blocking = false,
  bool ackProcessed = false,
})
```
Starts a new PseudoTerminal process.
- `executable`: The path to the executable to run.
- `arguments`: The arguments to pass to the executable.
- `workingDirectory`: The working directory for the process.
- `environment`: Environment variables for the process.
- `blocking`: If `true`, the PseudoTerminal starts in blocking mode (better suited for flutter release mode), otherwise in polling mode (better suited for flutter debug mode).
- `ackProcessed`: If `true`, requires manual acknowledgment of processed data via `ackProcessed()`.

### Methods

#### `init`
```dart
void init()
```
Initializes the pseudo-terminal. This is called automatically by `PseudoTerminal.start`.

#### `kill`
```dart
bool kill([ProcessSignal signal = ProcessSignal.sigterm])
```
Kills the pseudo-terminal process.

#### `write`
```dart
void write(String input)
```
Writes a string to the pseudo-terminal input.

#### `ackProcessed`
```dart
void ackProcessed()
```
Acknowledges that the last received data has been processed. Only relevant if `ackProcessed` was set to `true` in `start()`.

#### `resize`
```dart
void resize(int width, int height)
```
Resizes the pseudo-terminal window.

### Getters

#### `exitCode`
```dart
Future<int> get exitCode
```
Returns a future that completes with the exit code of the process.

#### `out`
```dart
Stream<String> get out
```
A stream of output from the pseudo-terminal.

---

## BasePseudoTerminal (abstract class)

An abstract base class for `PseudoTerminal` implementations.

---

## PollingPseudoTerminal (class)

A polling-based `PseudoTerminal` implementation. Mainly used in Flutter debug mode to make hot reload work. The underlying `PtyCore` must be non-blocking.

---

## BlockingPseudoTerminal (class)

An isolate-based `PseudoTerminal` implementation. Performs better than `PollingPseudoTerminal` and requires fewer resources. However, this prevents Flutter hot reload from working. Ideal for release builds. The underlying `PtyCore` must be blocking.
