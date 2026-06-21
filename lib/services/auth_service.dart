import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

/// 系统授权服务 — 通过远程 password.txt 验证
///
/// 与 pospal_stock_app 共用同一密码文件：
///   {serverUrl}/PIC/password.txt
///
/// 修改服务器上的 password.txt 后，两个 APP 都会强制重新验证。
class AuthService {
  static const _authKey = 'sys_auth_v3';
  static const _localPwdKey = 'sys_local_pwd_v3';

  final SharedPreferences _prefs;
  AuthService(this._prefs);

  bool get isAuthorized => _prefs.getBool(_authKey) ?? false;

  /// 规范化 URL：http/https 通吃，去掉末尾 /
  static String normalizeUrl(String serverUrl) {
    var url = serverUrl.trim();
    if (url.isEmpty) return url;
    if (url.startsWith('https://')) {
      url = 'http://${url.substring(8)}';
    }
    if (!url.startsWith('http://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// 从远程获取明文密码（返回空字符串表示无法获取）
  Future<String> _fetchRemotePassword(String serverUrl) async {
    try {
      final url = normalizeUrl(serverUrl);
      if (url.isEmpty) return '';
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final uri = Uri.parse('$url/PIC/password.txt');
      final request = await client.getUrl(uri);
      final response = await request.close().timeout(const Duration(seconds: 4));
      if (response.statusCode == 200) {
        final body = await response.transform(utf8.decoder).join();
        client.close();
        final pwd = body.trim();
        // Only accept short alphanumeric strings as valid passwords (not HTML)
        if (pwd.isNotEmpty && !pwd.contains('<') && pwd.length <= 100) {
          return pwd;
        }
      }
      client.close();
    } catch (_) {}
    return '';
  }

  /// 是否需要重新验证（远程密码变了 或 从未验证）
  Future<bool> needReAuth(String serverUrl) async {
    if (!_prefs.containsKey(_authKey)) return true;
    final remotePwd = await _fetchRemotePassword(serverUrl);
    if (remotePwd.isEmpty) return false; // 连不上服务器，先跳过
    final localPwd = _prefs.getString(_localPwdKey) ?? '';
    return remotePwd != localPwd;
  }

  /// 获取远程密码用于比对
  Future<String> fetchRemotePassword(String serverUrl) async {
    return _fetchRemotePassword(serverUrl);
  }

  /// 验证用户输入
  bool verifyPassword(String input, String remotePwd) {
    return input.trim() == remotePwd;
  }

  /// 标记已授权
  Future<void> authorize(String serverUrl) async {
    await _prefs.setBool(_authKey, true);
    final remotePwd = await _fetchRemotePassword(serverUrl);
    if (remotePwd.isNotEmpty) {
      await _prefs.setString(_localPwdKey, remotePwd);
    }
  }

  /// 清除授权（强制重新验证）
  Future<void> clearAuth() async {
    await _prefs.remove(_authKey);
    await _prefs.remove(_localPwdKey);
  }
}
