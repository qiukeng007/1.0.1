import 'dart:io' show Platform, File;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  if (Platform.isIOS) {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final cf = File('${dir.path}/pospal_cookie.txt');
      if (await cf.exists()) {
        final cookie = await cf.readAsString();
        if (cookie.isNotEmpty) {
          final prefs = await SharedPreferences.getInstance();
          final baseUrl = prefs.getString('login_base_url') ?? '';
          final account = prefs.getString('login_account') ?? '';
          final employee = prefs.getString('login_employee') ?? '';
          if (baseUrl.isNotEmpty && account.isNotEmpty && employee.isNotEmpty) {
            final fullUrl = 'https://${baseUrl.replaceAll('https://', '').replaceAll('http://', '')}';
            await prefs.setString('cookie_$fullUrl|$account|$employee', cookie);
            // Force sync to disk
            const syncCh = MethodChannel('com.smarteye/cookies_persist');
            await syncCh.invokeMethod('syncPrefs');
          }
        }
      }
    } catch (_) {}
  }
  
  runApp(const SmartEyeApp());
}
