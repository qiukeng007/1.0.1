import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';
import '../utils/constants.dart';
import '../models/printer_config.dart';
import '../services/printer_config_service.dart';
import '../services/printer_service.dart';
import '../widgets/scanner_view.dart';
import '../services/ai_service.dart';
import '../services/query_service.dart';
import '../services/voice_nlu_parser.dart';
import '../services/voice_text_normalizer.dart';
import '../services/model_service.dart';
import '../services/operation_log_service.dart';
import 'ocr_select_page.dart';
import 'records_page.dart';

enum AnalysisResult { oldItem, newItem }

class ResultSheet extends StatefulWidget {
  final List<File> photos;
  final VoidCallback? onSubmitComplete;
  final VoidCallback? onRetakePhotos;
  final String supplier;
  final String targetStore;
  final bool forceOldItem;
  final String? prefillBarcode;
  final bool fromScan;
  final dynamic productData;

  const ResultSheet({
    super.key,
    required this.photos,
    this.onSubmitComplete,
    this.onRetakePhotos,
    this.supplier = '邱铿',
    this.targetStore = '总店',
    this.forceOldItem = false,
    this.prefillBarcode,
    this.fromScan = false,
    this.productData,
  });

  @override
  State<ResultSheet> createState() => _ResultSheetState();
}

class _ResultSheetState extends State<ResultSheet> with TickerProviderStateMixin {
  AnalysisResult? _result;
  bool _analyzing = true;

  // ============ Common Controllers ============
  final _barcodeController = TextEditingController();
  final _nameController = TextEditingController();

  // ============ Old Item Fields ============
  String _stockTotal = '120';
  String _stockA = '85';
  String _stockB = '63';
  String _stockC = '42';
  double _oldBuyPrice = 0.80;
  double _oldSellPrice = 2.00;
  String _supplier = '邱铿';

  // Per-store restock (for old item)
  final Map<String, int> _oldRestock = {
    '总店': 0, 'C1': 0, 'C2': 0, 'C3': 0,
  };
  int get _totalOldRestock => _oldRestock.values.fold(0, (a, b) => a + b);

  // Persistent controllers for old-item stock fields (avoid rebuild creating new controllers)
  final Map<String, TextEditingController> _oldRestockCtrls = {
    '总店': TextEditingController(), 'C1': TextEditingController(),
    'C2': TextEditingController(), 'C3': TextEditingController(),
  };

  /// Update _oldRestock and sync the persistent controller
  void _setOldRestock(String store, int qty) {
    _oldRestock[store] = qty;
    final ctrl = _oldRestockCtrls[store];
    if (ctrl != null) {
      final newText = qty != 0 ? '$qty' : '';
      if (ctrl.text != newText) ctrl.text = newText;
    }
    setState(() {});
  }

  bool _priceChanged = false;
  double _newBuyPrice = 0.80;
  double _newSellPrice = 2.00;
  final _buyPriceController = TextEditingController();
  final _sellPriceController = TextEditingController();
  final _supplierController = TextEditingController();

  // ============ New Item Fields ============
  final _specController = TextEditingController();       // Empty - manual or voice
  final _articleNoController = TextEditingController();   // Empty - manual or voice
  String _selectedCategory = '';
  String _selectedUnit = 'each';
  String _selectedNewSupplier = '';
  final _supplierCtrl = TextEditingController();
  final _unitCtrl = TextEditingController();
  final _newBuyPriceController2 = TextEditingController();
  final _newSellPriceController2 = TextEditingController();
  final _newQtyController = TextEditingController();
  final List<TextEditingController> _extBarcodeCtrls = [];
  bool _extBarcodeExpanded = false;
  Set<String> _originalExtBarcodes = const <String>{}; // snapshot at load time for change detection

  /// Whether ext barcodes have been modified relative to the loaded snapshot
  bool get _extBarcodesChanged {
    final current = _extBarcodeCtrls.map((c) => c.text.trim()).where((b) => b.isNotEmpty).toSet();
    if (current.length != _originalExtBarcodes.length) return true;
    for (final b in current) {
      if (!_originalExtBarcodes.contains(b)) return true;
    }
    return false;
  }

  /// Comma-separated current ext barcodes (empty string if none)
  String get _extBarcodesCsv => _extBarcodeCtrls.map((c) => c.text.trim()).where((b) => b.isNotEmpty).join(',');

  // Unified getters — pick the non-empty value regardless of which form path set it
  String get _effUnit     => _unitCtrl.text.isNotEmpty ? _unitCtrl.text : _selectedUnit;
  String get _effSupplier => _supplierCtrl.text.isNotEmpty ? _supplierCtrl.text : _selectedNewSupplier;

  // Dropdown data (will be replaced with real data)
  static const List<String> _demoCategories = [
    '01---灯具电器', '灯具', '风扇', '电器', '线材开关插座', '电热器',
    '02---汽车配件', '车灯', '儿童自行车摩托车', '汽车配件',
    '03---五金工具',
    '04---生活用品', '窗帘用品', '地毯毛毯', '装饰摆件', '香薰香精', '个人洁护', '生活家电', '清洁护理', '生活用品',
    '05---厨房卫浴', '厨房厨具', '卫浴用品',
    '06---派对礼盒', '圣诞树', '礼盒礼袋', '生日派对',
    '07---化妆饰品', '化妆用品', '项链饰品', '美妆电子',
    '08---体育用品',
    '09---宠物用品',
    '10---塑料制品',
    '11---手机数码', '手机配件', '电脑配件', '电子数码', '音响', '数码线材',
    '12---茶食饮料', '饮料',
    '13---办公文具',
    '14---儿童玩具',
    '15---鞋服被褥', 'cosplay', '袜子手套帽子围巾', '拖鞋棉鞋', '内衣裤打底裤衣服裤子', '被子毛毯枕头',
    '16---花草渔具',
    '17---家具桌椅',
    '18---医药类',
    '19---监控探头',
    '20---电池电瓶',
    '21---防身自卫',
    '22---相框镜子',
    '23---窗帘地毯',
    '24---钱包箱包', '行李箱包', '书包餐包化妆包', '钱包',
    '25---通用条码',
    '26---未分类',
    '27---活动', '10%OFF', '15%OFF', '20%OFF', '25%OFF', '30%OFF', '35%OFF', '40%OFF', '45%OFF',
    '50%OFF', '55%OFF', '60%OFF', '65%OFF', '70%OFF',
    '快捷菜单', '玩具及学习用品', '生活用品类', '五金灯具开关', '电子数码类', '圣诞及礼品礼盒', '无',
  ];
  static const List<String> _demoUnits = [
    'each', 'box', 'pack', 'bottle', 'meter', 'pair',
  ];
  // Supplier list passed from camera page + demo extras
  List<String> _allSuppliersCache = ['L228','F05','N68','C108','D317','B64','G56-G57','KD康德kd','无'];
  bool _suppliersLoaded = false;

  Future<void> _loadSuppliers() async {
    if (_suppliersLoaded) return;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('supplier_list');
    final base = <String>{widget.supplier};
    if (saved != null && saved.isNotEmpty) {
      base.addAll(saved.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty));
    } else {
      base.addAll([
      '邱铿', 'L228', 'F05', 'N68', 'C108', 'D317', 'B64', 'G56-G57',
    ]);
    }
    _allSuppliersCache = base.toList()..sort();
    _suppliersLoaded = true;
    if (mounted) setState(() {});
  }

  Future<void> _loadLastCategory() async {
    final prefs = await SharedPreferences.getInstance();
    final cat = prefs.getString('last_category');
    if (cat != null && cat.isNotEmpty) {
      _selectedCategory = cat;
      if (mounted) setState(() {});
    }
  }

  Future<void> _saveLastCategory() async {
    if (_selectedCategory.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_category', _selectedCategory);
  }

  // ============ UI State ============
  bool _submitting = false;
  bool _submitted = false;
  bool _showDistribution = false;
  bool _recheckingBarcode = false;
  bool _showOldEdit = false;      // Old item: info display → edit form
  bool _showNewItemForm = false;  // New item: not-found → form
  bool _fromScan = false;         // Came from barcode scan (not AI)

  // Inline notification (replaces hidden SnackBars behind modal bottom sheet)
  String? _inlineMsg;
  Color? _inlineMsgColor;
  Timer? _inlineMsgTimer;

  // Persistent voice result (stays until user dismisses)
  String? _voiceResultText;
  bool _showVoiceActions = false;

  void _showInline(String msg, {bool isError = false, bool isWarning = false, Duration duration = const Duration(seconds: 3)}) {
    _inlineMsgTimer?.cancel();
    setState(() {
      _inlineMsg = msg;
      _inlineMsgColor = isError ? AppConstants.errorColor : isWarning ? AppConstants.warningColor : AppConstants.successColor;
    });
    _inlineMsgTimer = Timer(duration, () {
      if (mounted) setState(() { _inlineMsg = null; _inlineMsgColor = null; });
    });
  }

  // Category name → UID mapping (from Pospal HTML)
  static const Map<String, String> _categoryUids = {
    '01---灯具电器': '1716803895953887709', '灯具': '1723360035060642328', '风扇': '1723360089152807134',
    '电器': '1723360105387697351', '线材开关插座': '1723370633463984675', '电热器': '1748589985634159461',
    '02---汽车配件': '1716803926617450254', '车灯': '1748601936987405653', '儿童自行车摩托车': '1748601959414975298',
    '汽车配件': '1748602131183648017', '03---五金工具': '1716803940663180981',
    '04---生活用品': '1716816861453477841', '窗帘用品': '1721547515326184087', '地毯毛毯': '1721547655486188646',
    '装饰摆件': '1721547732404588329', '香薰香精': '1721593246882865390', '个人洁护': '1721636448448863868',
    '生活家电': '1721636489979670821', '清洁护理': '1721648057345699543', '生活用品': '1721981653616494994',
    '05---厨房卫浴': '1716816893614306229', '厨房厨具': '1721580749317105270', '卫浴用品': '1721580788028807783',
    '06---派对礼盒': '1716816917024708965', '圣诞树': '1729237717638390042', '礼盒礼袋': '1732907839652816666',
    '生日派对': '1732907893501698104', '07---化妆饰品': '1716816936915862511', '化妆用品': '1723020378791976731',
    '项链饰品': '1723020399688858411', '美妆电子': '1723020414092248368', '08---体育用品': '1716816959647511873',
    '09---宠物用品': '1716816976174938382', '10---塑料制品': '1716817606590308695',
    '11---手机数码': '1716817616000394037', '手机配件': '1721714525522904525', '电脑配件': '1721714605136868882',
    '电子数码': '1721714621729394088', '音响': '1748592043149962767', '数码线材': '1748602240166756383',
    '12---茶食饮料': '1716817639434174204', '饮料': '1727334948421725430',
    '13---办公文具': '1716817706440335226', '14---儿童玩具': '1716817723394813531',
    '15---鞋服被褥': '1716817754269422079', 'cosplay': '1748591774140626155',
    '袜子手套帽子围巾': '1748591836804381806', '拖鞋棉鞋': '1748591911539816046',
    '内衣裤打底裤衣服裤子': '1748591941333517612', '被子毛毯枕头': '1748591986417156390',
    '16---花草渔具': '1716820212100884740', '17---家具桌椅': '1716832799252645949',
    '18---医药类': '1716832897981255606', '19---监控探头': '1716832943623877484',
    '20---电池电瓶': '1716832965068777272', '21---防身自卫': '1716832985714512595',
    '22---相框镜子': '1716833013818567232', '23---窗帘地毯': '1716833062560152331',
    '24---钱包箱包': '1716833153851866012', '行李箱包': '1748602024852124150',
    '书包餐包化妆包': '1748602038072716605', '钱包': '1748602058777717591',
    '25---通用条码': '1716996999270396027', '26---未分类': '1716997038070988825',
    '27---活动': '1717580015070237346', '10%OFF': '1717580099175353225', '15%OFF': '1717580126971348460',
    '20%OFF': '1717580160687994081', '25%OFF': '1717580177266450350', '30%OFF': '1717580197173269294',
    '35%OFF': '1717580214465439410', '40%OFF': '1717580233001466391', '45%OFF': '1720864559986717693',
    '50%OFF': '1720864587103466178', '55%OFF': '1720864605181269181', '60%OFF': '1720864630055802750',
    '65%OFF': '1720864642314740300', '70%OFF': '1720864656468503518',
    '快捷菜单': '1737285654498103988', '玩具及学习用品': '1737447555276708181',
    '生活用品类': '1737447820067319603', '五金灯具开关': '1737447841352420446',
    '电子数码类': '1737447909501220099', '圣诞及礼品礼盒': '1737447929280615025', '无': '0',
  };

  String? _getCategoryUid(String name) => _categoryUids[name];

  static const Map<String, String> _unitUids = {
    'each': '1716997450288771749', 'box': '1716997532868211886', 'pack': '1716997545165229073',
    'bottle': '1716997563016102148', 'meter': '1716997571111667571', 'pair': '1734372628681491096',
  };

  static const Map<String, String> _supUids = {
    'A01': '899009567624761604', 'A02-A04-N9': '416171714438324527', 'A034': '532894013101468345',
    'A10': '316782780092469295', 'A107': '323077353124735781', 'A142': '1139529897406009086',
    'A18': '859508982322869305', 'A292': '756799647701736004', 'A3-A32-A33(行李箱)': '457464435963675020',
    'A407毛线': '479764158468246877', 'A408': '580978347076107144', 'A410(A4-10)': '896329615708985017',
    'A45(A4-5玩具店)': '623564136247158450', 'B01': '160558730743420195', 'B08毛毯城': '771193352851820104',
    'B10': '369943156244707615', 'B11(手机壳)': '866462052574192193', 'B13': '1069903426093151235',
    'B16': '1108017991810224912', 'B19': '490555859439327164', 'B27': '584351367117310704',
    'B33(手机壳、手机膜)': '222343012274327278', 'B34': '294274671935296535', 'B46': '1114001002562214192',
    'B54(anni)': '817027465620791476', 'B58枪店': '574656588088849938', 'B59': '690975872679049059',
    'B62': '908707614140879847', 'B64': '962422360051382623', 'B65': '1062476773534927505',
    'BJH(百佳惠超市)': '405611462215963528', 'C01': '30141739436235299', 'C04': '130039523424885199',
    'C06': '734581930898049856', 'C08': '96870443051591009', 'C104': '1134534508382560915',
    'C108': '114434418807107160', 'C12': '1043381934491318716', 'C17眼镜': '424081473579450568',
    'C21': '407872415107226824', 'C216(印度香)': '7088162153830422', 'C22': '1088917931354707024',
    'C24C25': '194869307536138462', 'C308': '715395956657502870', 'C34': '319688808634506999',
    'C37': '439904318133541889', 'C4': '824508802306313533', 'C43': '955268365567912417',
    'C88': '1109451221901075977', 'CD床垫': '470163177454097039', 'D104(林立)': '725596732127633607',
    'D313': '918907930002908328', 'D317': '72837722001060402', 'D326': '438297540341887002',
    'D327': '158747705334864751', 'DDSJ当地书籍（EDUCATION FOR THE NATION）(ddsj)': '248662171244964637',
    'DDYL(当地饮料)': '965210643816063033', 'E115': '311635021076765943', 'E12': '37360021291011631',
    'E18': '960594450461983620', 'F01-F02': '1012042854578281646', 'F05': '133207540280466416',
    'F08': '180164537142144785', 'F09': '1019356821465302993', 'F10A': '227116189604730955',
    'F10B': '770180509253013764', 'F10C(f10c)': '951762051718303722', 'F21': '540043752456560367',
    'F22': '574779508135689405', 'F33': '134998803447876086', 'G1': '865983407295157864',
    'G12': '1066145033007878464', 'G21': '929357406168806605', 'G27': '996074309629022224',
    'G39-G40(监控)': '535511481747168517', 'G42': '802636306788131659', 'G45': '1036557805383219502',
    'G5': '670245849254872463', 'G51': '45832615716413125', 'G52': '248560427057944783',
    'G56-G57': '1080176295703425661', 'H76': '156133032065611603', 'H78': '1134559147868187749',
    'HELLO TODAY': '419982666956583591', 'HILOOK A275': '505463438652242941',
    'JESON监控(D442)': '178385083254216886', 'JIAOHUI教会家具店': '1115655144880209432',
    'JJD(约堡家具店)': '991840144256458067', 'JJL佳佳乐jjl': '886590028779443844',
    'JZ镜子工厂': '328994781447878120', 'KD康德kd': '37790087008251562', 'L02': '812914505630391088',
    'L128': '79959985094536990', 'L144': '549980933191375229', 'L228': '95717256545864694',
    'L5': '170411626420710101', 'LFHJ龙发货架lfhj': '689430122917834778',
    'LSX隆升行': '726125380189773578', 'M101': '640951427701485641', 'M140': '192824238372672354',
    'M213': '792599725118590758', 'M23': '257486029645875290', 'M30': '713583044663653884',
    'MOMO(momo)-N1': '382204939003114541', 'MUCH BETTER': '637537256014696645',
    'N101': '1049139820392449433', 'N113': '300854981938366192', 'N68': '5799336938495667',
    'SASA(sasa)': '870582617434885345', 'T1': '929036604642491617',
    'TESCO-E3-Tina(e3)': '555507049303245579', 'U19': '1146173935741699',
    'V71': '152995126142420615', 'WFL万福来wfl': '413823585007907543',
    'WH208': '766270411930944475', 'WH219': '852354285178523032', 'WH227': '488578707461578462',
    'YDCL印度窗帘配件（papini trading）(ydcl)': '342166130789434678', 'YDDT印度地毯yddt': '310435286145001834',
    'YDSF印度沙发ydsf': '881400571665533946', 'ZGR中国人地毯(SAFARI CARPETS)': '432786241484365156',
    'ZZJ珍珠姐国旗': '638502360212026533',
  };

  String? _getSupplierUid(String name) => _supUids[name]?.isNotEmpty == true ? _supUids[name] : null;

  // ============ Distribution State ============
  final Map<String, int> _distribution = {
    '总店': 0, 'C1': 0, 'C2': 0, 'C3': 0,
  };

  int get _totalDistributed => _distribution.values.fold(0, (a, b) => a + b);
  int get _totalStock => int.tryParse(_newQtyController.text) ?? 0;
  int get _remainingStock => _totalStock - _totalDistributed;

  // Static toggle for demo alternating
  static bool? _toggleOldNew;

  // ============ Init ============

  String _nameTranslation = '';
  bool _translating = false;
  Timer? _translateTimer;

  @override
  void initState() {
    super.initState();
    _supplierController.text = widget.supplier;
    _selectedNewSupplier = widget.supplier;
    _supplierCtrl.text = widget.supplier;
    _loadSuppliers();

    // Listen to price changes for real-time margin calculation
    void onPriceChanged() { if (mounted) setState(() {}); }
    _buyPriceController.addListener(onPriceChanged);
    _sellPriceController.addListener(onPriceChanged);
    _newBuyPriceController2.addListener(onPriceChanged);
    _newSellPriceController2.addListener(onPriceChanged);

    // Default unit for new items
    _unitCtrl.text = 'each';

    // Debounced translation on name change
    _nameController.addListener(_onNameChanged);

    // Voice: pulse animation + eager model path loading
    _voicePulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _initVoiceModel();

    _simulateAnalysis();
  }

  void _onNameChanged() {
    _translateTimer?.cancel();
    final text = _nameController.text.trim();
    if (text.isEmpty || text == _nameTranslation) {
      setState(() => _nameTranslation = '');
      return;
    }
    _translateTimer = Timer(const Duration(milliseconds: 600), () => _doTranslate(text));
  }

  Future<void> _doTranslate(String text) async {
    if (text.isEmpty) return;
    setState(() => _translating = true);
    final from = _isChinese(text) ? 'zh-CN' : 'en';
    final to = from == 'zh-CN' ? 'en' : 'zh-CN';
    final result = await _googleTranslate(text, from: from, to: to);
    if (mounted) {
      setState(() {
        _translating = false;
        if (result != null && result != text) {
          _nameTranslation = result;
        } else {
          _nameTranslation = '';
        }
      });
    }
  }

  Widget _buildTranslationPreview(String original) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(children: [
        const SizedBox(width: 74), // align with field content
        Expanded(child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: const Color(0xFFE65100).withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFFE65100).withValues(alpha: 0.2)),
          ),
          child: Row(children: [
            const Text('🌐 ', style: TextStyle(fontSize: 12)),
            Expanded(child: _translating
                ? const Text('翻译中…', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary, fontStyle: FontStyle.italic))
                : _nameTranslation.isNotEmpty
                    ? GestureDetector(
                        onTap: () => _nameController.text = _nameTranslation,
                        child: Text(_nameTranslation, style: const TextStyle(fontSize: 13, color: Color(0xFFE65100), fontWeight: FontWeight.w500)),
                      )
                    : const Text('无法翻译', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
          )]),
        )),
      ]),
    );
  }

  @override
  void dispose() {
    _translateTimer?.cancel();
    _inlineMsgTimer?.cancel();
    _nameController.removeListener(_onNameChanged);
    _barcodeController.dispose();
    _nameController.dispose();
    _specController.dispose();
    _articleNoController.dispose();
    _buyPriceController.dispose();
    _sellPriceController.dispose();
    _supplierController.dispose();
    _supplierCtrl.dispose();
    _unitCtrl.dispose();
    _newBuyPriceController2.dispose();
    _newSellPriceController2.dispose();
    _newQtyController.dispose();
    for (final c in _extBarcodeCtrls) { c.dispose(); }
    _extBarcodeCtrls.clear();
    for (final c in _oldRestockCtrls.values) { c.dispose(); }
    _voicePulseCtrl.dispose();
    super.dispose();
  }

  Future<void> _simulateAnalysis() async {
    // If forced old item (from barcode scan), skip analysis
    if (widget.forceOldItem) {
      if (widget.prefillBarcode != null) {
        _barcodeController.text = widget.prefillBarcode!;
      }

      // Use real product data if available
      if (widget.productData != null) {
        final p = widget.productData;
        _nameController.text = p.name ?? '';
        _specController.text = p.specification ?? '';
        _selectedCategory = p.category ?? '';
        _selectedNewSupplier = p.supplier ?? widget.supplier;
        _supplierCtrl.text = _selectedNewSupplier;
        _selectedUnit = p.unit ?? '—';
        _unitCtrl.text = _selectedUnit;
        _extBarcodeCtrls.clear();
        final ext = p.extBarcode;
        if (ext != null && ext.isNotEmpty) {
          for (final b in ext.split(',')) {
            final t = b.trim();
            // Filter placeholder values returned by API when column is empty
            if (t.isNotEmpty && t != '—' && t != '–' && t != '-' && t != '无' && t != '暂无') {
              _extBarcodeCtrls.add(TextEditingController(text: t));
            }
          }
          // Don't auto-expand — only show when user taps "展开编辑"
        }
        _originalExtBarcodes = _extBarcodeCtrls.map((c) => c.text.trim()).where((b) => b.isNotEmpty).toSet();
        _buyPriceController.text = (p.buyPrice ?? 0).toStringAsFixed(2);
        _sellPriceController.text = (p.sellPrice ?? 0).toStringAsFixed(2);
        _oldBuyPrice = p.buyPrice ?? 0;
        _oldSellPrice = p.sellPrice ?? 0;

        // Multi-store stocks (as integers)
        String fmtStock(double? s) => s != null ? s.toInt().toString() : '—';
        if (p.storeStocks.isNotEmpty) {
          final ss = p.storeStocks;
          if (ss.length > 0) _stockTotal = fmtStock(ss[0].stock);
          if (ss.length > 1) _stockA = fmtStock(ss[1].stock);
          if (ss.length > 2) _stockB = fmtStock(ss[2].stock);
          if (ss.length > 3) _stockC = fmtStock(ss[3].stock);
        } else {
          _stockTotal = p.stock != null ? p.stock!.toInt().toString() : '0';
          _stockA = '—'; _stockB = '—'; _stockC = '—';
        }
      } else {
        _nameController.text = '卡通塑料解压捏捏乐';
      }

      _result = AnalysisResult.oldItem;
      _fromScan = true;
      _analyzing = false;
      if (mounted) setState(() {});
      return;
    }

    // New item: if from scan, show "not found" page first
    if (widget.fromScan && widget.photos.isEmpty) {
      _result = AnalysisResult.newItem;
      _fromScan = true;
      if (widget.prefillBarcode != null) _barcodeController.text = widget.prefillBarcode!;
      _analyzing = false;
      if (mounted) setState(() {});
      return;
    }

    // AI analysis for new items (with photos, from camera)
    if (widget.photos.isNotEmpty) {
      await _runAiAnalysis();
    }
    if (mounted) {
      _result = AnalysisResult.newItem;
      _fromScan = false;
      _showNewItemForm = true;
      if (_selectedNewSupplier.isEmpty) _selectedNewSupplier = widget.supplier;
      _loadLastCategory(); // only for new items — old items keep their own category
      setState(() => _analyzing = false);
    }
  }

  String? _aiError;

  Future<void> _runAiAnalysis() async {
    try {
      // ML Kit OCR — instant, offline
      final ai = AiService();
      final lines = await ai.getOcrLines(widget.photos);

      if (lines.isEmpty) {
        _aiError = '未识别到任何文字';
        _barcodeController.text = widget.prefillBarcode ?? '';
        return;
      }

      // Show OCR selection page
      if (mounted) {
        final result = await Navigator.of(context).push<Map<String, String>>(
          MaterialPageRoute(
            builder: (_) => OcrSelectPage(
              lines: lines,
              barcode: widget.prefillBarcode ?? '',
            ),
          ),
        );

        if (result != null && mounted) {
          if (result['name']?.isNotEmpty == true) _nameController.text = result['name']!;
          if (result['barcode']?.isNotEmpty == true) _barcodeController.text = result['barcode']!;
          // Build 规格及货号: "规格 货号#" (both in one field for display)
          final spec = result['specification'] ?? '';
          final artNo = result['articleNo'] ?? '';
          if (spec.isNotEmpty || artNo.isNotEmpty) {
            _specController.text = [spec, artNo].where((s) => s.isNotEmpty).join(' ');
          }
          if (artNo.isNotEmpty) {
            _articleNoController.text = artNo;
          }
          if (result['category']?.isNotEmpty == true) _selectedCategory = result['category']!;
          if (result['buyPrice']?.isNotEmpty == true) _newBuyPriceController2.text = result['buyPrice']!;
          if (result['sellPrice']?.isNotEmpty == true) _newSellPriceController2.text = result['sellPrice']!;
        }
      }
    } catch (e) {
      _aiError = e.toString();
      _barcodeController.text = widget.prefillBarcode ?? '';
    }
  }

  // ============ Build ============

  void _onVoiceResult(String text, Map<String, String> parsed) {
    if (parsed['qty']?.isNotEmpty == true) {
      final qty = int.tryParse(parsed['qty']!) ?? 0;
      final store = parsed['store']?.isNotEmpty == true ? parsed['store']! : null;
      if (_result == AnalysisResult.oldItem) {
        if (store != null && _oldRestock.containsKey(store)) {
          // User specified a store → put all qty there
          setState(() => _setOldRestock(store, qty));
        } else {
          // No store specified → use target store (from camera page selection)
          setState(() => _setOldRestock(widget.targetStore, qty));
        }
      } else {
        _newQtyController.text = qty.toString();
      }
    }
    if (parsed['buyPrice']?.isNotEmpty == true) {
      if (_result == AnalysisResult.oldItem) {
        _buyPriceController.text = parsed['buyPrice']!;
        _priceChanged = true;
      } else {
        _newBuyPriceController2.text = parsed['buyPrice']!;
      }
    }
    if (parsed['sellPrice']?.isNotEmpty == true) {
      if (_result == AnalysisResult.oldItem) {
        _sellPriceController.text = parsed['sellPrice']!;
        _priceChanged = true;
      } else {
        _newSellPriceController2.text = parsed['sellPrice']!;
      }
    }
    if (parsed['supplier']?.isNotEmpty == true) {
      setState(() { _selectedNewSupplier = parsed['supplier']!; _supplierCtrl.text = _selectedNewSupplier; });
    }
    if (parsed['unit']?.isNotEmpty == true) {
      final u = parsed['unit']!;
      if (_demoUnits.contains(u)) {
        setState(() { _selectedUnit = u; _unitCtrl.text = u; });
      }
    }
    if (parsed['category']?.isNotEmpty == true) {
      final c = parsed['category']!;
      if (_demoCategories.contains(c)) {
        setState(() => _selectedCategory = c);
      }
    }
    if (parsed['spec']?.isNotEmpty == true) {
      _specController.text = '${_specController.text} ${parsed['spec']}'.trim();
    }
    if (parsed['articleNo']?.isNotEmpty == true) {
      _articleNoController.text = parsed['articleNo']!;
      _specController.text = '${_specController.text} #${parsed['articleNo']}'.trim();
    }
    _showInline('🎤 $text');
  }

  @override
  Widget build(BuildContext context) {
    // Hierarchical back: edit→info, info→CameraPage
    final canGoBack = _showOldEdit || _showDistribution || _showNewItemForm;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_showOldEdit) {
          setState(() => _showOldEdit = false);
        } else if (_showDistribution) {
          setState(() => _showDistribution = false);
        } else if (_showNewItemForm && _fromScan) {
          setState(() => _showNewItemForm = false);
        } else {
          Navigator.of(context).pop();
        }
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        appBar: AppBar(
          leading: canGoBack
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () {
                    if (_showOldEdit) {
                      setState(() => _showOldEdit = false);
                    } else if (_showDistribution) {
                      setState(() => _showDistribution = false);
                    } else if (_showNewItemForm && _fromScan) {
                      setState(() => _showNewItemForm = false);
                    } else {
                      Navigator.of(context).pop();
                    }
                  },
                )
              : null,
          title: Text(
            _result == AnalysisResult.oldItem ? '已有商品' : '新品建档',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          actions: [
            if (_barcodeController.text.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.history, size: 22),
                tooltip: '查看库存明细',
                onPressed: () => _viewStockHistory(),
              ),
            Container(
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppConstants.primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text('🏪 ${widget.targetStore}',
                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppConstants.primaryColor)),
            ),
          ],
        ),
        body: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
              child: _analyzing
                  ? _buildAnalyzing()
                  : _submitted
                      ? _buildSuccess()
                      : _showDistribution
                          ? _buildDistributionPage()
                          : _result == AnalysisResult.oldItem
                              ? (_showOldEdit ? _buildOldItemEditPage() : _buildOldItemInfo())
                              : (_fromScan && !_showNewItemForm
                                  ? _buildNewItemNotFound()
                                  : _buildNewItemResult()),
            ),
            // Inline notification banner
            if (_inlineMsg != null)
              Positioned(top: 0, left: 0, right: 0, child: _buildInlineBanner()),
            // Persistent voice result bar
            if (_voiceResultText != null)
              Positioned(top: 0, left: 0, right: 0, child: _buildVoiceResultBar()),
            // Voice FAB
            if (!_analyzing && !_submitted)
              Positioned(right: 16, bottom: 80, child: _buildVoiceFab()),
          ],
        ),
    ),
    );
  }

  // ==================== Analyzing ====================

  Widget _buildAnalyzing() {
    final hasPhotos = widget.photos.isNotEmpty;
    return Column(
      children: [
        const SizedBox(height: 8),
        Container(
          width: 40, height: 4,
          decoration: BoxDecoration(color: AppConstants.dividerColor, borderRadius: BorderRadius.circular(2)),
        ),
        const Spacer(),
        Column(children: [
          if (hasPhotos)
            Image.file(widget.photos.first, width: 120, height: 120, fit: BoxFit.cover)
          else
            Container(
              width: 120, height: 120,
              decoration: BoxDecoration(color: AppConstants.primaryColor.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(16)),
              child: const Icon(Icons.search, size: 48, color: AppConstants.primaryColor),
            ),
          const SizedBox(height: 24),
          const SizedBox(width: 32, height: 32, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(height: 16),
          Text(
            hasPhotos ? 'AI 识别分析中…' : '查询商品信息…',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppConstants.textPrimary),
          ),
          const SizedBox(height: 4),
          Text(
            hasPhotos ? '正在提取条码、分析商品信息' : '正在数据库中检索条码',
            style: const TextStyle(fontSize: 13, color: AppConstants.textSecondary),
          ),
        ]),
        const Spacer(),
      ],
    );
  }

  // ==================== Old Item: Info Display ====================

  Widget _buildOldItemInfo() {
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
          width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          decoration: BoxDecoration(color: AppConstants.successColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(AppConstants.radiusSm), border: Border.all(color: AppConstants.successColor.withValues(alpha: 0.3))),
          child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.check_circle, color: AppConstants.successColor, size: 20), SizedBox(width: 8),
            Text('已有商品', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppConstants.successColor)),
          ]),
        ),
        const SizedBox(height: 16),

        // Product info card (read-only)
        _buildProductInfoCard(),
        const SizedBox(height: 16),

        // Stock display card
        Card(
          child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [
            const Text('各门店库存', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const Divider(height: 16),
            Row(
              children: [
                Expanded(child: _stockInfoCol(widget.productData != null && widget.productData!.storeStocks.isNotEmpty ? widget.productData!.storeStocks[0].storeName : '总店', _stockTotal)),
                Expanded(child: _stockInfoCol(widget.productData != null && widget.productData!.storeStocks.length > 1 ? widget.productData!.storeStocks[1].storeName : 'C1', _stockA)),
                Expanded(child: _stockInfoCol(widget.productData != null && widget.productData!.storeStocks.length > 2 ? widget.productData!.storeStocks[2].storeName : 'C2', _stockB)),
                Expanded(child: _stockInfoCol(widget.productData != null && widget.productData!.storeStocks.length > 3 ? widget.productData!.storeStocks[3].storeName : 'C3', _stockC)),
              ],
            ),
          ])),
        ),

        const SizedBox(height: 20),

        // Modify button
        SizedBox(width: double.infinity, child: ElevatedButton.icon(
          onPressed: () => setState(() => _showOldEdit = true),
          icon: const Icon(Icons.edit),
          label: const Text('修改信息 / 补货', style: TextStyle(fontSize: 16)),
          style: ElevatedButton.styleFrom(backgroundColor: AppConstants.primaryColor, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
        )),
        const SizedBox(height: 10),
        // Print button
        SizedBox(width: double.infinity, child: OutlinedButton.icon(
          onPressed: _showPrintDialog,
          icon: const Icon(Icons.print, size: 18),
          label: const Text('打印价签', style: TextStyle(fontSize: 14)),
          style: OutlinedButton.styleFrom(foregroundColor: AppConstants.primaryColor, side: const BorderSide(color: AppConstants.primaryColor), padding: const EdgeInsets.symmetric(vertical: 12)),
        )),
      ]),
    );
  }

  Widget _stockInfoCol(String name, String stock) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
      child: Column(children: [
        Text(name, style: const TextStyle(fontSize: 11, color: AppConstants.textSecondary)),
        const SizedBox(height: 4),
        Text(stock, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppConstants.textPrimary)),
      ]),
    );
  }

  // ==================== Old Item: Edit Page ====================

  Widget _buildOldItemEditPage() {
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          TextButton(
            onPressed: () => setState(() => _showOldEdit = false),
            child: const Text('取消', style: TextStyle(fontSize: 14, color: AppConstants.textSecondary)),
            style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
          ),
          const Expanded(child: Text('修改商品信息', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: 16),
        _buildOldItemEditForm(),
        const SizedBox(height: 16),
        // Stock adjustment
        Card(
          child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.add_shopping_cart, size: 16, color: AppConstants.primaryColor), SizedBox(width: 6),
              Text('库存调整', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              Spacer(),
              Text('调入/调出', style: TextStyle(fontSize: 11, color: AppConstants.textSecondary)),
            ]),
            const SizedBox(height: 4),
            Center(child: Text('${_totalOldRestock > 0 ? "+" : ""}$_totalOldRestock', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: _totalOldRestock < 0 ? AppConstants.errorColor : AppConstants.primaryColor))),
            const Divider(height: 18),
            Row(children: [
              Expanded(child: _oldRestockCol('总店', _stockTotal)),
              const SizedBox(width: 6),
              Expanded(child: _oldRestockCol('C1', _stockA)),
              const SizedBox(width: 6),
              Expanded(child: _oldRestockCol('C2', _stockB)),
              const SizedBox(width: 6),
              Expanded(child: _oldRestockCol('C3', _stockC)),
            ]),
          ])),
        ),
        const SizedBox(height: 16),
        SizedBox(width: double.infinity, child: ElevatedButton(
          onPressed: _submitting ? null : _submitOldItemEdit,
          style: ElevatedButton.styleFrom(backgroundColor: AppConstants.successColor, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
          child: _submitting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('✅ 提交库存调整', style: TextStyle(fontSize: 16)),
        )),
      ]),
    );
  }

  // ==================== Old Item ====================

  Widget _buildOldItemResult() {
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
          width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          decoration: BoxDecoration(color: AppConstants.successColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(AppConstants.radiusSm), border: Border.all(color: AppConstants.successColor.withValues(alpha: 0.3))),
          child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(Icons.check_circle, color: AppConstants.successColor, size: 20), SizedBox(width: 8),
            Text('旧商品 · 快捷补货', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppConstants.successColor)),
          ]),
        ),
        const SizedBox(height: 16),

        // Editable product info (except barcode)
        _buildOldItemEditForm(),
        const SizedBox(height: 16),

        // Per-store stock + add buttons
        Card(
          child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Row(children: [
              Icon(Icons.add_shopping_cart, size: 16, color: AppConstants.primaryColor), SizedBox(width: 6),
              Text('补货分配', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
              Spacer(),
              Text('本次补货', style: TextStyle(fontSize: 11, color: AppConstants.textSecondary)),
            ]),
            const SizedBox(height: 4),
            Center(
              child: Text('$_totalOldRestock', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: AppConstants.primaryColor)),
            ),
            const Divider(height: 18),
            Row(
              children: [
                Expanded(child: _oldRestockCol('总店', _stockTotal)),
                const SizedBox(width: 6),
                Expanded(child: _oldRestockCol('C1', _stockA)),
                const SizedBox(width: 6),
                Expanded(child: _oldRestockCol('C2', _stockB)),
                const SizedBox(width: 6),
                Expanded(child: _oldRestockCol('C3', _stockC)),
              ],
            ),
          ])),
        ),
        const SizedBox(height: 16),
        SizedBox(width: double.infinity, child: ElevatedButton(
          onPressed: _submitting ? null : _submitOldItem,
          style: ElevatedButton.styleFrom(backgroundColor: AppConstants.successColor, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
          child: _submitting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Text(_totalOldRestock > 0 ? '✅ 确认补货 ($_totalOldRestock件)' : '请点击 + 分配补货数量', style: const TextStyle(fontSize: 16)),
        )),
      ]),
    );
  }

  Widget _buildOldItemEditForm() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMd), side: BorderSide(color: AppConstants.successColor.withValues(alpha: 0.3))),
      child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.edit, size: 14, color: AppConstants.successColor), SizedBox(width: 6),
          Text('商品信息（可修改）', style: TextStyle(fontSize: 13, color: AppConstants.textSecondary)),
        ]),
        const Divider(height: 16),
        _labeledField('商品名称', _nameController, aiHint: '商品名称'),
        const SizedBox(height: 10),
        // Barcode - read only
        Row(children: [
          SizedBox(width: 70, child: Row(children: [const Icon(Icons.lock, size: 12, color: AppConstants.textSecondary), const SizedBox(width: 4), Flexible(child: Text('条码', style: TextStyle(fontSize: 13, color: AppConstants.textSecondary)))])),
          const SizedBox(width: 4),
          Expanded(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(color: AppConstants.bgColor, borderRadius: BorderRadius.circular(6)),
            child: Row(children: [
              Expanded(child: Text(_barcodeController.text, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
              Icon(Icons.lock, size: 14, color: AppConstants.textSecondary.withValues(alpha: 0.4)),
            ]),
          )),
        ]),
        const SizedBox(height: 10),
        _labeledField('规格及货号', _specController, aiHint: '规格 #货号'),
        const SizedBox(height: 10),
        _labeledDropdown('分类', _selectedCategory, _demoCategories, (v) => setState(() { _selectedCategory = v ?? ''; }), required: true),
        const SizedBox(height: 10),
        _labeledDropdown('单位', _selectedUnit, _demoUnits, (v) => setState(() { _selectedUnit = v ?? '个'; _unitCtrl.text = _selectedUnit; })),
        const SizedBox(height: 10),
        _labeledField('进价', _buyPriceController, isPrice: true, required: true),
        const SizedBox(height: 10),
        _labeledField('售价', _sellPriceController, isPrice: true, required: true),
        _buildMarginLabel(_buyPriceController, _sellPriceController),
        const SizedBox(height: 10),
        _labeledDropdown('供货商', _selectedNewSupplier, _allSuppliersCache, (v) => setState(() { _selectedNewSupplier = v ?? ''; _supplierCtrl.text = _selectedNewSupplier; }), required: true),
        const SizedBox(height: 10),
        _buildExtBarcodeSection(),
      ])),
    );
  }

  Widget _oldRestockCol(String storeName, String currentStock) {
    final addQty = _oldRestock[storeName] ?? 0;
    final stockNum = int.tryParse(currentStock) ?? 0;
    final newStock = stockNum + addQty;
    final ctrl = _oldRestockCtrls[storeName]!;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 1),
      child: Column(children: [
        Text(storeName, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: AppConstants.textPrimary)),
        const SizedBox(height: 2),
        Text('$stockNum → $newStock', style: TextStyle(fontSize: 11, color: addQty < 0 ? AppConstants.errorColor : addQty > 0 ? AppConstants.successColor : AppConstants.textSecondary)),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () => _setOldRestock(storeName, addQty + 1),
          child: Container(width: 36, height: 24, decoration: BoxDecoration(color: AppConstants.primaryColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(6)), child: const Icon(Icons.add, size: 18, color: AppConstants.primaryColor)),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 48, height: 28,
          child: TextField(
            controller: ctrl,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.numberWithOptions(signed: true),
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.zero, border: OutlineInputBorder()),
            onChanged: (v) => _setOldRestock(storeName, int.tryParse(v) ?? 0),
          ),
        ),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () => _setOldRestock(storeName, addQty - 1),
          child: Container(width: 36, height: 24, decoration: BoxDecoration(color: AppConstants.errorColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)), child: const Icon(Icons.remove, size: 18, color: AppConstants.errorColor)),
        ),
      ]),
    );
  }

  Widget _QtyBtn(IconData icon, VoidCallback onTap, {double size = 36}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(width: size, height: size, decoration: BoxDecoration(color: AppConstants.primaryColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)), child: Icon(icon, color: AppConstants.primaryColor, size: size * 0.5)),
    );
  }

  // ==================== New Item: Not Found Page ====================

  Widget _buildNewItemNotFound() {
    return Column(children: [
      const SizedBox(height: 8),
      const Spacer(),
      Container(
        width: 80, height: 80,
        decoration: BoxDecoration(color: AppConstants.warningColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(20)),
        child: const Icon(Icons.search_off, size: 40, color: AppConstants.warningColor),
      ),
      const SizedBox(height: 20),
      const Text('未找到该商品', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppConstants.textPrimary)),
      const SizedBox(height: 8),
      Text(
        '条码 ${_barcodeController.text} 在系统中不存在\n点击下方按钮拍照建档',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 13, color: AppConstants.textSecondary, height: 1.5),
      ),
      const SizedBox(height: 12),
      // Re-scan button
      OutlinedButton.icon(
        onPressed: () => Navigator.of(context).pop(false),
        icon: const Icon(Icons.qr_code_scanner, size: 16),
        label: const Text('重新扫码', style: TextStyle(fontSize: 13)),
        style: OutlinedButton.styleFrom(foregroundColor: AppConstants.textSecondary),
      ),
      const Spacer(),
      // Add button
      SizedBox(width: double.infinity, child: ElevatedButton.icon(
        onPressed: () => Navigator.of(context).pop(true),
        icon: const Icon(Icons.add_a_photo),
        label: const Text('新增商品，拍照建档', style: TextStyle(fontSize: 16)),
        style: ElevatedButton.styleFrom(backgroundColor: AppConstants.warningColor, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
      )),
    ]);
  }

  // ==================== New Item ====================

  Widget _buildNewItemResult() {
    return SingleChildScrollView(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Container(
          width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
          decoration: BoxDecoration(color: AppConstants.warningColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(AppConstants.radiusSm), border: Border.all(color: AppConstants.warningColor.withValues(alpha: 0.3))),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            const Icon(Icons.warning_amber, color: AppConstants.warningColor, size: 20), const SizedBox(width: 8),
            const Expanded(child: Text('未建档 · 判定为新品', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppConstants.warningColor))),
            Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4), decoration: BoxDecoration(color: AppConstants.primaryColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)), child: Text('🏪 ${widget.targetStore}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppConstants.primaryColor))),
          ]),
        ),
        const SizedBox(height: 16),

        // AI error banner
        if (_aiError != null)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppConstants.errorColor.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(AppConstants.radiusSm),
              border: Border.all(color: AppConstants.errorColor.withValues(alpha: 0.25)),
            ),
            child: Row(children: [
              const Icon(Icons.error_outline, color: AppConstants.errorColor, size: 18),
              const SizedBox(width: 8),
              Expanded(child: Text(
                'AI 识别失败：$_aiError\n已使用空表单，请手动填写',
                style: const TextStyle(fontSize: 11, color: AppConstants.errorColor, height: 1.4),
              )),
            ]),
          ),

        _buildNewItemFullForm(),
        const SizedBox(height: 16),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: OutlinedButton(
            onPressed: () { widget.onRetakePhotos?.call(); Navigator.of(context).pop(); },
            style: OutlinedButton.styleFrom(foregroundColor: AppConstants.textSecondary, padding: const EdgeInsets.symmetric(vertical: 14)),
            child: const Text('← 返回重新拍照', style: TextStyle(fontSize: 14)))),
          const SizedBox(width: 12),
          Expanded(flex: 2, child: ElevatedButton(
            onPressed: () { try { _submitNewItem(); } catch (e) { _showMsg("error: $e"); } },
          style: ElevatedButton.styleFrom(backgroundColor: AppConstants.warningColor, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
          child: _submitting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('✅ 确认建档', style: TextStyle(fontSize: 16)),
        )),
      ])
    ]));
  }

  // ==================== New Item Full Form ====================

  Widget _buildExtBarcodeSection() {
    final count = _extBarcodeCtrls.length;
    final hasExisting = _extBarcodeCtrls.any((c) => c.text.trim().isNotEmpty);

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Header row: show count badge if there are codes
      Row(children: [
        const Text('扩展条码', style: TextStyle(fontSize: 13, color: AppConstants.textSecondary)),
        if (hasExisting && !_extBarcodeExpanded) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(color: AppConstants.warningColor.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(8)),
            child: Text('$count个', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppConstants.warningColor)),
          ),
        ],
        const Spacer(),
        if (!_extBarcodeExpanded)
          TextButton.icon(
            onPressed: () => setState(() => _extBarcodeExpanded = true),
            icon: const Icon(Icons.edit, size: 14),
            label: Text(hasExisting ? '展开编辑' : '添加条码', style: const TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(foregroundColor: AppConstants.primaryColor, padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
          ),
      ]),
      // Expanded list
      if (_extBarcodeExpanded) ...[
        const SizedBox(height: 6),
        ...List.generate(count, (i) {
          final ctrl = _extBarcodeCtrls[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Expanded(child: TextField(
                controller: ctrl,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                  hintText: '输入或扫码获取条码',
                ),
                onChanged: (_) {
                  final allCodes = _extBarcodeCtrls.map((c) => c.text.trim()).where((b) => b.isNotEmpty).toList();
                  final dupes = allCodes.where((b) => allCodes.where((x) => x == b).length > 1).toSet();
                  final shortCodes = allCodes.where((b) => b.length < 5).toSet();
                  if (dupes.isNotEmpty) {
                    _showInline('⚠️ 重复条码: ${dupes.join(', ')}', isWarning: true, duration: const Duration(seconds: 3));
                  } else if (shortCodes.isNotEmpty) {
                    _showInline('⚠️ 条码过短(<5位): ${shortCodes.join(', ')}', isWarning: true, duration: const Duration(seconds: 3));
                  }
                  setState(() {});
                },
              )),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () async {
                  final barcode = await Navigator.of(context).push<String>(
                    MaterialPageRoute(builder: (_) => ScannerView(onDetect: (b) => Navigator.pop(context, b), onClose: () => Navigator.pop(context))));
                  if (barcode != null) ctrl.text = barcode;
                },
                child: Container(width: 34, height: 34, decoration: BoxDecoration(color: AppConstants.primaryColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)), child: const Icon(Icons.qr_code_scanner, size: 18, color: AppConstants.primaryColor)),
              ),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () => setState(() { _extBarcodeCtrls[i].dispose(); _extBarcodeCtrls.removeAt(i); }),
                child: Container(width: 34, height: 34, decoration: BoxDecoration(color: AppConstants.errorColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(6)), child: const Icon(Icons.close, size: 18, color: AppConstants.errorColor)),
              ),
            ]),
          );
        }),
        // "Add another" row at bottom
        const SizedBox(height: 4),
        TextButton.icon(
          onPressed: () => setState(() => _extBarcodeCtrls.add(TextEditingController())),
          icon: const Icon(Icons.add, size: 14),
          label: const Text('添加更多条码', style: TextStyle(fontSize: 12)),
          style: TextButton.styleFrom(foregroundColor: AppConstants.primaryColor, padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
        ),
        const SizedBox(height: 4),
        // Collapse button
        TextButton(
          onPressed: () => setState(() => _extBarcodeExpanded = false),
          child: const Text('收起 ▲', style: TextStyle(fontSize: 11, color: AppConstants.textSecondary)),
          style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
        ),
      ],
    ]);
  }

  Widget _buildNewItemFullForm() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppConstants.radiusMd), side: const BorderSide(color: AppConstants.dividerColor)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

          // ---- AI pre-filled ----
          _labeledField('商品名称', _nameController, aiHint: 'AI 根据包装生成', aiFilled: true, showCamera: true, onCameraTap: _scanProductName),
          // Real-time translation display
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _nameController,
            builder: (context, value, child) {
              if (value.text.trim().isEmpty) return const SizedBox.shrink();
              return _buildTranslationPreview(value.text.trim());
            },
          ),
          const SizedBox(height: 8),
          // 条码 - 最关键字段，带扫码按钮
          _labeledField('条码', _barcodeController, aiHint: 'AI 自动提取 | 可扫码修正', aiFilled: true, showScan: true),

          // 规格及货号 - EMPTY, manual or voice (single row)
          const SizedBox(height: 10),
          _labeledField('规格及货号', _specController, aiHint: '手动填写或语音输入，如：12×8×3cm #HH-001', empty: true),

          // 分类 - DROPDOWN
          const SizedBox(height: 10),
          _labeledDropdown('分类', _selectedCategory, _demoCategories, (v) => setState(() => _selectedCategory = v ?? '')),

          const Divider(height: 20),

          // ---- Required ----
          const Row(children: [
            Icon(Icons.warning_amber, size: 14, color: AppConstants.errorColor), SizedBox(width: 4),
            Text('以下需人工确认（红框 = 必填）', style: TextStyle(fontSize: 12, color: AppConstants.errorColor, fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 10),

          _labeledField('进价', _newBuyPriceController2, required: true, isPrice: true, aiHint: '语音说"进价8毛"'),
          const SizedBox(height: 10),
          _labeledField('售价', _newSellPriceController2, required: true, isPrice: true, aiHint: '语音说"卖2块"'),
          _buildMarginLabel(_newBuyPriceController2, _newSellPriceController2),

          // 供货商 - DROPDOWN
          const SizedBox(height: 10),
          _labeledDropdown('供货商', _selectedNewSupplier, _allSuppliersCache, (v) => setState(() { _selectedNewSupplier = v ?? ''; _supplierCtrl.text = _selectedNewSupplier; }), required: true),
          const SizedBox(height: 10),
          _labeledDropdown('单位', _selectedUnit, _demoUnits, (v) => setState(() { _selectedUnit = v ?? 'each'; _unitCtrl.text = _selectedUnit; }), required: true),

          // 扩展条码（一件多码）
          const SizedBox(height: 10),
          _buildExtBarcodeSection(),
          const SizedBox(height: 14),

          // ---- Total Stock ----
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: AppConstants.errorColor.withValues(alpha: 0.06), borderRadius: BorderRadius.circular(AppConstants.radiusSm), border: Border.all(color: AppConstants.errorColor.withValues(alpha: 0.3))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Row(children: [
                Icon(Icons.inventory, size: 16, color: AppConstants.errorColor), SizedBox(width: 6),
                Text('本次入库总量', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppConstants.errorColor)),
                SizedBox(width: 8),
                Text('← 分配到各门店的总数', style: TextStyle(fontSize: 11, color: AppConstants.textSecondary)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                _QtyBtn(Icons.remove, () { var v = int.tryParse(_newQtyController.text) ?? 0; if (v > 0) { v--; _newQtyController.text = v.toString(); } }),
                const SizedBox(width: 10),
                Expanded(child: TextField(
                  controller: _newQtyController, textAlign: TextAlign.center, keyboardType: TextInputType.number,
                  style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: AppConstants.errorColor),
                  decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 10), border: OutlineInputBorder(borderSide: BorderSide(color: AppConstants.errorColor)), hintText: '0'),
                )),
                const SizedBox(width: 10),
                _QtyBtn(Icons.add, () { var v = int.tryParse(_newQtyController.text) ?? 0; v++; _newQtyController.text = v.toString(); }),
              ]),
              const SizedBox(height: 6),
              const Text('💡 建档后进入分配页面，将库存分到各门店', style: TextStyle(fontSize: 11, color: AppConstants.textSecondary)),
            ]),
          ),
        ]),
      ),
    );
  }

  // ==================== Field Widgets ====================

  Widget _labeledField(String label, TextEditingController ctrl, {
    bool required = false, bool isPrice = false, bool aiFilled = false, bool empty = false, String? aiHint, bool showScan = false, bool showCamera = false, VoidCallback? onCameraTap,
  }) {
    return Row(children: [
      SizedBox(width: 70, child: Row(children: [
        if (required) const Icon(Icons.circle, size: 6, color: AppConstants.errorColor)
        else if (empty) const Icon(Icons.edit, size: 12, color: AppConstants.textSecondary)
        else const SizedBox(width: 6),
        const SizedBox(width: 4),
        Flexible(child: Text(label, style: TextStyle(fontSize: 13, fontWeight: required ? FontWeight.w600 : FontWeight.normal, color: required ? AppConstants.errorColor : empty ? AppConstants.textSecondary : AppConstants.textSecondary))),
      ])),
      const SizedBox(width: 4),
      Expanded(child: TextField(
        controller: ctrl, keyboardType: isPrice ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
        style: TextStyle(fontSize: 13, fontWeight: showScan ? FontWeight.w600 : (required ? FontWeight.w600 : FontWeight.normal)),
        decoration: InputDecoration(
          isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: showScan ? AppConstants.primaryColor : (required ? AppConstants.errorColor : empty ? AppConstants.dividerColor : AppConstants.dividerColor))),
          prefixText: isPrice ? 'R ' : null, prefixStyle: const TextStyle(color: AppConstants.errorColor),
          hintText: aiHint, hintStyle: TextStyle(fontSize: 10, color: AppConstants.textSecondary.withValues(alpha: 0.6)),
        ),
      )),
      if (showScan) ...[
        const SizedBox(width: 4),
        if (_recheckingBarcode)
          const Padding(
            padding: EdgeInsets.all(8),
            child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          )
        else ...[
          _miniBtn(Icons.qr_code_scanner, '扫码', _scanBarcode),
          const SizedBox(width: 3),
          _miniBtn(Icons.search, '验证', () {
            final barcode = _barcodeController.text.trim();
            if (barcode.isNotEmpty) _recheckBarcode(barcode);
          }),
        ],
      ],
      if (showCamera) ...[
        const SizedBox(width: 4),
        _miniBtn(Icons.camera_alt, '识图', onCameraTap!),
      ],
    ]);
  }

  Widget _labeledDropdown(String label, String value, List<String> items, ValueChanged<String?> onChanged, {bool required = false}) {
    final allItems = <String>[];
    if (value.isNotEmpty && !items.contains(value)) allItems.add(value);
    allItems.addAll(items);

    return Row(children: [
      SizedBox(width: 70, child: Text(label, style: TextStyle(fontSize: 13, fontWeight: required ? FontWeight.w600 : FontWeight.normal, color: required ? AppConstants.errorColor : AppConstants.textSecondary))),
      const SizedBox(width: 4),
      Expanded(child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(border: Border.all(color: AppConstants.dividerColor), borderRadius: BorderRadius.circular(6)),
        child: DropdownButtonHideUnderline(child: DropdownButton<String>(
          value: value.isNotEmpty && allItems.contains(value) ? value : null,
          isExpanded: true,
          hint: Text(value.isNotEmpty ? value : '选择', style: TextStyle(fontSize: 12, color: value.isNotEmpty ? AppConstants.textPrimary : AppConstants.textSecondary)),
          items: allItems.map((s) => DropdownMenuItem(value: s, child: Text(s, style: const TextStyle(fontSize: 13)))).toList(),
          onChanged: onChanged,
        )),
      )),
    ]);
  }

  // ==================== Old Item Widgets ====================

  Widget _buildProductInfoCard() {
    return Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('商品信息', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppConstants.textPrimary)),
      const Divider(height: 20),
      _infoRow('商品名称', _nameController.text.isNotEmpty ? _nameController.text : '—', bold: true),
      _infoRow('条码', _barcodeController.text.isNotEmpty ? _barcodeController.text : '—'),
      _infoRow('规格', _specController.text.isNotEmpty ? _specController.text : '—'),
      _infoRow('分类', _selectedCategory.isNotEmpty ? _selectedCategory : '—'),
      _infoRow('单位', _selectedUnit.isNotEmpty ? _selectedUnit : '—'),
      _infoRow('进价', _buyPriceController.text.isNotEmpty ? 'R${_buyPriceController.text}' : '—', valueColor: const Color(0xFF8B4513)),
      _infoRow('售价', _sellPriceController.text.isNotEmpty ? 'R${_sellPriceController.text}' : '—', valueColor: AppConstants.errorColor, valueBold: true),
      _infoRow('供货商', _selectedNewSupplier.isNotEmpty ? _selectedNewSupplier : widget.supplier),
    ])));
  }

  Widget _buildPriceFields() {
    return Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [
      Row(children: [const Text('进价变更：', style: TextStyle(fontSize: 14, color: AppConstants.textSecondary)), const SizedBox(width: 12), Expanded(child: TextField(controller: _buyPriceController..text = _oldBuyPrice.toStringAsFixed(2), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10), prefixText: 'R'), onChanged: (v) => _newBuyPrice = double.tryParse(v) ?? _oldBuyPrice))]),
      const SizedBox(height: 10),
      Row(children: [const Text('售价变更：', style: TextStyle(fontSize: 14, color: AppConstants.textSecondary)), const SizedBox(width: 12), Expanded(child: TextField(controller: _sellPriceController..text = _oldSellPrice.toStringAsFixed(2), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10), prefixText: 'R'), onChanged: (v) => _newSellPrice = double.tryParse(v) ?? _oldSellPrice))]),
    ])));
  }

  Widget _buildReadOnlyField(String label, String value) {
    return Card(child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [Text('$label：', style: const TextStyle(fontSize: 14, color: AppConstants.textSecondary)), const SizedBox(width: 12), Expanded(child: Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)))])));
  }

  // ==================== Inline Notification ====================

  Widget _buildInlineBanner() {
    final isError = _inlineMsgColor == AppConstants.errorColor;
    final isWarning = _inlineMsgColor == AppConstants.warningColor;
    final icon = isError ? Icons.error_outline : isWarning ? Icons.warning_amber : Icons.check_circle;
    return Material(
      elevation: 6,
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
      color: _inlineMsgColor ?? AppConstants.successColor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 44, 16, 12),
        child: Row(children: [
          Icon(icon, color: Colors.white, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(_inlineMsg ?? '', style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500))),
        ]),
      ),
    );
  }

  Widget _buildVoiceResultBar() {
    return Material(
      elevation: 6,
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(12)),
      color: AppConstants.primaryColor,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 44, 8, 12),
        child: Row(children: [
          const Icon(Icons.mic, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(
            _voiceResultText ?? '',
            style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500),
          )),
          // Add homophone button
          GestureDetector(
            onTap: _addHomophone,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Text('➕ 谐音', style: TextStyle(color: Colors.white, fontSize: 11)),
            ),
          ),
          const SizedBox(width: 4),
          // Dismiss button
          GestureDetector(
            onTap: () => setState(() => _voiceResultText = null),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(Icons.close, color: Colors.white70, size: 18),
            ),
          ),
        ]),
      ),
    );
  }

  Future<void> _addHomophone() async {
    final fullText = _voiceResultText;
    if (fullText == null || fullText.isEmpty) return;

    final prefs = await SharedPreferences.getInstance();
    var existingRaw = prefs.getString('voice_homophones') ?? '';

    // Persist helper
    Future<void> saveMapping(String target, String alias) async {
      final lines = existingRaw.split('\n');
      bool found = false;
      final buffer = StringBuffer();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.startsWith('$target=')) {
          final parts = trimmed.split('=');
          final existingAliases = parts.length > 1 ? parts[1].split(',').map((s) => s.trim()).toSet() : <String>{};
          existingAliases.add(alias);
          buffer.writeln('$target=${existingAliases.join(',')}');
          found = true;
        } else if (trimmed.isNotEmpty) {
          buffer.writeln(trimmed);
        }
      }
      if (!found) buffer.writeln('$target=$alias');
      final updated = buffer.toString().trim();
      await prefs.setString('voice_homophones', updated);
      existingRaw = updated; // keep snapshot in sync for consecutive saves
    }

    // Editable text — user can select a portion of the voice result
    final ctrl = TextEditingController(text: fullText);
    String selectedKw = '进价';
    bool customMode = false;
    final customCtrl = TextEditingController();
    bool done = false;

    // Keyword categories for the chip selector
    const quickKeys = ['进价', '售价', '库存', '供货商', '分类', '规格'];
    const unitKeys = ['个', '件', '只', '条', '台', '盒', '箱', '包', '瓶', '双', '米'];
    const priceKeys = ['块', '元', '毛', '角', '分'];
    const numKeys = ['十', '百', '千', '万', '半'];
    final allPresetKeys = [...quickKeys, ...unitKeys, ...priceKeys, ...numKeys];

    while (!done && mounted) {
      final kw = await showDialog<String>(
        context: context,
        builder: (ctx) => StatefulBuilder(
          builder: (ctx, setSt) {
            String effTarget() => customMode ? customCtrl.text.trim() : selectedKw;
            bool effCanSave() => customMode ? customCtrl.text.trim().isNotEmpty : true;

            return AlertDialog(
              title: const Text('添加谐音映射', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Reference: full voice text
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppConstants.primaryColor.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: AppConstants.primaryColor.withValues(alpha: 0.15)),
                      ),
                      child: Text(fullText, style: const TextStyle(fontSize: 13, color: AppConstants.textSecondary)),
                    ),
                    const SizedBox(height: 12),
                    // Editable field — user can trim to partial text
                    const Text('语音识别到（可修改/删减）:', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
                    const SizedBox(height: 6),
                    TextField(
                      controller: ctrl,
                      autofocus: true,
                      style: const TextStyle(fontSize: 15),
                      decoration: InputDecoration(
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        hintText: '输入或粘贴要映射的文本片段',
                      ),
                    ),
                    const SizedBox(height: 14),
                    // Keyword section
                    const Text('映射到标准词:', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8, runSpacing: 8,
                      children: allPresetKeys.map((kw) {
                        final sel = !customMode && kw == selectedKw;
                        return ChoiceChip(
                          label: Text(kw, style: TextStyle(fontSize: 13, color: sel ? Colors.white : AppConstants.textPrimary)),
                          selected: sel,
                          selectedColor: AppConstants.primaryColor,
                          onSelected: (_) => setSt(() { selectedKw = kw; customMode = false; }),
                          visualDensity: VisualDensity.compact,
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 8),
                    // Custom target toggle
                    Row(children: [
                      ChoiceChip(
                        label: Text(customMode ? '自定义: ${customCtrl.text.isNotEmpty ? customCtrl.text : "…"}' : '自定义…',
                          style: TextStyle(fontSize: 12, color: customMode ? Colors.white : AppConstants.textPrimary)),
                        selected: customMode,
                        selectedColor: AppConstants.primaryColor,
                        onSelected: (_) => setSt(() => customMode = !customMode),
                        visualDensity: VisualDensity.compact,
                      ),
                      if (customMode) ...[
                        const SizedBox(width: 8),
                        Expanded(child: TextField(
                          controller: customCtrl,
                          autofocus: true,
                          style: const TextStyle(fontSize: 14),
                          decoration: InputDecoration(
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                            hintText: '输入目标词,如"个"',
                          ),
                        )),
                      ],
                    ]),
                    if (customMode && customCtrl.text.isNotEmpty && ctrl.text.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '结果: "${ctrl.text.trim()}" → "${effTarget()}"',
                          style: const TextStyle(fontSize: 11, color: AppConstants.successColor),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () { done = true; Navigator.pop(ctx); },
                  child: const Text('完成', style: TextStyle(color: AppConstants.textSecondary)),
                ),
                ElevatedButton(
                  onPressed: effCanSave() ? () {
                    final alias = ctrl.text.trim();
                    if (alias.isEmpty) return;
                    final target = effTarget();
                    if (target.isEmpty) return;
                    saveMapping(target, alias);
                    _showInline('✅ 已添加: $target → $alias');
                    ctrl.clear();
                    customCtrl.clear();
                    Navigator.pop(ctx, target);
                  } : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppConstants.primaryColor,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('添加并继续 →'),
                ),
            ],
          ); // close AlertDialog (return value)
        },   // close builder function
      ),
    );       // close showDialog
      if (kw == null) done = true; // user tapped "完成" or dismissed
    }
  }

  // ==================== Voice ====================

  String? _modelDir;
  bool _isListening = false;
  bool _voicePressed = false; // instant press-down feedback (before isListening)
  bool _voiceProcessing = false; // guard against double-trigger during ASR
  int _voicePointerId = -1; // track the pointer that started recording
  String? _currentWavPath;
  late final AnimationController _voicePulseCtrl;
  static const _audioChannel = MethodChannel('com.smarteye/audio');
  static const _audioPlayChannel = MethodChannel('com.smarteye/audio_play');

  /// Pre-load model path eagerly so press→record is instant
  Future<void> _initVoiceModel() async {
    _modelDir = await ModelService.getModelPath();
  }

  Future<void> _startVoiceInput() async {
    if (_isListening || _voiceProcessing) return;

    // ── Haptic + beep on press ──
    HapticFeedback.mediumImpact();
    _playBeep(true);

    // ── Instant: show pressed + listening state ──
    setState(() {
      _isListening = true;
      _voicePressed = true;
    });
    _voicePulseCtrl.repeat(period: const Duration(milliseconds: 800));

    // ── Start recording immediately (no model check — defer to stop) ──
    try {
      final tempDir = await getTemporaryDirectory();
      _currentWavPath = '${tempDir.path}/voice_test.wav';
      await _audioChannel.invokeMethod('startRecord', {'path': _currentWavPath});
    } on PlatformException catch (e) {
      _resetVoice();
      if (e.code == 'PERMISSION_DENIED') {
        if (mounted) _showInline('请允许麦克风权限后重试', isWarning: true);
      } else {
        if (mounted) _showInline('录音失败: ${e.message}', isError: true);
      }
    } catch (e) {
      _resetVoice();
      if (mounted) _showInline('录音失败: $e', isError: true);
    }
  }

  void _resetVoice() {
    try { _audioChannel.invokeMethod('stopRecord'); } catch (_) {}
    _voicePulseCtrl.stop();
    _voicePulseCtrl.reset();
    setState(() {
      _isListening = false;
      _voicePressed = false;
      _voiceProcessing = false;
      _currentWavPath = null;
    });
  }

  /// Play a short tone: high beep on start, low beep on stop
  void _playBeep(bool start) async {
    try {
      await _audioPlayChannel.invokeMethod('beep', {'start': start});
    } catch (_) {
      // Audio playback not available — silently ignore
    }
  }

  Future<void> _stopAndTranscribe() async {
    if (!_isListening || _voiceProcessing) return;
    _voiceProcessing = true;

    try {
      // ── Haptic + beep on release ──
      HapticFeedback.lightImpact();
      _playBeep(false);

      final wavPath = _currentWavPath;
      _currentWavPath = null;

      // ── Stop recording + reset visual immediately ──
      try { await _audioChannel.invokeMethod('stopRecord'); } catch (_) {}
      _voicePulseCtrl.stop();
      _voicePulseCtrl.reset();
      if (mounted) setState(() {
        _isListening = false;
        _voicePressed = false;
      });

      if (wavPath == null || wavPath.isEmpty) {
        if (mounted) _showInline('未录到音频', isWarning: true);
        return;
      }

      // ── Now do model check (only needed for ASR, not recording) ──
      if (_modelDir == null) {
        _modelDir = await ModelService.getModelPath();
      }
      if (_modelDir == null) {
        if (mounted) _showInline('请先在配置页下载语音模型', isWarning: true);
        return;
      }

      // ── Processing indicator ──
      if (mounted) _showInline('🔍 识别中…', duration: const Duration(seconds: 10));

      // Short delay for file flush
      await Future.delayed(const Duration(milliseconds: 200));

      // Initialize sherpa-onnx native bindings (must be called before any other function)
      initBindings();

      // Read WAV and transcribe with Paraformer (Chinese-optimized, fast, small)
      final wave = readWave(wavPath);

      // Auto-detect model files in model dir
      final modelDir = Directory(_modelDir!);
      final files = await modelDir.list().toList();
      final modelFile = files.firstWhere((f) {
        final n = f.path.split('/').last.split('\\').last;
        return n.endsWith('.onnx');
      }, orElse: () => throw Exception('model.onnx not found'));
      final tokensFile = files.firstWhere((f) {
        final n = f.path.split('/').last.split('\\').last;
        return n.contains('tokens') && n.endsWith('.txt');
      }, orElse: () => throw Exception('tokens.txt not found'));

      final pf = OfflineParaformerModelConfig(model: modelFile.path);
      final model = OfflineModelConfig(
        paraformer: pf,
        tokens: tokensFile.path,
        numThreads: 2,
      );

      // NOTE: Paraformer does NOT support hotwords (only FunASR/Qwen3 models do).
      // Number recognition accuracy is handled by VoiceTextNormalizer post-processing.
      final recognizer = OfflineRecognizer(OfflineRecognizerConfig(model: model));
      final stream = recognizer.createStream();
      stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
      recognizer.decode(stream);
      final text = recognizer.getResult(stream).text.trim();
      stream.free();
      recognizer.free();

      if (mounted) {
        if (text.isNotEmpty) {
          // ── Normalize ASR output for better number recognition ──
          final normalizer = VoiceTextNormalizer();
          final normalized = normalizer.normalize(text);

          final prefs = await SharedPreferences.getInstance();
          final userHomophones = prefs.getString('voice_homophones') ?? '';
          final parsed = VoiceNluParser().parse(normalized,
            knownCategories: _demoCategories,
            knownSuppliers: _allSuppliersCache,
            knownUnits: _demoUnits,
            userHomophones: userHomophones,
          );

          // Show raw + normalized text for debugging
          if (normalized != text) {
            _showInline('🎤 $text → $normalized', duration: const Duration(seconds: 5));
          } else {
            _showInline('🎤 $text');
          }
          // Show persistent voice result bar for user review
          setState(() => _voiceResultText = normalized);
          _onVoiceResult(normalized, parsed);
        } else {
          _showInline('未识别到语音内容', isWarning: true);
        }
      }
    } catch (e) {
      _resetVoice();
      if (mounted) _showInline('识别失败: $e', isError: true);
      try { await _audioChannel.invokeMethod('stopRecord'); } catch (_) {}
    } finally {
      if (mounted) setState(() => _voiceProcessing = false);
    }
  }

  // ── Voice FAB with press animation + pulse halo ──

  Widget _buildVoiceFab() {
    return SizedBox(
      width: 88, height: 88,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // ── Outer pulse ring (recording only) ──
          if (_isListening)
            AnimatedBuilder(
              animation: _voicePulseCtrl,
              builder: (_, child) {
                final t = _voicePulseCtrl.value;
                return Transform.scale(
                  scale: 1.0 + t * 0.5,
                  child: Container(
                    width: 72, height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: AppConstants.errorColor.withValues(alpha: (0.5 * (1.0 - t)).clamp(0.1, 0.5)),
                        width: 2.5,
                      ),
                    ),
                  ),
                );
              },
            ),
          // ── Main button (Listener for push-to-talk: fires reliably regardless of hold duration) ──
          Listener(
            onPointerDown: (e) {
              _voicePointerId = e.pointer;
              _startVoiceInput();
            },
            onPointerUp: (e) {
              if (e.pointer == _voicePointerId) {
                _stopAndTranscribe();
                _voicePointerId = -1;
              }
            },
            onPointerCancel: (e) {
              // Finger moved out of button or system gesture interrupted
              if (e.pointer == _voicePointerId) {
                _voicePointerId = -1;
                _resetVoice();
              }
            },
            child: AnimatedScale(
              scale: _voicePressed ? 0.90 : 1.0,
              duration: const Duration(milliseconds: 80),
              curve: Curves.easeOutBack,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                width: _isListening ? 76 : 64,
                height: _isListening ? 76 : 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: _isListening
                      ? const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFFEF4444), Color(0xFFDC2626)],
                        )
                      : const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [Color(0xFF3B82F6), Color(0xFF2563EB)],
                        ),
                  boxShadow: [
                    BoxShadow(
                      color: (_isListening ? AppConstants.errorColor : AppConstants.primaryColor)
                          .withValues(alpha: _isListening ? 0.7 : 0.45),
                      blurRadius: _isListening ? 28 : 18,
                      spreadRadius: _isListening ? 6 : 1,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 150),
                  child: _isListening
                      ? const Icon(Icons.mic, key: ValueKey('mic_on'), color: Colors.white, size: 34)
                      : const Icon(Icons.mic_none, key: ValueKey('mic_off'), color: Colors.white, size: 28),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== Margin ====================

  Widget _buildMarginLabel(TextEditingController buyCtrl, TextEditingController sellCtrl) {
    final buy = double.tryParse(buyCtrl.text);
    final sell = double.tryParse(sellCtrl.text);
    String text = '毛利率：—';
    Color color = AppConstants.textSecondary;
    if (buy != null && sell != null && sell > 0 && sell >= buy) {
      final margin = ((sell - buy) / sell * 100).toStringAsFixed(2);
      text = '毛利率：$margin%';
      final m = double.parse(margin);
      if (m >= 80) { color = const Color(0xFF2E7D32); }       // dark green
      else if (m >= 60) { color = const Color(0xFFF9A825); }   // amber
      else if (m >= 40) { color = const Color(0xFFE65100); }   // orange
      else { color = AppConstants.errorColor; }                 // red
    }
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        const SizedBox(width: 74),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(6), border: Border.all(color: color.withValues(alpha: 0.25))),
          child: Text(text, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color)),
        ),
      ]),
    );
  }

  // ==================== Barcode Scanner ====================

  Future<void> _scanBarcode() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ScannerView(
          onDetect: (b) => Navigator.pop(context, b),
          onClose: () => Navigator.pop(context),
        ),
      ),
    );
    if (result == null || result.isEmpty) return;

    final newBarcode = result;
    final oldBarcode = _barcodeController.text;

    if (newBarcode == oldBarcode && _result != AnalysisResult.newItem) {
      // Same barcode, not a new item — no re-check needed
      _showInline('条码未变化：$newBarcode', isWarning: true);
      return;
    }

    _barcodeController.text = newBarcode;

    // If in new-item mode and barcode changed → re-check system
    if (_result == AnalysisResult.newItem && newBarcode != oldBarcode) {
      await _recheckBarcode(newBarcode);
    } else {
      _showInline('✅ 条码已更新：$newBarcode');
    }
  }

  /// Translate text using Google free API (same as OcrSelectPage)
  Future<String?> _googleTranslate(String text, {String from = 'en', String to = 'zh-CN'}) async {
    try {
      final url = 'https://translate.googleapis.com/translate_a/single?client=gtx&sl=$from&tl=$to&dt=t&q=${Uri.encodeComponent(text)}';
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
          return first[0].toString();
        }
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Auto-detect language: returns 'zh' if contains Chinese chars, else 'en'
  bool _isChinese(String text) => RegExp(r'[一-鿿]').hasMatch(text);

  /// Take a photo and run OCR, with auto-translation like OcrSelectPage
  Future<void> _scanProductName() async {
    final picker = ImagePicker();
    final photo = await picker.pickImage(source: ImageSource.camera, imageQuality: 85);
    if (photo == null || !mounted) return;

    showDialog(context: context, barrierDismissible: false, builder: (_) =>
      const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(color: Colors.white),
        SizedBox(height: 16),
        Text('识别中…', style: TextStyle(color: Colors.white70, fontSize: 14)),
      ]))
    );

    try {
      final ai = AiService();
      final lines = await ai.getOcrLines([File(photo.path)]);
      if (!mounted) return;
      Navigator.of(context).pop();

      final cleaned = lines.map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      if (cleaned.isEmpty) {
        if (mounted) _showInline('未识别到文字，请重试', isWarning: true);
        return;
      }

      // Auto-translate: if text is English → Chinese, if Chinese → English
      final Map<int, String> translations = {};
      for (var i = 0; i < cleaned.length; i++) {
        final t = cleaned[i];
        if (_isChinese(t)) {
          final en = await _googleTranslate(t, from: 'zh-CN', to: 'en');
          if (en != null && en != t) translations[i] = en;
        } else if (RegExp(r'[A-Za-z]{3,}').hasMatch(t)) {
          final zh = await _googleTranslate(t, from: 'en', to: 'zh-CN');
          if (zh != null && zh != t) translations[i] = zh;
        }
      }

      if (!mounted) return;

      // Show result dialog with translations (matching OcrSelectPage layout)
      final result = await showDialog<String>(context: context, builder: (ctx) {
        final ctrl = TextEditingController(text: cleaned.first);
        int selectedIdx = 0;
        return StatefulBuilder(builder: (ctx, setSt) {
          final hasTrans = translations.containsKey(selectedIdx);
          return AlertDialog(
            title: const Text('识图结果', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Selected line + translation
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppConstants.primaryColor.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppConstants.primaryColor.withValues(alpha: 0.2)),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(cleaned[selectedIdx], style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    if (hasTrans) Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text('🌐 ${translations[selectedIdx]}', style: const TextStyle(fontSize: 12, color: Color(0xFFE65100), fontWeight: FontWeight.w500)),
                    ),
                  ]),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: ctrl, autofocus: true,
                  style: const TextStyle(fontSize: 15),
                  decoration: InputDecoration(
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    hintText: '确认或修改',
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                ),
                // Quick-fill with translation
                if (hasTrans)
                  TextButton.icon(
                    onPressed: () => ctrl.text = translations[selectedIdx]!,
                    icon: const Icon(Icons.translate, size: 14),
                    label: Text('用翻译: ${translations[selectedIdx]}', style: const TextStyle(fontSize: 11)),
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFFE65100), padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
                  ),
                if (cleaned.length > 1) ...[
                  const SizedBox(height: 12),
                  const Text('备选文字（点击切换）:', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
                  const SizedBox(height: 4),
                  ...cleaned.asMap().entries.map((e) {
                    final idx = e.key;
                    final l = e.value;
                    final t = translations[idx];
                    return InkWell(
                      onTap: () {
                        ctrl.text = l;
                        selectedIdx = idx;
                        setSt(() {});
                      },
                      child: Container(
                        margin: const EdgeInsets.only(bottom: 4),
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        decoration: BoxDecoration(
                          color: idx == selectedIdx ? AppConstants.primaryColor.withValues(alpha: 0.08) : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                          border: idx == selectedIdx ? Border.all(color: AppConstants.primaryColor.withValues(alpha: 0.3)) : null,
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(l, style: TextStyle(fontSize: 14, fontWeight: idx == selectedIdx ? FontWeight.w600 : FontWeight.normal)),
                          if (t != null) Text('🌐 $t', style: const TextStyle(fontSize: 11, color: Color(0xFFE65100))),
                        ]),
                      ),
                    );
                  }),
                ],
              ]),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
              ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('确认')),
            ],
          );
        });
      });
      if (result != null && result.isNotEmpty && mounted) {
        _nameController.text = result;
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        _showInline('识别失败: $e', isError: true);
      }
    }
  }

  /// Translate product name field content (Chinese↔English auto-detect)
  Future<void> _translateName() async {
    final text = _nameController.text.trim();
    if (text.isEmpty) {
      if (mounted) _showInline('请先输入商品名称', isWarning: true);
      return;
    }

    if (!mounted) return;
    showDialog(context: context, barrierDismissible: false, builder: (_) =>
      const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(color: Colors.white),
        SizedBox(height: 16),
        Text('翻译中…', style: TextStyle(color: Colors.white70, fontSize: 14)),
      ]))
    );

    try {
      final from = _isChinese(text) ? 'zh-CN' : 'en';
      final to = from == 'zh-CN' ? 'en' : 'zh-CN';
      final translated = await _googleTranslate(text, from: from, to: to);

      if (!mounted) return;
      Navigator.of(context).pop();

      if (translated != null && translated != text) {
      final result = await showDialog<String>(context: context, builder: (ctx) {
        final ctrl = TextEditingController(text: translated);
        return AlertDialog(
          title: Text(from == 'zh-CN' ? '中→英 翻译' : '英→中 翻译', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('原文: $text', style: const TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl, autofocus: true,
              style: const TextStyle(fontSize: 16),
              decoration: InputDecoration(
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              ),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('使用')),
          ],
        );
      });
      if (result != null && result.isNotEmpty && mounted) {
        _nameController.text = result;
      }
      } else {
        if (mounted) _showInline('翻译失败，请检查网络', isWarning: true);
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        _showInline('翻译异常: $e', isError: true);
      }
    }
  }

  /// Re-query the system with corrected barcode to see if it's actually an existing product
  Future<void> _recheckBarcode(String barcode) async {
    setState(() => _recheckingBarcode = true);

    // TODO: Real API call — POST /Product/LoadProductsByPage with keyword=barcode
    await Future.delayed(const Duration(seconds: 1));

    if (!mounted) return;

    // Demo: simulate finding existing product for barcodes starting with "69"
    final isFound = barcode.startsWith('69');

    if (isFound) {
      // Barcode matched! Switch to old-item mode with mock data
      setState(() {
        _result = AnalysisResult.oldItem;
        _recheckingBarcode = false;
      });
      if (mounted) {
        _showInline('🔍 条码已匹配到已有商品！AI 识别错误，已切换为旧商品模式', duration: const Duration(seconds: 3));
      }
    } else {
      // Truly new product
      setState(() => _recheckingBarcode = false);
      if (mounted) {
        _showInline('🔍 条码未匹配到已有商品，确认为新品', isWarning: true);
      }
    }
  }

  // ==================== Helpers ====================

  Widget _miniBtn(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
        decoration: BoxDecoration(color: AppConstants.primaryColor.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(6)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: AppConstants.primaryColor),
          Text(label, style: const TextStyle(fontSize: 8, color: AppConstants.primaryColor)),
        ]),
      ),
    );
  }

  Widget _infoRow(String label, String value, {bool bold = false, Color? valueColor, bool valueBold = false}) {
    return Padding(padding: const EdgeInsets.only(top: 6), child: Row(children: [
      SizedBox(width: 70, child: Text(label, style: const TextStyle(fontSize: 13, color: AppConstants.textSecondary))),
      const SizedBox(width: 8),
      Expanded(child: Text(value, style: TextStyle(fontSize: bold ? 15 : 13, fontWeight: valueBold ? FontWeight.bold : (bold ? FontWeight.w600 : FontWeight.normal), color: valueColor ?? AppConstants.textPrimary))),
    ]));
  }

  // ==================== Submit - Old Item ====================

  // Submit from edit page → save via API
  Future<void> _submitOldItemEdit() async {
    // Validate required fields
    final barcode = _barcodeController.text.trim();
    if (barcode.isEmpty) { _showMsg('条码不能为空', err: true); return; }
    if (_buyPriceController.text.isEmpty) { _showMsg('请填写进价', err: true); return; }
    if (_sellPriceController.text.isEmpty) { _showMsg('请填写售价', err: true); return; }

    setState(() => _submitting = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final baseUrl = prefs.getString('login_base_url') ?? 'beta28.pospal.cn';
      final account = prefs.getString('login_account') ?? '';
      final employee = prefs.getString('login_employee') ?? '';
      final fullUrl = 'https://${baseUrl.replaceAll('https://', '').replaceAll('http://', '')}';
      final storeKey = 'cookie_$fullUrl|$account|$employee';
      final cookie = prefs.getString(storeKey) ?? '';

      if (cookie.isEmpty) {
        if (mounted) _showMsg('未登录，请先登录', err: true);
        return;
      }

      final storeIds = {'总店': '5634817', 'C1': '5634818', 'C2': '5634821', 'C3': '5968885'};
      final userId = storeIds[widget.targetStore] ?? '5634817';

      // Calculate new stock for primary store — use correct per-store stock
      final _stockByStore = {'总店': _stockTotal, 'C1': _stockA, 'C2': _stockB, 'C3': _stockC};
      final targetStockStr = _stockByStore[widget.targetStore] ?? _stockTotal;
      final currentStock = double.tryParse(targetStockStr) ?? 0;
      final addStock = (_oldRestock[widget.targetStore] ?? 0).toDouble();
      final newStock = currentStock + addStock;

      final name = _nameController.text.trim();
      final spec = _specController.text.trim();
      final buyPrice = double.tryParse(_buyPriceController.text);
      final sellPrice = double.tryParse(_sellPriceController.text);
      final category = _selectedCategory.isNotEmpty ? _selectedCategory : null;
      final unit = _selectedUnit.isNotEmpty ? _selectedUnit : null;
      final supplier = _selectedNewSupplier.isNotEmpty ? _selectedNewSupplier : null;
      if (mounted) {
        _showInline('⏳ 正在保存到 $widget.targetStore…', duration: const Duration(seconds: 10));
      }

      // Save to primary store (use fresh QueryService per store to avoid connection issues)
      String? error;
      {
        final qs = QueryService(baseUrl: fullUrl, cookie: cookie);
        error = await qs.saveProduct(
          userId: userId,
          barcode: barcode,
          name: name,
          specification: spec,
          category: category,
          unit: unit,
          supplier: supplier,
          buyPrice: buyPrice,
          sellPrice: sellPrice,
          stock: addStock != 0 ? newStock : null,
          extBarcodes: _extBarcodesChanged ? _extBarcodesCsv : null,
        );
        qs.dispose();
      }

      if (error != null) {
        if (mounted) _showMsg('保存失败: $error', err: true);
        return;
      }

      // Sync to other stores (each with fresh QueryService)
      _syncResults.clear();
      _syncResults[widget.targetStore] = true;

      // Get current stocks from storeStocks
      final currentStocks = <String, double>{};
      if (widget.productData != null && widget.productData!.storeStocks.isNotEmpty) {
        for (final ss in widget.productData!.storeStocks) {
          currentStocks[ss.storeName] = ss.stock ?? 0;
        }
      }

      int synced = 0, syncFailed = 0;
      for (final e in storeIds.entries) {
        if (e.key == widget.targetStore) continue;
        final curStock = currentStocks[e.key] ?? double.tryParse(_stockByStore[e.key] ?? '0') ?? 0;
        final add = (_oldRestock[e.key] ?? 0).toDouble();
        final syncNewStock = curStock + add;

        final qs2 = QueryService(baseUrl: fullUrl, cookie: cookie);
        final syncError = await qs2.saveProduct(
          userId: e.value,
          barcode: barcode,
          name: name,
          specification: spec,
          category: category,
          unit: unit,
          supplier: supplier,
          buyPrice: buyPrice,
          sellPrice: sellPrice,
          stock: add != 0 ? syncNewStock : null,
          extBarcodes: _extBarcodesChanged ? _extBarcodesCsv : null,
        );
        qs2.dispose();
        _syncResults[e.key] = (syncError == null);
        if (syncError == null) synced++; else syncFailed++;
      }

      if (mounted) {
        _showInline('✅ 同步完成: $synced 成功, $syncFailed 失败', isError: syncFailed > 0, duration: const Duration(seconds: 3));
        setState(() { _submitting = false; _submitted = true; });
        _saveLastCategory();
        OperationLogService.add(store: widget.targetStore, action: '编辑库存', barcode: barcode,
          detail: '同步${synced}店${syncFailed > 0 ? "(${syncFailed}失败)" : ""}');
      }
    } catch (e) {
      if (mounted) _showMsg('保存异常: $e', err: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _submitOldItem() async {
    await _submitOldItemEdit();
  }

  // ==================== Submit - New Item ====================

  void _showMsg(String msg, {bool err = false}) {
    showDialog(context: context, builder: (_) => AlertDialog(content: Text(msg), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('确定'))]));
  }

  Future<void> _submitNewItem() async {
    final totalStock = int.tryParse(_newQtyController.text) ?? 0;
    if (totalStock <= 0) { _showMsg('请填写本次入库总量', err: true); return; }
    if (_newBuyPriceController2.text.isEmpty || _newSellPriceController2.text.isEmpty) { _showMsg('请填写进价和售价', err: true); return; }
    if (_selectedCategory.isEmpty) { _showMsg('请选择分类', err: true); return; }
    if (_supplierCtrl.text.isEmpty) { _showMsg('请填写供货商', err: true); return; }
    if (_unitCtrl.text.isEmpty) { _showMsg('请填写单位', err: true); return; }

    // 规格及货号直接拼接到商品名称（OCR选择页已处理#后缀）
    final name = _nameController.text.trim();
    final specText = _specController.text.trim();
    final fullName = specText.isNotEmpty ? '$name $specText' : name;
    _showInline('DBG: name="$name" spec="$specText" → full="$fullName"', isWarning: true, duration: const Duration(seconds: 3));

    setState(() => _submitting = true);

    try {
      final prefs = await SharedPreferences.getInstance();
      final baseUrl = prefs.getString('login_base_url') ?? 'beta28.pospal.cn';
      final account = prefs.getString('login_account') ?? '';
      final employee = prefs.getString('login_employee') ?? '';
      final fullUrl = 'https://${baseUrl.replaceAll('https://', '').replaceAll('http://', '')}';
      final storeKey = 'cookie_$fullUrl|$account|$employee';
      final cookie = prefs.getString(storeKey) ?? '';
      final storeIds = {'总店': '5634817', 'C1': '5634818', 'C2': '5634821', 'C3': '5968885'};
      final qs = QueryService(baseUrl: fullUrl, cookie: cookie);

      // Always create in HQ first (stock=0), then copy to sub-stores
      // Stock is set later by _confirmDistribution per the user's allocation
        final pjson = _buildProductJson('5634817', fullName, stock: 0);
        final err = await qs.saveProductFromJson(userId: '5634817', productJson: pjson);

      if (err != null) {
        qs.dispose();
        if (mounted) _showMsg('建档失败: $err', err: true);
        setState(() => _submitting = false);
        return;
      }

      // Copy HQ → C1/C2/C3 (all start with stock=0)
      _syncResults.clear(); _syncResults['总部'] = (err == null);
      for (final e in storeIds.entries) {
        if (e.key == '总店') continue;
        final cpJson = Map<String, dynamic>.from(pjson);
        cpJson['userId'] = e.value;
        cpJson['stock'] = '0';
        // Translate category & unit UIDs for target store
        if (_selectedCategory.isNotEmpty) {
          final tc = QueryService.categoryUidForStore(e.value, _selectedCategory);
          if (tc != null) cpJson['categoryUid'] = tc;
        }
        if (_effUnit.isNotEmpty) {
          final tu = QueryService.unitUidForStore(e.value, _effUnit);
          if (tu != null) {
            cpJson['productUnitExchangeList'] = [
              {'productUnitUid': tu, 'unitQuantity': 1, 'baseUnitQuantity': 1, 'isBase': 1, 'isRequest': 0, 'isTicket': -1, 'isDiscard': -1, 'productUnitName': _effUnit}
            ];
          }
        }
          final se = await qs.copyToStore(fromUserId: '5634817', toUserId: e.value, productJson: cpJson);
        _syncResults[e.key] = (se == null);
      }
      qs.dispose();

      _saveLastCategory();
      OperationLogService.add(store: widget.targetStore, action: '新建商品', barcode: _barcodeController.text.trim());
      if (mounted) setState(() { _submitting = false; _showDistribution = true;
        _distribution['总店'] = 0; _distribution['C1'] = 0; _distribution['C2'] = 0; _distribution['C3'] = 0;
        _distribution[widget.targetStore] = totalStock; });
    } catch (e) {
      if (mounted) _showMsg('建档异常: $e', err: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // ==================== Distribution ====================

  Widget _buildDistributionPage() {
    return SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
        width: double.infinity, padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        decoration: BoxDecoration(color: AppConstants.successColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(AppConstants.radiusSm), border: Border.all(color: AppConstants.successColor.withValues(alpha: 0.3))),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          const Icon(Icons.check_circle, color: AppConstants.successColor, size: 20), const SizedBox(width: 8),
          Text('商品已在 ${widget.targetStore} 建档', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppConstants.successColor)),
        ]),
      ),
      const SizedBox(height: 16),
      Container(
        width: double.infinity, padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(gradient: const LinearGradient(colors: [AppConstants.primaryColor, AppConstants.primaryDark]), borderRadius: BorderRadius.circular(AppConstants.radiusMd)),
        child: Column(children: [
          const Text('入库总量', style: TextStyle(fontSize: 13, color: Colors.white70)), const SizedBox(height: 4),
          Text('$_totalStock', style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: Colors.white)),
          const SizedBox(height: 8),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            _statChip('已分配', '$_totalDistributed', Colors.white),
            const SizedBox(width: 16),
            _statChip('待分配', '$_remainingStock', _remainingStock > 0 ? Colors.amber : AppConstants.successColor),
          ]),
        ]),
      ),
      const SizedBox(height: 16),
      Card(
        child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [
          const Text('各门店分配数量', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const Divider(height: 16),
          Row(
            children: [
              Expanded(child: _distCol('总店')),
              const SizedBox(width: 6),
              Expanded(child: _distCol('C1')),
              const SizedBox(width: 6),
              Expanded(child: _distCol('C2')),
              const SizedBox(width: 6),
              Expanded(child: _distCol('C3')),
            ],
          ),
        ])),
      ),
      const SizedBox(height: 12),
      Card(
        child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('快捷分配', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: _distributeEqually, style: OutlinedButton.styleFrom(foregroundColor: AppConstants.primaryColor, padding: const EdgeInsets.symmetric(vertical: 10)), child: const Text('平均分配', style: TextStyle(fontSize: 12)))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton(onPressed: _distributeAllToTarget, style: OutlinedButton.styleFrom(foregroundColor: AppConstants.primaryColor, padding: const EdgeInsets.symmetric(vertical: 10)), child: Text('全部给${widget.targetStore}', style: const TextStyle(fontSize: 12)))),
          ]),
        ])),
      ),
      const SizedBox(height: 16),
      SizedBox(width: double.infinity, child: ElevatedButton(
        onPressed: _remainingStock != 0 ? null : (_submitting ? null : _confirmDistribution),
        style: ElevatedButton.styleFrom(backgroundColor: _remainingStock == 0 ? AppConstants.successColor : Colors.grey, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
        child: _submitting ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : Text(_remainingStock == 0 ? '✅ 确认分配并完成' : '⚠️ 还有 $_remainingStock 件未分配', style: const TextStyle(fontSize: 15)),
      )),
      const SizedBox(height: 8),
      TextButton(onPressed: () => setState(() => _showDistribution = false), child: const Text('← 返回修改商品信息')),
    ]));
  }

  Widget _distCol(String storeName) {
    final current = _distribution[storeName] ?? 0;
    final isTarget = storeName == widget.targetStore;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 1),
      child: Column(children: [
        Text(storeName, style: TextStyle(fontSize: 12, fontWeight: isTarget ? FontWeight.w700 : FontWeight.w500, color: isTarget ? AppConstants.primaryColor : AppConstants.textPrimary)),
        const SizedBox(height: 4),
        // + button
        GestureDetector(
          onTap: () { if (_remainingStock > 0) setState(() => _distribution[storeName] = current + 1); },
          child: Container(
            width: 36, height: 24,
            decoration: BoxDecoration(
              color: AppConstants.primaryColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(Icons.add, size: 18, color: AppConstants.primaryColor),
          ),
        ),
        const SizedBox(height: 6),
        // Number
        Text('$current', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: current > 0 ? AppConstants.primaryColor : AppConstants.textSecondary)),
        const SizedBox(height: 6),
        // - button (always visible)
        GestureDetector(
          onTap: () { if (current > 0) setState(() => _distribution[storeName] = current - 1); },
          child: Container(
            width: 36, height: 24,
            decoration: BoxDecoration(
              color: AppConstants.primaryColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(Icons.remove, size: 18,
              color: current > 0 ? AppConstants.primaryColor : AppConstants.textSecondary.withValues(alpha: 0.3)),
          ),
        ),
      ]),
    );
  }

  Widget _statChip(String label, String value, Color color) {
    return Column(children: [Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color)), Text(label, style: TextStyle(fontSize: 11, color: color.withValues(alpha: 0.8)))]);
  }

  void _distributeEqually() {
    final perStore = _totalStock ~/ 4;
    final remainder = _totalStock % 4;
    setState(() {
      _distribution['总店'] = perStore + (remainder > 0 ? 1 : 0);
      _distribution['C1'] = perStore + (remainder > 1 ? 1 : 0);
      _distribution['C2'] = perStore + (remainder > 2 ? 1 : 0);
      _distribution['C3'] = perStore;
    });
  }

  void _distributeAllToTarget() {
    setState(() {
      _distribution['总店'] = 0;
      _distribution['C1'] = 0;
      _distribution['C2'] = 0;
      _distribution['C3'] = 0;
      _distribution[widget.targetStore] = _totalStock;
    });
  }

  Map<String, dynamic> _buildProductJson(String userId, String name, {int stock = 0}) {
    // Parse prices as doubles — Pospal API rejects string-formatted numbers
    final sellPrice = double.tryParse(_newSellPriceController2.text);
    final buyPrice = double.tryParse(_newBuyPriceController2.text);
    final supplierUid = _getSupplierUid(_effSupplier);

    // Use store-specific UID lookups (not hardcoded HQ maps)
    final catUid = QueryService.categoryUidForStore(userId, _selectedCategory) ?? _getCategoryUid(_selectedCategory) ?? '';
    final unitUid = QueryService.unitUidForStore(userId, _effUnit) ?? _unitUids[_effUnit];

    final json = <String, dynamic>{
      'id': 0, 'enable': '1', 'userId': userId,
      'barcode': _barcodeController.text.trim(),
      'name': name,
      'categoryUid': catUid,
      'categoryName': _selectedCategory.isNotEmpty ? _selectedCategory : '',
      'sellPrice': sellPrice ?? 1.0,
      'buyPrice': buyPrice ?? 1.0,
      'isCustomerDiscount': '1', 'customerPrice': '', 'sellPrice2': '', 'pinyin': '',
      'supplierUid': supplierUid ?? '',
      'supplierName': _effSupplier.isNotEmpty ? _effSupplier : '无',
      'supplierRangeList': _effSupplier.isNotEmpty ? [
        {'supplierUid': supplierUid ?? '', 'supplierName': _effSupplier, 'isDefault': '1'}
      ] : [],
      'productionDate': '', 'shelfLife': '', 'maxStock': '', 'minStock': '',
      'description': '', 'noStock': 0, 'stock': '$stock',
      'attribute6': '', // 规格拼到名称里了，attribute6 留空
      'productCommonAttribute': {'canAppointed': 0},
      'baseUnitName': _effUnit.isNotEmpty ? _effUnit : '无',
      'customerPrices': [],
      'productUnitExchangeList': unitUid != null ? [
        {'productUnitUid': unitUid, 'unitQuantity': 1, 'baseUnitQuantity': 1, 'isBase': 1, 'isRequest': 0, 'isTicket': -1, 'isDiscard': -1, 'productUnitName': _effUnit}
      ] : [],
      'productimages': [],
      'productTags': [{'uid': '1717232007906861613', 'name': '税率'}],
    };

    // Only include extended barcodes if user has added any
    final extBarcodes = _extBarcodeCtrls
        .where((c) => c.text.trim().isNotEmpty)
        .map((c) => {'extBarcode': c.text.trim()})
        .toList();
    if (extBarcodes.isNotEmpty) {
      json['productExtBarcodes'] = extBarcodes;
    }

    return json;
  }

  Future<void> _confirmDistribution() async {
    setState(() => _submitting = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final baseUrl = prefs.getString('login_base_url') ?? 'beta28.pospal.cn';
      final account = prefs.getString('login_account') ?? '';
      final employee = prefs.getString('login_employee') ?? '';
      final fullUrl = 'https://${baseUrl.replaceAll('https://', '').replaceAll('http://', '')}';
      final storeKey = 'cookie_$fullUrl|$account|$employee';
      final cookie = prefs.getString(storeKey) ?? '';
      final storeIds = {'总店': '5634817', 'C1': '5634818', 'C2': '5634821', 'C3': '5968885'};

      if (cookie.isEmpty) {
        if (mounted) {
          _showInline('未登录，请先登录', isError: true);
        }
        return;
      }

      _syncResults.clear();
      for (final e in storeIds.entries) {
        final dist = _distribution[e.key] ?? 0;
        if (dist == 0) {
          _syncResults[e.key] = true; // No stock to add = success
          continue;
        }
        // Each store update uses a fresh QueryService to avoid connection reuse issues
        final qs = QueryService(baseUrl: fullUrl, cookie: cookie);
        final se = await qs.saveProduct(
          userId: e.value,
          barcode: _barcodeController.text.trim(),
          name: _nameController.text.trim(),
          stock: dist.toDouble(),
          extBarcodes: _extBarcodesChanged ? _extBarcodesCsv : null,
        );
        qs.dispose();
        _syncResults[e.key] = (se == null);
      }
      _saveLastCategory();
      OperationLogService.add(store: widget.targetStore, action: '分配库存', barcode: _barcodeController.text.trim(),
        detail: _distribution.entries.where((e) => e.value > 0).map((e) => '${e.key}+${e.value}').join(' '));
      if (mounted) setState(() => _submitted = true);
    } catch (e) {
      if (mounted) _showMsg('分配库存失败: $e', err: true);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  // ==================== Success ====================

  final Map<String, bool> _syncResults = {};

  Widget _buildSuccess() {
    return Column(children: [
      const Spacer(),
      const Icon(Icons.check_circle, size: 64, color: AppConstants.successColor),
      const SizedBox(height: 12),
      Text(
        _result == AnalysisResult.oldItem ? '保存成功' : '建档成功',
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppConstants.textPrimary),
      ),
      const SizedBox(height: 4),
      Text(widget.targetStore, style: const TextStyle(fontSize: 14, color: AppConstants.primaryColor, fontWeight: FontWeight.w600)),
      const SizedBox(height: 16),
      Card(
        child: Padding(padding: const EdgeInsets.all(12), child: Column(children: [
          const Text('同步到各门店', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (_syncResults.isEmpty)
            const Text('仅保存当前门店', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary))
          else
            ..._syncResults.entries.map((e) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                Icon(e.value ? Icons.check_circle : Icons.error, size: 16, color: e.value ? AppConstants.successColor : AppConstants.errorColor),
                const SizedBox(width: 8), Text(e.key, style: const TextStyle(fontSize: 13)),
              ]),
            )),
        ])),
      ),
      const SizedBox(height: 16),
      SizedBox(width: double.infinity, child: OutlinedButton.icon(
        onPressed: () => _showPrintDialog(),
        icon: const Icon(Icons.print, size: 16),
        label: const Text('打印价签', style: TextStyle(fontSize: 14)),
        style: OutlinedButton.styleFrom(foregroundColor: AppConstants.primaryColor, side: const BorderSide(color: AppConstants.primaryColor), padding: const EdgeInsets.symmetric(vertical: 14)),
      )),
      const SizedBox(height: 10),
      SizedBox(width: double.infinity, child: ElevatedButton(
        onPressed: () { widget.onSubmitComplete?.call(); Navigator.of(context).pop(); },
        style: ElevatedButton.styleFrom(backgroundColor: AppConstants.primaryColor, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
        child: const Text('继续', style: TextStyle(fontSize: 14)),
      )),
      const Spacer(),
    ]);
  }

  void _viewStockHistory() {
    final barcode = _barcodeController.text.trim();
    final name = _nameController.text.trim();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => RecordsPage(
        initialBarcode: barcode.isNotEmpty ? barcode : null,
        productName: name.isNotEmpty ? name : null,
      )),
    );
  }

  void _showPrintDialog() async {
    // Load printers with configured IPs
    final configService = PrinterConfigService();
    final allConfigs = await configService.loadConfigs();
    final printers = allConfigs.where((c) => c.ip.isNotEmpty).toList();

    if (!mounted) return;

    if (printers.isEmpty) {
      _showInline('请先在设置中配置打印机IP', isWarning: true);
      return;
    }

    final qtyCtrl = TextEditingController(text: '1');
    PrinterConfig? selected = printers.first;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      qtyCtrl.selection = TextSelection(baseOffset: 0, extentOffset: qtyCtrl.text.length);
    });

    showDialog(context: context, builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setDialogState) {
        void doPrint() {
          final qty = int.tryParse(qtyCtrl.text) ?? 1;
          if (selected == null) return;
          Navigator.pop(ctx);
          _doPrint(selected!, qty > 0 ? qty : 1);
        }

        return AlertDialog(
          title: const Text('打印价签', style: TextStyle(fontSize: 16)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            // Printer selector
            if (printers.length > 1) ...[
              const Text('选择打印机:', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
              const SizedBox(height: 4),
              ...printers.map((p) => RadioListTile<PrinterConfig>(
                title: Text('${p.name} (${p.ip})', style: const TextStyle(fontSize: 13)),
                value: p, groupValue: selected,
                dense: true, contentPadding: EdgeInsets.zero,
                onChanged: (v) => setDialogState(() => selected = v),
              )),
              const Divider(),
            ],
            Row(children: [
              const Text('数量:', style: TextStyle(fontSize: 15)),
              const SizedBox(width: 12),
              SizedBox(width: 80, child: TextField(
                controller: qtyCtrl,
                keyboardType: TextInputType.number,
                autofocus: true,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                onSubmitted: (_) => doPrint(),
              )),
            ]),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            ElevatedButton(onPressed: doPrint, child: const Text('打印')),
          ],
        );
      });
    });
  }

  Future<void> _doPrint(PrinterConfig config, int qty) async {
    try {
      final name = _nameController.text.isNotEmpty ? _nameController.text : _barcodeController.text;
      final barcode = _barcodeController.text;
      final isNew = _result == AnalysisResult.newItem;
      final rawPrice = isNew ? _newSellPriceController2.text : _sellPriceController.text;
      final price = rawPrice.isNotEmpty ? rawPrice : '0';
      final supplier = _effSupplier.isNotEmpty ? _effSupplier : '';
      final unit = _effUnit.isNotEmpty ? _effUnit : '';

      // Send HTTP POST JSON to PC print server (PC converts to TSPL/ZPL)
      final json = jsonEncode({
        'barcode': barcode, 'name': name,
        'price': price, 'supplier': supplier, 'unit': unit,
        'templateId': config.id,
        'showPrice': config.showPrice ? '1' : '0',
        'qty': '$qty',
      });
      final body = utf8.encode(json);
      final all = utf8.encode(
        'POST / HTTP/1.1\r\n'
        'Host: ${config.ip}:${config.port}\r\n'
        'Content-Type: application/json\r\n'
        'Content-Length: ${body.length}\r\n'
        'Connection: close\r\n'
        '\r\n') + body;
      final socket = await Socket.connect(config.ip, config.port, timeout: const Duration(seconds: 5));
      socket.add(all);
      await socket.flush();
      await socket.close();

      if (mounted) {
        _showInline('✅ 已发送到打印机');
      }
    } catch (e) {
      if (mounted) _showInline('❌ 打印失败: $e', isError: true);
    }
  }
}
