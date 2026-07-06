// Conditional export: real TCP client on desktop (dart:io), no-op on web.
export 'clip_agent_bridge_web.dart'
    if (dart.library.io) 'clip_agent_bridge_io.dart';
