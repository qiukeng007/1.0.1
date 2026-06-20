import 'package:flutter/material.dart';
import '../utils/constants.dart';

class VoiceFab extends StatefulWidget {
  final void Function(String text, Map<String, String> parsed) onResult;
  const VoiceFab({super.key, required this.onResult});
  @override State<VoiceFab> createState() => _VoiceFabState();
}

class _VoiceFabState extends State<VoiceFab> {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _showVoiceDialog(),
      child: Container(
        width: 52, height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppConstants.primaryColor,
          boxShadow: [BoxShadow(color: AppConstants.primaryColor.withValues(alpha: 0.4), blurRadius: 12, offset: const Offset(0, 4))],
        ),
        child: const Icon(Icons.mic_none, color: Colors.white, size: 26),
      ),
    );
  }

  void _showVoiceDialog() {
    final ctrl = TextEditingController();
    bool submitted = false;

    void submit() {
      if (submitted) return;
      submitted = true;
      final text = ctrl.text.trim();
      if (text.isNotEmpty) {
        widget.onResult(text, _parse(text));
      }
      Navigator.of(context).maybePop();
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.keyboard_voice, color: AppConstants.primaryColor),
          SizedBox(width: 8),
          Text('语音输入', style: TextStyle(fontSize: 16)),
        ]),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: '点键盘 🎤 说话，自动填入',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            helperText: '设备不支持系统语音，请用键盘麦克风',
            helperStyle: const TextStyle(fontSize: 11),
          ),
          onSubmitted: (_) => submit(),
          onChanged: (v) {
            if (v.length >= 5) submit();
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: submit, child: Text('确定', style: TextStyle(color: AppConstants.primaryColor))),
        ],
      ),
    ).then((_) => ctrl.dispose());
  }

  Map<String, String> _parse(String text) {
    final m = <String, String>{};
    final q = RegExp(r'(-?\d+)\s*[个件只]|进了\s*(\d+)').firstMatch(text);
    if (q != null) m['qty'] = q.group(1) ?? q.group(2) ?? '';
    final b = RegExp(r'进价\s*(\d+\.?\d*)\s*[块元毛角]?').firstMatch(text);
    if (b != null) m['buyPrice'] = b.group(1)!;
    final s = RegExp(r'(?:[卖售]价?)\s*(\d+\.?\d*)\s*[块元毛角]?').firstMatch(text);
    if (s != null) m['sellPrice'] = s.group(1)!;
    final u = RegExp(r'(?:供应?商|供货商)\s*(\S+)').firstMatch(text);
    if (u != null) m['supplier'] = u.group(1)!;
    final un = RegExp(r'单位\s*(\S+)').firstMatch(text);
    if (un != null) m['unit'] = un.group(1)!;
    final c = RegExp(r'分类\s*(\S+)').firstMatch(text);
    if (c != null) m['category'] = c.group(1)!;
    final sp = RegExp(r'规格\s*(\S+)').firstMatch(text);
    if (sp != null) m['spec'] = sp.group(1)!;
    final an = RegExp(r'货号\s*(\S+)').firstMatch(text);
    if (an != null) m['articleNo'] = an.group(1)!;
    return m;
  }
}
