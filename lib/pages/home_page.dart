import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/constants.dart';
import '../services/auth_service.dart';
import 'camera_page.dart';
import 'records_page.dart';
import 'operation_logs_page.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _currentIndex = 0;
  final _settingsKey = GlobalKey<SettingsPageState>();
  final _logsKey = GlobalKey<OperationLogsPageState>();
  final _cameraKey = GlobalKey<CameraPageState>();
  bool _authChecked = false;
  bool _authDialogShowing = false;

  late final _pages = <Widget>[
    CameraPage(key: _cameraKey),
    const RecordsPage(),
    OperationLogsPage(key: _logsKey),
    SettingsPage(key: _settingsKey),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkAuth());
  }

  Future<void> _checkAuth() async {
    final prefs = await SharedPreferences.getInstance();
    final auth = AuthService(prefs);

    while (mounted && !auth.isAuthorized) {
      var serverUrl = AuthService.normalizeUrl(prefs.getString('server_url') ?? '');

      // First time or server cleared: show setup dialog
      if (serverUrl.isEmpty || serverUrl == 'http://') {
        _authDialogShowing = true;
        await _showSetupDialog(prefs, auth);
        _authDialogShowing = false;
        // Check if setup completed
        if (auth.isAuthorized) break;
        // User might have dismissed or failed — reload prefs and retry
        continue;
      }

      // Check if password changed
      final needAuth = await auth.needReAuth(serverUrl);
      if (!needAuth) break; // already authorized

      _authDialogShowing = true;
      await _showAuthDialog(auth, serverUrl);
      _authDialogShowing = false;
      if (auth.isAuthorized) break;
    }
    if (mounted) setState(() => _authChecked = true);
  }

  /// First-launch: configure server URL + verify password
  Future<void> _showSetupDialog(SharedPreferences prefs, AuthService auth) async {
    final urlCtrl = TextEditingController();
    final pwdCtrl = TextEditingController();

    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) {
          String status = '';
          bool checking = false;
          return AlertDialog(
            title: const Text('首次配置'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('请填写服务器地址：', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 8),
                TextField(
                  controller: urlCtrl,
                  decoration: const InputDecoration(
                    hintText: '如 http://192.168.1.138',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 16),
                const Text('请输入授权码：', style: TextStyle(fontSize: 13)),
                const SizedBox(height: 8),
                TextField(
                  controller: pwdCtrl,
                  obscureText: true,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    hintText: '请输入授权码',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                if (status.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(status, style: TextStyle(fontSize: 12, color: checking ? Colors.orange : Colors.green)),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () async {
                  final url = urlCtrl.text.trim();
                  if (url.isEmpty) {
                    setSt(() { status = '请填写服务器地址'; checking = false; });
                    return;
                  }
                  setSt(() { status = '正在连接...'; checking = true; });
                  final remotePwd = await auth.fetchRemotePassword(url);
                  if (remotePwd.isNotEmpty) {
                    if (pwdCtrl.text.trim() == remotePwd) {
                      final normalizedUrl = AuthService.normalizeUrl(url);
                      await prefs.setString('server_url', normalizedUrl);
                      await auth.authorize(normalizedUrl);
                      Navigator.pop(ctx);
                    } else {
                      setSt(() { status = '授权码错误'; checking = false; });
                    }
                  } else {
                    setSt(() { status = '无法连接服务器，请检查地址'; checking = false; });
                  }
                },
                child: const Text('验证并保存'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showAuthDialog(AuthService auth, String serverUrl) async {
    final pwdCtrl = TextEditingController();
    final remotePwd = await auth.fetchRemotePassword(serverUrl);
    final useFallback = remotePwd.isEmpty;
    final effectivePwd = useFallback ? '21771737' : remotePwd;

    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('系统安全验证'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(useFallback ? Icons.close : Icons.check_circle,
                  size: 16, color: useFallback ? Colors.red : Colors.green),
              const SizedBox(width: 6),
              Text(useFallback ? '无法连接服务器，使用默认密码' : '服务器连接成功',
                  style: TextStyle(fontSize: 13, color: useFallback ? Colors.red : Colors.green)),
            ]),
            const SizedBox(height: 12),
            const Text('请输入授权码：', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 12),
            TextField(
              controller: pwdCtrl,
              obscureText: true,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: '请输入授权码',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) {
                if (v.trim() == effectivePwd) { Navigator.pop(ctx); }
                else { ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('授权码错误'), backgroundColor: Colors.red)); }
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              final p = await SharedPreferences.getInstance();
              await p.remove('server_url');
              await auth.clearAuth();
              Navigator.pop(ctx);
            },
            child: const Text('更换服务器', style: TextStyle(color: AppConstants.textSecondary)),
          ),
          TextButton(
            onPressed: () {
              if (pwdCtrl.text.trim() == effectivePwd) { Navigator.pop(ctx); }
              else { ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('授权码错误'), backgroundColor: Colors.red)); }
            },
            child: const Text('验证'),
          ),
        ],
      ),
    );
    if (mounted) await auth.authorize(serverUrl);
  }

  @override
  Widget build(BuildContext context) {
    if (!_authChecked) {
      return const Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.lock_outline, size: 48, color: AppConstants.textSecondary),
            SizedBox(height: 16),
            Text('正在验证授权…', style: TextStyle(fontSize: 16, color: AppConstants.textSecondary)),
          ]),
        ),
      );
    }
    return Scaffold(
      body: IndexedStack(index: _currentIndex, children: _pages),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        type: BottomNavigationBarType.fixed,
        onTap: (i) {
          setState(() => _currentIndex = i);
          if (i == 0) _cameraKey.currentState?.onTabSelected();
          if (i == 2) _logsKey.currentState?.refresh();
          if (i == 3) _settingsKey.currentState?.onTabSelected();
        },
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.camera_alt_outlined), activeIcon: Icon(Icons.camera_alt), label: '入库'),
          BottomNavigationBarItem(icon: Icon(Icons.inventory_2_outlined), activeIcon: Icon(Icons.inventory_2), label: '库存明细'),
          BottomNavigationBarItem(icon: Icon(Icons.receipt_long_outlined), activeIcon: Icon(Icons.receipt_long), label: '记录'),
          BottomNavigationBarItem(icon: Icon(Icons.settings_outlined), activeIcon: Icon(Icons.settings), label: '配置'),
        ],
      ),
    );
  }
}
