import 'dart:async';
import 'dart:io' show HttpClient, Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../utils/constants.dart';
import '../services/store_service.dart';

class LoginPage extends StatefulWidget {
  final String baseUrl;
  final String account;
  final String cashierJobNumber;
  final String password;

  const LoginPage({
    super.key,
    this.baseUrl = 'https://beta28.pospal.cn',
    this.account = '',
    this.cashierJobNumber = '',
    this.password = '',
  });

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final WebViewController _controller;
  bool _loading = true;
  bool _formReady = false;
  bool _loggedIn = false;
  Timer? _pollTimer;
  Timer? _urlPollTimer;

  static String get _userAgent {
    if (Platform.isIOS) {
      return 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
    }
    return 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
  }

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_userAgent)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          debugPrint('🔀 WebView nav: ${request.url}');
          return NavigationDecision.navigate;
        },
        onPageFinished: (url) {
          setState(() => _loading = false);
          debugPrint('📄 Page finished: $url');

          // Success: redirected to target page
          if (url.contains('/Product/Manage') || url.contains('/Home')) {
            _stopPolling();
            _onLoginSuccess();
            return;
          }

          // On signin/login page — inject auto-fill
          if (url.contains('signin') || url.contains('login') || url.contains('account')) {
            _injectAutoFill();
            if (!_formReady) {
              _formReady = true;
              Future.delayed(const Duration(seconds: 5), () {
                if (mounted && !_loggedIn) _startPolling();
              });
            }
          }
        },
        onWebResourceError: (error) {
          debugPrint('❌ WebView error: ${error.description}');
        },
      ))
      ..loadRequest(Uri.parse(
        '${widget.baseUrl}/account/signin?ReturnUrl=%2fProduct%2fManage',
      ));
  }

  // ---- Polling ----

  void _startPolling() {
    // Check cookies every 4s
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (_loggedIn) return;
      try {
        const channel = MethodChannel('com.smarteye/cookies');
        final cookieStr = await channel.invokeMethod('getCookies', {
          'url': widget.baseUrl,
        }) as String? ?? '';
        if (cookieStr.isNotEmpty) {
          _stopPolling();
          _onLoginSuccess();
        }
      } catch (_) {}
    });

    // Check URL every 3s
    _urlPollTimer?.cancel();
    _urlPollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_loggedIn) return;
      try {
        final currentUrl = await _controller.currentUrl();
        if (currentUrl != null && (currentUrl.contains('/Product/Manage') || currentUrl.contains('/Home'))) {
          _stopPolling();
          _onLoginSuccess();
        }
      } catch (_) {}
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _urlPollTimer?.cancel();
    _urlPollTimer = null;
  }

  @override
  void dispose() {
    _stopPolling();
    super.dispose();
  }

  // ---- Form auto-fill ----

  Future<void> _injectAutoFill() async {
    if (_loggedIn) return;

    await _controller.runJavaScript('''
      (function() {
        // Switch to employee login tab
        var empTab = document.querySelector('span[data-type="2"]');
        if (empTab) empTab.click();

        setTimeout(function() {
          // Fill employee number
          var jobInput = document.getElementById('txt_cashierJobName');
          if (jobInput) {
            jobInput.value = '${widget.cashierJobNumber}';
            jobInput.dispatchEvent(new Event('input', { bubbles: true }));
            jobInput.dispatchEvent(new Event('change', { bubbles: true }));
          }

          // Fill password
          var pwInputs = document.querySelectorAll('input[type="password"]');
          for (var i = 0; i < pwInputs.length; i++) {
            pwInputs[i].value = '${widget.password}';
            pwInputs[i].dispatchEvent(new Event('input', { bubbles: true }));
            pwInputs[i].dispatchEvent(new Event('change', { bubbles: true }));
          }

          // Fill account
          var accInput = document.getElementById('txt_userName') || document.querySelector('input[placeholder*="账号"]');
          if (accInput) {
            accInput.value = '${widget.account}';
            accInput.dispatchEvent(new Event('input', { bubbles: true }));
            accInput.dispatchEvent(new Event('change', { bubbles: true }));
          }

          // Click submit
          setTimeout(function() {
            var btn = document.querySelector('button[type="submit"]')
              || document.querySelector('input[type="submit"]')
              || document.querySelector('button.btn-primary')
              || document.querySelector('a.btn-primary')
              || document.querySelector('button[class*="login"]')
              || document.querySelector('button[class*="submit"]')
              || document.querySelector('a[class*="login"]');
            if (btn) {
              btn.click();
            } else {
              var forms = document.querySelectorAll('form');
              for (var f = 0; f < forms.length; f++) {
                try { forms[f].submit(); } catch(e) {}
              }
            }
          }, 400);
        }, 500);
      })();
    ''');
  }

  // ---- Login success ----

  Future<void> _onLoginSuccess() async {
    if (_loggedIn) return;
    _loggedIn = true;

    try {
      await Future.delayed(const Duration(seconds: 1));

      // Collect from WKWebView native cookie store + JS document.cookie
      String nativeCookies = '';
      String jsCookies = '';
      try {
        const channel = MethodChannel('com.smarteye/cookies');
        nativeCookies = await channel.invokeMethod('getCookies', {
          'url': widget.baseUrl,
        }) as String? ?? '';
      } catch (_) {}
      try {
        jsCookies = await _controller.runJavaScriptReturningResult('document.cookie') as String? ?? '';
      } catch (_) {}

      // Merge and deduplicate
      final merged = <String, String>{};
      for (final src in [nativeCookies, jsCookies]) {
        for (final part in src.split(';')) {
          final trimmed = part.trim();
          final eq = trimmed.indexOf('=');
          if (eq > 0) {
            final name = trimmed.substring(0, eq).trim();
            final value = trimmed.substring(eq + 1).trim();
            if (name.isNotEmpty && value.isNotEmpty) {
              merged[name] = value;
            }
          }
        }
      }
      final cookieStr = merged.entries.map((e) => '${e.key}=${e.value}').join('; ');

      if (cookieStr.isEmpty) {
        debugPrint('⚠️ No cookies captured');
        if (mounted) Navigator.of(context).pop(true);
        return;
      }

      // Save
      final prefs = await SharedPreferences.getInstance();
      final storeKey = '${widget.baseUrl}|${widget.account}|${widget.cashierJobNumber}';
      await prefs.setString('cookie_$storeKey', cookieStr);

      // iOS: sync WKWebView → NSHTTPCookieStorage
      int syncedCount = 0;
      if (Platform.isIOS) {
        try {
          const channel = MethodChannel('com.smarteye/cookies');
          final count = await channel.invokeMethod('syncToShared');
          syncedCount = (count is int) ? count : 0;
        } catch (_) {}
      }

      // Validate WITHOUT manual Cookie header — let NSURLSession use
      // the synced NSHTTPCookieStorage cookies automatically.
      String validateMsg = '';
      try {
        final client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 8);
        final req = await client.getUrl(Uri.parse('${widget.baseUrl}/Product/Manage'));
        // DON'T set Cookie header — use synced NSHTTPCookieStorage
        req.followRedirects = false;
        final resp = await req.close();
        final loc = resp.headers.value('location') ?? '';
        client.close();

        if (loc.contains('signin') || loc.contains('login')) {
          validateMsg = '⚠️ Cookie验证失败！同步${syncedCount}个，重定向到登录页';
        } else if (resp.statusCode == 200) {
          validateMsg = '✅ Cookie验证通过 (同步${syncedCount}个)';
        } else {
          validateMsg = '状态:${resp.statusCode} 同步:${syncedCount}';
        }
      } catch (e) {
        validateMsg = '异常:$e 同步:${syncedCount}';
      }

      // Fetch stores
      try {
        final stores = await StoreService.fetchStores(
          baseUrl: widget.baseUrl,
          cookie: cookieStr,
        );
        if (stores.isNotEmpty) {
          await StoreService.saveStores(widget.baseUrl, stores);
        }
      } catch (_) {}

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(validateMsg.isEmpty ? '登录成功！' : '登录成功！$validateMsg'),
            backgroundColor: validateMsg.contains('失败') ? Colors.orange : AppConstants.successColor,
            duration: Duration(seconds: validateMsg.contains('失败') ? 5 : 2),
          ),
        );
        Navigator.of(context).pop(true);
      }
    } catch (_) {
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppConstants.bgColor,
      appBar: AppBar(
        title: const Text('员工登录', style: TextStyle(fontSize: 16)),
        actions: [
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            color: AppConstants.primaryColor.withValues(alpha: 0.05),
            child: Column(
              children: [
                if (!_formReady)
                  const Text('⏳ 正在加载登录页…', style: TextStyle(fontSize: 13, color: AppConstants.textSecondary))
                else
                  const Text('🔐 正在自动填写并提交登录…', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppConstants.primaryColor)),
              ],
            ),
          ),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
