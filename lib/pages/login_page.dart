import 'dart:async';
import 'dart:io' show Platform, File;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../utils/constants.dart';
import '../services/store_service.dart';

class LoginPage extends StatefulWidget {
  final String baseUrl, account, cashierJobNumber, password;
  const LoginPage({super.key, this.baseUrl = 'https://beta28.pospal.cn', this.account = '', this.cashierJobNumber = '', this.password = ''});
  @override State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  InAppWebViewController? _ctrl;
  bool _loading = true, _loggedIn = false, _wxSeen = false;
  Timer? _urlTimer;

  static String get _ua => Platform.isIOS
      ? 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1'
      : 'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 Chrome/120.0.0.0 Mobile Safari/537.36';

  @override void dispose() { _urlTimer?.cancel(); super.dispose(); }

  // ---- URL monitoring ----
  Future<void> _checkURL() async {
    if (_loggedIn || _ctrl == null) return;
    final u = await _ctrl!.getUrl(); if (u == null) return;
    final us = u.toString();
    setState(() => _loading = false);

    if (us.contains('/Product/Manage') || us.contains('/Home')) { _onSuccess(); return; }
    if (us.contains('UserLoginByWx')) {
      if (_wxSeen) return; // block duplicate
      _wxSeen = true;
      if (Platform.isAndroid) {
        _ctrl!.evaluateJavascript(source: 'for(var i=1;i<99999;i++){clearInterval(i);clearTimeout(i);}');
      }
    }
    if (_wxSeen && (us.contains('LoginByWx=true') || us.contains('signin') || us.contains('login'))) {
      _ctrl!.loadUrl(urlRequest: URLRequest(url: WebUri('${widget.baseUrl}/Product/Manage')));
      return;
    }
    if (us.contains('signin') || us.contains('login') || us.contains('account')) _injectFill();
  }

  Future<NavigationActionPolicy?> _overrideUrl(InAppWebViewController c, NavigationAction a) async {
    final url = a.request.url?.toString() ?? '';
    if (url.contains('UserLoginByWx')) {
      if (_wxSeen) return Platform.isAndroid ? NavigationActionPolicy.CANCEL : NavigationActionPolicy.ALLOW;
      _wxSeen = true;
      if (Platform.isAndroid) {
        c.evaluateJavascript(source: 'for(var i=1;i<99999;i++){clearInterval(i);clearTimeout(i);}');
      }
    }
    return NavigationActionPolicy.ALLOW;
  }

  void _onLoadStop(InAppWebViewController c, Uri? url) {
    if (_loggedIn || url == null) return;
    final u = url.toString();
    setState(() => _loading = false);
    if (u.contains('/Product/Manage') || u.contains('/Home')) { _onSuccess(); return; }
    if (_wxSeen && (u.contains('LoginByWx=true') || u.contains('signin') || u.contains('login'))) {
      c.loadUrl(urlRequest: URLRequest(url: WebUri('${widget.baseUrl}/Product/Manage')));
      return;
    }
    if (u.contains('UserLoginByWx')) {
      if (!_wxSeen) {
        _wxSeen = true;
        c.evaluateJavascript(source: 'var hi=setInterval(function(){},99999);for(var i=1;i<hi;i++){clearInterval(i);clearTimeout(i);}');
      }
    }
    if (u.contains('signin') || u.contains('login') || u.contains('account')) { _injectFill(); _urlTimer ??= Timer.periodic(const Duration(seconds: 2), (_) => _checkURL()); }
  }

  // ---- Auto-fill ----
  Future<void> _injectFill() async {
    if (_ctrl == null) return;
    await _ctrl!.evaluateJavascript(source: '''
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

  // ---- Success ----
  Future<void> _onSuccess() async {
    if (_loggedIn) return;
    _loggedIn = true; _urlTimer?.cancel();
    // Poll for cookies (WKWebView writes them asynchronously, up to 8 attempts = 4s)
    String ck = '';
    for (int attempt = 0; attempt < 8 && ck.isEmpty; attempt++) {
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        final cs = await CookieManager.instance().getCookies(url: WebUri(widget.baseUrl));
        ck = cs.map((c) => '${c.name}=${c.value}').join('; ');
      } catch (_) {}
      if (ck.isEmpty && Platform.isIOS) {
        try {
          const persistCh = MethodChannel('com.smarteye/cookies_persist');
          ck = await persistCh.invokeMethod('getAllCookies', widget.baseUrl) as String? ?? '';
        } catch (_) {}
      }
      if (ck.isEmpty && Platform.isIOS) {
        try {
          const ch = MethodChannel('com.smarteye/cookies');
          ck = await ch.invokeMethod('getCookies', {'url': widget.baseUrl}) as String? ?? '';
        } catch (_) {}
      }
    }

    // Fallback for Android / when iOS methods fail
    if (ck.isEmpty) {
      try { final cs = await CookieManager.instance().getCookies(url: WebUri(widget.baseUrl)); ck = cs.map((c) => '${c.name}=${c.value}').join('; '); } catch (_) {}
    }
    if (ck.isEmpty && _ctrl != null) {
      try { ck = await _ctrl!.evaluateJavascript(source: 'document.cookie') as String? ?? ''; } catch (_) {}
    }
    if (ck.isNotEmpty) {
      final p = await SharedPreferences.getInstance();
      await p.setString('cookie_${widget.baseUrl}|${widget.account}|${widget.cashierJobNumber}', ck);
      // Also persist to file (iOS NSUserDefaults may not flush on force-quit)
      try {
        final dir = await getApplicationDocumentsDirectory();
        final cf = File('${dir.path}/pospal_cookie.txt');
        await cf.writeAsString(ck, flush: true);
      } catch (_) {}
      try { final s = await StoreService.fetchStores(baseUrl: widget.baseUrl, cookie: ck); if (s.isNotEmpty) await StoreService.saveStores(widget.baseUrl, s); } catch (_) {}
    }
    if (mounted) { Navigator.of(context).pop(true); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppConstants.bgColor,
    appBar: AppBar(
      title: const Text('微信扫码登录', style: TextStyle(fontSize: 16)),
      actions: [if (_loading) const Padding(padding: EdgeInsets.only(right: 16), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))],
    ),
    body: Column(children: [
      Container(width: double.infinity, padding: const EdgeInsets.all(14), color: AppConstants.primaryColor.withValues(alpha: 0.05),
        child: Column(children: [
          if (_loading) const Text('⏳ 正在加载…', style: TextStyle(fontSize: 13, color: AppConstants.textSecondary))
          else ...[
            const Text('📸 请截图后用微信扫一扫验证', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppConstants.primaryColor)),
            const SizedBox(height: 4),
            const Text('微信 → 扫一扫 → 右下角相册 → 选择截图', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
          ],
        ]),
      ),
      Expanded(child: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri('${widget.baseUrl}/Product/Manage')),
        initialSettings: InAppWebViewSettings(javaScriptEnabled: true, userAgent: _ua, sharedCookiesEnabled: true),
        onWebViewCreated: (c) => _ctrl = c,
        onLoadStop: _onLoadStop,
        shouldOverrideUrlLoading: _overrideUrl,
      )),
    ]),
  );
}
