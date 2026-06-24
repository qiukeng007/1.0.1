import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, HttpClient, HttpClientResponse, HttpHeaders;
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
  // ── Android: WebView login ──
  late final WebViewController _controller;
  bool _webLoading = true;
  bool _webLoggedIn = false;
  Timer? _pollTimer;

  // ── iOS: direct HTTP login ──
  String _iosStatus = '';
  bool _iosError = false;

  static const _httpUa =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0.0.0 Safari/537.36';
  static const _webUa =
      'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36';

  @override
  void initState() {
    super.initState();
    if (Platform.isIOS) {
      // iOS: try fast HTTP login first. If server requires WeChat (re-enabled
      // later), auto-fallback to WebView so the user can scan the QR code.
      _doHttpLogin();
    } else {
      _initWebView();
    }
  }

  /// Switch to WebView login on iOS (when HTTP login detects WeChat required).
  void _fallbackToWebView() {
    setState(() {
      _iosStatus = '';
      _iosError = false;
    });
    _initWebView();
  }

  // ═══════════════════════════════════════════════
  //  iOS: direct HTTP login (no WebView)
  // ═══════════════════════════════════════════════

  Future<void> _doHttpLogin() async {
    final baseUrl = widget.baseUrl.replaceAll(RegExp(r'/$'), '');
    final account = widget.account.trim();
    final jobNumber = widget.cashierJobNumber.trim();
    final password = widget.password.trim();

    if (account.isEmpty || jobNumber.isEmpty || password.isEmpty) {
      _iosError = true;
      setState(() => _iosStatus = '请填写门店账号、员工工号和工号密码');
      return;
    }

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      // Step 1: GET signin page
      setState(() => _iosStatus = '正在打开登录页…');
      final signinUri = Uri.parse('$baseUrl/account/signin?ReturnUrl=%2fProduct%2fManage');
      final r1 = await client.getUrl(signinUri);
      r1.headers.set('User-Agent', _httpUa);
      r1.followRedirects = false;
      final resp1 = await r1.close().timeout(const Duration(seconds: 15));
      await _drain(resp1);
      if (resp1.statusCode >= 400) { _fail('无法打开登录页 (${resp1.statusCode})'); return; }
      String cookie = _merge('', resp1.headers);

      // Step 2: POST login
      setState(() => _iosStatus = '正在登录…');
      final r2 = await client.postUrl(Uri.parse('$baseUrl/account/SignIn'));
      r2.headers.set('User-Agent', _httpUa);
      r2.headers.set('Accept', 'application/json, text/javascript, */*');
      r2.headers.set('Referer', signinUri.toString());
      r2.headers.set('Origin', baseUrl);
      r2.headers.set('Content-Type', 'application/x-www-form-urlencoded; charset=UTF-8');
      r2.headers.set('X-Requested-With', 'XMLHttpRequest');
      if (cookie.isNotEmpty) r2.headers.set('Cookie', cookie);
      r2.followRedirects = false;
      r2.write('userName=${Uri.encodeComponent('$account:$jobNumber')}&password=${Uri.encodeComponent(password)}&returnUrl=%2fProduct%2fManage&screenSize=1080*1920&employeeSignin=true');
      final resp2 = await r2.close().timeout(const Duration(seconds: 15));
      final body2 = await _read(resp2);
      cookie = _merge(cookie, resp2.headers);

      // Step 3: Parse
      String? redirectUrl;
      try {
        final j = jsonDecode(body2) as Map<String, dynamic>;
        if (j['successed'] != true) { final msg = j['msg'] as String? ?? ''; if (msg.contains('微信') || msg.contains('扫码') || msg.contains('wechat')) { _fallbackToWebView(); } else { _fail('登录失败：${msg.isNotEmpty ? msg : "未知错误"}'); } return; }
        redirectUrl = j['msg'] as String?;
        if (redirectUrl == null || redirectUrl.isEmpty) { _fail('服务器未返回重定向'); return; }
      } catch (_) { _fail('无法解析服务器响应'); return; }

      // Step 4: Follow redirect
      setState(() => _iosStatus = '正在验证…');
      final redirUri = redirectUrl.startsWith('http')
          ? Uri.parse(redirectUrl)
          : Uri.parse('$baseUrl${redirectUrl.startsWith('/') ? '' : '/'}$redirectUrl');
      final r3 = await client.getUrl(redirUri);
      r3.headers.set('User-Agent', _httpUa);
      r3.headers.set('Cookie', cookie);
      r3.headers.set('Referer', signinUri.toString());
      r3.followRedirects = false;
      final resp3 = await r3.close().timeout(const Duration(seconds: 10));
      await _drain(resp3);
      cookie = _merge(cookie, resp3.headers);

      // Step 5: Verify
      final r4 = await client.getUrl(Uri.parse('$baseUrl/Product/Manage'));
      r4.headers.set('User-Agent', _httpUa);
      r4.headers.set('Cookie', cookie);
      r4.followRedirects = false;
      final resp4 = await r4.close().timeout(const Duration(seconds: 10));
      final vBody = await _read(resp4);
      final vLoc = resp4.headers.value('location') ?? '';
      if (vLoc.contains('signin') || vLoc.contains('login') ||
          (vBody.contains('signin') && vBody.contains('form'))) {
        _fail('验证失败：Cookie 无效'); return;
      }

      // Save & done
      final storeKey = '$baseUrl|$account|$jobNumber';
      await (await SharedPreferences.getInstance()).setString('cookie_$storeKey', cookie);
      try {
        final stores = await StoreService.fetchStores(baseUrl: baseUrl, cookie: cookie);
        if (stores.isNotEmpty) await StoreService.saveStores(baseUrl, stores);
      } catch (_) {}
      if (mounted) { Navigator.of(context).pop(true); }
    } catch (e) { _fail('$e'); }
    finally { client.close(); }
  }

  void _fail(String msg) {
    if (mounted) setState(() { _iosError = true; _iosStatus = msg; });
  }

  Future<String> _read(HttpClientResponse r) async {
    final b = <int>[]; await for (final c in r) { b.addAll(c); } return utf8.decode(b);
  }
  Future<void> _drain(HttpClientResponse r) async { await _read(r); }

  String _merge(String cur, HttpHeaders h) {
    final m = <String, String>{};
    for (final p in cur.split(';')) { final e = p.trim().indexOf('='); if (e > 0) m[p.substring(0, e).trim()] = p.substring(e + 1).trim(); }
    for (final raw in h['set-cookie'] ?? <String>[]) {
      final s = raw.indexOf(';'); final nv = s > 0 ? raw.substring(0, s).trim() : raw.trim();
      final eq = nv.indexOf('=');
      if (eq > 0) { final nm = nv.substring(0, eq).trim(); if (!RegExp(r'^(path|domain|expires|max-age|secure|httponly|samesite)', caseSensitive: false).hasMatch(nm)) { m[nm] = nv.substring(eq + 1).trim(); } }
    }
    return m.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  // ═══════════════════════════════════════════════
  //  Android: WebView login (unchanged)
  // ═══════════════════════════════════════════════

  void _initWebView() {
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_webUa)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) => NavigationDecision.navigate,
        onPageFinished: (url) {
          setState(() => _webLoading = false);
          if (url.contains('/Product/Manage') || url.contains('/Home')) {
            _stopPolling();
            _onWebLoginSuccess();
          } else if (url.contains('signin') || url.contains('login') || url.contains('account')) {
            _injectAutoFill();
            Future.delayed(const Duration(seconds: 10), () {
              if (mounted && !_webLoggedIn) _startPolling();
            });
          }
        },
      ))
      ..loadRequest(Uri.parse('${widget.baseUrl}/account/signin?ReturnUrl=%2fProduct%2fManage'));
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      if (_webLoggedIn) return;
      try {
        const channel = MethodChannel('com.smarteye/cookies');
        final c = await channel.invokeMethod('getCookies', {'url': widget.baseUrl}) as String? ?? '';
        if (c.isNotEmpty) { _stopPolling(); _onWebLoginSuccess(); }
      } catch (_) {}
    });
  }

  void _stopPolling() { _pollTimer?.cancel(); _pollTimer = null; }

  Future<void> _injectAutoFill() async {
    if (_webLoggedIn) return;
    await _controller.runJavaScript('''
      (function(){
        var emp=document.querySelector('span[data-type="2"]');if(emp)emp.click();
        setTimeout(function(){
          var j=document.getElementById('txt_cashierJobName');if(j){j.value='${widget.cashierJobNumber}';j.dispatchEvent(new Event('input',{bubbles:true}));j.dispatchEvent(new Event('change',{bubbles:true}));}
          var pw=document.querySelectorAll('input[type="password"]');for(var i=0;i<pw.length;i++){pw[i].value='${widget.password}';pw[i].dispatchEvent(new Event('input',{bubbles:true}));pw[i].dispatchEvent(new Event('change',{bubbles:true}));}
          var a=document.getElementById('txt_userName')||document.querySelector('input[placeholder*="账号"]');if(a){a.value='${widget.account}';a.dispatchEvent(new Event('input',{bubbles:true}));a.dispatchEvent(new Event('change',{bubbles:true}));}
          setTimeout(function(){
            var btn=document.querySelector('button[type="submit"]')||document.querySelector('input[type="submit"]')||document.querySelector('button.btn-primary')||document.querySelector('a.btn-primary')||document.querySelector('button[class*="login"]')||document.querySelector('button[class*="submit"]')||document.querySelector('a[class*="login"]');
            if(btn)btn.click();
            else{var fs=document.querySelectorAll('form');for(var f=0;f<fs.length;f++)try{fs[f].submit()}catch(e){}}
          },400);
        },500);
      })();
    ''');
  }

  Future<void> _onWebLoginSuccess() async {
    if (_webLoggedIn) return;
    _webLoggedIn = true;
    try {
      String c = '';
      try { const ch = MethodChannel('com.smarteye/cookies'); c = await ch.invokeMethod('getCookies', {'url': widget.baseUrl}) as String? ?? ''; } catch (_) {}
      if (c.isEmpty) try { c = await _controller.runJavaScriptReturningResult('document.cookie') as String? ?? ''; } catch (_) {}
      if (c.isNotEmpty) {
        final p = await SharedPreferences.getInstance();
        await p.setString('cookie_${widget.baseUrl}|${widget.account}|${widget.cashierJobNumber}', c);
        try { final s = await StoreService.fetchStores(baseUrl: widget.baseUrl, cookie: c); if (s.isNotEmpty) await StoreService.saveStores(widget.baseUrl, s); } catch (_) {}
      }
      if (mounted) { Navigator.of(context).pop(true); }
    } catch (_) { if (mounted) Navigator.of(context).pop(true); }
  }

  @override
  void dispose() { _stopPolling(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    if (Platform.isIOS) {
      // Show WebView when HTTP login fell back (WeChat required)
      if (_iosStatus.isEmpty) {
        return Scaffold(
          backgroundColor: AppConstants.bgColor,
          appBar: AppBar(title: const Text('微信扫码登录', style: TextStyle(fontSize: 16))),
          body: Expanded(child: WebViewWidget(controller: _controller)),
        );
      }
      return Scaffold(
        backgroundColor: AppConstants.bgColor,
        appBar: AppBar(title: const Text('员工登录', style: TextStyle(fontSize: 16))),
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (!_iosError) ...[
              const SizedBox(width: 48, height: 48, child: CircularProgressIndicator(strokeWidth: 3)),
              const SizedBox(height: 24),
            ] else ...[
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 24),
            ],
            Text(_iosStatus, style: TextStyle(fontSize: 15, color: _iosError ? Colors.red : AppConstants.textSecondary)),
            if (_iosError) ...[
              const SizedBox(height: 24),
              ElevatedButton(onPressed: () => Navigator.pop(context), child: const Text('返回')),
            ],
          ]),
        ),
      );
    }

    // Android: WebView
    return Scaffold(
      backgroundColor: AppConstants.bgColor,
      appBar: AppBar(
        title: const Text('微信扫码登录', style: TextStyle(fontSize: 16)),
        actions: [
          if (_webLoading)
            const Padding(padding: EdgeInsets.only(right: 16), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
        ],
      ),
      body: Expanded(child: WebViewWidget(controller: _controller)),
    );
  }
}
