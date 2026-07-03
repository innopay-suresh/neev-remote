// Conditional export: registry-based launch-at-login on desktop, no-op on web.
export 'startup_web.dart' if (dart.library.io) 'startup_io.dart';
