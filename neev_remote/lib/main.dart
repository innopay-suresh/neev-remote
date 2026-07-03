import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'window_manager.dart' show initWindowManager;
import 'presentation/pages/connect_page.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initWindowManager();
  runApp(const ProviderScope(child: NeevRemoteApp()));
}

class NeevRemoteApp extends StatelessWidget {
  const NeevRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Neev Remote',
      debugShowCheckedModeBanner: false,
      theme: lightTheme(),
      home: const ConnectPage(),
    );
  }
}
