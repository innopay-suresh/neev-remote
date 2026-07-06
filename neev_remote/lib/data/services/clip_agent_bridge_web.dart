/// Web/no-op stub — the user-context clipboard agent is a Windows-host feature.
class ClipAgentBridge {
  bool get supported => false;
  Future<List<String>?> readFiles() async => null;
  Future<bool> writeFiles(List<String> paths) async => false;
}
