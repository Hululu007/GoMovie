import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'core_bridge.dart';

abstract final class WebViewBridge {
  static const MethodChannel _channel = MethodChannel('gomovie/webview');
  static HttpServer? _server;

  static bool get supported =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  static bool isChallengeError(String message) =>
      message.contains('Cloudflare 人机验证') ||
      message.contains('完成人机验证') ||
      message.toLowerCase().contains('just a moment');

  static Future<int> _ensureServer() async {
    final existing = _server;
    if (existing != null) return existing.port;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen((request) async {
      try {
        if (request.uri.path != '/fetch') {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
        }
        final target = request.uri.queryParameters['url'] ?? '';
        if (target.isEmpty) {
          request.response.statusCode = HttpStatus.badRequest;
          await request.response.close();
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
