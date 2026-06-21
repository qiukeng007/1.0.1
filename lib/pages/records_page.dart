import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/constants.dart';
import '../services/query_service.dart';
import '../services/operation_log_service.dart';
import '../widgets/scanner_view.dart';

class RecordsPage extends StatefulWidget {
  final String? initialBarcode;
  final String? productName;

  const RecordsPage({super.key, this.initialBarcode, this.productName});

  /// Static cache so state survives when user navigates back and forth
  static String? cachedBarcode;
  static Set<String> cachedStores = {'总店', 'C1', 'C2', 'C3'};
  static int cachedDays = 7;
  static DateTime? cachedCustomStart;
  static DateTime? cachedCustomEnd;
  static List<StockHistoryResult> cachedResults = [];
  static bool cachedHasSearched = false;

  @override
  State<RecordsPage> createState() => _RecordsPageState();
}

class _RecordsPageState extends State<RecordsPage> {
  final _barcodeCtrl = TextEditingController();
  final _selectedStores = <String>{'总店', 'C1', 'C2', 'C3'};
  int _selectedDays = 7;
  DateTime? _customStart;
  DateTime? _customEnd;
  bool _loading = false;
  List<StockHistoryResult> _results = [];
  String? _error;
  bool _hasSearched = false; // results are cached

  // Cache last search params to avoid redundant queries
  String? _lastBarcode;
  Set<String>? _lastStores;
  int? _lastDays;
  DateTime? _lastCustomStart;
  DateTime? _lastCustomEnd;

  bool get _paramsChanged {
    if (!_hasSearched) return true;
    if (_barcodeCtrl.text.trim() != _lastBarcode) return true;
    if (!_setEquals(_selectedStores, _lastStores)) return true;
    if (_selectedDays != _lastDays) return true;
    if (_customStart != _lastCustomStart || _customEnd != _lastCustomEnd) return true;
    return false;
  }

  bool _setEquals(Set<String> a, Set<String>? b) {
    if (b == null) return false;
    return a.length == b.length && a.every(b.contains);
  }

  /// Sync current params to static cache so they survive page navigation
  void _syncCache() {
    RecordsPage.cachedStores = Set.from(_selectedStores);
    RecordsPage.cachedDays = _selectedDays;
    RecordsPage.cachedCustomStart = _customStart;
    RecordsPage.cachedCustomEnd = _customEnd;
    _savePrefs();
  }

  static const _storeIds = {'总店': '5634817', 'C1': '5634818', 'C2': '5634821', 'C3': '5968885'};
  static const _storeColors = {
    '总店': Color(0xFF2563EB), 'C1': Color(0xFF16A34A),
    'C2': Color(0xFFD97706), 'C3': Color(0xFF7C3AED),
  };

  static const _prefsStoresKey = 'stock_history_stores';
  static const _prefsDaysKey = 'stock_history_days';

  @override
  void initState() {
    super.initState();
    if (widget.initialBarcode != null) {
      _barcodeCtrl.text = widget.initialBarcode!;
    }
    _initFromPrefs();
  }

  Future<void> _initFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    // Restore store selection
    final savedStores = prefs.getStringList(_prefsStoresKey);
    if (savedStores != null && savedStores.isNotEmpty) {
      _selectedStores.clear();
      _selectedStores.addAll(savedStores.where((s) => _storeIds.containsKey(s)));
      RecordsPage.cachedStores = Set.from(_selectedStores);
    } else if (RecordsPage.cachedStores.isNotEmpty) {
      _selectedStores.clear();
      _selectedStores.addAll(RecordsPage.cachedStores);
    }
    // Restore days
    final savedDays = prefs.getInt(_prefsDaysKey);
    if (savedDays != null) {
      _selectedDays = savedDays;
      RecordsPage.cachedDays = savedDays;
    } else {
      _selectedDays = RecordsPage.cachedDays;
    }
    // Restore search results cache
    _results = RecordsPage.cachedResults;
    _hasSearched = RecordsPage.cachedHasSearched;
    _lastBarcode = RecordsPage.cachedBarcode;
    _lastStores = RecordsPage.cachedStores;
    _lastDays = RecordsPage.cachedDays;
    _lastCustomStart = RecordsPage.cachedCustomStart;
    _lastCustomEnd = RecordsPage.cachedCustomEnd;
    _customStart = RecordsPage.cachedCustomStart;
    _customEnd = RecordsPage.cachedCustomEnd;
    if (mounted) setState(() {});

    // Auto-search only on first visit for this barcode
    if (widget.initialBarcode != null && mounted) {
      final barcode = widget.initialBarcode!;
      if (!_hasSearched || barcode != RecordsPage.cachedBarcode) {
        // Small delay to ensure UI is ready
        await Future.delayed(const Duration(milliseconds: 100));
        if (mounted) _search();
      }
    }
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_prefsStoresKey, _selectedStores.toList());
    await prefs.setInt(_prefsDaysKey, _selectedDays);
  }

  String _fmtDate(DateTime dt) =>
      '${dt.year}.${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')}';

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final initial = _customEnd ?? now;
    final picked = await showDateRangePicker(
      context: context,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now,
      initialDateRange: DateTimeRange(
        start: _customStart ?? initial.subtract(const Duration(days: 7)),
        end: initial,
      ),
      helpText: '选择查询时间范围',
      cancelText: '取消',
      confirmText: '确定',
    );
    if (picked != null) {
      setState(() {
        _customStart = picked.start;
        _customEnd = picked.end;
        _selectedDays = 0;
        RecordsPage.cachedCustomStart = _customStart;
        RecordsPage.cachedCustomEnd = _customEnd;
        RecordsPage.cachedDays = _selectedDays;
      });
    }
  }

  @override
  void dispose() {
    _barcodeCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final barcode = _barcodeCtrl.text.trim();
    if (barcode.isEmpty) {
      setState(() => _error = '请输入条码');
      return;
    }

    setState(() { _loading = true; _error = null; _results = []; });

    // Log this search
    final stores = _selectedStores.join('+');
    await OperationLogService.add(store: stores, action: '查询库存明细', barcode: barcode);

    try {
      final prefs = await SharedPreferences.getInstance();
      final bu = prefs.getString('login_base_url') ?? 'beta28.pospal.cn';
      final ac = prefs.getString('login_account') ?? '';
      final em = prefs.getString('login_employee') ?? '';
      final fullUrl = 'https://${bu.replaceAll('https://', '').replaceAll('http://', '')}';
      final ck = prefs.getString('cookie_$fullUrl|$ac|$em') ?? '';

      if (ck.isEmpty) {
        setState(() { _error = '未登录，请先登录'; _loading = false; });
        return;
      }

      // Date range — Pospal format: yyyy.MM.dd HH:mm:ss
      String fmt(DateTime dt, String time) =>
          '${dt.year}.${dt.month.toString().padLeft(2, '0')}.${dt.day.toString().padLeft(2, '0')} $time';
      final end = _customEnd ?? DateTime.now();
      final start = _customStart ?? end.subtract(Duration(days: _selectedDays));

      final storesToQuery = _storeIds.entries
          .where((e) => _selectedStores.contains(e.key))
          .toList();

      final results = <StockHistoryResult>[];
      for (final entry in storesToQuery) {
        final qs = QueryService(baseUrl: fullUrl, cookie: ck);
        final r = await qs.fetchStockHistory(
          userId: entry.value,
          storeName: entry.key,
          barcode: barcode,
          startTime: fmt(start, '00:00:00'),
          endTime: fmt(end, '23:59:59'),
        );
        qs.dispose();
        results.add(r);
      }

      if (mounted) {
        setState(() {
          _results = results;
          _loading = false;
          _hasSearched = true;
          // Cache search params (instance + static for cross-page persistence)
          _lastBarcode = barcode;
          _lastStores = Set.from(_selectedStores);
          _lastDays = _selectedDays;
          _lastCustomStart = _customStart;
          _lastCustomEnd = _customEnd;
          RecordsPage.cachedBarcode = barcode;
          RecordsPage.cachedStores = Set.from(_selectedStores);
          RecordsPage.cachedDays = _selectedDays;
          RecordsPage.cachedCustomStart = _customStart;
          RecordsPage.cachedCustomEnd = _customEnd;
          RecordsPage.cachedResults = results;
          RecordsPage.cachedHasSearched = true;
          if (results.every((r) => r.error != null)) {
            _error = results.first.error;
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() { _error = '$e'; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.productName ?? widget.initialBarcode ?? '库存明细',
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      body: Column(
        children: [
          // ── Search form ──
          _buildSearchBar(),
          // ── Loading ──
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator())),
          // ── Error ──
          if (!_loading && _error != null)
            Expanded(child: Center(child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.error_outline, size: 48, color: AppConstants.textSecondary),
                const SizedBox(height: 12),
                Text(_error!, textAlign: TextAlign.center,
                  style: const TextStyle(color: AppConstants.textSecondary, fontSize: 14)),
                const SizedBox(height: 16),
                ElevatedButton(onPressed: _search, child: const Text('重试')),
              ]),
            ))),
          // ── Empty / no search yet ──
          if (!_loading && _error == null && !_hasSearched)
            Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.search, size: 48, color: AppConstants.textSecondary),
              const SizedBox(height: 12),
              const Text('点击"查询"查看库存变动明细', style: TextStyle(color: AppConstants.textSecondary)),
            ]))),
          // ── Empty results ──
          if (!_loading && _error == null && _hasSearched && _results.isEmpty)
            Expanded(child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.inventory_2_outlined, size: 48, color: AppConstants.textSecondary),
              const SizedBox(height: 12),
              const Text('该条码暂无变动记录', style: TextStyle(color: AppConstants.textSecondary)),
            ]))),
          // ── Results ──
          if (!_loading && _error == null && _results.isNotEmpty) ...[
            // Stale hint when params changed but showing cached results
            if (_paramsChanged)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                color: AppConstants.warningColor.withValues(alpha: 0.1),
                child: Row(children: [
                  const Icon(Icons.info_outline, size: 16, color: AppConstants.warningColor),
                  const SizedBox(width: 8),
                  const Expanded(child: Text('参数已变化，点击查询按钮刷新',
                    style: TextStyle(fontSize: 12, color: AppConstants.warningColor))),
                  TextButton(
                    onPressed: _search,
                    child: const Text('刷新', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(foregroundColor: AppConstants.warningColor, padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact),
                  ),
                ]),
              ),
            Expanded(child: _buildResults()),
          ],
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: AppConstants.dividerColor)),
      ),
      child: Column(children: [
        // Barcode input + scan + search button
        Row(children: [
          IconButton(
            icon: const Icon(Icons.qr_code_scanner, size: 22, color: AppConstants.primaryColor),
            tooltip: '扫码输入',
            onPressed: () async {
              final barcode = await Navigator.of(context).push<String>(
                MaterialPageRoute(builder: (_) => ScannerView(
                  onDetect: (b) => Navigator.pop(context, b),
                  onClose: () => Navigator.pop(context),
                )));
              if (barcode != null && barcode.isNotEmpty) {
                _barcodeCtrl.text = barcode;
                _search();
              }
            },
          ),
          const SizedBox(width: 4),
          Expanded(child: TextField(
            controller: _barcodeCtrl,
            keyboardType: TextInputType.number,
            style: const TextStyle(fontSize: 14),
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              hintText: '输入条码',
            ),
            onSubmitted: (_) => _search(),
          )),
          const SizedBox(width: 8),
          ElevatedButton(
            onPressed: _loading ? null : _search,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppConstants.primaryColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
            ),
            child: _loading
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('查询', style: TextStyle(fontSize: 14)),
          ),
        ]),
        const SizedBox(height: 8),
        // Store multi-select chips
        Row(children: [
          Expanded(child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              // Select all / deselect all
              GestureDetector(
                onTap: () => setState(() {
                  if (_selectedStores.length == _storeIds.length) {
                    _selectedStores.clear();
                  } else {
                    _selectedStores.addAll(_storeIds.keys);
                  }
                  _syncCache();
                }),
                child: Container(
                  margin: const EdgeInsets.only(right: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _selectedStores.length == _storeIds.length
                        ? AppConstants.primaryColor
                        : AppConstants.bgColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppConstants.dividerColor),
                  ),
                  child: Text(_selectedStores.length == _storeIds.length ? '取消全选' : '全选',
                    style: TextStyle(fontSize: 11, color: _selectedStores.length == _storeIds.length
                        ? Colors.white : AppConstants.textSecondary)),
                ),
              ),
              // Individual store chips
              ..._storeIds.keys.map((s) {
                final sel = _selectedStores.contains(s);
                final color = _storeColors[s] ?? AppConstants.primaryColor;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: FilterChip(
                    label: Text(s, style: TextStyle(fontSize: 11, color: sel ? Colors.white : AppConstants.textPrimary)),
                    selected: sel,
                    selectedColor: color,
                    checkmarkColor: Colors.white,
                    onSelected: (v) => setState(() {
                      if (v) { _selectedStores.add(s); } else { _selectedStores.remove(s); }
                      _syncCache();
                    }),
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                );
              }),
            ]),
          )),
        ]),
        const SizedBox(height: 6),
        // Date picker row
        Row(children: [
          const Text('时间:', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
          const SizedBox(width: 6),
          // Quick days presets
          ...['7天', '30天', '90天', '自定义'].map((label) {
            final isPreset = label != '自定义';
            int? days;
            if (isPreset) days = int.parse(label.replaceAll('天', ''));
            final active = _customStart == null && _customEnd == null && _selectedDays == days;
            return Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ChoiceChip(
                label: Text(label, style: TextStyle(fontSize: 11,
                  color: active ? Colors.white : AppConstants.textPrimary)),
                selected: active,
                selectedColor: AppConstants.primaryColor,
                onSelected: (_) => setState(() {
                  if (isPreset) {
                    _selectedDays = days!;
                    _customStart = null;
                    _customEnd = null;
                    _syncCache();
                  } else {
                    _pickDateRange();
                  }
                }),
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            );
          }),
          if (_customStart != null) ...[
            const SizedBox(width: 4),
            Expanded(child: Text(
              '${_fmtDate(_customStart!)} ~ ${_fmtDate(_customEnd!)}',
              style: const TextStyle(fontSize: 10, color: AppConstants.warningColor),
              overflow: TextOverflow.ellipsis,
            )),
            GestureDetector(
              onTap: () => setState(() { _customStart = null; _customEnd = null; _selectedDays = 7; _syncCache(); }),
              child: const Icon(Icons.close, size: 14, color: AppConstants.textSecondary),
            ),
          ],
        ]),
      ]),
    );
  }

  Widget _buildResults() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _results.length,
      itemBuilder: (ctx, i) {
        final r = _results[i];
        final color = _storeColors[r.storeName] ?? AppConstants.primaryColor;
        return _buildStoreSection(r, color);
      },
    );
  }

  Widget _buildStoreSection(StockHistoryResult r, Color color) {
    if (r.error != null) {
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Icon(Icons.store, size: 16, color: color),
            const SizedBox(width: 6),
            Text(r.storeName, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color)),
            const Spacer(),
            Text(r.error!, style: const TextStyle(fontSize: 12, color: AppConstants.errorColor)),
          ]),
        ),
      );
    }

    if (r.records.isEmpty) {
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Icon(Icons.store, size: 16, color: color),
            const SizedBox(width: 6),
            Text(r.storeName, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color)),
            const Spacer(),
            const Text('无变动记录', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
          ]),
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Store header
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(AppConstants.radiusSm)),
          ),
          child: Row(children: [
            Icon(Icons.store, size: 16, color: color),
            const SizedBox(width: 6),
            Text(r.storeName, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: color)),
            const Spacer(),
            Text('${r.records.length} 条',
              style: TextStyle(fontSize: 12, color: color.withValues(alpha: 0.7))),
          ]),
        ),
        // Table — compact width to fit screen
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowColor: WidgetStateProperty.all(AppConstants.bgColor),
            columnSpacing: 8,
            dataRowMinHeight: 32,
            dataRowMaxHeight: 44,
            columns: const [
              DataColumn(label: Text('#', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
              DataColumn(label: Text('时间', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
              DataColumn(label: Text('类型', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
              DataColumn(label: Text('变动', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
              DataColumn(label: Text('库存', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
              DataColumn(label: Text('备注', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
            ],
            rows: r.records.map((rec) {
              final isIn = (rec.stockChange ?? 0) > 0;
              final hasStockChange = rec.stockChange != null && rec.stockChange != 0;
              // Short time: "06-19 21:30"
              final shortTime = rec.time.length >= 16 ? rec.time.substring(5, 16) : rec.time;
              return DataRow(cells: [
                DataCell(SizedBox(width: 24, child: Text('${rec.index}',
                  style: const TextStyle(fontSize: 10, color: AppConstants.textSecondary)))),
                DataCell(SizedBox(width: 88, child: Text(shortTime, style: const TextStyle(fontSize: 10)))),
                DataCell(SizedBox(width: 60, child: Text(rec.changeType,
                  style: const TextStyle(fontSize: 10)))),
                DataCell(SizedBox(width: 44, child: hasStockChange
                    ? Text('${isIn ? "+" : ""}${rec.stockChange!.toInt()}',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                          color: isIn ? AppConstants.successColor : AppConstants.errorColor))
                    : const Text('—', style: TextStyle(fontSize: 10, color: AppConstants.textSecondary)))),
                DataCell(SizedBox(width: 40, child: Text(
                  rec.correctedStock != null ? '${rec.correctedStock!.toInt()}' : '—',
                  style: const TextStyle(fontSize: 10)))),
                DataCell(SizedBox(width: 120, child: Text(rec.remark,
                  style: const TextStyle(fontSize: 10, color: AppConstants.textSecondary),
                  maxLines: 2, overflow: TextOverflow.ellipsis))),
              ]);
            }).toList(),
          ),
        ),
      ]),
    );
  }
}
