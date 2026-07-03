import 'package:flutter/foundation.dart' show kIsWeb;

import '../window_manager.dart';

/// Initializes desktop window state. Window sizing is handled by
/// [initWindowManager]; on web this is a no-op.
Future<void> initializeApp() async {
  if (kIsWeb) return;
  await initWindowManager();
}
