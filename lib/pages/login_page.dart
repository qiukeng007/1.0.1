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
  bool _qrReady = false;
  bool _loggedIn = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent('Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36')
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          return NavigationDecision.navigate;
        },
        onPageStarted: (url) {
          debugPrint('WebView navigating: $url');
        },
        onPageFinished: (url) {
          setState(() => _loading = false);
          debugPrint('WebView finished: $url');

          if (url.contains('/Product/Manage')) {
            _onLoginSuccess();
          } else if (url.contains('signin') || url.contains('login') || url.contains('account')) {
            _injectAutoFill();
          }
        },
        onWebResourceError: (error) {
          debugPrint('WebView error: ${error.description}');
        },
      ))
      ..loadRequest(Uri.parse(
        '${widget.baseUrl}/account/signin?ReturnUrl=%2fProduct%2fManage',
      ));
  }

  Future<void> _injectAutoFill() async {
    if (_loggedIn) return;

    final js = '''
      (function() {
        // Switch to employee login tab
        var empTab = document.querySelector('span[data-type="2"]');
        if (empTab) empTab.click();

        // Wait a moment then fill form
        setTimeout(function() {
          // Fill employee number
          var jobInput = document.getElementById('txt_cashierJobName');
          if (jobInput) {
            jobInput.value = '${widget.cashierJobNumber}';
            jobInput.dispatchEvent(new Event('input', { bubbles: true }));
          }

          // Fill password
          var pwInputs = document.querySelectorAll('input[type="password"]');
          for (var i = 0; i < pwInputs.length; i++) {
            pwInputs[i].value = '${widget.password}';
            pwInputs[i].dispatchEvent(new Event('input', { bubbles: true }));
          }

          // Fill account (if visible)
          var accInput = document.getElementById('txt_userName') || document.querySelector('input[placeholder*="账号"]');
          if (accInput) {
            accInput.value = '${widget.account}';
            accInput.dispatchEvent(new Event('input', { bubbles: true }));
          }

          setQRReady();
        }, 500);
      })();

      function setQRReady() {
        // Check if QR code popup appears
        setTimeout(function() {
          var qrDiv = document.getElementById('wxLoginQrcodeDiv');
          if (qrDiv && qrDiv.innerHTML.trim() !== '') {
            window.flutterQRReady.postMessage('ready');
          }
        }, 1000);
      }
    ''';

    await _controller.runJavaScript(js);
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
                else
                  const Text('📸 请截图后用微信扫一扫验证', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppConstants.primaryColor)),
                const SizedBox(height: 6),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.touch_app, size: 14, color: AppConstants.textSecondary),
                    const SizedBox(width: 4),
                    Text(
                      '微信 → 扫一扫 → 右下角相册 → 选择截图',
                      style: TextStyle(fontSize: 12, color: AppConstants.textSecondary),
                    ),
                  ],
                ),
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
