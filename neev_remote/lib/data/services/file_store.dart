// Conditional export: real disk-writing store on desktop (dart:io), no-op on web.
export 'file_store_web.dart' if (dart.library.io) 'file_store_io.dart';
