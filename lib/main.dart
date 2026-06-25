import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io' show File;
import 'package:path_provider/path_provider.dart';
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
    // Read from FILE first (NSUserDefaults may not flush on iOS force-quit)
    final dir = await getApplicationDocumentsDirectory();
    final cf = File('${dir.path}/pospal_cookie.txt');
    String? cookie;
    if (await cf.exists()) {
      cookie = await cf.readAsString();
    }

    // Fallback to SharedPreferences
    if (cookie == null || cookie.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      final baseUrl = prefs.getString('login_base_url') ?? '';
      final account = prefs.getString('login_account') ?? '';
      final employee = prefs.getString('login_employee') ?? '';
      if (baseUrl.isNotEmpty && account.isNotEmpty && employee.isNotEmpty) {
        final fullUrl = 'https://${baseUrl.replaceAll('https://', '').replaceAll('http://', '')}';
        final storeKey = 'cookie_$fullUrl|$account|$employee';
        cookie = prefs.getString(storeKey);
        // If found in prefs, also write to file for future reliability
        if (cookie != null && cookie.isNotEmpty) {
          try { await cf.writeAsString(cookie, flush: true); } catch (_) {}
        }
      }
    }

    // Restore to WKHTTPCookieStore
    if (cookie != null && cookie.isNotEmpty) {
      try {
        const persistCh = MethodChannel('com.smarteye/cookies_persist');
        await persistCh.invokeMethod('restoreCookies', cookie);
      } catch (_) {}
      // Also ensure SharedPreferences has it (for other code to find)
      try {
        final prefs = await SharedPreferences.getInstance();
        final baseUrl = prefs.getString('login_base_url') ?? '';
        final account = prefs.getString('login_account') ?? '';
        final employee = prefs.getString('login_employee') ?? '';
        if (baseUrl.isNotEmpty && account.isNotEmpty && employee.isNotEmpty) {
          final fullUrl = 'https://${baseUrl.replaceAll('https://', '').replaceAll('http://', '')}';
          final storeKey = 'cookie_$fullUrl|$account|$employee';
          await prefs.setString(storeKey, cookie);
        }
      } catch (_) {}
    }
  } catch (_) {}
}
