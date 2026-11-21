import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core_bridge.dart';
import '../../local_store.dart';
import '../app_scope.dart';
import '../theme/tokens.dart';

/// 红果扫码登录：二维码由红果服务端下发，用红果 App 扫码确认。
/// Cookie 只存本机应用私有目录，不上传任何服务。
class HongguoLoginPage extends StatefulWidget {
  const HongguoLoginPage({required this.store, super.key});

  final LocalStore store;

  @override
  State<HongguoLoginPage> createState() => _HongguoLoginPageState();
}

class _HongguoLoginPageState extends State<HongguoLoginPage> {
  bool _loading = false;
  bool _loggedIn = false;
  String _nickname = '';
  int _cookieCount = 0;

  AppRepository get _repo => AppScope.of(context).repository;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    try {
      final status = await _repo.hongguoStatus();
      if (!mounted) return;
      setState(() {
        _loggedIn = status['loggedIn'] == true;
        _nickname = status['nickname'] as String? ?? '';
        _cookieCount = (status['cookieCount'] as num?)?.toInt() ?? 0;
      });
    } catch (_) {}
  }

  Future<void> _login() async {
    setState(() => _loading = true);
    try {
      final state = await _repo.hongguoLogin();
      final session = state['session'] as String? ?? '';
      final png = state['qrBase64'] as String? ?? '';
      if (session.isEmpty || png.isEmpty) {
        throw StateError('红果没有返回二维码，请稍后再试');
      }
      if (!mounted) return;
      setState(() => _loading = false);
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _HongguoQrDialog(session: session, png: png, repo: _repo),
      );
      if (ok == true) await _refresh();
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _logout() async {
    setState(() => _loading = true);
    try {
      await _repo.hongguoLogout();
      await _refresh();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('红果账号')),
      body: ListView(
        padding: const EdgeInsets.all(Insets.page),
        children: [
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(Radii.lg),
            ),
            child: Row(
              children: [
                Icon(
                  _loggedIn ? Icons.verified_rounded : Icons.person_outline_rounded,
                  color: _loggedIn ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _loggedIn ? (_nickname.isEmpty ? '已登录红果' : _nickname) : '未登录',
                        style: TextStyle(
                          fontSize: TypeScale.title,
                          fontWeight: FontWeight.w600,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _loggedIn
                            ? '已保存 $_cookieCount 项会话凭据，仅存本机'
                            : '扫码后可以播放需要登录的剧集',
                        style: TextStyle(
                          fontSize: TypeScale.label,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (!_loggedIn)
            FilledButton.icon(
              onPressed: _loading ? null : _login,
              icon: const Icon(Icons.qr_code_2_rounded, size: 20),
              label: Text(_loading ? '正在获取二维码…' : '扫码登录'),
            )
          else
            OutlinedButton.icon(
              onPressed: _loading ? null : _logout,
              icon: const Icon(Icons.logout_rounded, size: 20),
              label: const Text('退出登录'),
            ),
          const SizedBox(height: 20),
          Text(
            '凭据只保存在这台设备上，不会上传到任何服务器；退出登录会立即清除。',
            style: TextStyle(fontSize: TypeScale.caption, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _HongguoQrDialog extends StatefulWidget {
  const _HongguoQrDialog({required this.session, required this.png, required this.repo});

  final String session;
  final String png;
  final AppRepository repo;

  @override
  State<_HongguoQrDialog> createState() => _HongguoQrDialogState();
}

class _HongguoQrDialogState extends State<_HongguoQrDialog> {
  Timer? _timer;
  String _hint = '请用红果 App 扫码';
  bool _done = false;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    if (_done) return;
    _ticks++;
    if (_ticks > 90) {
      _finish(false, '二维码已过期，请重新获取');
      return;
    }
    try {
      final state = await widget.repo.hongguoLoginPoll(widget.session);
      final status = (state['status'] as String? ?? '').toLowerCase();
      if (status == 'confirmed') {
        _finish(true, '登录成功');
        return;
      }
      if (status == 'expired') {
        _finish(false, '二维码已过期，请重新获取');
        return;
      }
      if (status == 'scanning' || status == 'scanned') {
        if (mounted) setState(() => _hint = '已扫码，请在手机上确认');
      }
    } catch (_) {}
  }

  void _finish(bool ok, String hint) {
    _done = true;
    _timer?.cancel();
    if (!mounted) return;
    setState(() => _hint = hint);
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (mounted) Navigator.of(context).pop(ok);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('扫码登录红果'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(Radii.md),
            ),
            child: Image.memory(
              base64Decode(widget.png),
              width: 200,
              height: 200,
              fit: BoxFit.contain,
            ),
          ),
          const SizedBox(height: 14),
          Text(_hint, style: const TextStyle(fontSize: TypeScale.body)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            _timer?.cancel();
            Navigator.of(context).pop(false);
          },
          child: const Text('取消'),
        ),
      ],
    );
  }
}
