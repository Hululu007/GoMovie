import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'core_bridge.dart';

abstract final class WebViewBridge {
  static const MethodChannel _channel = MethodChannel('gomovie/webview');
  static const MethodChannel _spiderChannel = MethodChannel('gomovie/spider');
  static HttpServer? _server;

  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  static bool get spiderSupported => !kIsWeb && Platform.isAndroid;

  static bool isChallengeError(String message) =>
      message.contains('Cloudflare 人机验证') ||
      message.contains('完成人机验证') ||
      message.contains('手动完成验证') ||
      message.toLowerCase().contains('just a moment');

  static Future<int> _ensureServer() async {
    final existing = _server;
    if (existing != null) return existing.port;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) async {
      try {
        if (request.uri.path == '/spider' && request.method == 'POST') {
          final bodyText = await utf8.decoder.bind(request).join();
          final payload = Map<String, dynamic>.from(
            jsonDecode(bodyText) as Map,
          );
          final res = await _spiderChannel.invokeMapMethod<String, dynamic>(
            'callSpider',
            payload,
          );
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'ok': res?['ok'] == true,
              'json': res?['json'] as String? ?? '',
              'error': res?['error'] as String? ?? '',
            }),
          );
          return;
        }
        if (request.uri.path != '/fetch') {
          request.response.statusCode = HttpStatus.notFound;
          return;
        }
        final target = request.uri.queryParameters['url'] ?? '';
        if (target.isEmpty) {
          request.response.statusCode = HttpStatus.badRequest;
          return;
        }
        final res = await _channel.invokeMapMethod<String, dynamic>(
          'fetchHtml',
          {'url': target},
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'ok': res?['ok'] == true,
            'html': res?['html'] as String? ?? '',
            'url': res?['url'] as String? ?? target,
          }),
        );
      } catch (error) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'ok': false, 'error': '$error'}));
      } finally {
        await request.response.close();
      }
    });
    return server.port;
  }

  static Future<void> ensureSpiderBridge(AppRepository repo) async {
    if (!spiderSupported) return;
    final port = await _ensureServer();
    await repo.registerSpiderBridge(port);
  }

  static Future<bool> verifySource(AppRepository repo, String source) async {
    if (!supported) return false;
    final url = await repo.sourceChallengeUrl(source);
    if (url.isEmpty) return false;
    final res = await _channel.invokeMapMethod<String, dynamic>(
      'openChallenge',
      {'url': url},
    );
    if (res?['ok'] != true) return false;
    final cookies = res?['cookies'] as String? ?? '';
    final userAgent = res?['userAgent'] as String? ?? '';
    final port = await _ensureServer();
    await repo.registerWebViewBridge(
      port: port,
      url: url,
      source: source,
      cookies: cookies,
      userAgent: userAgent,
    );
    return true;
  }
}
