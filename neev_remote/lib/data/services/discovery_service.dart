// Platform-switched LAN discovery: real UDP broadcast on desktop, no-op on web.
export 'discovery_model.dart';
export 'discovery_service_web.dart'
    if (dart.library.io) 'discovery_service_io.dart';
