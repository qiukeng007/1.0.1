import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:archive/archive.dart';

/// Manages Paraformer voice model download & caching.
/// Model is ~30MB, downloaded once and cached on device.
class ModelService {
  static const _modelDirName = 'paraformer_zh_small';
  static const _modelUrl =
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/'
      'sherpa-onnx-paraformer-zh-small-2024-03-09.tar.bz2';

  /// Generate a hotwords file to boost recognition of numbers and domain terms.
  /// Returns the file path, or null on failure.
  ///
  /// Hotwords bias the ASR model toward expected vocabulary. Without them,
  /// Paraformer-small frequently misrecognizes digits because single-syllable
  /// Chinese numbers (四/十/是, 七/一, etc.) sound nearly identical.
  static Future<String?> generateHotwordsFile() async {
    try {
      final dir = await _modelDir;
      final file = File('${dir.path}/hotwords.txt');

      // Don't regenerate if already exists
      if (await file.exists()) return file.path;

      final sb = StringBuffer();

      // ── Numbers 0-100 in Chinese (high boost — critical for prices) ──
      const digits = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十'];
      for (final d in digits) {
        sb.writeln('$d 4.0');
      }
      // Compound numbers
      for (int i = 1; i <= 99; i++) {
        final cn = _arabicToChinese(i);
        if (cn.length > 1) sb.writeln('$cn 3.5');
      }

      // ── Price-specific phrases (very high boost) ──
      const pricePhrases = [
        '进价', '售价', '卖价', '成本价', '价格',
        '一块', '两块', '三块', '四块', '五块', '六块', '七块', '八块', '九块', '十块',
        '一块五', '两块五', '三块五', '四块五', '五块五', '六块五', '七块五', '八块五', '九块五',
        '一毛', '两毛', '三毛', '四毛', '五毛', '六毛', '七毛', '八毛', '九毛',
        '8毛', '5毛', '3毛', '2毛', '1毛',
        '8块', '5块', '10块', '12块', '15块', '20块', '25块', '30块', '50块',
        '8块5', '12块5', '15块8',
      ];
      for (final p in pricePhrases) {
        sb.writeln('$p 4.0');
      }

      // ── Quantity phrases ──
      const qtyPhrases = [
        '一个', '两个', '三个', '四个', '五个', '六个', '七个', '八个', '九个', '十个',
        '一件', '两件', '三件', '四件', '五件',
        '一箱', '两箱', '三箱',
        '来', '要', '一共', '总共', '入库', '增加', '库存',
        '50个', '100个', '20个', '30个', '12个', '24个', '36个', '48个',
        '10个', '15个', '25个', '60个', '80个', '120个', '200个',
      ];
      for (final q in qtyPhrases) {
        sb.writeln('$q 3.0');
      }

      // ── Store names ──
      sb.writeln('总店 4.0');
      sb.writeln('C1 4.0');
      sb.writeln('C2 4.0');
      sb.writeln('C3 4.0');

      // ── Units ──
      const units = ['个', '件', '只', '条', '台', '盒', '箱', '包', '瓶', '双', '米', '厘米', '毫米'];
      for (final u in units) {
        sb.writeln('$u 3.0');
      }

      await file.writeAsString(sb.toString());
      return file.path;
    } catch (_) {
      return null;
    }
  }

  /// Convert Arabic integer to Chinese numeral (e.g., 25 → 二十五)
  static String _arabicToChinese(int n) {
    if (n <= 0) return '零';
    if (n < 10) return ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'][n];
    if (n < 20) return '十${n % 10 == 0 ? '' : ['', '一', '二', '三', '四', '五', '六', '七', '八', '九'][n % 10]}';
    if (n < 100) {
      final tens = n ~/ 10;
      final ones = n % 10;
      return '${['', '', '二', '三', '四', '五', '六', '七', '八', '九'][tens]}十${ones == 0 ? '' : ['', '一', '二', '三', '四', '五', '六', '七', '八', '九'][ones]}';
    }
    return '$n'; // fallback: Arabic
  }

  /// Check if model is already downloaded and extracted
  static Future<bool> isDownloaded() async {
    final dir = await _modelDir;
    if (!await dir.exists()) return false;
    final files = await dir.list().toList();
    return files.any((f) => f.path.endsWith('.onnx')) &&
           files.any((f) => f.path.endsWith('.txt')) &&
           files.any((f) => f.path.endsWith('.mvn'));
  }

  /// Get model directory path (null if not downloaded)
  static Future<String?> getModelPath() async {
    if (await isDownloaded()) return (await _modelDir).path;
    return null;
  }

  /// Download & extract model. Reports progress via callback.
  /// Returns model dir path on success, null on failure.
  static Future<String?> download(void Function(String msg) onProgress) async {
    final dir = await _modelDir;

    onProgress('⬇ 正在下载语音模型(~30MB)…');

    final client = http.Client();
    final request = http.Request('GET', Uri.parse(_modelUrl));
    final streamedResp = await client.send(request);

    if (streamedResp.statusCode != 200) {
      client.close();
      onProgress('下载失败 HTTP ${streamedResp.statusCode}');
      return null;
    }

    final tempFile = File('${dir.parent.path}/model_download.tar.bz2');
    final sink = tempFile.openWrite();
    await streamedResp.stream.pipe(sink);
    await sink.close();
    client.close();

    onProgress('🔧 正在解压模型…');

    if (await dir.exists()) await dir.delete(recursive: true);
    await dir.create(recursive: true);

    final fileBytes = await tempFile.readAsBytes();
    await tempFile.delete();

    final bz2 = BZip2Decoder().decodeBytes(fileBytes);
    final tar = TarDecoder().decodeBytes(bz2);
    for (final file in tar) {
      if (file.isFile &&
          (file.name.endsWith('.onnx') || file.name.endsWith('.txt') || file.name.endsWith('.mvn'))) {
        final name = file.name.split('/').last;
        if (name.isNotEmpty) {
          await File('${dir.path}/$name').writeAsBytes(file.content);
        }
      }
    }

    onProgress('✅ 语音模型就绪');
    return dir.path;
  }

  static Future<Directory> get _modelDir async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory('${appDir.path}/$_modelDirName');
  }
}
