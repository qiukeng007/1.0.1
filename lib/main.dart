import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  if (Platform.isIOS) {
    try {
      final prefs = await SharedPreferences.getInstance();
      final account = prefs.getString('login_account') ?? '';
      final employee = prefs.getString('login_employee') ?? '';
      if (account.isNotEmpty && employee.isNotEmpty) {
        const atomCh = MethodChannel('com.smarteye/cookies_persist');
        final ck = await atomCh.invokeMethod('loadAtomic', '$account|$employee');
        if (ck != null && (ck as String).isNotEmpty) {
          final baseUrl = prefs.getString('login_base_url') ?? '';
          if (baseUrl.isNotEmpty) {
            final fullUrl = 'https://${baseUrl.replaceAll('https://', '').replaceAll('http://', '')}';
            await prefs.setString('cookie_$fullUrl|$account|$employee', ck as String);
          }
        }
      }
    } catch (_) {}
  }
  
  runApp(const SmartEyeApp());
}
