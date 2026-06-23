import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MissingPluginException, MethodChannel, SystemChannels;
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
  bool _wechatCallbackSeen = false;
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
        onNavigationRequest: (request) {
          final url = request.url;
          debugPrint('🔀 WebView nav: $url');

          // CRITICAL: UserLoginByWx is a one-time-use OAuth callback.
          // The page's polling JS often fires it TWICE — the second call
          // consumes the already-used auth code, returns an error, and
          // OVERWRITES the successful first redirect with an empty msg=
          // error page.  Block the duplicate.
          if (url.contains('UserLoginByWx')) {
            if (_wechatCallbackSeen) {
              debugPrint('🛑 BLOCKED duplicate UserLoginByWx — '
                  'preventing auth code double-consumption');
              return NavigationDecision.prevent;
            }
            _wechatCallbackSeen = true;
            debugPrint('✅ First UserLoginByWx — allowing, killing JS timers');
            _controller.runJavaScript(
              'for(var i=1;i<99999;i++){clearInterval(i);clearTimeout(i);}'
            );
          }

          if (url.contains('LoginByWx=true')) {
            debugPrint('⚠️ LoginByWx redirect — will force-navigate on finish');
          }

          return NavigationDecision.navigate;
        },
        onPageFinished: (url) {
          setState(() => _loading = false);
          debugPrint('📄 Page finished: $url');

          // Success: landed on target page
          if (url.contains('/Product/Manage') || url.contains('/Home')) {
            _stopPolling();
            _onLoginSuccess();
            return;
          }

          // Stuck on Signin?LoginByWx=true — the intermediate redirect failed.
          // Don't wait, don't check _wechatCallbackSeen — just force through.
          if (url.contains('LoginByWx=true')) {
            debugPrint('🔄 Stuck at LoginByWx — forcing navigation to /Product/Manage');
            _stopPolling();
            Future.delayed(const Duration(milliseconds: 500), () {
              if (mounted && !_loggedIn) {
                _controller.loadRequest(
                  Uri.parse('${widget.baseUrl}/Product/Manage'),
                );
              }
            });
            return;
          }

          // WeChat callback was processed but we're back on a signin page.
          // The session cookie may have been set — try navigating to target.
          if (_wechatCallbackSeen &&
              (url.contains('signin') || url.contains('login') || url.contains('account'))) {
            debugPrint('🔄 WeChat callback seen but on signin page — trying /Product/Manage');
            _stopPolling();
            Future.delayed(const Duration(seconds: 1), () {
              if (mounted && !_loggedIn) {
                _controller.loadRequest(
                  Uri.parse('${widget.baseUrl}/Product/Manage'),
                );
              }
            });
            return;
          }

          if (url.contains('signin') || url.contains('login') || url.contains('account')) {
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
      if (url.contains('/Product/Manage') || url.contains('/Home')) {
        _stopPolling();
        _onLoginSuccess();
        return;
      }
      // WeChat OAuth callback detected via JS
      if (url.contains('UserLoginByWx')) {
        _wechatCallbackSeen = true;
        debugPrint('✅ JS detected WeChat callback');
      }
      // Stuck on LoginByWx — force navigate (no condition)
      if (url.contains('LoginByWx=true')) {
        debugPrint('🔄 JS: stuck at LoginByWx, forcing /Product/Manage');
        _stopPolling();
        _controller.loadRequest(Uri.parse('${widget.baseUrl}/Product/Manage'));
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

    // WebView-internal fetch probe result
    // probe:200:basic → authenticated (no redirect)
    // probe:0:opaqueredirect → redirected (still on signin)
    if (text.startsWith('probe:')) {
      final parts = text.substring(6).split(':');
      final statusCode = int.tryParse(parts[0]) ?? 0;
      debugPrint('🔍 WebView probe result: status=$statusCode (${parts.join(":")})');
      if (statusCode == 200) {
        debugPrint('✅ WebView probe: authenticated — navigating to Product/Manage');
        _stopPolling();
        _controller.loadRequest(Uri.parse('${widget.baseUrl}/Product/Manage'));
      }
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

  /// Recovery: navigate directly to /Product/Manage.
  /// If the server already authenticated the session (via WeChat callback),
  /// this will load the target page. Otherwise it will redirect back to signin.
  Future<void> _reloadPage() async {
    if (_reloading || _loggedIn) return;
    _reloading = true;
    try {
      final currentUrl = await _controller.currentUrl();
      if (currentUrl != null && currentUrl.contains('/Product/Manage')) {
        _onLoginSuccess();
        _reloading = false;
        return;
      }
      debugPrint('🔄 Recovery: navigating directly to /Product/Manage');
      await _controller.loadRequest(Uri.parse('${widget.baseUrl}/Product/Manage'));
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

    // Polling strategy 3: WebView-internal fetch probe (every 8s).
    // fetch() runs INSIDE the WebView's JS context, sharing its session/cookies.
    // Uses redirect: 'manual' — a 200 response means we're authenticated
    // (no redirect to signin), while an opaque response means still redirected.
    _startWebViewProbing();
  }

  Timer? _webViewProbeTimer;
  int _webViewProbeCount = 0;

  void _startWebViewProbing() {
    _webViewProbeTimer?.cancel();
    _webViewProbeTimer = Timer.periodic(const Duration(seconds: 8), (_) async {
      if (_loggedIn) return;
      _webViewProbeCount++;
      try {
        // Run fetch INSIDE the WebView — shares its session & cookies
        final result = await _controller.runJavaScriptReturningResult('''
          (function() {
            try {
              fetch('/Product/Manage', { redirect: 'manual', cache: 'no-store' })
                .then(function(r) {
                  SmartEyeChannel.postMessage('probe:' + r.status + ':' + r.type);
                })
                .catch(function(e) {
                  SmartEyeChannel.postMessage('probe_error:' + e.message);
                });
              return 'sent';
            } catch(e) {
              return 'error:' + e.toString();
            }
          })();
        ''');
        debugPrint('🔍 WebView probe #$_webViewProbeCount: $result');
      } catch (e) {
        debugPrint('❌ WebView probe error: $e');
      }
    });
  }

  void _stopPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _urlPollTimer?.cancel();
    _urlPollTimer = null;
    _webViewProbeTimer?.cancel();
    _webViewProbeTimer = null;
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

  /// Open the login flow in SFSafariViewController (full Safari engine).
  /// This completely bypasses WKWebView's broken redirect/cookie handling.
  Future<void> _openSafariLogin() async {
    // Prevent double-tap
    if (_reloading) return;
    _reloading = true;
    setState(() {});

    try {
      const channel = MethodChannel('com.smarteye/cookies');
      final cookieStr = await channel.invokeMethod('openSafariLogin', {
        'url': '${widget.baseUrl}/account/signin?ReturnUrl=%2fProduct%2fManage',
      }).timeout(const Duration(minutes: 3)); // Safari login can take time

      if (!mounted) return;
      if (cookieStr is String && cookieStr.isNotEmpty) {
        final prefs = await SharedPreferences.getInstance();
        final storeKey = '${widget.baseUrl}|${widget.account}|${widget.cashierJobNumber}';
        await prefs.setString('cookie_$storeKey', cookieStr);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('登录成功！'), backgroundColor: AppConstants.successColor),
          );
          Navigator.of(context).pop(true);
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('未检测到登录会话，请在 Safari 中完成扫码验证后再点完成'), backgroundColor: Colors.orange),
          );
        }
      }
    } on MissingPluginException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Safari 登录需要重新编译 App（原生代码已更新）'), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      debugPrint('❌ Safari login error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开 Safari 失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
    _reloading = false;
    setState(() {});
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

          // Safari login button — uses SFSafariViewController (full Safari
          // engine) instead of embedded WKWebView.  Solves the WeChat OAuth
          // redirect chain / cookie persistence issue on iOS.
          if (_qrReady && !_loggedIn)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.1), blurRadius: 4, offset: const Offset(0, -2)),
                ],
              ),
              child: SafeArea(
                top: false,
                child: ElevatedButton.icon(
                  icon: _reloading
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.open_in_browser, size: 20),
                  label: Text(_reloading ? '请在 Safari 中完成登录…' : '在 Safari 浏览器中登录', style: const TextStyle(fontSize: 15)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppConstants.primaryColor,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(double.infinity, 48),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusSm)),
                  ),
                  onPressed: _reloading ? null : _openSafariLogin,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
