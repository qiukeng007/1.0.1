import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/constants.dart';
import '../services/store_service.dart';
import '../services/session_webview.dart';

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
  InAppWebViewController? _controller;
  bool _loading = true;
  bool _loggedIn = false;
  bool _wxCallbackSeen = false;
  Timer? _pollTimer;
  Timer? _urlTimer;

  static String get _ua {
    if (Platform.isIOS) {
      return 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
    }
    return 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36';
  }

  @override
  void dispose() { _stopPolling(); super.dispose(); }

  // ---- Navigation handling ----

  void _onLoadStop(InAppWebViewController ctrl, Uri? url) {
    if (_loggedIn || url == null) return;
    final u = url.toString();
    debugPrint('📄 $u');
    setState(() => _loading = false);

    if (u.contains('/Product/Manage') || u.contains('/Home')) {
      _stopPolling();
      _onLoginSuccess();
      return;
    }

    // Fix 2: stuck on LoginByWx AFTER WeChat callback confirmed.
    // Only trigger if UserLoginByWx was already seen (callback happened).
    // LoginByWx=true also appears on the initial QR page — don't force-navigate then.
    if (_wxCallbackSeen && u.contains('LoginByWx=true')) {
      debugPrint('🔄 wx callback seen + stuck at LoginByWx, forcing /Product/Manage');
      _stopPolling();
      Future.delayed(const Duration(milliseconds: 500), () {
        if (!_loggedIn) ctrl.loadUrl(urlRequest: URLRequest(url: WebUri('${widget.baseUrl}/Product/Manage')));
      });
      return;
    }

    // Fix 3: wx callback seen but back on signin
    if (_wxCallbackSeen && (u.contains('signin') || u.contains('login'))) {
      debugPrint('🔄 wx callback seen, trying /Product/Manage');
      _stopPolling();
      Future.delayed(const Duration(seconds: 1), () {
        if (!_loggedIn) ctrl.loadUrl(urlRequest: URLRequest(url: WebUri('${widget.baseUrl}/Product/Manage')));
      });
      return;
    }

    if (u.contains('signin') || u.contains('login') || u.contains('account')) {
      _injectAutoFill(ctrl);
      // Start polling immediately, don't wait
      if (!_loggedIn) _startPolling();
    }
  }

  Future<NavigationActionPolicy?> _shouldOverrideUrl(InAppWebViewController ctrl, NavigationAction action) async {
    final url = action.request.url?.toString() ?? '';
    debugPrint('🔀 $url');

    // Fix 1: block duplicate UserLoginByWx
    if (url.contains('UserLoginByWx')) {
      if (_wxCallbackSeen) {
        debugPrint('🛑 BLOCKED duplicate UserLoginByWx');
        return NavigationActionPolicy.CANCEL;
      }
      _wxCallbackSeen = true;
      ctrl.evaluateJavascript(source: 'for(var i=1;i<99999;i++){clearInterval(i);clearTimeout(i);}');
    }
    return NavigationActionPolicy.ALLOW;
  }

  // ---- Polling ----

  void _startPolling() {
    _pollTimer?.cancel();
    // iOS: skip cookie polling — signin page cookies trigger false positives.
    // Only use URL-based detection (Product/Manage redirect).
    if (!Platform.isIOS) {
      _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
        if (_loggedIn) return;
        try {
          final cookies = await CookieManager.instance().getCookies(url: WebUri(widget.baseUrl));
          if (cookies.isNotEmpty) { _stopPolling(); _onLoginSuccess(); }
        } catch (_) {}
      });
    }
    _urlTimer?.cancel();
    _urlTimer = Timer.periodic(const Duration(seconds: _wxCallbackSeen ? 1 : 3), (_) async {
      if (_loggedIn || _controller == null) return;
      try {
        final u = await _controller!.getUrl();
        if (u == null) return;
        final us = u.toString();
        if (us.contains('/Product/Manage') || us.contains('/Home')) {
          _stopPolling(); _onLoginSuccess();
        }
        // After wx callback, aggressively re-check: if still on signin, force to target
        if (_wxCallbackSeen && (us.contains('signin') || us.contains('login'))) {
          _stopPolling();
          _controller!.loadUrl(urlRequest: URLRequest(url: WebUri('${widget.baseUrl}/Product/Manage')));
        }
      } catch (_) {}
    });
  }

  void _stopPolling() { _pollTimer?.cancel(); _pollTimer = null; _urlTimer?.cancel(); _urlTimer = null; }

  // ---- Auto-fill ----

  Future<void> _injectAutoFill(InAppWebViewController ctrl) async {
    if (_loggedIn) return;
    await ctrl.evaluateJavascript(source: '''
      (function(){
        var emp=document.querySelector('span[data-type="2"]');if(emp)emp.click();
        setTimeout(function(){
          var j=document.getElementById('txt_cashierJobName');if(j){j.value='${widget.cashierJobNumber}';j.dispatchEvent(new Event('input',{bubbles:true}));j.dispatchEvent(new Event('change',{bubbles:true}));}
          var pw=document.querySelectorAll('input[type="password"]');for(var i=0;i<pw.length;i++){pw[i].value='${widget.password}';pw[i].dispatchEvent(new Event('input',{bubbles:true}));pw[i].dispatchEvent(new Event('change',{bubbles:true}));}
          var a=document.getElementById('txt_userName')||document.querySelector('input[placeholder*="账号"]');if(a){a.value='${widget.account}';a.dispatchEvent(new Event('input',{bubbles:true}));a.dispatchEvent(new Event('change',{bubbles:true}));}
          setTimeout(function(){
            var btn=document.querySelector('button[type="submit"]')||document.querySelector('input[type="submit"]')||document.querySelector('button.btn-primary')||document.querySelector('a.btn-primary')||document.querySelector('button[class*="login"]')||document.querySelector('button[class*="submit"]')||document.querySelector('a[class*="login"]');
            if(btn)btn.click();else{var fs=document.querySelectorAll('form');for(var f=0;f<fs.length;f++)try{fs[f].submit()}catch(e){}}
          },400);
        },500);
      })();
    ''');
  }

  // ---- Login success ----

  Future<void> _onLoginSuccess() async {
    if (_loggedIn) return;
    _loggedIn = true;
    try {
      // iOS: NSHTTPCookieStorage may need time to sync from sharedCookiesEnabled.
      // Retry up to 3 times with 2s intervals.
      String cookieStr = '';
      String cookieSource = '';
      for (int attempt = 0; attempt < 3 && cookieStr.isEmpty; attempt++) {
        await Future.delayed(const Duration(seconds: 2));
        if (Platform.isIOS) {
          try {
            const ch = MethodChannel('com.smarteye/cookies');
            cookieStr = await ch.invokeMethod('getCookies', {'url': widget.baseUrl}) as String? ?? '';
            if (cookieStr.isNotEmpty) cookieSource = 'NSHTTPCookieStorage';
          } catch (_) {}
        }
        if (cookieStr.isEmpty) {
          try {
            final cookies = await CookieManager.instance().getCookies(url: WebUri(widget.baseUrl));
            cookieStr = cookies.map((c) => '${c.name}=${c.value}').join('; ');
            if (cookieStr.isNotEmpty) cookieSource = 'CookieManager';
          } catch (_) {}
        }
        if (cookieStr.isEmpty) {
          try {
            cookieStr = await _controller!.evaluateJavascript(source: 'document.cookie') as String? ?? '';
            if (cookieStr.isNotEmpty) cookieSource = 'document.cookie';
          } catch (_) {}
        }
      }

      if (cookieStr.isNotEmpty) {
        final p = await SharedPreferences.getInstance();
        await p.setString('cookie_${widget.baseUrl}|${widget.account}|${widget.cashierJobNumber}', cookieStr);

        // Also persist cookies into the system cookie store so NEXT
        // WebView instance (from "re-login") picks them up automatically.
        try {
          final cookies = await CookieManager.instance().getCookies(url: WebUri(widget.baseUrl));
          await CookieManager.instance().setCookie(
            url: WebUri(widget.baseUrl),
            name: '__session_check', value: '1', // dummy to test persistence
          );
          // Actually set all captured cookies for future WebViews
          for (final c in cookies) {
            try { await CookieManager.instance().setCookie(url: WebUri(widget.baseUrl), name: c.name, value: c.value); } catch (_) {}
          }
        } catch (_) {}

        try {
          final s = await StoreService.fetchStores(baseUrl: widget.baseUrl, cookie: cookieStr);
          if (s.isNotEmpty) await StoreService.saveStores(widget.baseUrl, s);
        } catch (_) {}
      }
      // iOS: keep WebView alive for session (cookies not accessible from dart:io)
      if (Platform.isIOS && _controller != null) {
        SessionWebView.instance.setController(_controller!);
      }

      if (mounted) {
        final msg = cookieStr.isNotEmpty
            ? '登录成功，已保存会话'
            : '登录成功（iOS将持续验证）';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: AppConstants.successColor, duration: const Duration(seconds: 2)));
        Navigator.of(context).pop(true);
      }
    } catch (_) { if (mounted) Navigator.of(context).pop(true); }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppConstants.bgColor,
      appBar: AppBar(
        title: const Text('微信扫码登录', style: TextStyle(fontSize: 16)),
        actions: [
          if (_loading)
            const Padding(padding: EdgeInsets.only(right: 16), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          if (!_loading && !_loggedIn)
            IconButton(icon: const Icon(Icons.refresh, size: 22), tooltip: '刷新', onPressed: () {
              _controller?.loadUrl(urlRequest: URLRequest(url: WebUri('${widget.baseUrl}/account/signin?ReturnUrl=%2fProduct%2fManage')));
              setState(() => _loading = true);
            }),
        ],
      ),
      body: Column(children: [
        Container(
          width: double.infinity, padding: const EdgeInsets.all(14),
          color: AppConstants.primaryColor.withValues(alpha: 0.05),
          child: Column(children: [
            if (_loading)
              const Text('⏳ 正在加载…', style: TextStyle(fontSize: 13, color: AppConstants.textSecondary))
            else ...[
              const Text('📸 请截图后用微信扫一扫验证', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppConstants.primaryColor)),
              const SizedBox(height: 4),
              const Text('微信 → 扫一扫 → 右下角相册 → 选择截图', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
            ],
          ]),
        ),
        Expanded(child: InAppWebView(
          // Try Product/Manage first — if session exists, loads directly
          initialUrlRequest: URLRequest(url: WebUri('${widget.baseUrl}/Product/Manage')),
          initialSettings: InAppWebViewSettings(
            javaScriptEnabled: true,
            userAgent: _ua,
            // KEY: share cookies with NSHTTPCookieStorage on iOS
            sharedCookiesEnabled: true,
          ),
          onWebViewCreated: (ctrl) => _controller = ctrl,
          onLoadStop: _onLoadStop,
          shouldOverrideUrlLoading: _shouldOverrideUrl,
        )),
      ]),
    );
  }
}
