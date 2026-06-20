import 'dart:convert';
import 'dart:io';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

/// AI Service — extracts product info from photos
///
/// Primary: ML Kit Text Recognition (offline, instant, free, unlimited)
/// Fallback: Gemini API or Ollama (cloud/local)
class AiService {
  final String? ollamaBaseUrl;
  final String? geminiKey;

  AiService({this.ollamaBaseUrl, this.geminiKey});

  /// Get raw OCR lines from photos (for manual selection)
  Future<List<String>> getOcrLines(List<File> photos) async {
    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    final lines = <String>[];

    for (final p in photos) {
      final inputImage = InputImage.fromFilePath(p.path);
      final recognized = await textRecognizer.processImage(inputImage);
      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          final t = line.text.trim();
          if (t.isNotEmpty) lines.add(t);
        }
      }
    }
    textRecognizer.close();
    return lines;
  }

  Future<AiProductResult> analyzePhotos(List<File> photos) async {
    // Primary: ML Kit OCR — instant, offline
    try {
      return await _analyzeWithMlKit(photos);
    } catch (e) {
      // Fallback to Gemini if available
      if (geminiKey != null && geminiKey!.isNotEmpty) {
        return _analyzeWithGemini(photos);
      }
      return AiProductResult(error: 'OCR 识别失败: $e');
    }
  }

  // ==================== ML Kit OCR ====================

  Future<AiProductResult> _analyzeWithMlKit(List<File> photos) async {
    final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
    final allText = <String>[];

    for (final p in photos) {
      final inputImage = InputImage.fromFilePath(p.path);
      final recognized = await textRecognizer.processImage(inputImage);
      allText.add(recognized.text);
      for (final block in recognized.blocks) {
        for (final line in block.lines) {
          allText.add(line.text);
        }
      }
    }
    textRecognizer.close();

    final fullText = allText.join('\n');
    return _parseOcrText(fullText);
  }

  /// Parse OCR text to extract product information
  AiProductResult _parseOcrText(String text) {
    String name = '';
    String barcode = '';
    String specification = '';
    String category = '';

    // 1. Extract barcode (13-digit or standard formats)
    final barcodeMatch = RegExp(r'\b(\d{13})\b|\b(\d{12})\b').firstMatch(text);
    if (barcodeMatch != null) {
      barcode = barcodeMatch.group(1) ?? barcodeMatch.group(2) ?? '';
    }

    // 2. Extract specification (dimensions like 12×8×3cm, 12*8*3cm, 12x8x3)
    final specMatch = RegExp(r'(\d+\.?\d*\s*[×xX\*]\s*\d+\.?\d*\s*[×xX\*]?\s*\d+\.?\d*\s*(?:cm|mm|CM|MM)?)').firstMatch(text);
    if (specMatch != null) {
      specification = specMatch.group(1)!.trim();
    }

    // 3. Product name — smart parsing for English/Chinese product labels
    final lines = text.split('\n').map((l) => l.trim()).where((l) =>
      l.isNotEmpty && l.length >= 2
    ).toList();

    // Noise patterns (both English and Chinese)
    final noise = [
      RegExp(r'^(生产日期|保质期|有效期|生产商|制造商|产地|地址|电话|邮编|网址|合格|检验|警告|注意)'),
      RegExp(r'^(净含量|净重|材质|成分|配料|执行标准|使用方法|贮藏|保存)'),
      RegExp(r'^(\d+\.?\d*\s*(元|￥|cm|mm|g|kg|ml|L)$)'),
      RegExp(r'^(MADE\s+IN|PRODUCT\s+OF|DISTRIBUTED\s+BY|IMPORTED\s+BY|MANUFACTURED)', caseSensitive: false),
      RegExp(r'^(www\.|http|\.com|\.cn)'),
      RegExp(r'^(WARNING|CAUTION|ATTENTION|NOTE|IMPORTANT)', caseSensitive: false),
      RegExp(r'^(BATCH|LOT\s*NO|MFG|EXP|PROD\s*DATE)', caseSensitive: false),
      RegExp(r'^(CHOKING\s+HAZARD|SMALL\s+PARTS|NOT\s+SUITABLE)', caseSensitive: false),
      RegExp(r'^\d{8,}'),  // barcodes
      RegExp(r'^[+\-]?\d+\.?\d*\s*(g|kg|ml|L|cm|mm|oz|lb|pcs|pc)$', caseSensitive: false),
    ];

    final candidates = <String>[];

    for (final line in lines) {
      bool skip = false;
      for (final p in noise) {
        if (p.hasMatch(line)) { skip = true; break; }
      }
      if (skip) continue;
      if (line.length < 3) continue;
      // Skip pure numbers/prices
      if (RegExp(r'^[$£¥€]?\d+\.?\d*$').hasMatch(line)) continue;

      // Accept: any line with letters or Chinese, reasonable length
      final hasText = RegExp(r'[A-Za-z一-鿿]').hasMatch(line);
      if (hasText && line.length >= 3 && line.length <= 60) {
        candidates.add(line);
      }
    }

    if (candidates.isNotEmpty) {
      // Score: prefer lines that look like brand/product names
      candidates.sort((a, b) {
        // Mixed case English = likely brand name (like "Nano Banana Pro")
        final aMixed = RegExp(r'[A-Z][a-z]').hasMatch(a) ? 3 : 0;
        final bMixed = RegExp(r'[A-Z][a-z]').hasMatch(b) ? 3 : 0;
        // Has numbers AND letters = likely model/spec, downgrade
        final aNumLetter = (RegExp(r'\d').hasMatch(a) && RegExp(r'[A-Za-z]').hasMatch(a)) ? -2 : 0;
        final bNumLetter = (RegExp(r'\d').hasMatch(b) && RegExp(r'[A-Za-z]').hasMatch(b)) ? -2 : 0;
        // Very short = downgrade
        final aShort = a.length < 5 ? -1 : 0;
        final bShort = b.length < 5 ? -1 : 0;

        return (bMixed + bNumLetter + bShort) - (aMixed + aNumLetter + aShort);
      });
      name = candidates.first;
    }

    // 4. Category from keywords
    final keywordMap = {
      '玩具': ['玩具', 'toy', '模型', '玩偶', '积木', '拼图', '公仔', '娃娃'],
      '文具': ['笔', '纸', '本', '文具', 'pen', 'pencil', '尺', '橡皮', '胶带', '胶水', '画', '颜料'],
      '家居': ['家居', '日用', '厨房', '浴室', '清洁', '收纳', '装饰', '家具'],
      '饰品': ['饰品', '发饰', '首饰', '项链', '耳环', '手链', '戒指', '发夹'],
      '数码': ['数码', '电子', '手机', '电脑', '充电', '数据线', '耳机', 'cable', 'USB'],
      '箱包': ['箱包', '包', '袋', '箱子', '旅行', '背包', '钱包'],
      '服装': ['衣服', '服装', '袜', '帽', '围巾', '手套', '鞋', 'T恤', '裤子'],
      '食品': ['食品', '饮料', '零食', '糖', '饼干', '茶', '咖啡', 'food'],
      '化妆品': ['化妆', '护肤', '美容', '香水', '洗面奶', '面霜', '口红', '粉底'],
      '五金': ['五金', '工具', '螺丝', '钳', '锤', '锯', '刀', '工具套'],
    };

    final lower = text.toLowerCase();
    for (final entry in keywordMap.entries) {
      for (final kw in entry.value) {
        if (lower.contains(kw.toLowerCase())) {
          category = entry.key;
          break;
        }
      }
      if (category.isNotEmpty) break;
    }

    return AiProductResult(
      name: name,
      barcode: barcode,
      specification: specification,
      category: category,
    );
  }

  // ==================== Gemini (fallback) ====================

  Future<AiProductResult> _analyzeWithGemini(List<File> photos) async {
    final parts = <Map<String, dynamic>>[];
    parts.add({
      'text': '识别商品照片，返回JSON：{"name":"商品名","barcode":"条码或空","specification":"规格或空","category":"玩具/文具/家居/饰品/数码/箱包/服装/食品/化妆品/五金/其他"}。只返回JSON。',
    });

    for (final p in photos) {
      final bytes = await p.readAsBytes();
      parts.add({
        'inline_data': {'mime_type': 'image/jpeg', 'data': base64Encode(bytes)},
      });
    }

    final body = jsonEncode({
      'contents': [{'parts': parts}],
      'generationConfig': {'temperature': 0.1, 'maxOutputTokens': 300},
    });

    try {
      final resp = await _httpPost(
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=${geminiKey!}',
        body,
      );
      final json = jsonDecode(resp) as Map<String, dynamic>;
      final text = json['candidates']?[0]?['content']?['parts']?[0]?['text'] as String? ?? '';
      return _extractJson(text);
    } catch (e) {
      return AiProductResult(error: 'Gemini: $e');
    }
  }

  // ==================== Helpers ====================

  AiProductResult _extractJson(String text) {
    try {
      final m = RegExp(r'\{[^{}]*\}').firstMatch(text);
      if (m != null) {
        final json = jsonDecode(m.group(0)!) as Map<String, dynamic>;
        return AiProductResult(
          name: json['name'] as String? ?? '',
          barcode: json['barcode'] as String? ?? '',
          specification: json['specification'] as String? ?? '',
          category: json['category'] as String? ?? '',
        );
      }
      return AiProductResult(error: '未返回有效 JSON');
    } catch (e) {
      return AiProductResult(error: '解析失败: $e');
    }
  }

  Future<String> _httpPost(String url, String body) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse(url);
      final request = await client.postUrl(uri);
      request.headers.set('Content-Type', 'application/json; charset=utf-8');
      final bytes = utf8.encode(body);
      request.headers.set('Content-Length', bytes.length.toString());
      request.add(bytes);
      final response = await request.close();
      final resp = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 400) {
        throw Exception('HTTP ${response.statusCode}');
      }
      return resp;
    } finally {
      client.close();
    }
  }
}

class AiProductResult {
  final String name;
  final String barcode;
  final String specification;
  final String category;
  final String? error;

  const AiProductResult({
    this.name = '',
    this.barcode = '',
    this.specification = '',
    this.category = '',
    this.error,
  });

  bool get ok => error == null && (name.isNotEmpty || barcode.isNotEmpty);
}
