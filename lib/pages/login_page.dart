import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
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

class _LoginPageState extends State<LoginPage> with WidgetsBindingObserver {
  late final WebViewController _controller;
  bool _loading = true;
  bool _qrReady = false;
  bool _loggedIn = false;
  bool _reloading = false;
  Timer? _pollTimer;
  Timer? _urlPollTimer;

  /// Platform-aware User-Agent — critical for WeChat OAuth redirect compatibility.
  /// iOS WKWebView must NOT pretend to be Android Chrome, or WeChat's JS bridge
  /// will use Android-specific redirect methods that fail silently on WKWebView.
  static String get _userAgent {
    if (Platform.isIOS) {
      return 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
    }
    return 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_userAgent)
      ..addJavaScriptChannel('SmartEyeChannel',
        onMessageReceived: _onPageMessage,
      )
      ..setNavigationDelegate(NavigationDelegate(
        // Log every navigation request for debugging WeChat OAuth redirects
        onNavigationRequest: (request) {
          debugPrint('🔀 WebView nav: ${request.url}');
          return NavigationDecision.navigate;
        },
        onPageFinished: (url) {
          setState(() => _loading = false);
          debugPrint('📄 Page finished: $url');
          if (url.contains('/Product/Manage')) {
            _stopPolling();
            _onLoginSuccess();
          } else if (url.contains('signin') || url.contains('login') || url.contains('account')) {
            _injectAutoFill();
            if (!_qrReady) {
              _qrReady = true;
              Future.delayed(const Duration(seconds: 10), () {
                if (mounted && !_loggedIn) _startPolling();
              });
            }
          }
        },
        onWebResourceError: (error) {
          debugPrint('❌ WebView error: ${error.description} (${error.url})');
        },
      ))
      ..loadRequest(Uri.parse(
        '${widget.baseUrl}/account/signin?ReturnUrl=%2fProduct%2fManage',
      ));
  }

  /// Receives messages from JavaScript via SmartEyeChannel.
  /// The injected JS reports page state changes (URL, DOM mutations, etc.)
  void _onPageMessage(JavaScriptMessage msg) {
    final text = msg.message;
    debugPrint('📨 JS channel: $text');
    if (_loggedIn) return;

    // URL changed to target page
    if (text.startsWith('url:')) {
      final url = text.substring(4);
      if (url.contains('/Product/Manage')) {
        _stopPolling();
        _onLoginSuccess();
        return;
      }
      // Login form disappeared = likely redirected
      if (!url.contains('signin') && !url.contains('login') && !url.contains('account')) {
        debugPrint('⚠️ URL left signin page: $url — checking cookies');
        _checkCookiesAndLogin();
      }
    }

    // Page reported a redirect was attempted
    if (text == 'redirect_attempted') {
      debugPrint('⚠️ Page reports redirect attempt — checking state');
      _checkCookiesAndLogin();
    }

    // QR code disappeared from DOM
    if (text == 'qr_div_gone') {
      debugPrint('⚠️ QR code div disappeared — checking login state');
      _checkCookiesAndLogin();
    }
  }

  /// Quick check: if we have cookies or are on the right page, login.
  Future<void> _checkCookiesAndLogin() async {
    if (_loggedIn) return;
    try {
      const channel = MethodChannel('com.smarteye/cookies');
      final cookieStr = await channel.invokeMethod('getCookies', {
        'url': widget.baseUrl,
      }) as String? ?? '';
      if (cookieStr.isNotEmpty) {
        _stopPolling();
        _onLoginSuccess();
        return;
      }
      final currentUrl = await _controller.currentUrl();
      if (currentUrl != null && currentUrl.contains('/Product/Manage')) {
        _stopPolling();
        _onLoginSuccess();
      }
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _qrReady && !_loggedIn && mounted) {
      debugPrint('🔄 App resumed — triggering page reload to recover from possible stuck state');
      _reloadPage();
    }
  }

  /// Recovery: tries multiple strategies to detect a completed login.
  /// 1. Check if session cookie already exists (native check)
  /// 2. Navigate directly to /Product/Manage (if server already authenticated)
  /// 3. Reload the signin page (server may redirect to Product/Manage)
  Future<void> _reloadPage() async {
    if (_reloading || _loggedIn) return;
    _reloading = true;
    try {
      // Strategy 1: Check cookies
      const channel = MethodChannel('com.smarteye/cookies');
      final cookieStr = await channel.invokeMethod('getCookies', {
        'url': widget.baseUrl,
      }) as String? ?? '';
      if (cookieStr.isNotEmpty) {
        _onLoginSuccess();
        _reloading = false;
        return;
      }

      // Strategy 2: Navigate directly to target page.
      // If the server-side QR session was confirmed, this should work.
      final currentUrl = await _controller.currentUrl();
      if (currentUrl != null && currentUrl.contains('/Product/Manage')) {
        _onLoginSuccess();
        _reloading = false;
        return;
      }
      debugPrint('🔄 Recovery: navigating directly to /Product/Manage');
      await _controller.loadRequest(Uri.parse('${widget.baseUrl}/Product/Manage'));

      // Wait 3 seconds for the page to load, then check
      await Future.delayed(const Duration(seconds: 3));
      final newUrl = await _controller.currentUrl();
      if (newUrl != null && newUrl.contains('/Product/Manage')) {
        _onLoginSuccess();
        _reloading = false;
        return;
      }

      // Strategy 3: Reload the signin page
      debugPrint('🔄 Recovery: reloading signin page');
      await _controller.loadRequest(Uri.parse(
        '${widget.baseUrl}/account/signin?ReturnUrl=%2fProduct%2fManage',
      ));
    } catch (_) {
      try {
        await _controller.loadRequest(Uri.parse(
          '${widget.baseUrl}/account/signin?ReturnUrl=%2fProduct%2fManage',
        ));
      } catch (_) {}
    }
    _reloading = false;
    setState(() {});
  }

  void _startPolling() {
    // Polling strategy 1: Native cookie check (every 4s)
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

    // Polling strategy 2: URL-based polling (every 3s)
    _urlPollTimer?.cancel();
    _urlPollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_loggedIn) return;
      try {
        final currentUrl = await _controller.currentUrl();
        if (currentUrl != null && currentUrl.contains('/Product/Manage')) {
          _stopPolling();
          _onLoginSuccess();
        }
      } catch (_) {}
    });

    // Polling strategy 3: Dart HTTP probe (every 15s).
    // Makes a direct HTTP request to /Product/Manage with WebView cookies.
    // This bypasses WebView JavaScript entirely — if the server has
    // authenticated the session, we detect it even if the page is stuck.
    _startHttpProbing();
  }

  Timer? _httpProbeTimer;
  int _httpProbeCount = 0;

  void _startHttpProbing() {
    _httpProbeTimer?.cancel();
    _httpProbeTimer = Timer.periodic(const Duration(seconds: 15), (_) async {
      if (_loggedIn) return;
      _httpProbeCount++;
      try {
        // Get cookies from WKWebView's cookie store
        const channel = MethodChannel('com.smarteye/cookies');
        final cookieStr = await channel.invokeMethod('getCookies', {
          'url': widget.baseUrl,
        }) as String? ?? '';

        // Probe the target page directly via HTTP
        final response = await http.get(
          Uri.parse('${widget.baseUrl}/Product/Manage'),
          headers: {
            'User-Agent': _userAgent,
            if (cookieStr.isNotEmpty) 'Cookie': cookieStr,
          },
        ).timeout(const Duration(seconds: 8));

        debugPrint('🔍 HTTP probe #$_httpProbeCount: status=${response.statusCode}, '
            'redirects=${response.request?.url}, cookies=$cookieStr');

        // If we get 200 AND not redirected to signin, we're authenticated
        final finalUrl = response.request?.url.toString() ?? '';
        if (response.statusCode == 200 && !finalUrl.contains('signin') && !finalUrl.contains('login')) {
          debugPrint('✅ HTTP probe: server says authenticated!');
          _stopPolling();
          _onLoginSuccess();
          return;
        }

        // Check if response set any cookies — capture them
        final setCookie = response.headers['set-cookie'];
        if (setCookie != null && setCookie.isNotEmpty) {
          debugPrint('🍪 HTTP probe: server set cookies: $setCookie');
          // Store these cookies combined with existing ones
          final combined = cookieStr.isNotEmpty
              ? '$cookieStr; $setCookie'
              : setCookie;
          if (combined.isNotEmpty) {
            final prefs = await SharedPreferences.getInstance();
            final storeKey = '${widget.baseUrl}|${widget.account}|${widget.cashierJobNumber}';
            await prefs.setString('cookie_$storeKey', combined);
            _stopPolling();
            _onLoginSuccess();
          }
        }
      } catch (e) {
        debugPrint('❌ HTTP probe error: $e');
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _urlPollTimer?.cancel();
    _urlPollTimer = null;
    _httpProbeTimer?.cancel();
    _httpProbeTimer = null;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPolling();
    super.dispose();
  }

  Future<void> _injectAutoFill() async {
    if (_loggedIn) return;

    // 1. Override window.open → window.location (WKWebView drops popups silently)
    // 2. Inject page state monitor that reports back via SmartEyeChannel
    // 3. Switch to employee tab, fill form, AND CLICK SUBMIT
    await _controller.runJavaScript('''
      (function() {
        // --- window.open override ---
        var _nativeOpen = window.open;
        window.open = function(url, target, features) {
          if (url && typeof url === 'string' && url !== '' && url !== 'about:blank') {
            try { window.location.href = url; } catch(e) {}
            try { window.location.replace(url); } catch(e) {}
            SmartEyeChannel.postMessage('redirect_attempted');
          }
          return window;
        };

        // --- Page state monitor (reports every 3s) ---
        setInterval(function() {
          var url = window.location.href;
          SmartEyeChannel.postMessage('url:' + url);

          var qrDiv = document.getElementById('wxLoginQrcodeDiv');
          if (!qrDiv || qrDiv.innerHTML.trim() === '') {
            SmartEyeChannel.postMessage('qr_div_gone');
          }

          // Check for any success indicator
          var bodyText = document.body ? document.body.innerText : '';
          if (bodyText.indexOf('成功') !== -1 || bodyText.indexOf('success') !== -1) {
            SmartEyeChannel.postMessage('success_text_found');
          }
        }, 3000);

        // --- Intercept history.pushState / replaceState ---
        var _pushState = history.pushState;
        history.pushState = function() {
          _pushState.apply(this, arguments);
          setTimeout(function() {
            SmartEyeChannel.postMessage('url:' + window.location.href);
          }, 100);
        };
        var _replaceState = history.replaceState;
        history.replaceState = function() {
          _replaceState.apply(this, arguments);
          setTimeout(function() {
            SmartEyeChannel.postMessage('url:' + window.location.href);
          }, 100);
        };

        // --- Intercept location changes ---
        var _assign = window.location.assign;
        window.location.assign = function(url) {
          SmartEyeChannel.postMessage('redirect_attempted');
          return _assign.call(window.location, url);
        };
        var _replace = window.location.replace;
        window.location.replace = function(url) {
          SmartEyeChannel.postMessage('redirect_attempted');
          return _replace.call(window.location, url);
        };

        // --- Switch to employee login tab ---
        var empTab = document.querySelector('span[data-type="2"]');
        if (empTab) empTab.click();

        // --- Fill form AND click submit after delay ---
        setTimeout(function() {
          var jobInput = document.getElementById('txt_cashierJobName');
          if (jobInput) {
            jobInput.value = '${widget.cashierJobNumber}';
            jobInput.dispatchEvent(new Event('input', { bubbles: true }));
            jobInput.dispatchEvent(new Event('change', { bubbles: true }));
            jobInput.dispatchEvent(new Event('blur', { bubbles: true }));
          }

          var pwInputs = document.querySelectorAll('input[type="password"]');
          for (var i = 0; i < pwInputs.length; i++) {
            pwInputs[i].value = '${widget.password}';
            pwInputs[i].dispatchEvent(new Event('input', { bubbles: true }));
            pwInputs[i].dispatchEvent(new Event('change', { bubbles: true }));
            pwInputs[i].dispatchEvent(new Event('blur', { bubbles: true }));
          }

          var accInput = document.getElementById('txt_userName') || document.querySelector('input[placeholder*="账号"]');
          if (accInput) {
            accInput.value = '${widget.account}';
            accInput.dispatchEvent(new Event('input', { bubbles: true }));
            accInput.dispatchEvent(new Event('change', { bubbles: true }));
            accInput.dispatchEvent(new Event('blur', { bubbles: true }));
          }

          // Click the submit/login button — this is the KEY fix.
          // Previously we only filled the form but never submitted it,
          // which may leave the QR session in an uninitialized state on iOS.
          setTimeout(function() {
            var btn = document.querySelector('button[type="submit"]')
              || document.querySelector('input[type="submit"]')
              || document.querySelector('button.btn-primary')
              || document.querySelector('a.btn-primary')
              || document.querySelector('button.login-btn')
              || document.querySelector('.login-btn')
              || document.querySelector('button[class*="login"]')
              || document.querySelector('button[class*="submit"]')
              || document.querySelector('a[class*="login"]');
            if (btn) {
              btn.click();
              SmartEyeChannel.postMessage('submit_clicked');
            } else {
              // Last resort: try to submit any form on the page
              var forms = document.querySelectorAll('form');
              for (var f = 0; f < forms.length; f++) {
                try { forms[f].submit(); SmartEyeChannel.postMessage('form_submitted'); } catch(e) {}
              }
            }
          }, 300);

          SmartEyeChannel.postMessage('form_filled');
        }, 500);
      })();
    ''');
  }

  Future<void> _onLoginSuccess() async {
    if (_loggedIn) return;
    _loggedIn = true;

    try {
      // Get ALL cookies via Android CookieManager (handles HttpOnly)
      String cookieStr = '';
      try {
        const channel = MethodChannel('com.smarteye/cookies');
        cookieStr = await channel.invokeMethod('getCookies', {
          'url': widget.baseUrl,
        }) as String? ?? '';
      } catch (_) {}

      // Fallback to JS document.cookie
      if (cookieStr.isEmpty) {
        final jsCookies = await _controller.runJavaScriptReturningResult('document.cookie') as String?;
        cookieStr = jsCookies ?? '';
      }

      if (cookieStr.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        final storeKey = '${widget.baseUrl}|${widget.account}|${widget.cashierJobNumber}';
        await prefs.setString('cookie_$storeKey', cookieStr);

        // Fetch and save available stores
        try {
          final stores = await StoreService.fetchStores(
            baseUrl: widget.baseUrl,
            cookie: cookieStr,
          );
          if (stores.isNotEmpty) {
            await StoreService.saveStores(widget.baseUrl, stores);
          }
        } catch (e) {
          // Store fetch failed, but login succeeded
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('登录成功！门店已同步'), backgroundColor: AppConstants.successColor),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppConstants.bgColor,
      appBar: AppBar(
        title: const Text('微信扫码登录', style: TextStyle(fontSize: 16)),
        actions: [
          if (_qrReady && !_loggedIn) ...[
            IconButton(
              icon: const Icon(Icons.check_circle_outline, size: 22),
              tooltip: '已完成扫码验证',
              onPressed: _reloading ? null : () => _reloadPage(),
            ),
            IconButton(
              icon: const Icon(Icons.refresh, size: 22),
              tooltip: '重新加载登录页',
              onPressed: _reloading ? null : () async {
                await _controller.loadRequest(Uri.parse(
                  '${widget.baseUrl}/account/signin?ReturnUrl=%2fProduct%2fManage',
                ));
                setState(() {});
              },
            ),
          ],
          if (_loading)
            const Padding(
              padding: EdgeInsets.only(right: 16),
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ),
        ],
      ),
      body: Column(
        children: [
          // Status banner
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            color: AppConstants.primaryColor.withValues(alpha: 0.05),
            child: Column(
              children: [
                if (!_qrReady)
                  const Text('⏳ 正在加载登录页并自动填写…', style: TextStyle(fontSize: 13, color: AppConstants.textSecondary))
                else ...[
                  const Text('📸 请截图后用微信扫一扫验证', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppConstants.primaryColor)),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.touch_app, size: 14, color: AppConstants.textSecondary),
                      const SizedBox(width: 4),
                      const Text(
                        '微信 → 扫一扫 → 右下角相册 → 选择截图',
                        style: TextStyle(fontSize: 12, color: AppConstants.textSecondary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '扫码成功后点右上角 ✅ 按钮即可登入',
                    style: TextStyle(fontSize: 12, color: AppConstants.primaryColor.withValues(alpha: 0.7)),
                  ),
                ],
              ],
            ),
          ),

          // WebView
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
