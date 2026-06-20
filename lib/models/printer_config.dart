import 'dart:convert';

/// 标签打印元素
class PrintElement {
  final String type; // barcode / name / price / supplier / barcodeNumber / spec / unit
  final double x, y;
  final double? width, height;
  final int fontSize;
  final bool bold;
  final double rightOffset;

  const PrintElement({
    required this.type, required this.x, required this.y,
    this.width, this.height, this.fontSize = 16, this.bold = false, this.rightOffset = 0.0,
  });

  Map<String, dynamic> toJson() => {
    'type': type, 'x': x, 'y': y, 'w': width, 'h': height,
    'fs': fontSize, 'b': bold, 'ro': rightOffset,
  };

  factory PrintElement.fromJson(Map<String, dynamic> j) => PrintElement(
    type: j['type'] as String,
    x: (j['x'] as num).toDouble(), y: (j['y'] as num).toDouble(),
    width: j['w'] != null ? (j['w'] as num).toDouble() : null,
    height: j['h'] != null ? (j['h'] as num).toDouble() : null,
    fontSize: j['fs'] as int? ?? 16, bold: j['b'] as bool? ?? false,
    rightOffset: (j['ro'] as num?)?.toDouble() ?? 0.0,
  );
}

class PrinterConfig {
  final String id, name, ip;
  final int port;
  final double labelWidth, labelHeight, columnGap;
  final bool doubleColumn, showPrice;
  final String protocol, barcodeType;
  final int dpi, barcodeNarrow, fontPreset;
  final List<PrintElement> elements;

  const PrinterConfig({
    required this.id, required this.name, this.ip = '', this.port = 18888,
    this.labelWidth = 40, this.labelHeight = 30, this.doubleColumn = false,
    this.elements = const [], this.showPrice = true, this.protocol = 'tspl',
    this.dpi = 180, this.columnGap = 2.0, this.barcodeNarrow = 2,
    this.fontPreset = 0, this.barcodeType = 'code128',
  });

  PrinterConfig copyWith({
    String? id, String? name, String? ip, int? port,
    double? labelWidth, double? labelHeight, bool? doubleColumn,
    List<PrintElement>? elements, bool? showPrice, String? protocol, int? dpi,
    int? barcodeNarrow, double? columnGap, int? fontPreset, String? barcodeType,
  }) => PrinterConfig(
    id: id ?? this.id, name: name ?? this.name, ip: ip ?? this.ip, port: port ?? this.port,
    labelWidth: labelWidth ?? this.labelWidth, labelHeight: labelHeight ?? this.labelHeight,
    doubleColumn: doubleColumn ?? this.doubleColumn, elements: elements ?? this.elements,
    showPrice: showPrice ?? this.showPrice, protocol: protocol ?? this.protocol,
    dpi: dpi ?? this.dpi, barcodeNarrow: barcodeNarrow ?? this.barcodeNarrow,
    columnGap: columnGap ?? this.columnGap, fontPreset: fontPreset ?? this.fontPreset,
    barcodeType: barcodeType ?? this.barcodeType,
  );

  Map<String, dynamic> toJson() => {
    'id': id, 'name': name, 'ip': ip, 'port': port,
    'lw': labelWidth, 'lh': labelHeight, 'dc': doubleColumn,
    'sp': showPrice, 'pr': protocol, 'dp': dpi, 'bn': barcodeNarrow,
    'cg': columnGap, 'fp': fontPreset, 'bt': barcodeType,
    'el': elements.map((e) => e.toJson()).toList(),
  };

  factory PrinterConfig.fromJson(Map<String, dynamic> j) => PrinterConfig(
    id: j['id'] as String? ?? DateTime.now().millisecondsSinceEpoch.toString(),
    name: j['name'] as String? ?? '', ip: j['ip'] as String? ?? '',
    port: j['port'] as int? ?? 18888,
    labelWidth: (j['lw'] as num?)?.toDouble() ?? 40,
    labelHeight: (j['lh'] as num?)?.toDouble() ?? 30,
    doubleColumn: j['dc'] as bool? ?? false, showPrice: j['sp'] as bool? ?? true,
    protocol: j['pr'] as String? ?? 'tspl', dpi: j['dp'] as int? ?? 180,
    barcodeNarrow: j['bn'] as int? ?? 2,
    columnGap: (j['cg'] as num?)?.toDouble() ?? 2.0,
    fontPreset: j['fp'] as int? ?? 0, barcodeType: j['bt'] as String? ?? 'code128',
    elements: (j['el'] as List<dynamic>?)?.map((e) => PrintElement.fromJson(e as Map<String, dynamic>)).toList() ?? [],
  );
}

List<PrinterConfig> defaultPrinters() => [
  PrinterConfig(id: 'p1', name: '80×35 大价签', labelWidth: 80, labelHeight: 35, showPrice: true, elements: const [
    PrintElement(type: 'supplier', x: 2, y: 1),
    PrintElement(type: 'name', x: 2, y: 6),
    PrintElement(type: 'unit', x: 50, y: 6),
    PrintElement(type: 'barcode', x: 2, y: 14, width: 76, height: 10),
    PrintElement(type: 'barcodeNumber', x: 2, y: 24),
    PrintElement(type: 'price', x: 2, y: 28),
  ]),
  PrinterConfig(id: 'p2', name: '40×25 双列', labelWidth: 40, labelHeight: 25, doubleColumn: true, protocol: 'zpl', elements: const [
    PrintElement(type: 'barcode', x: 2, y: 4, width: 36, height: 8),
    PrintElement(type: 'name', x: 2, y: 13),
    PrintElement(type: 'price', x: 2, y: 19),
  ]),
  PrinterConfig(id: 'p3', name: '40×30 单列', labelWidth: 40, labelHeight: 30, elements: const [
    PrintElement(type: 'name', x: 2, y: 1),
    PrintElement(type: 'barcode', x: 2, y: 7, width: 36, height: 10),
    PrintElement(type: 'price', x: 2, y: 22),
  ]),
  PrinterConfig(id: 'p4', name: '30×12 小条码', labelWidth: 30, labelHeight: 12, showPrice: false, elements: const [
    PrintElement(type: 'barcode', x: 2, y: 2, width: 26, height: 6),
    PrintElement(type: 'name', x: 2, y: 9),
  ]),
];
