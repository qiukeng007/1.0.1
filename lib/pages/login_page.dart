import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

  
  Future<void> _seedCookies() async {
    if (!Platform.isIOS) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final ck = prefs.getString('cookie_${widget.baseUrl}|${widget.account}|${widget.cashierJobNumber}');
      if (ck == null || ck.isEmpty) return;
      final parts = ck.split('; ');
      for (final p in parts) {
        final idx = p.indexOf('=');
        if (idx <= 0) continue;
        final name = p.substring(0, idx).trim();
        final value = p.substring(idx + 1).trim();
        if (name.isEmpty || value.isEmpty) continue;
        try {
          await CookieManager.instance().setCookie(
            url: WebUri(widget.baseUrl),
            name: name,
            value: value,
            path: '/',
            domain: Uri.parse(widget.baseUrl).host,
          );
        } catch (_) {}
      }
    } catch (_) {}
  }
  Future<void> _checkURL() async {
    if (_loggedIn || _ctrl == null) return;
    final u = await _ctrl!.getUrl(); if (u == null) return;
    final us = u.toString();
    setState(() => _loading = false);
    if (us.contains('/Product/Manage') || us.contains('/Home')) { _onSuccess(); return; }
    if (us.contains('UserLoginByWx')) {
      if (_wxSeen) return;
      _wxSeen = true;
      _ctrl!.evaluateJavascript(source: 'var hi=setInterval(function(){},99999);for(var i=1;i<hi;i++){clearInterval(i);clearTimeout(i);}');
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
      c.evaluateJavascript(source: 'var hi=setInterval(function(){},99999);for(var i=1;i<hi;i++){clearInterval(i);clearTimeout(i);}');
    }
    return NavigationActionPolicy.ALLOW;
  }

  void _onLoadStop(InAppWebViewController c, Uri? url) {
    if (_loggedIn || url == null) return;
    final u = url.toString();
    setState(() => _loading = false);
    if (u.contains('/Product/Manage') || u.contains('/Home')) { _onSuccess(); return; }
    if (u.contains('UserLoginByWx')) {
      if (!_wxSeen) {
        _wxSeen = true;
        c.evaluateJavascript(source: 'var hi=setInterval(function(){},99999);for(var i=1;i<hi;i++){clearInterval(i);clearTimeout(i);}');
      }
    }
    if (_wxSeen && (u.contains('LoginByWx=true') || u.contains('signin') || u.contains('login'))) {
      c.loadUrl(urlRequest: URLRequest(url: WebUri('${widget.baseUrl}/Product/Manage')));
      return;
    }
    if (u.contains('signin') || u.contains('login') || u.contains('account')) { _injectFill(); _urlTimer ??= Timer.periodic(const Duration(seconds: 2), (_) => _checkURL()); }
  }

  Future<void> _injectFill() async {
    if (_ctrl == null) return;
    await _ctrl!.evaluateJavascript(source: '''
      (function(){
        var emp=document.querySelector('span[data-type="2"]');if(emp)emp.click();
        setTimeout(function(){
          var j=document.getElementById('txt_cashierJobName');if(j){j.value='${widget.cashierJobNumber}';j.dispatchEvent(new Event('input',{bubbles:true}));j.dispatchEvent(new Event('change',{bubbles:true}));}
          var pw=document.querySelectorAll('input[type="password"]');for(var i=0;i<pw.length;i++){pw[i].value='${widget.password}';pw[i].dispatchEvent(new Event('input',{bubbles:true}));pw[i].dispatchEvent(new Event('change',{bubbles:true}));}
          var a=document.getElementById('txt_userName')||document.querySelector('input[placeholder*="\u8d26\u53f7"]');if(a){a.value='${widget.account}';a.dispatchEvent(new Event('input',{bubbles:true}));a.dispatchEvent(new Event('change',{bubbles:true}));}
          setTimeout(function(){
            var btn=document.querySelector('button[type="submit"]')||document.querySelector('input[type="submit"]')||document.querySelector('button.btn-primary')||document.querySelector('a.btn-primary')||document.querySelector('button[class*="login"]')||document.querySelector('button[class*="submit"]')||document.querySelector('a[class*="login"]');
            if(btn)btn.click();else{var fs=document.querySelectorAll('form');for(var f=0;f<fs.length;f++)try{fs[f].submit()}catch(e){}}
          },400);
        },500);
      })();
    ''');
  }

  Future<void> _onSuccess() async {
    if (_loggedIn) return;
    _loggedIn = true; _urlTimer?.cancel();
    // Poll for cookies (WKWebView writes them asynchronously)
    String ck = '';
    for (int attempt = 0; attempt < 6 && ck.isEmpty; attempt++) {
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        final cs = await CookieManager.instance().getCookies(url: WebUri(widget.baseUrl));
        ck = cs.map((c) => '${c.name}=${c.value}').join('; ');
      } catch (_) {}
      if (ck.isEmpty && Platform.isIOS) {
        try {
          const ch = MethodChannel('com.smarteye/cookies');
          ck = await ch.invokeMethod('getCookies', {'url': widget.baseUrl}) as String? ?? '';
        } catch (_) {}
      }
    }
    if (ck.isEmpty && _ctrl != null) {
      try { ck = await _ctrl!.evaluateJavascript(source: 'document.cookie') as String? ?? ''; } catch (_) {}
    }
    if (ck.isNotEmpty) {
      final p = await SharedPreferences.getInstance();
      await p.setString('cookie_${widget.baseUrl}|${widget.account}|${widget.cashierJobNumber}', ck);
      try { final s = await StoreService.fetchStores(baseUrl: widget.baseUrl, cookie: ck); if (s.isNotEmpty) await StoreService.saveStores(widget.baseUrl, s); } catch (_) {}
    }
    if (mounted) { Navigator.of(context).pop(true); }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppConstants.bgColor,
    appBar: AppBar(
      title: const Text('\u5fae\u4fe1\u626b\u7801\u767b\u5f55', style: TextStyle(fontSize: 16)),
      actions: [if (_loading) const Padding(padding: EdgeInsets.only(right: 16), child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)))],
    ),
    body: Column(children: [
      Container(width: double.infinity, padding: const EdgeInsets.all(14), color: AppConstants.primaryColor.withValues(alpha: 0.05),
        child: Column(children: [
          if (_loading) const Text('\u23f3 \u6b63\u5728\u52a0\u8f7d\u2026', style: TextStyle(fontSize: 13, color: AppConstants.textSecondary))
          else ...[
            const Text('\ud83d\udcf1 \u8bf7\u622a\u56fe\u540e\u7528\u5fae\u4fe1\u626b\u4e00\u626b\u9a8c\u8bc1', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppConstants.primaryColor)),
            const SizedBox(height: 4),
            const Text('\u5fae\u4fe1 \u2192 \u626b\u4e00\u626b \u2192 \u53f3\u4e0b\u89d2\u76f8\u518c \u2192 \u9009\u62e9\u622a\u56fe', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
          ],
        ]),
      ),
      Expanded(child: InAppWebView(
        initialUrlRequest: URLRequest(url: WebUri('${widget.baseUrl}/Product/Manage')),
        initialSettings: InAppWebViewSettings(javaScriptEnabled: true, userAgent: _ua, sharedCookiesEnabled: true),
        onWebViewCreated: (c) { _ctrl = c; _seedCookies(); },
        onLoadStop: _onLoadStop,
        shouldOverrideUrlLoading: _overrideUrl,
      )),
    ]),
  );
}
