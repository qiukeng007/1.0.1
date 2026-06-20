import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../utils/constants.dart';

class OcrSelectPage extends StatefulWidget {
  final List<String> lines;
  final String barcode;

  const OcrSelectPage({
    super.key,
    required this.lines,
    this.barcode = '',
  });

  @override
  State<OcrSelectPage> createState() => _OcrSelectPageState();
}

class _OcrSelectPageState extends State<OcrSelectPage> {
  final Map<int, String> _assignments = {};   // lineIndex → field
  final Map<int, String> _translations = {};   // lineIndex → Chinese translation

  static const _fieldOptions = ['忽略', '商品名称', '条码', '规格', '货号'];

  Future<void> _translateLine(int i, String text) async {
    if (text.isEmpty) return;
    if (!RegExp(r'[A-Za-z]{3,}').hasMatch(text)) return; // No English, skip

    try {
      final url = 'https://translate.googleapis.com/translate_a/single?client=gtx&sl=en&tl=zh-CN&dt=t&q=${Uri.encodeComponent(text)}';
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('User-Agent', 'Mozilla/5.0');
      final resp = await req.close();
      final body = await resp.transform(utf8.decoder).join();
      client.close();

      final json = jsonDecode(body) as List;
      if (json.isNotEmpty && json[0] is List && (json[0] as List).isNotEmpty) {
        final first = (json[0] as List)[0];
        if (first is List && first.isNotEmpty) {
          final translated = first[0].toString();
          if (mounted && translated != text) {
            setState(() => _translations[i] = translated);
          }
        }
      }
    } catch (_) {}
  }

  bool _needsTranslation(String text) {
    return RegExp(r'[A-Za-z]{3,}').hasMatch(text);
  }

  @override
  void initState() {
    super.initState();
    // Auto-translate all English lines
    for (var i = 0; i < widget.lines.length; i++) {
      final line = widget.lines[i].trim();
      if (_needsTranslation(line)) _translateLine(i, line);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.lines.where((l) => l.trim().isNotEmpty).toList();

    return Scaffold(
      backgroundColor: AppConstants.bgColor,
      appBar: AppBar(
        title: const Text('选择字段', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        actions: [
          TextButton(
            onPressed: _confirm,
            child: const Text('确认', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
      body: Column(
        children: [
          // Hint
          Container(
            margin: const EdgeInsets.fromLTRB(14, 14, 14, 0),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppConstants.primaryColor.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppConstants.primaryColor.withValues(alpha: 0.15)),
            ),
            child: const Text(
              '为每行文字选择对应字段，英文商品名会自动翻译',
              style: TextStyle(fontSize: 12, color: AppConstants.textSecondary, height: 1.5),
            ),
          ),

          const SizedBox(height: 8),

          // Lines list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              itemCount: lines.length,
              itemBuilder: (ctx, i) {
                final line = lines[i];
                final assigned = _assignments[i] ?? '忽略';
                return Card(
                  margin: const EdgeInsets.only(bottom: 6),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Line text + translation
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                line,
                                style: TextStyle(
                                  fontSize: 14,
                                  fontWeight: assigned == '忽略' ? FontWeight.normal : FontWeight.w600,
                                  color: assigned == '忽略' ? AppConstants.textPrimary : AppConstants.primaryColor,
                                ),
                              ),
                              if (_translations.containsKey(i))
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    '🌐 ${_translations[i]}',
                                    style: const TextStyle(fontSize: 12, color: Color(0xFFE65100), fontWeight: FontWeight.w500),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        // Dropdown
                        Expanded(
                          flex: 2,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              border: Border.all(color: assigned == '忽略' ? AppConstants.dividerColor : AppConstants.primaryColor),
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: assigned,
                                isExpanded: true,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: assigned == '忽略' ? AppConstants.textSecondary : AppConstants.primaryColor,
                                  fontWeight: assigned == '忽略' ? FontWeight.normal : FontWeight.w600,
                                ),
                                items: () {
                                  final base = _fieldOptions.where((f) {
                                    if (f == '忽略' || f == '商品名称') return true;
                                    for (final e in _assignments.entries) {
                                      if (e.key != i && e.value == f) return false;
                                    }
                                    return true;
                                  }).toList();
                                  // Add current assigned value if it's a numbered name
                                  if (assigned.startsWith('名称') && !base.contains(assigned)) {
                                    base.add(assigned);
                                  }
                                  return base.map((f) => DropdownMenuItem(
                                    value: f,
                                    child: Text(f, style: const TextStyle(fontSize: 12)),
                                  )).toList();
                                }(),
                                onChanged: (v) {
                                  if (v == '商品名称') {
                                    // Auto-number: count existing name selections
                                    var count = 1;
                                    for (final e in _assignments.entries) {
                                      if (e.key != i && e.value.startsWith('名称')) count++;
                                    }
                                    v = '名称$count';
                                  }
                                  setState(() => _assignments[i] = v ?? '忽略');
                                },
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          // Bottom bar
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [BoxShadow(color: Colors.black.withAlpha(13), blurRadius: 4, offset: const Offset(0, -1))],
            ),
            child: Row(children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    setState(() {
                      _assignments.clear();
                    });
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppConstants.textSecondary,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('重置', style: TextStyle(fontSize: 14)),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: _confirm,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppConstants.primaryColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: const Text('确认 → 编辑信息', style: TextStyle(fontSize: 14)),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  void _confirm() {
    String name1 = '', name2 = '', name3 = '', name4 = '', name5 = '', name = '';
    String barcode = widget.barcode;
    String specification = '';
    String articleNo = '';
    String category = '';
    String buyPrice = '';
    String sellPrice = '';

    for (final entry in _assignments.entries) {
      final text = widget.lines[entry.key].trim();
      switch (entry.value) {
        case '名称1': if (name1.isEmpty) name1 = text; break;
        case '名称2': if (name2.isEmpty) name2 = text; break;
        case '名称3': if (name3.isEmpty) name3 = text; break;
        case '名称4': if (name4.isEmpty) name4 = text; break;
        case '名称5': if (name5.isEmpty) name5 = text; break;
        case '商品名称': if (name.isEmpty) name = text; break;
        case '条码': if (barcode.isEmpty) barcode = _extractDigits(text); break;
        case '规格': if (specification.isEmpty) specification = text; break;
        case '货号':
          if (articleNo.isEmpty) { articleNo = text; if (!articleNo.endsWith('#')) articleNo = '$articleNo#'; }
          break;
        case '分类': if (category.isEmpty) category = text; break;
        case '进价': if (buyPrice.isEmpty) buyPrice = _extractPrice(text); break;
        case '售价': if (sellPrice.isEmpty) sellPrice = _extractPrice(text); break;
      }
    }

    // Concatenate 名称1+2+3+4+5
    final parts = [name1, name2, name3, name4, name5].where((p) => p.isNotEmpty).toList();
    if (parts.isNotEmpty) name = parts.join(' ');

    Navigator.of(context).pop({
      'name': name,
      'barcode': barcode,
      'specification': specification,
      'articleNo': articleNo,
      'category': category,
      'buyPrice': buyPrice,
      'sellPrice': sellPrice,
    });
  }

  String _extractDigits(String s) => s.replaceAll(RegExp(r'[^\d]'), '');
  String _extractPrice(String s) {
    final m = RegExp(r'(\d+\.?\d*)').firstMatch(s);
    return m != null ? m.group(1)! : '';
  }
}
