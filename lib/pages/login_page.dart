import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

    // Fix 2: stuck on LoginByWx intermediate page
    if (u.contains('LoginByWx=true')) {
      debugPrint('🔄 stuck at LoginByWx, forcing /Product/Manage');
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
      Future.delayed(const Duration(seconds: 10), () {
        if (mounted && !_loggedIn) _startPolling();
      });
    }
  }

  bool _shouldOverrideUrl(InAppWebViewController ctrl, NavigationAction action) {
    final url = action.request.url?.toString() ?? '';
    debugPrint('🔀 $url');

    // Fix 1: block duplicate UserLoginByWx
    if (url.contains('UserLoginByWx')) {
      if (_wxCallbackSeen) {
        debugPrint('🛑 BLOCKED duplicate UserLoginByWx');
        return true; // cancel
      }
      _wxCallbackSeen = true;
      ctrl.evaluateJavascript(source: 'for(var i=1;i<99999;i++){clearInterval(i);clearTimeout(i);}');
    }
    return false; // allow
  }

  // ---- Polling ----

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (_loggedIn || _controller == null) return;
      try {
        final cookies = await _controller!.getCookies(url: WebUri(widget.baseUrl));
        if (cookies.isNotEmpty) { _stopPolling(); _onLoginSuccess(); }
      } catch (_) {}
    });
    _urlTimer?.cancel();
    _urlTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_loggedIn || _controller == null) return;
      try {
        final u = await _controller!.getUrl();
        if (u != null && (u.toString().contains('/Product/Manage') || u.toString().contains('/Home'))) {
          _stopPolling(); _onLoginSuccess();
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
    if (_loggedIn || _controller == null) return;
    _loggedIn = true;
    try {
      await Future.delayed(const Duration(seconds: 2));

      // Get cookies using InAppWebView's API (respects sharedCookiesEnabled)
      String cookieStr = '';
      try {
        final cookies = await _controller!.getCookies(url: WebUri(widget.baseUrl));
        cookieStr = cookies.map((c) => '${c.name}=${c.value}').join('; ');
      } catch (_) {}
      if (cookieStr.isEmpty) {
        try {
          final js = await _controller!.evaluateJavascript(source: 'document.cookie');
          cookieStr = (js as String?) ?? '';
        } catch (_) {}
      }

      if (cookieStr.isNotEmpty) {
        final p = await SharedPreferences.getInstance();
        await p.setString('cookie_${widget.baseUrl}|${widget.account}|${widget.cashierJobNumber}', cookieStr);
        try {
          final s = await StoreService.fetchStores(baseUrl: widget.baseUrl, cookie: cookieStr);
          if (s.isNotEmpty) await StoreService.saveStores(widget.baseUrl, s);
        } catch (_) {}
      }
      if (mounted) { Navigator.of(context).pop(true); }
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
          initialUrlRequest: URLRequest(url: WebUri('${widget.baseUrl}/account/signin?ReturnUrl=%2fProduct%2fManage')),
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
