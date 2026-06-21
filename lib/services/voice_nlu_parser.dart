import 'dart:math' show max;

/// Parse Chinese natural language voice input into structured product fields.
///
/// Handles the "大白话" patterns spoken by warehouse staff during stock entry.
/// Pure rule-engine, zero network, zero cost.

enum _PriceType { yuanJiaoFen, yuanJiao, digitUnit, jiao, chineseUnit, chineseDecimal, bareNum, chineseBare }

class _PricePattern {
  final RegExp re;
  final _PriceType type;
  const _PricePattern(this.re, {required this.type});
}

class VoiceNluParser {
  // ── Chinese digit mapping (extended) ──
  static const _digits = {
    '零': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5,
    '六': 6, '七': 7, '八': 8, '九': 9, '十': 10, '百': 100,
    '千': 1000, '万': 10000, '半': 0.5,
  };

  /// Main entry: parse recognized speech text into structured fields.
  /// Accepts lists of known categories/suppliers/units for fuzzy matching.
  /// [userHomophones] — raw config string from settings (format: "进价=竞价,金价")
  Map<String, String> parse(String text, {
    List<String> knownCategories = const [],
    List<String> knownSuppliers = const [],
    List<String> knownUnits = const [],
    String userHomophones = '',
  }) {
    final result = <String, String>{};
    if (text.isEmpty) return result;

    // Apply user-defined homophones first (e.g. "进价=竞价,金价")
    String lower = text;
    for (final line in userHomophones.split('\n')) {
      final parts = line.trim().split('=');
      if (parts.length == 2) {
        final target = parts[0].trim();
        final aliases = parts[1].split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
        for (final a in aliases) {
          lower = lower.replaceAll(a, target);
        }
      }
    }

    // Built-in normalization
    lower = lower
        .replaceAll('快', '块')
        .replaceAll('原', '元')
        .replaceAll('园', '元')
        .toLowerCase()
        .trim();

    // 1. Extract quantity: "50个", "来50个", "五十个", "一共50"
    _extractQty(lower, result);

    // 2. Extract store name: "C1增加", "总店入库"
    _extractStore(lower, result);

    // 3. Extract prices: "进价8毛", "卖2块", "进价一块五"
    _extractPrices(lower, result);

    // 4. Extract specification: "12乘8乘3cm"
    _extractSpec(lower, result);

    // 5. Fuzzy-match supplier name
    _extractSupplier(lower, knownSuppliers, result);

    // 6. Fuzzy-match category
    _extractCategory(lower, knownCategories, result);

    // 7. Match unit keywords
    _extractUnit(lower, knownUnits, result);

    return result;
  }

  // ── Quantity ──

  void _extractQty(String text, Map<String, String> out) {
    // Pattern: (来|要|一共|总共|库存|增加)? NUM (个|件|只|条|台|盒|箱|包)
    // Unit suffix is REQUIRED to avoid confusing prices ("8块") with qty ("8个")
    final m = RegExp(
      r'(?:来|要|一共|总共|入库|库存|进了?|增加)?\s*(\d+|[一二两三四五六七八九十百半]+)\s*(?:个|件|只|条|台|盒|箱|包)',
    ).firstMatch(text);
    if (m != null) {
      final num = _parseNumber(m.group(1)!);
      if (num > 0) out['qty'] = num.toInt().toString();
    }
  }

  // ── Prices ──

  /// Build a fuzzy regex from a keyword by expanding each char to its pinyin homophones.
  /// "进价" → [进近金今紧尽仅禁劲晋][价家假架驾嫁嘉佳夹甲贾钾]
  static final _pinyinExpand = <String, String>{
    '进': '进近金今紧尽仅禁劲晋浸锦',
    '价': '价家假架驾嫁嘉佳夹甲贾钾界借接届姐戒阶',
    '售': '售受手首守兽瘦收',
    '卖': '卖买麦迈脉埋',
    '货': '货或火活获霍祸',
    '购': '购够构勾狗垢',
    '零': '零铃灵龄凌陵',
    '成': '成程城诚承呈乘',
    '本': '本苯笨奔',
    '分': '分粉纷芬氛坟',
    '类': '类累雷泪垒蕾',
  };

  static String _fuzzy(String word) {
    final sb = StringBuffer();
    for (int i = 0; i < word.length; i++) {
      final ch = word[i];
      sb.write(_pinyinExpand.containsKey(ch) ? '[${_pinyinExpand[ch]}]' : ch);
    }
    return sb.toString();
  }

  void _extractPrices(String text, Map<String, String> out) {
    // Buy price prefix — pinyin-expanded fuzzy matching
    _tryPrice(text, out, 'buyPrice', RegExp('${_fuzzy("进价")}|${_fuzzy("成本")}|buy|价格'));

    // Sell price prefix — pinyin-expanded fuzzy matching
    _tryPrice(text, out, 'sellPrice', RegExp('${_fuzzy("售价")}|${_fuzzy("卖价")}|sell|${_fuzzy("零售")}'));
  }

  void _tryPrice(String text, Map<String, String> out, String key, RegExp prefixRe) {
    // Try structured patterns first, then bare numbers
    final patterns = <_PricePattern>[
      // "进价2块5毛4" / "8块5毛4" → 8.54 — three-level
      _PricePattern(RegExp(r'(\d+\.?\d*)\s*[块元快]\s*(\d+\.?\d*)\s*[毛角]\s*(\d+\.?\d*)'), type: _PriceType.yuanJiaoFen),
      // "进价2块5毛" / "进价2块5" — digit + unit + digit
      _PricePattern(RegExp(r'(\d+\.?\d*)\s*[块元快]\s*(\d+\.?\d*)\s*[毛角]?'), type: _PriceType.yuanJiao),
      // "进价2块" / "进价2元" — digit + unit
      _PricePattern(RegExp(r'(\d+\.?\d*)\s*[块元快](?:\b|$)'), type: _PriceType.digitUnit),
      // "进价8毛" — digit + 毛
      _PricePattern(RegExp(r'(\d+\.?\d*)\s*[毛角]'), type: _PriceType.jiao),
      // "进价一块五" / "进价两块半" — Chinese digits + unit + optional digit
      _PricePattern(RegExp(r'([一二两三四五六七八九十百千半]+)\s*[块元快]\s*([一二两三四五六七八九半]+)?\s*[毛角]?'), type: _PriceType.chineseUnit),
      // "进价一块" — Chinese digit + unit
      _PricePattern(RegExp(r'([一二两三四五六七八九十百千半]+)\s*[块元快]'), type: _PriceType.chineseUnit),
      // "进价八点四" / "八点五四" — Chinese decimal (1-2 digits after 点)
      _PricePattern(RegExp(r'([一二两三四五六七八九十百半]+)\s*点\s*([一二两三四五六七八九半])([一二两三四五六七八九半])?'), type: _PriceType.chineseDecimal),
      // "进价12.5" / "进价12" / "进价8.4" — bare decimal/float (must be near prefix)
      _PricePattern(RegExp(r'(?<!\d)(\d+\.\d+)(?!\s*[块元快毛角个件只条台盒箱包])'), type: _PriceType.bareNum),
      // "进价125" — bare integer (3-5 digits likely a price in cents or large)
      _PricePattern(RegExp(r'(?<!\d)(\d{2,5})(?!\s*[块元快毛角个件只条台盒箱包])'), type: _PriceType.bareNum),
      // "卖十三" / "卖二十五" — bare Chinese number
      _PricePattern(RegExp(r'([一二两三四五六七八九十百千半]+)'), type: _PriceType.chineseBare),
    ];

    for (final pp in patterns) {
      for (final m in pp.re.allMatches(text)) {
        // Check proximity to prefix (within 8 chars before match)
        final start = m.start;
        final before = start > 0 ? text.substring(max(0, start - 8), start) : '';
        if (!prefixRe.hasMatch(before)) continue;

        // Skip if this match is already consumed by another price
        if (out.containsKey(key)) return;

        double? price;
        switch (pp.type) {
          case _PriceType.yuanJiaoFen:
            // "8块5毛4" → 8.54
            final v1 = double.tryParse(m.group(1)!);
            final v2 = double.tryParse(m.group(2)!);
            final v3 = double.tryParse(m.group(3)!);
            if (v1 != null) price = v1 + (v2 ?? 0) / 10 + (v3 ?? 0) / 100;

          case _PriceType.yuanJiao:
            final yuan = double.tryParse(m.group(1)!);
            final jiao = double.tryParse(m.group(2)!);
            if (yuan != null) price = yuan + (jiao != null ? jiao / 10 : 0);

          case _PriceType.digitUnit:
            price = double.tryParse(m.group(1)!);

          case _PriceType.jiao:
            final v = double.tryParse(m.group(1)!);
            if (v != null) price = v / 10;

          case _PriceType.chineseUnit:
            final v1 = _parseChineseNum(m.group(1)!);
            price = v1;
            if (m.groupCount >= 2 && m.group(2) != null) {
              final v2 = _parseChineseNum(m.group(2)!);
              if (v2 != null) price = (v1 ?? 0) + v2 / 10;
            }

          case _PriceType.chineseDecimal:
            // "八点四" → 8.4, "八点五四" → 8.54
            final v1 = _parseChineseNum(m.group(1)!);
            final v2 = _parseChineseNum(m.group(2)!);
            final v3 = m.groupCount >= 3 && m.group(3) != null ? _parseChineseNum(m.group(3)!) : null;
            if (v1 != null && v2 != null) {
              if (v3 != null) {
                price = v1 + v2 / 10 + v3 / 100;
              } else {
                price = v1 + v2 / 10;
              }
            }

          case _PriceType.bareNum:
            final v = double.tryParse(m.group(1)!);
            // Only accept bare numbers if they could be prices (>= 0.1, not barcode-like)
            if (v != null && v >= 0.1 && v < 100000) price = v;

          case _PriceType.chineseBare:
            price = _parseChineseNum(m.group(1)!);
        }

        if (price != null && price > 0) {
          out[key] = price.toStringAsFixed(2);
          return;
        }
      }
    }
  }

  // ── Specification ──

  void _extractSpec(String text, Map<String, String> out) {
    // "12乘8乘3cm", "12×8×3", "12x8"
    final m = RegExp(
      r'(\d+\.?\d*)\s*[×xX\*乘]\s*(\d+\.?\d*)\s*(?:[×xX\*乘]\s*(\d+\.?\d*))?\s*(cm|mm|厘米|毫米)?',
      caseSensitive: false,
    ).firstMatch(text);
    if (m != null) {
      final parts = [m.group(1)!, m.group(2)!];
      if (m.group(3) != null) parts.add(m.group(3)!);
      final unit = m.group(4) ?? '';
      out['spec'] = '${parts.join('×')}$unit';
    }
  }

  // ── Store detection ──

  void _extractStore(String text, Map<String, String> out) {
    const stores = ['总店', 'C1', 'C2', 'C3'];
    for (final s in stores) {
      if (text.contains(s)) {
        out['store'] = s;
        return;
      }
    }
  }

  // ── Supplier fuzzy match ──

  void _extractSupplier(String text, List<String> suppliers, Map<String, String> out) {
    if (suppliers.isEmpty) return;
    // Sort by length desc for longest-match-first
    final sorted = suppliers.where((s) => s.isNotEmpty).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final s in sorted) {
      if (text.contains(s.toLowerCase())) {
        out['supplier'] = s;
        return;
      }
    }
  }

  // ── Category fuzzy match ──

  void _extractCategory(String text, List<String> categories, Map<String, String> out) {
    if (categories.isEmpty) return;
    final sorted = categories.where((c) => c.isNotEmpty).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final c in sorted) {
      // Match short label after "---", e.g. "01---灯具电器" → match "灯具"
      final short = c.split('---').last;
      if (text.contains(short) || text.contains(c)) {
        out['category'] = c;
        return;
      }
    }
  }

  // ── Unit match ──

  void _extractUnit(String text, List<String> units, Map<String, String> out) {
    // Direct match from known units
    for (final u in units) {
      if (text.contains(u)) {
        out['unit'] = u;
        return;
      }
    }
    // Common keyword mapping
    const kwMap = {'个': 'each', '盒': 'box', '包': 'pack', '瓶': 'bottle', '米': 'meter', '双': 'pair'};
    for (final e in kwMap.entries) {
      if (text.contains(e.key)) {
        out['unit'] = e.value;
        return;
      }
    }
  }

  // ── Number helpers ──

  double? _parseChineseNum(String s) {
    if (s.isEmpty) return null;
    // Try direct Arabic parse first
    final d = double.tryParse(s);
    if (d != null) return d;

    // Also try removing spaces: "1 2 5" → 125
    final compact = s.replaceAll(' ', '');
    final dc = double.tryParse(compact);
    if (dc != null) return dc;

    double result = 0;
    double current = 0;
    double section = 0;
    int lastUnit = 1;
    bool hadZero = false;
    bool hasDigit = false;

    for (int i = 0; i < s.length; i++) {
      final ch = s[i];
      final v = _digits[ch];
      if (v == null) continue;
      hasDigit = true;

      if (v == 10) {
        if (current == 0) current = 1;
        result += current * 10;
        current = 0;
        lastUnit = 10;
      } else if (v == 100) {
        if (current == 0) current = 1;
        result += current * 100;
        current = 0;
        lastUnit = 100;
        hadZero = false;
      } else if (v == 1000) {
        if (current == 0) current = 1;
        result += current * 1000;
        current = 0;
        lastUnit = 1000;
        hadZero = false;
      } else if (v == 10000) {
        if (current == 0 && result == 0) {
          result = 1;
        } else if (current > 0) {
          result += current;
          current = 0;
        }
        section = result * 10000;
        result = 0;
        lastUnit = 10000;
        hadZero = false;
      } else if (v == 0.5) {
        current = 0.5;
      } else if (v == 0) {
        hadZero = true;
      } else {
        current = v.toDouble();
      }
    }
    if (!hadZero && current > 0 && current < 10 && lastUnit == 100) {
      current *= 10;
    } else if (!hadZero && current > 0 && current < 100 && lastUnit == 1000) {
      current *= 100;
    }
    result += current;
    if (section > 0) result += section;
    return hasDigit ? result : null;
  }

  /// Parse number from string: "50" → 50, "五十" → 50
  num _parseNumber(String s) {
    final n = int.tryParse(s);
    if (n != null) return n;
    final cn = _parseChineseNum(s);
    return cn ?? 0;
  }
}

