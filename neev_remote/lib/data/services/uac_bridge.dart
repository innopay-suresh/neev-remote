// Platform-switched UAC bridge: the real localhost-TCP client on native
// (Windows host), a no-op stub on web. Importers just use `UacBridge`.
export 'uac_bridge_web.dart' if (dart.library.io) 'uac_bridge_io.dart';
