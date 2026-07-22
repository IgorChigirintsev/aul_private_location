import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app.dart';
// Imported so the background-isolate entrypoint (aulLocationServiceMain) is
// compiled into the app and discoverable by the native LocationService.
import 'src/platform/background_service.dart';

// Ensure the background entrypoint is retained (vm:entry-point + this reference).
// ignore: unused_element
final _keepEntrypoint = aulLocationServiceMain;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: AulApp()));
}
