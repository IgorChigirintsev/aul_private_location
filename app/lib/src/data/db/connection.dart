import 'dart:io';

import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'queue_db.dart';

/// Opens the on-device offline-queue database (file-backed). Used by both the UI
/// isolate and the background service isolate; SQLite handles the shared file.
Future<QueueDatabase> openQueueDatabase() async {
  final dir = await getApplicationSupportDirectory();
  final file = File(p.join(dir.path, 'aul_queue.sqlite'));
  return QueueDatabase(NativeDatabase.createInBackground(file));
}
