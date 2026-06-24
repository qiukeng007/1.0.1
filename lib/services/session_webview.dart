import 'dart:async';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Keeps the login WebView alive after login so API requests can use its
/// session (including HttpOnly cookies that WKWebView won't expose).
class SessionWebView {
  static final SessionWebView instance = SessionWebView._();
  SessionWebView._();

  InAppWebViewController? _controller;
  bool _ready = false;
  int _reqId = 0;
  final _completers = <int, Completer<String>>{};

  void setController(InAppWebViewController ctrl) {
    _controller = ctrl;
    if (!_ready) {
      ctrl.addJavaScriptHandler(handlerName: 'apiResp', callback: (args) {
        final list = args as List<dynamic>?;
        if (list == null || list.isEmpty) return;
        final id = int.tryParse(list[0].toString());
        final body = list.length > 1 ? list[1].toString() : '';
        if (id != null) _completers.remove(id)?.complete(body);
      });
      _ready = true;
    }
  }

  bool get hasController => _controller != null;

  /// Make an HTTP request through the WebView's session.
  Future<String> fetch(String method, String url, {Map<String, String>? headers, String? body}) async {
    final ctrl = _controller;
    if (ctrl == null) throw StateError('SessionWebView not ready');

    final id = ++_reqId;
    final c = Completer<String>();
    _completers[id] = c;

    final h = headers?.entries.map((e) => '${e.key}: ${e.value}').join(',') ?? '';
    final b = (body ?? '').replaceAll("'", "\\'");

    await ctrl.evaluateJavascript(source: '''
      (async function(){
        try{
          var h={}; var hp='$h'.split(','); for(var i=0;i<hp.length;i++){var x=hp[i]; var ci=x.indexOf(':'); if(ci>0)h[x.substring(0,ci).trim()]=x.substring(ci+1).trim();}
          var opts={method:'$method',headers:h};
          if('$method'==='POST') opts.body='$b';
          var r=await fetch('$url',opts);
          var t=await r.text();
          window.flutter_inappwebview.callHandler('apiResp',$id,r.status+':'+encodeURIComponent(t));
        }catch(e){
          window.flutter_inappwebview.callHandler('apiResp',$id,'ERROR:'+e.message);
        }
      })();
      'ok';
    ''');

    final result = await c.future.timeout(const Duration(seconds: 30));
    if (result.startsWith('ERROR:')) throw Exception(result.substring(6));
    final colon = result.indexOf(':');
    final status = int.tryParse(result.substring(0, colon)) ?? 0;
    final respBody = Uri.decodeComponent(result.substring(colon + 1));
    if (status >= 400) throw Exception('HTTP $status');
    return respBody;
  }

  void dispose() {
    _completers.forEach((_, c) => c.complete('ERROR:disposed'));
    _completers.clear();
    _controller = null;
    _ready = false;
  }
}
