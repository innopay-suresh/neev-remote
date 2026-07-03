import 'dart:typed_data';

/// Web/no-op stub of [UacBridge]. UAC remote-control is a Windows-host-only
/// native feature; on web (and as a safe default) it does nothing.
class UacBridge {
  void Function(int w, int h, int kind)? onActive;
  void Function(Uint8List png)? onFrame;
  void Function()? onGone;

  bool get isSupported => false;
  bool get isConnected => false;

  void start() {}
  void sendClick(int button, double x, double y) {}
  void sendKey(int vk) {}
  void sendInput(Map<String, dynamic> e) {}

  /// Machine-wide credentials from the SYSTEM helper. Always null off Windows.
  Future<({String id, String password})?> fetchMachineCreds(
          {Duration timeout = const Duration(seconds: 4)}) async =>
      null;

  /// Set the machine-wide password. No-op off Windows.
  void setMachinePassword(String password) {}

  /// Type [text] into the focused field on the host. No-op off Windows.
  void sendTypeText(String text, {bool tab = false, bool enter = false}) {}

  void dispose() {}
}
