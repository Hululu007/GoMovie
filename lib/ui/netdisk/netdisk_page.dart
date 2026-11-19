import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core_bridge.dart';
import '../app_scope.dart';

/// 网盘频道：扫码登录夸克 → 粘贴分享链接 → 选集播放。
///
/// 说明：分享列表免登录即可解析；播放需要登录态（cookie 只存本机）。
class NetdiskPage extends StatefulWidget {
  const NetdiskPage({super.key});

  @override
  State<NetdiskPage> createState() => _NetdiskPageState();
}

class _NetdiskPageState extends State<NetdiskPage> {
  final _link = TextEditingController();
  final _tvboxUrl = TextEditingController();
  bool _loading = false;
  bool _loggedIn = false;
  String _status = '';
  String _tvboxSummary = '未订阅饭太硬 / TVBox 接口';
  List<Map<String, dynamic>> _episodes = const [];
  String _shareUrl = '';

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  @override
  void dispose() {
    _link.dispose();
    _tvboxUrl.dispose();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    try {
      final repo = AppScope.of(context).repository;
      final data = await repo.netdiskStatus();
      final ready = data['ready'] as Map? ?? const {};
      final tvbox = await repo.tvboxStatus();
      if (!mounted) return;
      final subUrl = tvbox['url'] as String? ?? '';
      final supported = tvbox['supportedCount'] as int? ?? 0;
      final skipped = tvbox['skippedCount'] as int? ?? 0;
      if (subUrl.isNotEmpty && _tvboxUrl.text.isEmpty) {
        _tvboxUrl.text = subUrl;
      }
      setState(() {
        _loggedIn = ready['quark'] == true;
        _status = _loggedIn ? '夸克已登录' : '夸克未登录';
        _tvboxSummary = subUrl.isEmpty
            ? '未订阅饭太硬 / TVBox 接口'
            : '已加载 $supported 个兼容站源（跳过 $skipped 个 .jar 源）';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _status = '$error');
    }
  }

  Future<void> _login() async {
    setState(() => _loading = true);
    try {
      final repo = AppScope.of(context).repository;
      final state = await repo.netdiskLogin();
      final id = state['id'] as String? ?? '';
      final png = state['qrBase64'] as String? ?? '';
      if (id.isEmpty || png.isEmpty) {
        throw StateError('无法获取登录二维码');
      }
      if (!mounted) return;
      setState(() => _loading = false);
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _QrDialog(session: id, png: png, repo: repo),
      );
      if (ok == true) {
        await _refreshStatus();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _logout() async {
    await AppScope.of(context).repository.netdiskLogout('quark');
    await _refreshStatus();
  }

  Future<void> _cleanupTemp() async {
    setState(() => _loading = true);
    try {
      final res = await AppScope.of(context).repository.netdiskCleanup();
      final deleted = res['deleted'] as int? ?? 0;
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已清理 $deleted 个临时转存文件')));
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _subscribeTVBox() async {
    final url = _tvboxUrl.text.trim();
    if (url.isEmpty) return;
    setState(() => _loading = true);
    try {
      await AppScope.of(context).repository.tvboxSubscribe(url);
      await _refreshStatus();
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(_tvboxSummary)));
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _clearTVBox() async {
    setState(() => _loading = true);
    try {
      await AppScope.of(context).repository.tvboxClear();
      _tvboxUrl.clear();
      await _refreshStatus();
      if (!mounted) return;
      setState(() => _loading = false);
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _parse() async {
    final url = _link.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _loading = true;
      _episodes = const [];
      _shareUrl = url;
    });
    try {
      final data = await AppScope.of(context).repository.netdiskShare(url);
      final rows = (data['episodes'] as List? ?? const [])
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList();
      if (!mounted) return;
      setState(() {
        _episodes = rows;
        _loading = false;
        _status = rows.isEmpty ? '这个分享里没有可播放的视频' : '共 ${rows.length} 集';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _status = '$error';
      });
    }
  }

  Future<void> _play(int index) async {
    setState(() => _loading = true);
    try {
      final data = await AppScope.of(context).repository.netdiskPlay(
        _shareUrl,
        index,
      );
      final url = data['url'] as String? ?? '';
      final headers = <String, String>{
        for (final row in (data['headers'] as Map? ?? const {}).entries)
          '${row.key}': '${row.value}',
      };
      if (url.isEmpty) throw StateError('没有拿到播放地址');
      if (!mounted) return;
      setState(() => _loading = false);
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _NetdiskPlayerPage(url: url, headers: headers),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('网盘分享与订阅')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.cloud_outlined),
                  title: const Text('夸克网盘'),
                  subtitle: Text(_status),
                  trailing: _loggedIn
                      ? TextButton(onPressed: _logout, child: const Text('退出登录'))
                      : FilledButton(
                          onPressed: _loading ? null : _login,
                          child: const Text('扫码登录'),
                        ),
                ),
                if (_loggedIn)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: TextButton.icon(
                        onPressed: _loading ? null : _cleanupTemp,
                        icon: const Icon(
                          Icons.cleaning_services_outlined,
                          size: 16,
                        ),
                        label: const Text('清理临时目录 (gomovie_tmp)'),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '饭太硬 / TVBox 接口订阅',
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _tvboxSummary,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _tvboxUrl,
                          decoration: const InputDecoration(
                            hintText: '输入订阅 JSON 地址 (http/https)',
                            border: OutlineInputBorder(),
                            isDense: true,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: _loading ? null : _subscribeTVBox,
                        child: const Text('同步'),
                      ),
                    ],
                  ),
                  if (_tvboxUrl.text.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _loading ? null : _clearTVBox,
                        child: const Text('清除订阅'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _link,
            decoration: const InputDecoration(
              labelText: '粘贴夸克分享链接',
              hintText: 'https://pan.quark.cn/s/xxxx',
              border: OutlineInputBorder(),
            ),
            maxLines: 1,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _loading ? null : _parse,
            icon: const Icon(Icons.search),
            label: Text(_loading ? '处理中…' : '解析分享'),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 3),
          const SizedBox(height: 12),
          for (var i = 0; i < _episodes.length; i++)
            ListTile(
              dense: true,
              leading: Text('${i + 1}'),
              title: Text('${_episodes[i]['name'] ?? ''}'),
              subtitle: Text(_sizeText(_episodes[i]['size'])),
              trailing: const Icon(Icons.play_arrow_rounded),
              onTap: () => _play(i),
            ),
        ],
      ),
    );
  }

  static String _sizeText(Object? raw) {
    final size = (raw as num?)?.toDouble() ?? 0;
    if (size <= 0) return '';
    if (size > 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    return '${(size / (1024 * 1024)).toStringAsFixed(0)} MB';
  }
}

/// 显示二维码并轮询登录结果。
class _QrDialog extends StatefulWidget {
  const _QrDialog({
    required this.session,
    required this.png,
    required this.repo,
  });
  final String session;
  final String png;
  final AppRepository repo;

  @override
  State<_QrDialog> createState() => _QrDialogState();
}

class _QrDialogState extends State<_QrDialog> {
  Timer? _timer;
  String _hint = '用夸克 App 扫码并确认登录';

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final state = await widget.repo.netdiskLoginPoll(widget.session);
      final status = state['status'] as String? ?? '';
      if (!mounted) return;
      if (status == 'done') {
        _timer?.cancel();
        Navigator.of(context).pop(true);
        return;
      }
      if (status == 'expired' || status == 'error') {
        _timer?.cancel();
        setState(() => _hint = state['message'] as String? ?? '登录失败，请重试');
        return;
      }
      if (status == 'scanned') {
        setState(() => _hint = '已扫码，正在保存登录态…');
      }
    } catch (_) {
      // 轮询失败不打断，下一轮继续。
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = base64Decode(widget.png);
    return AlertDialog(
      title: const Text('扫码登录夸克网盘'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 240,
            height: 240,
            child: Image.memory(Uint8List.fromList(bytes), fit: BoxFit.contain),
          ),
          const SizedBox(height: 12),
          Text(_hint, textAlign: TextAlign.center),
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

/// 极简播放页：直链 + 请求头（网盘 CDN 需要 cookie）。
class _NetdiskPlayerPage extends StatefulWidget {
  const _NetdiskPlayerPage({required this.url, required this.headers});
  final String url;
  final Map<String, String> headers;

  @override
  State<_NetdiskPlayerPage> createState() => _NetdiskPlayerPageState();
}

class _NetdiskPlayerPageState extends State<_NetdiskPlayerPage> {
  late final Player _player;
  late final VideoController _controller;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _controller = VideoController(_player);
    _player.open(Media(widget.url, httpHeaders: widget.headers));
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('网盘播放'),
      ),
      body: Center(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Video(controller: _controller),
        ),
      ),
    );
  }
}
