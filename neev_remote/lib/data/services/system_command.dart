// Conditional export: real process-based reboot on desktop, no-op on web.
export 'system_command_web.dart'
    if (dart.library.io) 'system_command_io.dart';
