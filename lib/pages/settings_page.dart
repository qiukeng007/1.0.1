import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';
import '../utils/constants.dart';
import '../models/printer_config.dart';
import '../services/printer_config_service.dart';
import '../services/store_service.dart';
import '../services/model_service.dart';
import '../services/auth_service.dart';
import 'login_page.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => SettingsPageState();
}

class SettingsPageState extends State<SettingsPage> {
  void onTabSelected() async {
    _loadHomophones();
    // Reload server URL (may have been updated by auth dialog)
    final p = await SharedPreferences.getInstance();
    final svr = p.getString('server_url') ?? '';
    if (svr != _serverUrlCtrl.text) {
      _serverUrlCtrl.text = svr;
    }
  }
  bool _isLoggedIn = false;
  bool _voiceEnabled = true;
  int _photoCount = 3;
  String _defaultSupplier = '邱铿';
  String _lastLoginTime = '';
  String _geminiKey = '';
  String _ollamaUrl = '';
  int _cName = 3, _cBarcode = 4, _cSpec = 8, _cCategory = 10;
  int _cUnit = 12, _cSupplier = 19, _cStock = 11, _cSell = 14, _cBuy = 13;

  final _accountCtrl = TextEditingController();
  final _employeeCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _baseUrlCtrl = TextEditingController();
  final _supplierCtrl = TextEditingController();
  final _serverUrlCtrl = TextEditingController();
  final _serverPwdCtrl = TextEditingController();
  final _homophoneCtrl = TextEditingController();

  // Multi-profile printer state
  final _printerConfigService = PrinterConfigService();
  List<PrinterConfig> _printerConfigs = [];
  String _activeProfile = '默认';
  List<String> _profileNames = ['默认'];
  final Map<String, TextEditingController> _printerIpCtrls = {};
  final Map<String, TextEditingController> _printerPortCtrls = {};

  final List<String> _supplierList = ['邱铿', '陈姐', '老王', '张老板'];

  String get _storeKey => 'https://${(_baseUrlCtrl.text).replaceAll('https://', '').replaceAll('http://', '')}|${_accountCtrl.text}|${_employeeCtrl.text}';

  @override
  void dispose() {
    _accountCtrl.dispose();
    _employeeCtrl.dispose();
    _passwordCtrl.dispose();
    _baseUrlCtrl.dispose();
    _supplierCtrl.dispose();
    _homophoneCtrl.dispose();
    for (final c in _printerIpCtrls.values) { c.dispose(); }
    for (final c in _printerPortCtrls.values) { c.dispose(); }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadAll();
    _checkModel();
  }

  Future<void> _loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _accountCtrl.text = prefs.getString('login_account') ?? '';
      _employeeCtrl.text = prefs.getString('login_employee') ?? '';
      _passwordCtrl.text = prefs.getString('login_password') ?? '';
      _baseUrlCtrl.text = prefs.getString('login_base_url') ?? 'beta28.pospal.cn';
      _geminiKey = prefs.getString('gemini_api_key') ?? '';
      _ollamaUrl = prefs.getString('ollama_url') ?? '';
      _cName = prefs.getInt('col_name') ?? 3;
      _cBarcode = prefs.getInt('col_barcode') ?? 4;
      _cSpec = prefs.getInt('col_spec') ?? 8;
      _cCategory = prefs.getInt('col_category') ?? 10;
      _cUnit = prefs.getInt('col_unit') ?? 12;
      _cSupplier = prefs.getInt('col_supplier') ?? 17;
      _cStock = prefs.getInt('col_stock') ?? 11;
      _cSell = prefs.getInt('col_sell') ?? 13;
      _cBuy = prefs.getInt('col_buy') ?? 14;
      _lastLoginTime = prefs.getString('login_last_time') ?? '';
      _supplierCtrl.text = prefs.getString('supplier_list') ?? '';
      _photoCount = prefs.getInt('photo_count') ?? 3;
      _serverUrlCtrl.text = prefs.getString('server_url') ?? '';
      _serverPwdCtrl.text = prefs.getString('server_password') ?? '';
      final ck = prefs.getString('cookie_$_storeKey');
      _isLoggedIn = ck != null && ck.isNotEmpty;
    });
    _loadPrinterConfigs();
    _loadHomophones();
  }

  Future<void> _loadHomophones() async {
    final prefs = await SharedPreferences.getInstance();
    _homophoneCtrl.text = prefs.getString('voice_homophones') ?? '';
  }

  Future<void> _saveHomophones() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('voice_homophones', _homophoneCtrl.text);
  }

  Future<void> _loadPrinterConfigs() async {
    _activeProfile = await _printerConfigService.getActiveProfileName();
    _profileNames = await _printerConfigService.getProfileNames();
    _printerConfigs = await _printerConfigService.loadConfigs();
    _syncPrinterCtrls();
    if (mounted) setState(() {});
  }

  void _syncPrinterCtrls() {
    for (final c in _printerConfigs) {
      if (_printerIpCtrls.containsKey(c.id)) {
        _printerIpCtrls[c.id]!.text = c.ip;
      } else {
        _printerIpCtrls[c.id] = TextEditingController(text: c.ip);
      }
      if (_printerPortCtrls.containsKey(c.id)) {
        _printerPortCtrls[c.id]!.text = c.port.toString();
      } else {
        _printerPortCtrls[c.id] = TextEditingController(text: c.port.toString());
      }
    }
  }

  Future<void> _savePrinterField(String id, String field, String value) async {
    final idx = _printerConfigs.indexWhere((c) => c.id == id);
    if (idx < 0) return;
    PrinterConfig c = _printerConfigs[idx];
    if (field == 'ip') c = c.copyWith(ip: value);
    else if (field == 'port') c = c.copyWith(port: int.tryParse(value) ?? 18888);
    _printerConfigs[idx] = c;
    await _printerConfigService.saveConfigs(_printerConfigs);
  }

  Future<void> _switchProfile(String name) async {
    await _printerConfigService.setActiveProfile(name);
    await _loadPrinterConfigs();
  }

  Future<void> _createProfile() async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('新建场地'), content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: '如：家里、店铺2')),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')), TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('创建'))],
    ));
    if (name != null && name.isNotEmpty) {
      await _printerConfigService.createProfile(name);
      await _switchProfile(name);
    }
  }

  Future<void> _renameProfile() async {
    final ctrl = TextEditingController(text: _activeProfile);
    final name = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
      title: const Text('重命名场地'), content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(hintText: '新名称')),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')), TextButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('重命名'))],
    ));
    if (name != null && name.isNotEmpty && name != _activeProfile) {
      await _printerConfigService.renameProfile(_activeProfile, name);
      await _loadPrinterConfigs();
    }
  }

  Future<void> _deleteProfile() async {
    if (_profileNames.length <= 1) return;
    final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text('删除场地 "$_activeProfile"？'), content: const Text('该场地的打印机配置将被删除'),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')), TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除', style: TextStyle(color: Colors.red)))],
    ));
    if (ok == true) {
      await _printerConfigService.deleteProfile(_activeProfile);
      await _loadPrinterConfigs();
    }
  }

  Future<void> _saveCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('login_account', _accountCtrl.text.trim());
    await prefs.setString('login_employee', _employeeCtrl.text.trim());
    await prefs.setString('login_password', _passwordCtrl.text.trim());
    await prefs.setString('login_base_url', _baseUrlCtrl.text.trim());
  }

  Future<void> _saveAiConfig() async {
    final prefs = await SharedPreferences.getInstance();
    if (_geminiKey.isNotEmpty) {
      await prefs.setString('gemini_api_key', _geminiKey);
    } else {
      await prefs.remove('gemini_api_key');
    }
    if (_ollamaUrl.isNotEmpty) {
      await prefs.setString('ollama_url', _ollamaUrl);
    } else {
      await prefs.remove('ollama_url');
    }
  }

  String _formatNow() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2, '0')}-${n.day.toString().padLeft(2, '0')} ${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('系统配置', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _section('总店账号'),
          const SizedBox(height: 8),
          _buildAccountCard(),
          const SizedBox(height: 20),
          _section('子门店同步设置'),
          const SizedBox(height: 8),
          _buildSubStoreCard(),
          const SizedBox(height: 20),
          _section('店铺服务器'),
          const SizedBox(height: 8),
          _buildServerCard(),
          const SizedBox(height: 20),
          _section('打印机配置（价签打印）'),
          const SizedBox(height: 8),
          _buildPrinterCard(),
          const SizedBox(height: 20),
          _section('供货商列表（逗号分隔，改完自动保存）'),
          const SizedBox(height: 8),
          _buildSupplierCard(),
          const SizedBox(height: 20),
          _section('语音识别'),
          const SizedBox(height: 8),
          _buildAppSettingsCard(),
          const SizedBox(height: 20),
          const Center(child: Text('银豹入库 v1.0.1', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary))),
          const SizedBox(height: 16),
        ]),
      ),
    );
  }

  Widget _section(String t) => Text(t, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: AppConstants.textPrimary));

  // ==================== Account Card ====================

  Widget _buildAccountCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Row(children: [
            Container(width: 12, height: 12, decoration: BoxDecoration(shape: BoxShape.circle,
              color: _isLoggedIn ? AppConstants.successColor : AppConstants.textSecondary)),
            const SizedBox(width: 8),
            Text(_isLoggedIn ? '已登录' : '未登录', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600,
              color: _isLoggedIn ? AppConstants.successColor : AppConstants.textSecondary)),
            const Spacer(),
            Text(_lastLoginTime.isNotEmpty ? '上次：$_lastLoginTime' : '尚未登录',
              style: const TextStyle(fontSize: 11, color: AppConstants.textSecondary)),
          ]),
          const Divider(height: 24),
          _field('总店账号', _accountCtrl, onChanged: (_) => _saveCredentials()),
          const SizedBox(height: 10),
          _field('员工工号', _employeeCtrl, onChanged: (_) => _saveCredentials()),
          const SizedBox(height: 10),
          _field('工号密码', _passwordCtrl, obscure: true, onChanged: (_) => _saveCredentials()),
          const SizedBox(height: 10),
          _field('后台地址', _baseUrlCtrl, hint: 'beta28.pospal.cn'),
          const SizedBox(height: 16),
          SizedBox(width: double.infinity, child: OutlinedButton.icon(
            onPressed: () async {
              await _saveCredentials();
              final r = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (_) => LoginPage(
                baseUrl: 'https://${_baseUrlCtrl.text.replaceAll('https://', '').replaceAll('http://', '')}',
                account: _accountCtrl.text.trim(),
                cashierJobNumber: _employeeCtrl.text.trim(),
                password: _passwordCtrl.text.trim(),
              )));
              if (r == true && mounted) {
                final now = _formatNow();
                final prefs = await SharedPreferences.getInstance();
                await prefs.setString('login_last_time', now);
                await _loadAll();
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('登录成功，门店已同步'), backgroundColor: AppConstants.successColor),
                );
              }
            },
            icon: Icon(_isLoggedIn ? Icons.refresh : Icons.login),
            label: Text(_isLoggedIn ? '重新登录' : 'WebView 登录（微信扫码）'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _isLoggedIn ? AppConstants.successColor : AppConstants.primaryColor,
              side: BorderSide(color: _isLoggedIn ? AppConstants.successColor : AppConstants.primaryColor),
            ),
          )),
        ]),
      ),
    );
  }

  Widget _field(String label, TextEditingController ctrl, {bool obscure = false, String? hint, ValueChanged<String>? onChanged}) {
    return Row(children: [
      SizedBox(width: 72, child: Text(label, style: const TextStyle(fontSize: 13, color: AppConstants.textSecondary))),
      const SizedBox(width: 8),
      Expanded(child: TextField(
        controller: ctrl, obscureText: obscure,
        style: const TextStyle(fontSize: 13),
        onChanged: onChanged,
        decoration: InputDecoration(
          isDense: true, filled: true, fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          hintText: hint,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: AppConstants.dividerColor)),
        ),
      )),
    ]);
  }

  // ==================== Sub Stores ====================

  List<Map<String, String>> _stores = [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _loadStores();
  }

  Future<void> _loadStores() async {
    final url = _baseUrlCtrl.text;
    if (url.isEmpty) return;
    final stores = await StoreService.loadStores('https://${url.replaceAll('https://', '').replaceAll('http://', '')}');
    if (mounted) {
      setState(() => _stores = stores);
      await _loadStoreNames();
    }
  }

  final Map<String, TextEditingController> _storeNameCtrls = {};

  Widget _buildSubStoreCard() {
    if (_stores.isEmpty) {
      return Card(
        child: Padding(padding: const EdgeInsets.all(20), child: Center(
          child: Column(children: [
            const Icon(Icons.store_outlined, size: 32, color: AppConstants.textSecondary),
            const SizedBox(height: 8),
            const Text('登录后将自动获取门店列表', style: TextStyle(fontSize: 13, color: AppConstants.textSecondary)),
          ]),
        )),
      );
    }

    return Card(
      child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [
        const Text('门名称（可自定义修改）', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
        const SizedBox(height: 8),
        ..._stores.asMap().entries.map((e) {
          final i = e.key;
          final s = e.value;
          final label = s['label'] ?? '?';
          final id = s['id'] ?? '';
          final serverName = s['name'] ?? '';

          // Init controller with saved name or server name
          if (!_storeNameCtrls.containsKey(label)) {
            _storeNameCtrls[label] = TextEditingController(text: serverName);
          }
          final ctrl = _storeNameCtrls[label]!;

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(children: [
              Container(
                width: 36,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                decoration: BoxDecoration(
                  color: AppConstants.primaryColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: AppConstants.primaryColor)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: ctrl,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                    hintText: serverName,
                  ),
                  onChanged: (v) => _saveStoreName(label, v),
                ),
              ),
              const SizedBox(width: 6),
              Text(id, style: const TextStyle(fontSize: 9, color: AppConstants.textSecondary)),
            ]),
          );
        }),
      ])),
    );
  }

  Future<void> _saveStoreName(String label, String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('store_name_$label', name.trim());
  }

  Future<void> _loadStoreNames() async {
    final prefs = await SharedPreferences.getInstance();
    for (final s in _stores) {
      final label = s['label'] ?? '';
      if (label.isEmpty) continue;
      final saved = prefs.getString('store_name_$label');
      if (saved != null && saved.isNotEmpty) {
        _storeNameCtrls[label]?.text = saved;
      }
    }
  }

  bool _modelReady = false;
  bool _modelDownloading = false;

  // Voice test state
  bool _voiceTesting = false;
  String? _voiceTestResult;
  String? _voiceTestWavPath;
  static const _audioChannel = MethodChannel('com.smarteye/audio');

  Future<void> _startVoiceTest() async {
    if (_voiceTesting) return;
    if (!_modelReady) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('请先下载语音模型'), backgroundColor: AppConstants.warningColor),
        );
      }
      return;
    }
    setState(() => _voiceTesting = true);
    try {
      final tempDir = await getTemporaryDirectory();
      _voiceTestWavPath = '${tempDir.path}/voice_test_setting.wav';
      await _audioChannel.invokeMethod('startRecord', {'path': _voiceTestWavPath});
    } catch (e) {
      setState(() => _voiceTesting = false);
    }
  }

  Future<void> _stopVoiceTest() async {
    final wavPath = _voiceTestWavPath;
    _voiceTestWavPath = null;
    if (!_voiceTesting) return;

    try {
      await _audioChannel.invokeMethod('stopRecord');
      await Future.delayed(const Duration(milliseconds: 300));

      if (wavPath == null || !await File(wavPath).exists()) {
        setState(() { _voiceTesting = false; _voiceTestResult = null; });
        return;
      }

      setState(() => _voiceTesting = false);
      final modelDir = await ModelService.getModelPath();
      if (modelDir == null) return;

      initBindings();
      final wave = readWave(wavPath);
      final modelDirObj = Directory(modelDir);
      final files = await modelDirObj.list().toList();
      final modelFile = files.firstWhere((f) => f.path.endsWith('.onnx'));
      final tokensFile = files.firstWhere((f) => f.path.contains('tokens') && f.path.endsWith('.txt'));

      final pf = OfflineParaformerModelConfig(model: modelFile.path);
      final model = OfflineModelConfig(paraformer: pf, tokens: tokensFile.path, numThreads: 2);
      final recognizer = OfflineRecognizer(OfflineRecognizerConfig(model: model));
      final stream = recognizer.createStream();
      stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
      recognizer.decode(stream);
      final text = recognizer.getResult(stream).text.trim();
      stream.free();
      recognizer.free();

      setState(() => _voiceTestResult = text.isNotEmpty ? text : '(未识别到语音)');
    } catch (e) {
      setState(() { _voiceTesting = false; _voiceTestResult = '错误: $e'; });
    }
  }

  Future<void> _addTestHomophone() async {
    final text = _voiceTestResult;
    if (text == null || text.isEmpty || text.startsWith('(') || text.startsWith('错误')) return;

    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text('将 "$text" 添加为哪个标准词的谐音？'),
        children: [
          for (final kw in ['进价', '售价', '库存', '供货商', '分类', '规格', 'C1', 'C2', 'C3', '总店'])
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, kw),
              child: Text('$kw → $text', style: const TextStyle(fontSize: 15)),
            ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: AppConstants.textSecondary)),
          ),
        ],
      ),
    );
    if (target == null || !mounted) return;

    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString('voice_homophones') ?? '';
    final lines = existing.split('\n');
    bool found = false;
    final buffer = StringBuffer();
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.startsWith('$target=')) {
        final parts = trimmed.split('=');
        final aliases = parts.length > 1 ? parts[1].split(',').map((s) => s.trim()).toSet() : <String>{};
        aliases.add(text);
        buffer.writeln('$target=${aliases.join(',')}');
        found = true;
      } else if (trimmed.isNotEmpty) {
        buffer.writeln(trimmed);
      }
    }
    if (!found) {
      buffer.writeln('$target=$text');
    }
    final updated = buffer.toString().trim();
    await prefs.setString('voice_homophones', updated);
    _homophoneCtrl.text = updated;
    setState(() => _voiceTestResult = null);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✅ 已添加: $target → $text'), backgroundColor: AppConstants.successColor),
      );
    }
  }

  Future<void> _checkModel() async {
    final ready = await ModelService.isDownloaded();
    if (mounted) setState(() => _modelReady = ready);
  }

  Future<void> _downloadModel() async {
    if (_modelDownloading) return;
    setState(() => _modelDownloading = true);
    try {
      final path = await ModelService.download((msg) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
          );
        }
      });
      if (path != null) {
        setState(() => _modelReady = true);
      }
    } finally {
      if (mounted) setState(() => _modelDownloading = false);
    }
  }

  // ==================== App Settings ====================

  Widget _buildAppSettingsCard() {
    return Card(
      child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [
        _switchRow('语音输入', _voiceEnabled, (v) => setState(() => _voiceEnabled = v)),
        const Divider(),
        // Model download
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('语音模型', style: TextStyle(fontSize: 14)),
              Text(
                _modelReady ? '✅ 已下载' : '⚠️ 未下载（~30MB）',
                style: TextStyle(fontSize: 12, color: _modelReady ? AppConstants.successColor : AppConstants.warningColor),
              ),
            ])),
            _modelDownloading
                ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                : TextButton(
                    onPressed: _modelReady ? null : _downloadModel,
                    child: Text(_modelReady ? '已就绪' : '下载'),
                  ),
          ]),
        ),
        const Divider(),
        // Homophone mappings
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Text('语音谐音配置', style: TextStyle(fontSize: 14)),
              const Spacer(),
              GestureDetector(
                onTap: _loadHomophones,
                child: const Icon(Icons.refresh, size: 18, color: AppConstants.textSecondary),
              ),
            ]),
            const SizedBox(height: 4),
            Text(
              '格式：标准词=谐音1,谐音2\n例：进价=竞价,金价,进架',
              style: TextStyle(fontSize: 11, color: AppConstants.textSecondary),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _homophoneCtrl,
              maxLines: null,
              minLines: 2,
              keyboardType: TextInputType.multiline,
              style: const TextStyle(fontSize: 12, height: 1.5),
              decoration: const InputDecoration(
                hintText: '售价=首家,受戒,手价\n进价=竞价,金价,进架',
                isDense: true,
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              onChanged: (_) => _saveHomophones(),
            ),
          ]),
        ),
        const Divider(),
        // Voice test section
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('语音测试', style: TextStyle(fontSize: 14)),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: AppConstants.bgColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppConstants.dividerColor),
                  ),
                  child: Text(
                    _voiceTestResult ?? '按住右侧按钮说话…',
                    style: TextStyle(
                      fontSize: 13,
                      color: _voiceTestResult != null ? AppConstants.textPrimary : AppConstants.textSecondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Record button
              Listener(
                onPointerDown: (_) => _startVoiceTest(),
                onPointerUp: (_) => _stopVoiceTest(),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _voiceTesting ? AppConstants.errorColor : AppConstants.primaryColor,
                  ),
                  child: Icon(
                    _voiceTesting ? Icons.mic : Icons.mic_none,
                    color: Colors.white, size: 22,
                  ),
                ),
              ),
              // Add homophone
              if (_voiceTestResult != null && !_voiceTestResult!.startsWith('(')) ...[
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: _addTestHomophone,
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppConstants.successColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text('➕', style: TextStyle(fontSize: 16)),
                  ),
                ),
              ],
            ]),
          ]),
        ),
        const Divider(),
        _dropRow('连拍张数', ['1', '2', '3', '4', '5'], _photoCount.toString(), (v) async {
          setState(() => _photoCount = int.parse(v!));
          final p = await SharedPreferences.getInstance();
          await p.setInt('photo_count', _photoCount);
        }),
      ])),
    );
  }

  Widget _switchRow(String title, bool v, ValueChanged<bool> cb) {
    return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(children: [
      Expanded(child: Text(title, style: const TextStyle(fontSize: 14))),
      Switch(value: v, onChanged: cb, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
    ]));
  }

  Widget _dropRow(String title, List<String> items, String v, ValueChanged<String?> cb) {
    return Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Row(children: [
      Text(title, style: const TextStyle(fontSize: 14)), const Spacer(),
      DropdownButton<String>(
        value: v,
        underline: const SizedBox(),
        items: items.map((e) => DropdownMenuItem<String>(value: e, child: Text(e))).toList(),
        onChanged: cb,
      ),
    ]));
  }

  // ==================== AI Config ====================

  Widget _buildAiConfigCard() {
    return Card(
      child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('选择一种 AI 服务，免费使用', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
        const SizedBox(height: 10),
        TextField(
          controller: TextEditingController(text: _geminiKey),
          decoration: InputDecoration(labelText: 'Gemini API Key（免费）', hintText: '从 aistudio.google.com 获取',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)), isDense: true,
            suffixIcon: _geminiKey.isNotEmpty ? Icon(Icons.check_circle, color: AppConstants.successColor, size: 18) : null),
          onChanged: (v) { _geminiKey = v.trim(); _saveAiConfig(); },
        ),
        const SizedBox(height: 8),
        TextField(
          controller: TextEditingController(text: _ollamaUrl),
          decoration: InputDecoration(labelText: 'Ollama 地址（本地免费）', hintText: 'http://192.168.x.x:11434',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)), isDense: true,
            suffixIcon: _ollamaUrl.isNotEmpty ? Icon(Icons.check_circle, color: AppConstants.successColor, size: 18) : null),
          onChanged: (v) { _ollamaUrl = v.trim(); _saveAiConfig(); },
        ),
      ])),
    );
  }

  Widget _buildColumnConfigCard() {
    return Card(
      child: Padding(padding: const EdgeInsets.all(10), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('表格列号（0开始，改完扫条码生效）', style: TextStyle(fontSize: 11, color: AppConstants.textSecondary)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          _colChip('名称', _cName, 'col_name'),
          _colChip('条码', _cBarcode, 'col_barcode'),
          _colChip('规格', _cSpec, 'col_spec'),
          _colChip('分类', _cCategory, 'col_category'),
          _colChip('单位', _cUnit, 'col_unit'),
          _colChip('供货商', _cSupplier, 'col_supplier'),
          _colChip('库存', _cStock, 'col_stock'),
          _colChip('售价', _cSell, 'col_sell'),
          _colChip('进价', _cBuy, 'col_buy'),
        ]),
      ])),
    );
  }

  Widget _colChip(String label, int value, String key) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: BoxDecoration(border: Border.all(color: AppConstants.dividerColor), borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: const TextStyle(fontSize: 11)),
        const SizedBox(width: 4),
        GestureDetector(onTap: () => _setCol(key, value - 1), child: const Icon(Icons.remove, size: 14)),
        const SizedBox(width: 2),
        SizedBox(width: 22, child: Text('$value', textAlign: TextAlign.center, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold))),
        const SizedBox(width: 2),
        GestureDetector(onTap: () => _setCol(key, value + 1), child: const Icon(Icons.add, size: 14)),
      ]),
    );
  }

  Future<void> _setCol(String key, int v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(key, v);
    setState(() {
      switch (key) {
        case 'col_name': _cName = v; case 'col_barcode': _cBarcode = v;
        case 'col_spec': _cSpec = v; case 'col_category': _cCategory = v;
        case 'col_unit': _cUnit = v; case 'col_supplier': _cSupplier = v;
        case 'col_stock': _cStock = v; case 'col_sell': _cSell = v;
        case 'col_buy': _cBuy = v;
      }
    });
  }

  Widget _buildSupplierCard() {
    return Card(
      child: Padding(padding: const EdgeInsets.all(12), child: TextField(
        controller: _supplierCtrl,
        maxLines: 3,
        style: const TextStyle(fontSize: 12),
        decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, contentPadding: EdgeInsets.all(10),
          hintText: '以逗号分隔，如：邱铿,陈姐,老王'),
        onChanged: (v) async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('supplier_list', v);
        },
      )),
    );
  }

  Widget _buildServerCard() {
    return Card(
      child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
        SizedBox(width: 72, child: Text('服务器', style: const TextStyle(fontSize: 13, color: AppConstants.textSecondary))),
        Expanded(child: TextField(controller: _serverUrlCtrl,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(hintText: 'http://192.168.1.138', isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
          onChanged: (v) async { final p = await SharedPreferences.getInstance(); await p.setString('server_url', AuthService.normalizeUrl(v)); })),
      ])),
    );
  }

  Widget _buildPrinterCard() {
    return Card(
      child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Profile selector
        Row(children: [
          const Text('场地:', style: TextStyle(fontSize: 13, color: AppConstants.textSecondary)),
          const SizedBox(width: 8),
          Expanded(child: DropdownButton<String>(
            value: _activeProfile,
            isExpanded: true,
            underline: const SizedBox(),
            items: _profileNames.map((n) => DropdownMenuItem(value: n, child: Text(n, style: const TextStyle(fontSize: 14)))).toList(),
            onChanged: (v) { if (v != null && v != _activeProfile) _switchProfile(v); },
          )),
          const SizedBox(width: 4),
          GestureDetector(onTap: _createProfile, child: const Icon(Icons.add_circle_outline, size: 20, color: AppConstants.primaryColor)),
          const SizedBox(width: 4),
          GestureDetector(onTap: _renameProfile, child: const Icon(Icons.edit_outlined, size: 18, color: AppConstants.textSecondary)),
          const SizedBox(width: 4),
          if (_profileNames.length > 1)
            GestureDetector(onTap: _deleteProfile, child: const Icon(Icons.delete_outline, size: 18, color: AppConstants.errorColor)),
        ]),
        const Divider(height: 20),
        // Printer list
        ..._printerConfigs.map((c) => _buildPrinterRow(c)),
      ])),
    );
  }

  Widget _buildPrinterRow(PrinterConfig c) {
    final ipCtrl = _printerIpCtrls[c.id] ?? TextEditingController(text: c.ip);
    final portCtrl = _printerPortCtrls[c.id] ?? TextEditingController(text: c.port.toString());
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), decoration: BoxDecoration(color: AppConstants.primaryColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(4)), child: Text(c.name, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppConstants.primaryColor))),
          const Spacer(),
          Text('${c.labelWidth.toInt()}×${c.labelHeight.toInt()}mm ${c.protocol.toUpperCase()}', style: const TextStyle(fontSize: 10, color: AppConstants.textSecondary)),
        ]),
        const SizedBox(height: 4),
        Row(children: [
          Expanded(flex: 3, child: TextField(
            controller: ipCtrl, style: const TextStyle(fontSize: 12),
            decoration: const InputDecoration(hintText: 'IP 地址', isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
            onChanged: (v) => _savePrinterField(c.id, 'ip', v.trim()),
          )),
          const SizedBox(width: 6),
          SizedBox(width: 72, child: TextField(
            controller: portCtrl, style: const TextStyle(fontSize: 12), keyboardType: TextInputType.number,
            decoration: const InputDecoration(hintText: '端口', isDense: true, border: OutlineInputBorder(), contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6)),
            onChanged: (v) => _savePrinterField(c.id, 'port', v.trim()),
          )),
        ]),
      ]),
    );
  }

  // ==================== Template ====================

  Widget _buildTemplateCard() {
    return Card(
      child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('非核心参数默认值', style: TextStyle(fontSize: 12, color: AppConstants.textSecondary)),
        const SizedBox(height: 10),
        _tpl('货号', '自动生成'), _tpl('品牌', '常规'), _tpl('单位', '个'), _tpl('保质期', '无'), _tpl('会员折扣', '是'),
      ])),
    );
  }

  Widget _tpl(String k, String v) {
    return Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [
      SizedBox(width: 70, child: Text(k, style: const TextStyle(fontSize: 13, color: AppConstants.textSecondary))),
      Expanded(child: Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: AppConstants.bgColor, borderRadius: BorderRadius.circular(6)),
        child: Text(v, style: const TextStyle(fontSize: 13)))),
    ]));
  }
}
