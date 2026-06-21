/// Normalizes ASR (Paraformer) output text to improve number recognition
/// before feeding into VoiceNluParser.
///
/// Paraformer small model frequently misrecognizes numbers because:
/// 1. Chinese digits sound similar: 四(sì)/十(shí), 七(qī)/一(yī), 九(jiǔ)/六(liù)
/// 2. Model outputs inconsistent format: sometimes Arabic "125", sometimes Chinese "一百二十五"
/// 3. Background noise distorts short syllables (digits are single-syllable in Chinese)
///
/// This normalizer applies layered corrections from safest to most aggressive.

class VoiceTextNormalizer {
  // ── Chinese digit → Arabic ──
  static const Map<String, int> _cnDigit = {
    '零': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4, '五': 5,
    '六': 6, '七': 7, '八': 8, '九': 9, '十': 10, '百': 100,
  };

  // ── Common ASR digit confusions (context-dependent) ──
  // Only applied when preceded/followed by price/quantity keywords
  static const Map<String, String> _digitConfusions = {
    '是': '4', '似': '4', '寺': '4', '死': '4', '思': '4',
    '酒': '9', '就': '9', '久': '9', '旧': '9', '救': '9',
    '吧': '8', '巴': '8', '拔': '8', '爸': '8',
    '汽': '7', '七': '7', '起': '7', '妻': '7', '奇': '7',
    '留': '6', '六': '6', '刘': '6', '流': '6',
    '武': '5', '五': '5', '无': '5', '屋': '5',
    '衣': '1', '一': '1', '以': '1', '已': '1',
    '耳': '2', '二': '2', '而': '2',
    '伞': '3', '三': '3', '散': '3',
    '石': '10', '十': '10',
  };

  /// Keywords that suggest a number is nearby (for context-based correction)
  static const _numberContextBefore = {
    '进价', '售价', '卖价', '成本', '价格', '价钱',
    '进', '卖', 'buy', 'sell', '块', '元', '毛', '角', '分',
    '来', '要', '一共', '总共', '入库', '增加', '补', '加',
  };
  static const _numberContextAfter = {
    '块', '元', '毛', '角', '分', '个', '件', '只', '条', '台', '盒', '箱', '包', '瓶',
    'cm', 'mm', '厘米', '毫米', '乘', '×', 'x',
  };

  /// Main entry: normalize ASR output for better NLU parsing
  String normalize(String text) {
    if (text.isEmpty) return text;

    var result = text;

    // ── Step 1: Normalize whitespace around digits ──
    result = result.replaceAll(RegExp(r'(\d)\s+(\d)'), r'$1$2');

    // ── Step 1.5: Convert Chinese decimal points BEFORE general number conversion ──
    // "十一点二三" → "11.23", "八点五" → "8.5", "二十五点七五" → "25.75", "一点零五" → "1.05"
    // Must run before Step 2, otherwise "十一" gets converted to "11" and "点二三" is orphaned.
    result = _convertChineseDecimals(result);

    // ── Step 2: Convert pure Chinese numbers to Arabic ──
    // "一百二十五" → "125", "五十个" → "50个", "八毛" → "8毛"
    result = _convertChineseNumbers(result);

    // ── Step 3: Mixed Chinese-Arabic normalization ──
    // "8块五" → "8块5", "2百5" → "250"
    result = _normalizeMixedNumbers(result);

    // ── Step 4: Context-aware digit confusion correction ──
    // "进价是块" → "进价4块" (context: near price keyword)
    result = _correctDigitConfusions(result);

    // ── Step 5: Fix common price patterns ──
    // "8快5" → "8块5", "8yuan" → "8元"
    result = result
        .replaceAll('快', '块')
        .replaceAll('原', '元')
        .replaceAll('园', '元')
        .replaceAll('yuan', '元')
        .replaceAll('mao', '毛')
        .replaceAll('jiao', '角')
        .replaceAll('fen', '分')
        .replaceAll(RegExp(r'(\d)快'), r'$1块')
        .replaceAll(RegExp(r'(\d)原'), r'$1元');

    // ── Step 6: Join separated adjacent digits in number context ──
    // "价格 1 2 5" → "价格 125"
    result = _joinAdjacentDigits(result);

    return result.trim();
  }

  // ── Chinese decimal conversion (must run BEFORE general number conversion) ──

  /// Convert "ChineseNumber + 点 + ChineseDigits" → Arabic decimal.
  /// "十一点二三" → "11.23", "八点五" → "8.5", "一点零五" → "1.05"
  String _convertChineseDecimals(String text) {
    final re = RegExp(r'([零一二两三四五六七八九十百]+)\s*点\s*([零一二两三四五六七八九]+)');
    return text.replaceAllMapped(re, (m) {
      final intCn = m.group(1)!;
      final fracCn = m.group(2)!;
      final intPart = _cnToArabic(intCn)?.toString() ?? intCn;
      // Convert each fractional digit individually: "二三" → "23", "五" → "5", "零五" → "05"
      final fracBuf = StringBuffer();
      for (int i = 0; i < fracCn.length; i++) {
        final d = _cnDigit[fracCn[i]];
        fracBuf.write(d?.toString() ?? fracCn[i]);
      }
      return '$intPart.$fracBuf';
    });
  }

  // ── Chinese number to Arabic ──

  String _convertChineseNumbers(String text) {
    // Match sequences of Chinese number characters (including 十百)
    final re = RegExp(r'[零一二两三四五六七八九十百]+');
    return text.replaceAllMapped(re, (m) {
      final cn = m.group(0)!;
      final arabic = _cnToArabic(cn);
      return arabic?.toString() ?? cn;
    });
  }

  int? _cnToArabic(String s) {
    if (s.isEmpty) return null;
    final d = int.tryParse(s);
    if (d != null) return d;

    int result = 0;
    int current = 0;
    int lastUnit = 1;
    bool hadZero = false; // "三百零六"=306, not 360

    for (int i = 0; i < s.length; i++) {
      final v = _cnDigit[s[i]];
      if (v == null) return null;

      if (v == 10) {
        if (current == 0) current = 1;
        if (result == 0 && current == 1 && i == 1 && _cnDigit[s[0]] != 10) {
          result = current * 10;
        } else {
          result += current * 10;
        }
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
      } else if (v == 0) {
        hadZero = true;
      } else {
        current = v;
      }
    }
    // Shorthand: "三百五"=350 (not 305), "一千三"=1300.
    // Only when there's no 零 in between (so "三百零六" stays 306).
    if (!hadZero && current > 0 && current < 10 && lastUnit == 100) {
      current *= 10;
    } else if (!hadZero && current > 0 && current < 100 && lastUnit == 1000) {
      current *= 100;
    }
    result += current;
    return result > 0 ? result : null;
  }

  // ── Mixed format normalization ──

  String _normalizeMixedNumbers(String text) {
    var result = text;

    // "8块五" → "8块5"
    result = result.replaceAllMapped(
      RegExp(r'(\d+)\s*[块元]\s*([一二两三四五六七八九半])'),
      (m) => '${m.group(1)}块${_singleCnToDigit(m.group(2)!)}',
    );

    // "8毛五" → "8毛5"
    result = result.replaceAllMapped(
      RegExp(r'(\d+)\s*[毛角]\s*([一二两三四五六七八九半])'),
      (m) => '${m.group(1)}毛${_singleCnToDigit(m.group(2)!)}',
    );

    // "8百5十" → "850" (rarer pattern)
    result = result.replaceAllMapped(
      RegExp(r'(\d+)\s*百\s*(\d+)\s*十'),
      (m) => '${int.parse(m.group(1)!) * 100 + int.parse(m.group(2)!) * 10}',
    );

    // "8百5" → "805"
    result = result.replaceAllMapped(
      RegExp(r'(\d+)\s*百\s*(\d+)(?!\s*十)'),
      (m) => '${int.parse(m.group(1)!) * 100 + int.parse(m.group(2)!)}',
    );

    return result;
  }

  String _singleCnToDigit(String cn) {
    final v = _cnDigit[cn];
    if (v != null && v < 10) return v.toString();
    if (cn == '半') return '5';
    return cn;
  }

  // ── Context-aware digit confusion correction ──

  String _correctDigitConfusions(String text) {
    final chars = text.split('');
    final result = StringBuffer();
    final len = chars.length;

    for (int i = 0; i < len; i++) {
      final ch = chars[i];
      final correction = _digitConfusions[ch];

      if (correction != null && _isNumberContext(text, i)) {
        result.write(correction);
      } else {
        result.write(ch);
      }
    }
    return result.toString();
  }

  /// Check if position i is in a number context (near price/qty keyword or another digit)
  bool _isNumberContext(String text, int pos) {
    // Check preceding context (within 5 chars)
    final start = pos > 5 ? pos - 5 : 0;
    final before = text.substring(start, pos);

    for (final kw in _numberContextBefore) {
      if (before.contains(kw)) return true;
    }

    // Check following context (within 3 chars)
    final end = pos + 3 < text.length ? pos + 3 : text.length;
    if (pos + 1 < text.length) {
      final after = text.substring(pos + 1, end);

      for (final kw in _numberContextAfter) {
        if (after.startsWith(kw) || after.contains(kw)) return true;
      }

      // If next char is a digit, we're in a number context
      if (after.isNotEmpty && RegExp(r'\d').hasMatch(after[0])) return true;
    }

    // If previous char is a digit, we're in a number context
    if (pos > 0 && RegExp(r'\d').hasMatch(text[pos - 1])) return true;

    return false;
  }

  // ── Adjacent digit joining ──

  String _joinAdjacentDigits(String text) {
    // Join single digits separated by spaces when near price/quantity keywords
    // "进价 1 2 块 5" → "进价 12 块 5"
    var result = text;

    // Pattern: keyword followed by space-separated digits
    for (final kw in _numberContextBefore) {
      final re = RegExp('($kw)\\s+(\\d)\\s+(\\d)');
      result = result.replaceAllMapped(re, (m) {
        return '${m.group(1)} ${m.group(2)}${m.group(3)}';
      });
    }

    // Global: join space-separated single digits (1-9) that appear together
    // "1 2 5" → "125", but only when near a context keyword
    result = result.replaceAllMapped(
      RegExp(r'(?<=[\d])\s+(?=\d)'),
      (m) => '',
    );

    return result;
  }
}
