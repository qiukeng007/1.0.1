import 'package:flutter/material.dart';
import 'utils/constants.dart';
import 'pages/home_page.dart';

class SmartEyeApp extends StatelessWidget {
  const SmartEyeApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: AppConstants.primaryColor,
        scaffoldBackgroundColor: AppConstants.bgColor,
        appBarTheme: const AppBarTheme(centerTitle: true, elevation: 0, scrolledUnderElevation: 1),
        cardTheme: CardThemeData(elevation: 1, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMd)), surfaceTintColor: Colors.transparent),
        inputDecorationTheme: InputDecorationTheme(border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSm)), contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12), isDense: true),
        elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSm)), padding: const EdgeInsets.symmetric(vertical: 14), textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(type: BottomNavigationBarType.fixed, selectedItemColor: AppConstants.primaryColor, unselectedItemColor: AppConstants.textSecondary),
      ),
      home: const _DebugOverlay(child: HomePage()),
    );
  }
// ------ FULL DEBUG PANEL ------
import 'dart:async';
import 'dart:io' show File;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'utils/constants.dart';

class _DebugOverlay extends StatefulWidget {
  final Widget child;
  const _DebugOverlay({required this.child});
  @override State<_DebugOverlay> createState() => _DebugOverlayState();
}
class _DebugOverlayState extends State<_DebugOverlay> {
  String _txt = 'loading...';
  Timer? _t;
  @override void initState() { super.initState(); _refresh(); _t = Timer.periodic(const Duration(seconds: 3), (_) => _refresh()); }
  @override void dispose() { _t?.cancel(); super.dispose(); }
  
  Future<void> _refresh() async {
    final sb = StringBuffer();
    try {
      final dir = await getApplicationDocumentsDirectory();
      final prefs = await SharedPreferences.getInstance();
      
      // Auth
      sb.writeln('auth=' + (prefs.getBool('sys_auth_v3') == true ? 'YES' : 'NO'));
      
      // Credentials
      final bu = prefs.getString('login_base_url') ?? '';
      final ac = prefs.getString('login_account') ?? '';
      final em = prefs.getString('login_employee') ?? '';
      sb.writeln('url=' + bu);
      sb.writeln('acct=' + ac + ' emp=' + em);
      final fullUrl = 'https://' + bu.replaceAll('https://', '').replaceAll('http://', '');
      final ckKey = 'cookie_$fullUrl|$ac|$em';
      final spCk = prefs.getString(ckKey);
      sb.writeln('SharedPrefs ck=' + (spCk != null ? 'len=' + spCk.length.toString() : 'NULL'));
      
      // Debug marker file
      final m = File('${dir.path}/cookie_debug.txt');
      if (await m.exists()) {
        sb.writeln('DEBUG=' + (await m.readAsString()));
      } else {
        sb.writeln('DEBUG=missing');
      }
      
      // Cookie file
      final f = File('${dir.path}/pospal_cookie.txt');
      if (await f.exists()) {
        final len = await f.length();
        final c = await f.readAsString();
        sb.writeln('CFILE len=' + len.toString() + ' first30=' + c.substring(0, c.length > 30 ? 30 : c.length));
      } else {
        sb.writeln('CFILE=missing');
      }
    } catch (e) {
      sb.writeln('ERR=' + e.toString());
    }
    if (mounted) setState(() => _txt = sb.toString());
  }
  
  @override Widget build(BuildContext ctx) => Stack(children: [
    widget.child,
    Positioned(bottom: 50, left: 4, right: 4,
      child: GestureDetector(
        onTap: _refresh,
        child: Container(padding: const EdgeInsets.all(6), decoration: BoxDecoration(color: const Color(0xDD000000), borderRadius: BorderRadius.circular(6)),
          child: Text(_txt, style: const TextStyle(fontSize: 10, color: Color(0xFF00FF00), fontFamily: 'monospace', height: 1.4)))))
  ]);
}

}