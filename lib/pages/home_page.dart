import 'package:flutter/material.dart';
import '../utils/constants.dart';
import 'camera_page.dart';
import 'records_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;
  final _settingsKey = GlobalKey<SettingsPageState>();

  late final _pages = <Widget>[
    const CameraPage(),
    const RecordsPage(),
    SettingsPage(key: _settingsKey),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (i) {
          setState(() => _currentIndex = i);
          if (i == 2) _settingsKey.currentState?.onTabSelected();
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.camera_alt_outlined), activeIcon: Icon(Icons.camera_alt), label: '入库'),
          BottomNavigationBarItem(icon: Icon(Icons.receipt_long_outlined), activeIcon: Icon(Icons.receipt_long), label: '记录'),
          BottomNavigationBarItem(icon: Icon(Icons.settings_outlined), activeIcon: Icon(Icons.settings), label: '配置'),
        ],
      ),
    );
  }
}
