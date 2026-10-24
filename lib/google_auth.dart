import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'l10n/l10n.dart';

/// Read-only access to the account's YouTube data, as older versions asked.
const youtubeReadonlyScope = 'https://www.googleapis.com/auth/youtube.readonly';

/// Reading the account, and the changes the user makes from Lumtub: likes,
/// comments, playlists and subscriptions. Nothing is changed unless the user
/// asks for it.
const youtubeScope = 'https://www.googleapis.com/auth/youtube.force-ssl';

/// Whether a grant of [scope] allows changing the account.
bool canWriteWith(String? scope) =>
    scope != null && (scope.split(' ').contains(youtubeScope) || scope.split(' ').contains('https://www.googleapis.com/auth/youtube'));

/// A Google OAuth client of the "Desktop app" type. Google treats the secret
/// of a desktop client as public, so it may ship inside the app.
class OAuthClientConfig {
  const OAuthClientConfig(this.id, this.secret);
  final String id;
  final String secret;

  /// Set at build time with `--dart-define`; empty when the build has none.
  static const builtIn = OAuthClientConfig(
    String.fromEnvironment('LUMTUB_GOOGLE_CLIENT_ID'),
    String.fromEnvironment('LUMTUB_GOOGLE_CLIENT_SECRET'),
  );

  bool get isValid => id.trim().endsWith('.apps.googleusercontent.com');

  Map<String, dynamic> toJson() => {'id': id, 'secret': secret};

  static OAuthClientConfig? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final config = OAuthClientConfig(raw['id']?.toString().trim() ?? '', raw['secret']?.toString().trim() ?? '');
    return config.isValid ? config : null;
  }
}

/// PKCE (RFC 7636) verifier and its S256 challenge.
class Pkce {
  Pkce(this.verifier) : challenge = challengeFor(verifier);

  factory Pkce.generate([Random? random]) => Pkce(randomToken(64, random));

  final String verifier;
  final String challenge;

  static String challengeFor(String verifier) => base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');

  static const _unreserved = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';

  static String randomToken(int length, [Random? random]) {
    final source = random ?? Random.secure();
    return String.fromCharCodes(List.generate(length, (_) => _unreserved.codeUnitAt(source.nextInt(_unreserved.length))));
  }
}

class OAuthTokens {
  const OAuthTokens({required this.accessToken, required this.expiresAt, this.refreshToken, this.scope});
  final String accessToken;
  final DateTime expiresAt;
  final String? refreshToken;
  /// The scopes Google granted, separated by spaces.
  final String? scope;

  /// Treated as expired a minute early so a request does not race the expiry.
  bool get expired => DateTime.now().isAfter(expiresAt.subtract(const Duration(minutes: 1)));

  static OAuthTokens parse(String body, {String? previousRefreshToken}) {
    final data = jsonDecode(body);
    if (data is! Map || data['access_token'] is! String) throw OAuthException(tr('Google 返回的令牌格式不正确'));
    final seconds = data['expires_in'] is num ? (data['expires_in'] as num).toInt() : 3600;
    return OAuthTokens(
      accessToken: data['access_token'] as String,
      expiresAt: DateTime.now().add(Duration(seconds: seconds)),
      refreshToken: data['refresh_token'] is String ? data['refresh_token'] as String : previousRefreshToken,
      scope: data['scope'] is String ? data['scope'] as String : null,
    );
  }
}

/// Errors carry Google's error code, never a token or the request.
class OAuthException implements Exception {
  const OAuthException(this.message, {this.revoked = false});
  final String message;

  /// The refresh token no longer works; the user must sign in again.
  final bool revoked;

  @override
  String toString() => message;
}

/// Google sign-in for a desktop app: the system browser shows Google's page
/// and returns to a one-shot server on 127.0.0.1 (RFC 8252), with PKCE.
class GoogleAuth {
  GoogleAuth(this.config, this._client, {Future<void> Function(Uri)? openBrowser}) : _openBrowser = openBrowser ?? _openInBrowser;

  final OAuthClientConfig config;
  final http.Client _client;
  final Future<void> Function(Uri) _openBrowser;
  HttpServer? _server;

  static final authEndpoint = Uri.https('accounts.google.com', '/o/oauth2/v2/auth');
  static final tokenEndpoint = Uri.https('oauth2.googleapis.com', '/token');
  static final revokeEndpoint = Uri.https('oauth2.googleapis.com', '/revoke');

  Uri authorizationUri({required String redirectUri, required Pkce pkce, required String state}) => authEndpoint.replace(queryParameters: {
        'client_id': config.id,
        'redirect_uri': redirectUri,
        'response_type': 'code',
        'scope': youtubeScope,
        'code_challenge': pkce.challenge,
        'code_challenge_method': 'S256',
        'state': state,
        // A refresh token, so the user signs in once rather than hourly.
        'access_type': 'offline',
        'prompt': 'consent',
      });

  /// Opens the browser and waits for Google to send the user back.
  Future<OAuthTokens> signIn({Duration timeout = const Duration(minutes: 5)}) async {
    await cancel();
    final server = _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final redirectUri = 'http://127.0.0.1:${server.port}';
    final pkce = Pkce.generate();
    final state = Pkce.randomToken(32);
    // Listen before the browser opens, so a fast redirect is not missed.
    final callback = waitForCode(server, state);
    try {
      try {
        await _openBrowser(authorizationUri(redirectUri: redirectUri, pkce: pkce, state: state));
      } catch (_) {
        callback.ignore();
        throw OAuthException(tr('无法打开浏览器'));
      }
      final code = await callback.timeout(timeout, onTimeout: () => throw OAuthException(tr('登录超时，请重试')));
      return await _token({
        'grant_type': 'authorization_code',
        'code': code,
        'code_verifier': pkce.verifier,
        'redirect_uri': redirectUri,
      });
    } finally {
      await cancel();
    }
  }

  /// Stops waiting for the browser.
  Future<void> cancel() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  /// Answers requests to [server] until one carries the result for [state].
  /// Requests for other paths, such as the browser's favicon, are ignored.
  static Future<String> waitForCode(HttpServer server, String state) async {
    await for (final request in server) {
      final query = request.uri.queryParameters;
      if (request.uri.path != '/' || (!query.containsKey('code') && !query.containsKey('error'))) {
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
        continue;
      }
      final ok = query['state'] == state && query['code'] != null;
      request.response.headers.contentType = ContentType.html;
      request.response.write(_page(ok ? tr('登录成功') : tr('登录没有完成'), ok ? tr('可以关闭这个页面，回到 Lumtub。') : tr('请回到 Lumtub 重试。')));
      await request.response.close();
      if (query['state'] != state) throw OAuthException(tr('登录回调校验失败，请重试'));
      final error = query['error'];
      if (error != null) throw OAuthException(error == 'access_denied' ? tr('已取消授权') : tr('Google 拒绝了登录：{0}', [error]));
      return query['code']!;
    }
    throw OAuthException(tr('登录已取消'));
  }

  Future<OAuthTokens> refresh(String refreshToken) => _token({'grant_type': 'refresh_token', 'refresh_token': refreshToken}, previousRefreshToken: refreshToken);

  /// Asks Google to invalidate [token]; failures are ignored because the
  /// local copy is deleted either way.
  Future<void> revoke(String token) async {
    try {
      await _client.post(revokeEndpoint, body: {'token': token}).timeout(const Duration(seconds: 10));
    } catch (_) {}
  }

  Future<OAuthTokens> _token(Map<String, String> fields, {String? previousRefreshToken}) async {
    final response = await _client.post(tokenEndpoint, body: {
      ...fields,
      'client_id': config.id,
      if (config.secret.isNotEmpty) 'client_secret': config.secret,
    }).timeout(const Duration(seconds: 20));
    if (response.statusCode != 200) {
      final error = _errorCode(response.body);
      throw OAuthException(tr('Google 登录失败（{0}）', [error]), revoked: error == 'invalid_grant');
    }
    return OAuthTokens.parse(response.body, previousRefreshToken: previousRefreshToken);
  }

  static String _errorCode(String body) {
    try {
      final data = jsonDecode(body);
      if (data is Map && data['error'] is String) return data['error'] as String;
    } catch (_) {}
    return tr('HTTP 错误');
  }

  static Future<void> _openInBrowser(Uri uri) async {
    if (Platform.isWindows) {
      // rundll32 passes the whole address to the default browser; explorer.exe
      // can drop everything after the first '&'.
      await Process.start('rundll32.exe', ['url.dll,FileProtocolHandler', uri.toString()]);
    }
  }

  static String _page(String title, String message) => '<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>Lumtub</title>'
      '<body style="font-family:system-ui,sans-serif;display:grid;place-items:center;height:90vh;margin:0">'
      '<div style="text-align:center"><h2>$title</h2><p>$message</p></div></body></html>';
}
