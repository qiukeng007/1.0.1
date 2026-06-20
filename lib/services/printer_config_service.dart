import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/printer_config.dart';

class PrinterConfigService {
  static const _activeKey = 'printer_profile_active';
  static const _listKey = 'printer_profile_list';
  static const _prefix = 'printer_profile_';
  static const _currentKey = 'printer_configs';

  // ── Active profile ──

  Future<String> getActiveProfileName() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeKey) ?? '默认';
  }

  Future<List<String>> getProfileNames() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_listKey);
    if (s == null || s.isEmpty) return ['默认'];
    try { return (jsonDecode(s) as List).cast<String>(); } catch (_) { return ['默认']; }
  }

  Future<void> setActiveProfile(String name) async {
    final current = await loadConfigs();
    final oldName = await getActiveProfileName();
    await _saveProfile(oldName, current);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, name);
    final newConfigs = await _loadProfile(name);
    await _saveCurrent(newConfigs);
  }

  Future<void> createProfile(String name) async {
    final current = await loadConfigs();
    await _saveProfile(name, current);
    final names = await getProfileNames();
    names.add(name);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_listKey, jsonEncode(names));
  }

  Future<void> renameProfile(String oldName, String newName) async {
    final prefs = await SharedPreferences.getInstance();
    final oldJson = prefs.getString('$_prefix$oldName');
    if (oldJson != null) { await prefs.setString('$_prefix$newName', oldJson); await prefs.remove('$_prefix$oldName'); }
    final names = await getProfileNames();
    final i = names.indexOf(oldName);
    if (i >= 0) { names[i] = newName; await prefs.setString(_listKey, jsonEncode(names)); }
    final active = await getActiveProfileName();
    if (active == oldName) await prefs.setString(_activeKey, newName);
  }

  Future<void> deleteProfile(String name) async {
    final names = await getProfileNames();
    names.remove(name);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_listKey, jsonEncode(names));
    await prefs.remove('$_prefix$name');
    final active = await getActiveProfileName();
    if (active == name && names.isNotEmpty) await setActiveProfile(names.first);
  }

  // ── Current configs (active profile) ──

  Future<List<PrinterConfig>> loadConfigs() async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString(_currentKey);
    if (s == null || s.isEmpty) return defaultPrinters();
    try {
      final list = (jsonDecode(s) as List).map((e) => PrinterConfig.fromJson(e as Map<String, dynamic>)).toList();
      return list.isEmpty ? defaultPrinters() : list;
    } catch (_) { return defaultPrinters(); }
  }

  Future<void> saveConfigs(List<PrinterConfig> configs) async {
    final name = await getActiveProfileName();
    await _saveProfile(name, configs);
    await _saveCurrent(configs);
  }

  Future<void> _saveCurrent(List<PrinterConfig> configs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_currentKey, jsonEncode(configs.map((c) => c.toJson()).toList()));
  }

  Future<void> _saveProfile(String name, List<PrinterConfig> configs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefix$name', jsonEncode(configs.map((c) => c.toJson()).toList()));
  }

  Future<List<PrinterConfig>> _loadProfile(String name) async {
    final prefs = await SharedPreferences.getInstance();
    final s = prefs.getString('$_prefix$name');
    if (s == null || s.isEmpty) return defaultPrinters();
    try {
      final list = (jsonDecode(s) as List).map((e) => PrinterConfig.fromJson(e as Map<String, dynamic>)).toList();
      return list.isEmpty ? defaultPrinters() : list;
    } catch (_) { return defaultPrinters(); }
  }
}
