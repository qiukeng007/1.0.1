import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Restore cookies on iOS before app launches
  if (Platform.isIOS) {
    await _restoreCookies();
  }
  
  runApp(const SmartEyeApp());
}

Future<void> _restoreCookies() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final baseUrl = prefs.getString('login_base_url') ?? '';
    final account = prefs.getString('login_account') ?? '';
    final employee = prefs.getString('login_employee') ?? '';
    if (baseUrl.isEmpty || account.isEmpty || employee.isEmpty) return;
    
    final fullUrl = 'https://${baseUrl.replaceAll('https://', '').replaceAll('http://', '')}';
    final storeKey = 'cookie_$fullUrl|$account|$employee';
    final cookie = prefs.getString(storeKey);
    
    if (cookie != null && cookie.isNotEmpty) {
      try {
        const persistCh = MethodChannel('com.smarteye/cookies_persist');
        await persistCh.invokeMethod('restoreCookies', cookie);
      } catch (_) {}
    }
  } catch (_) {}
}
