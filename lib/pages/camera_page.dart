import 'dart:io';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import '../utils/constants.dart';
import '../widgets/scanner_view.dart';
import '../services/query_service.dart';
import 'result_sheet.dart';

class CameraPage extends StatefulWidget {
  const CameraPage({super.key});
  @override State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> with WidgetsBindingObserver {
  CameraController? _controller;
  final List<File> _photos = [];
  bool _isTakingPhoto = false, _isSubmitting = false, _cameraActive = false, _isInitialized = false;
  String? _error;
  int _maxPhotos = 3;
  String _selectedStore = 'C1';
  String _selectedSupplier = '';
  String? _newItemBarcode;
  final _barcodeCtrl = TextEditingController();
  final _supplierSearchCtrl = TextEditingController();
  final List<String> _storeList = ['总店', 'C1', 'C2', 'C3'];
  final List<String> _supplierList = [
    '邱铿', 'L228', 'F05', 'N68', 'C108', 'D317', 'B64', 'G56-G57',
    'MOMO(momo)-N1', 'B62', 'G27', 'L128', 'G45', 'A142', 'B34', 'HELLO TODAY',
    'N101', 'D313', 'V71', 'G21', 'KD康德kd', 'D104(林立)', 'M213',
    'LFHJ龙发货架lfhj', 'B54(anni)', 'F10B', 'MUCH BETTER', 'B16',
    'C216(印度香)', 'YDSF印度沙发ydsf', 'C06', 'C04', 'F09', 'F01-F02',
    'E12', 'C21', 'H76', 'G12', 'E115', 'A45(A4-5玩具店)', 'C88', 'L02',
    'A02-A04-N9', 'JJL佳佳乐jjl', 'WFL万福来wfl', 'F08', 'A18', 'B27',
    'B46', 'A034', 'C104', 'C22', 'M23', 'TESCO-E3-Tina(e3)', 'A292',
    'B65', 'SASA(sasa)', 'A3-A32-A33(行李箱)', 'F22', 'F33', 'H78',
    'JESON监控(D442)', 'A408', 'C01', 'L144', 'D327', 'B01', 'C43', 'C12',
    'G5', 'G52', 'JZ镜子工厂', 'U19', 'C308', 'CD床垫', 'G39-G40(监控)',
    'F10A', 'DDSJ当地书籍(ddsj)', 'B33(手机壳、手机膜)', 'HILOOK A275',
    'YDDT印度地毯yddt', 'YDCL印度窗帘配件(y dcl)', 'A01', 'B19', 'M140',
    'M101', 'T1', 'G1', 'L5', 'DDYL(当地饮料)', 'D326', 'BJH(百佳惠超市)',
    'ZZJ珍珠姐国旗', 'B11(手机壳)', 'ZGR中国人地毯', 'C37', 'G51', 'A10',
    'B58枪店', 'C17眼镜', 'M30', 'B08毛毯城', 'A407毛线', 'JJD(约堡家具店)',
    'C4', 'G42', 'C24C25', 'A107', 'E18', 'N113', 'B13', 'A410(A4-10)',
    'B10', 'C08', 'JIAOHUI教会家具店', 'C34', 'B59', 'F10C(f10c)',
    'WH208', 'WH219', 'WH227', 'F21', 'LSX隆升行',
  ];

  @override void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); _loadConfig(); }

  Future<void> _saveSelection() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_store', _selectedStore);
    await prefs.setString('last_supplier', _selectedSupplier);
  }

  // ── Select2-style searchable dropdown ──
  Widget _buildSupplierDropdown() {
    return GestureDetector(
      onTap: () => _showSupplierPicker(),
      child: Container(
        width: double.infinity,
        height: 42,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          border: Border.all(color: AppConstants.dividerColor),
          borderRadius: BorderRadius.circular(8),
          color: Colors.white,
        ),
        child: Row(children: [
          Expanded(child: Text(
            _selectedSupplier.isNotEmpty ? _selectedSupplier : '-- 请选择供货商 --',
            style: TextStyle(
              fontSize: 14,
              color: _selectedSupplier.isNotEmpty ? AppConstants.textPrimary : AppConstants.textSecondary,
            ),
          )),
          const Icon(Icons.arrow_drop_down, color: AppConstants.textSecondary),
        ]),
      ),
    );
  }

  void _showSupplierPicker() {
    final searchCtrl = TextEditingController();
    String filter = '';

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setSheetState) {
          final filtered = filter.isEmpty
              ? _supplierList
              : _supplierList.where((s) => s.toLowerCase().contains(filter.toLowerCase())).toList();
          return Container(
            height: MediaQuery.of(context).size.height * 0.6,
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              // Search input inside dropdown (Select2 style)
              TextField(
                controller: searchCtrl,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: '搜索供货商…',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: searchCtrl.text.isNotEmpty
                      ? IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: () { searchCtrl.clear(); setSheetState(() => filter = ''); })
                      : null,
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                ),
                onChanged: (v) => setSheetState(() => filter = v),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: filtered.isEmpty
                    ? const Center(child: Text('无匹配供货商', style: TextStyle(color: AppConstants.textSecondary)))
                    : ListView.separated(
                        itemCount: filtered.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final s = filtered[i];
                          final isSel = s == _selectedSupplier;
                          return ListTile(
                            dense: true,
                            selected: isSel,
                            title: Text(s, style: TextStyle(fontSize: 14, fontWeight: isSel ? FontWeight.w600 : FontWeight.normal, color: isSel ? AppConstants.primaryColor : AppConstants.textPrimary)),
                            trailing: isSel ? const Icon(Icons.check, size: 18, color: AppConstants.primaryColor) : null,
                            onTap: () {
                              setState(() { _selectedSupplier = s; _supplierSearchCtrl.text = s; });
                              _saveSelection();
                              Navigator.pop(ctx);
                            },
                          );
                        },
                      ),
              ),
            ]),
          );
        });
      },
    );
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    // Supplier list
    final saved = prefs.getString('supplier_list');
    if (saved != null && saved.isNotEmpty) {
      _supplierList.clear();
      final items = saved.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList()..sort();
      _supplierList.addAll(items);
    }
    // Restore last selections
    _selectedStore = prefs.getString('last_store') ?? 'C1';
    _selectedSupplier = prefs.getString('last_supplier') ?? (_supplierList.isNotEmpty ? _supplierList.first : '');
    _maxPhotos = prefs.getInt('photo_count') ?? 3;
    // Sync the search field to show the restored supplier
    if (mounted) setState(() {});
  }
  @override void dispose() { WidgetsBinding.instance.removeObserver(this); _controller?.dispose(); _barcodeCtrl.dispose(); _supplierSearchCtrl.dispose(); super.dispose(); }

  @override void didChangeAppLifecycleState(AppLifecycleState s) {
    if (!_cameraActive) return;
    if (s == AppLifecycleState.inactive) { _controller?.dispose(); _isInitialized = false; }
    else if (s == AppLifecycleState.resumed) _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) { setState(() => _error = '无摄像头'); return; }
      _controller = CameraController(
        cameras.firstWhere((c) => c.lensDirection == CameraLensDirection.back, orElse: () => cameras.first),
        ResolutionPreset.medium, enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await _controller!.initialize();
      if (mounted) setState(() { _isInitialized = true; _error = null; });
    } catch (e) { if (mounted) setState(() => _error = '$e'); }
  }

  Future<void> _startCamera() async { setState(() => _cameraActive = true); await _initCamera(); }
  Future<void> _stopCamera() async {
    await _controller?.dispose();
    setState(() { _cameraActive = false; _isInitialized = false; _photos.clear(); });
  }

  Future<void> _takePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized || _isTakingPhoto || _photos.length >= _maxPhotos) return;
    setState(() => _isTakingPhoto = true);
    try {
      final dir = await getTemporaryDirectory();
      final path = '${dir.path}/p_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final f = await _controller!.takePicture();
      await File(f.path).copy(path);
      setState(() { _photos.add(File(path)); _isTakingPhoto = false; });
    } catch (e) { setState(() => _isTakingPhoto = false); }
  }

  void _removePhoto(int i) => setState(() => _photos.removeAt(i));
  void _clearPhotos() => setState(() => _photos.clear());

  Future<void> _submitPhotos() async {
    if (_photos.isEmpty) return;
    setState(() => _isSubmitting = true);
    await Future.delayed(const Duration(seconds: 1));
    await _controller?.dispose();
    setState(() { _cameraActive = false; _isInitialized = false; _isSubmitting = false; });
    if (!mounted) return;
    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ResultSheet(photos: List.from(_photos), supplier: _selectedSupplier,
        targetStore: _selectedStore, prefillBarcode: _newItemBarcode,
        onSubmitComplete: () { _clearPhotos(); _newItemBarcode = null; }, onRetakePhotos: () { _clearPhotos(); _startCamera(); })));
    _clearPhotos();
  }

  Future<void> _startFlow() async {
    final barcode = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => ScannerView(onDetect: (b) => Navigator.pop(context, b), onClose: () => Navigator.pop(context))));
    if (barcode == null || barcode.isEmpty) return;
    _barcodeCtrl.text = barcode;
    await _searchBarcode(barcode);
  }

  Future<void> _searchBarcode(String barcode) async {
    final prefs = await SharedPreferences.getInstance();
    final bu = prefs.getString('login_base_url') ?? 'beta28.pospal.cn';
    final ac = prefs.getString('login_account') ?? '';
    final em = prefs.getString('login_employee') ?? '';
    final fullUrl = 'https://${bu.replaceAll('https://', '').replaceAll('http://', '')}';
    final ck = prefs.getString('cookie_$fullUrl|$ac|$em') ?? '';
    if (ck.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先登录'), backgroundColor: AppConstants.errorColor)); return; }

    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.white)));

    ProductData? product;
    try {
      final qs = QueryService(baseUrl: fullUrl, cookie: ck);
      final ids = {'总店': '5634817', 'C1': '5634818', 'C2': '5634821', 'C3': '5968885'};
      final pid = ids[_selectedStore] ?? '5634817';
      final all = ids.entries.map((e) => {'id': e.value, 'label': e.key, 'name': e.key}).toList();
      product = await qs.searchBarcode(barcode, subUsers: all, primaryStoreId: pid);
      qs.dispose();
    } catch (e) { product = ProductData(error: '$e'); }

    Navigator.of(context).pop();

    if (product == null || product!.error != null) {
      final err = product?.error ?? '';
      if (err.contains('未找到')) {
        _newItemBarcode = barcode;
        final startCamera = await Navigator.of(context).push<bool>(
          MaterialPageRoute(builder: (_) => ResultSheet(photos: const [], supplier: _selectedSupplier,
            targetStore: _selectedStore, forceOldItem: false, prefillBarcode: barcode, fromScan: true)));
        if (startCamera == true) { _newItemBarcode = barcode; await _startCamera(); }
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('查询失败：$err'), backgroundColor: AppConstants.errorColor));
      return;
    }

    await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ResultSheet(photos: const [], supplier: _selectedSupplier,
        targetStore: _selectedStore, forceOldItem: true, prefillBarcode: barcode, productData: product)));
  }

  @override Widget build(BuildContext context) {
    return Scaffold(backgroundColor: _cameraActive ? Colors.black : AppConstants.bgColor,
      body: SafeArea(child: _cameraActive ? _buildCamera() : _buildIdle()));
  }

  Widget _buildIdle() {
    return SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(children: [
      const SizedBox(height: 16),
      const Text('银豹入库', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppConstants.textPrimary)),
      const SizedBox(height: 4),
      const Text('选择门店和供货商，再扫码', style: TextStyle(fontSize: 13, color: AppConstants.textSecondary)),
      const SizedBox(height: 20),
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [Icon(Icons.store, size: 18, color: AppConstants.primaryColor), SizedBox(width: 8), Text('入库门店', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600))]),
        const SizedBox(height: 12),
        Row(children: _storeList.map((s) {
          final sel = s == _selectedStore;
          return Expanded(child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: ChoiceChip(label: Text(s, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: sel ? Colors.white : AppConstants.textPrimary)),
              selected: sel, selectedColor: AppConstants.primaryColor, backgroundColor: AppConstants.bgColor,
              onSelected: (_) { setState(() => _selectedStore = s); _saveSelection(); }, visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6)),
          ));
        }).toList()),
      ]))),
      const SizedBox(height: 14),
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [Icon(Icons.business, size: 18, color: AppConstants.primaryColor), SizedBox(width: 8), Text('选择供货商', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600))]),
        const SizedBox(height: 12),
        _buildSupplierDropdown(),
      ]))),
      const SizedBox(height: 16),
      // Barcode input + scan button
      Card(child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
        Expanded(child: GestureDetector(
          onDoubleTap: () => _barcodeCtrl.selection = TextSelection(baseOffset: 0, extentOffset: _barcodeCtrl.text.length),
          child: TextField(
          controller: _barcodeCtrl,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '手动输入或生成条码，双击全选', isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
          onSubmitted: (v) { if (v.trim().isNotEmpty) _searchBarcode(v.trim()); },
        ))),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          onPressed: _startFlow,
          icon: const Icon(Icons.qr_code_scanner, size: 18),
          label: const Text('扫码', style: TextStyle(fontSize: 13)),
          style: ElevatedButton.styleFrom(backgroundColor: AppConstants.primaryColor, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12)),
        ),
      ]))),
      const SizedBox(height: 10),
      // Generate + Search buttons
      Row(children: [
        Expanded(child: SizedBox(height: 40, child: ElevatedButton.icon(
          onPressed: () {
            final n = DateTime.now();
            final d = '${n.year.toString().substring(2)}${n.month.toString().padLeft(2,'0')}${n.day.toString().padLeft(2,'0')}${n.hour.toString().padLeft(2,'0')}${n.minute.toString().padLeft(2,'0')}';
            final r = (n.millisecond % 10).toString();
            setState(() => _barcodeCtrl.text = '$d$r');
          },
          icon: const Icon(Icons.auto_awesome, size: 14),
          label: const Text('生成条码', style: TextStyle(fontSize: 13)),
          style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, foregroundColor: Colors.white),
        ))),
        const SizedBox(width: 10),
        Expanded(child: SizedBox(height: 40, child: ElevatedButton.icon(
          onPressed: () { if (_barcodeCtrl.text.trim().isNotEmpty) _searchBarcode(_barcodeCtrl.text.trim()); },
          icon: const Icon(Icons.search, size: 16),
          label: const Text('搜索条码', style: TextStyle(fontSize: 13)),
          style: ElevatedButton.styleFrom(backgroundColor: AppConstants.primaryColor, foregroundColor: Colors.white),
        ))),
      ]),
      const SizedBox(height: 8),
      Text('$_selectedStore · $_selectedSupplier', style: const TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
    ]));
  }

  Widget _buildCamera() {
    return Column(children: [
      Container(color: Colors.black, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Row(children: [
        GestureDetector(onTap: _stopCamera, child: const Icon(Icons.close, color: Colors.white70, size: 24)),
        const SizedBox(width: 12),
        Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: AppConstants.primaryColor.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(12)),
          child: Text('$_selectedStore · $_selectedSupplier', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600))),
        const Spacer(), Text('${_photos.length}/$_maxPhotos', style: const TextStyle(color: Colors.white54, fontSize: 13)),
      ])),
      Expanded(child: _buildCameraArea()),
      Container(color: Colors.black, padding: const EdgeInsets.fromLTRB(16, 12, 16, 16), child: Stack(alignment: Alignment.center, children: [
        Align(alignment: Alignment.centerRight, child: _submitBtn()),
        GestureDetector(
          onTap: (_photos.length >= _maxPhotos || _isTakingPhoto || !_isInitialized) ? null : _takePhoto,
          child: Container(width: 60, height: 60, decoration: BoxDecoration(shape: BoxShape.circle,
            color: _photos.length >= _maxPhotos ? Colors.white12 : Colors.white, border: Border.all(color: Colors.white24, width: 3)),
            child: Icon(Icons.camera, color: _photos.length >= _maxPhotos ? Colors.white30 : AppConstants.primaryColor, size: 28))),
      ])),
    ]);
  }

  Widget _buildCameraArea() {
    if (_error != null) return Center(child: Text(_error!, style: const TextStyle(color: Colors.white54)));
    if (!_isInitialized || _controller == null) return const Center(child: CircularProgressIndicator(color: Colors.white));
    return Stack(fit: StackFit.expand, children: [
      CameraPreview(_controller!),
      if (_isTakingPhoto) Positioned.fill(child: Container(color: Colors.white54)),
      if (_photos.isNotEmpty) _photoStrip(),
    ]);
  }

  Widget _photoStrip() {
    return Positioned(bottom: 0, left: 0, right: 0,
      child: Container(height: 85, color: Colors.black54,
        child: Row(mainAxisAlignment: MainAxisAlignment.center,
          children: _photos.map((p) => _photoThumb(p)).toList())));
  }

  Widget _photoThumb(File photo) {
    final i = _photos.indexOf(photo);
    return Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Stack(children: [
        ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.file(photo, width: 65, height: 65, fit: BoxFit.cover)),
        Positioned(top: -4, right: -4,
          child: GestureDetector(onTap: () => _removePhoto(i),
            child: Container(width: 22, height: 22,
              decoration: BoxDecoration(color: AppConstants.errorColor, shape: BoxShape.circle),
              child: const Icon(Icons.close, size: 14, color: Colors.white)))),
      ]));
  }

  Widget _submitBtn() {
    final on = _photos.isNotEmpty && !_isSubmitting;
    return GestureDetector(onTap: on ? _submitPhotos : null,
      child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: on ? AppConstants.primaryColor : Colors.white12, borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.cloud_upload_outlined, color: on ? Colors.white : Colors.white30, size: 16), const SizedBox(width: 6),
          Text(_isSubmitting ? '分析中…' : '提交', style: TextStyle(color: on ? Colors.white : Colors.white30, fontSize: 13, fontWeight: FontWeight.w600)),
          if (_photos.isNotEmpty) ...[const SizedBox(width: 4), Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(8)),
            child: Text('${_photos.length}', style: const TextStyle(color: Colors.white, fontSize: 11)))],
        ])));
  }
}
