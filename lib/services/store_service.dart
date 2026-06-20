import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

class SubStore {
  final String id;
  final String name;
  const SubStore({required this.id, required this.name});
}

class StoreService {
  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// Fetch available sub-stores from the Product/Manage page
  static Future<List<SubStore>> fetchStores({
    required String baseUrl,
    required String cookie,
  }) async {
    final url = Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}/Product/Manage');
    final client = HttpClient();
    try {
      final req = await client.getUrl(url);
      req.headers.set('User-Agent', _ua);
      req.headers.set('Cookie', cookie);
      req.headers.set('Accept', 'text/html,application/xhtml+xml');
      final resp = await req.close().timeout(const Duration(seconds: 10));
      final body = await resp.transform(utf8.decoder).join();

      if (resp.statusCode != 200) return [];

      final stores = <SubStore>[];

      // Parse main userId
      final userIdMatch = RegExp(r'var\s+currentUserId\s*=\s*(\d+)\s*;').firstMatch(body);
      final mainId = userIdMatch?.group(1);

      // Parse sub-user dropdown items
      // Pattern: <li ... data-userid="123" ...>StoreName</li>
      final liRegex = RegExp(r'<li[^>]*data-userid="(\d+)"[^>]*>([^<]+)</li>', caseSensitive: false);
      for (final m in liRegex.allMatches(body)) {
        stores.add(SubStore(id: m.group(1)!, name: m.group(2)!.trim()));
      }

      // If no sub-users found, use the main store
      if (stores.isEmpty && mainId != null) {
        // Try to extract store name from page
        final nameMatch = RegExp(r'currentShopName\s*=\s*"([^"]*)"').firstMatch(body);
        stores.add(SubStore(id: mainId, name: nameMatch?.group(1) ?? '总店'));
      }

      return stores;
    } finally {
      client.close();
    }
  }

  /// Save with fixed C1/C2/C3/C4 labels (position-based, never changes)
  static Future<void> saveStores(String baseUrl, List<SubStore> stores) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'stores_${baseUrl.hashCode}';
    final labels = ['总店', 'C1', 'C2', 'C3'];
    final data = <Map<String, String>>[];
    for (var i = 0; i < stores.length && i < labels.length; i++) {
      data.add({'id': stores[i].id, 'name': stores[i].name, 'label': labels[i]});
    }
    await prefs.setString(key, jsonEncode(data));
  }

  /// Load store mapping: {label: {id, name}}
  static Future<List<Map<String, String>>> loadStores(String baseUrl) async {
    final prefs = await SharedPreferences.getInstance();
    final key = 'stores_${baseUrl.hashCode}';
    final raw = prefs.getString(key);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List;
    return list.map((j) => {
      'id': j['id'] as String,
      'name': j['name'] as String,
      'label': j['label'] as String,
    }).toList();
  }
}
