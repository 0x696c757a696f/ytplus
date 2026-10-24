import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumtub/google_auth.dart';

const config = OAuthClientConfig('123-abc.apps.googleusercontent.com', 'desktop-secret');

void main() {
  test('derives the S256 challenge from RFC 7636', () {
    expect(Pkce('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk').challenge, 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
    final generated = Pkce.generate();
    expect(generated.verifier, hasLength(64));
    expect(generated.verifier, matches(RegExp(r'^[A-Za-z0-9\-._~]+$')));
  });

  test('accepts only desktop client ids', () {
    expect(config.isValid, isTrue);
    expect(const OAuthClientConfig('not-a-client', '').isValid, isFalse);
    expect(OAuthClientConfig.fromJson({'id': ' 123-abc.apps.googleusercontent.com ', 'secret': 's'})!.id, config.id);
    expect(OAuthClientConfig.fromJson({'id': 'x'}), isNull);
  });

  test('asks only for read-only YouTube access with PKCE', () {
    final uri = GoogleAuth(config, MockClient((_) async => http.Response('', 500)))
        .authorizationUri(redirectUri: 'http://127.0.0.1:5000', pkce: Pkce('verifier-verifier-verifier-verifier-verifier-1'), state: 'xyz');
    final query = uri.queryParameters;
    expect(uri.host, 'accounts.google.com');
    expect(query['scope'], 'https://www.googleapis.com/auth/youtube.force-ssl');
    expect(query['code_challenge_method'], 'S256');
    expect(query['code_challenge'], Pkce.challengeFor('verifier-verifier-verifier-verifier-verifier-1'));
    expect(query['redirect_uri'], 'http://127.0.0.1:5000');
    expect(query['state'], 'xyz');
    expect(query['access_type'], 'offline');
    expect(query.containsKey('client_secret'), isFalse);
  });

  test('signs in through the loopback redirect', () async {
    late Map<String, String> tokenRequest;
    final client = MockClient((request) async {
      expect(request.url, GoogleAuth.tokenEndpoint);
      tokenRequest = Uri.splitQueryString(request.body);
      return http.Response(jsonEncode({'access_token': 'access-1', 'expires_in': 3599, 'refresh_token': 'refresh-1'}), 200);
    });
    String? browserPage;
    final auth = GoogleAuth(config, client, openBrowser: (uri) async {
      // Plays the browser: Google sends the user back with a code.
      final redirect = Uri.parse(uri.queryParameters['redirect_uri']!);
      expect(redirect.host, '127.0.0.1');
      final http = HttpClient();
      // The favicon request must not end the sign-in.
      await (await (await http.getUrl(redirect.replace(path: '/favicon.ico'))).close()).drain<void>();
      final response = await (await http.getUrl(redirect.replace(queryParameters: {'code': 'the-code', 'state': uri.queryParameters['state']!}))).close();
      browserPage = await response.transform(utf8.decoder).join();
      http.close();
    });
    final tokens = await auth.signIn();
    expect(tokens.accessToken, 'access-1');
    expect(tokens.refreshToken, 'refresh-1');
    expect(tokens.expired, isFalse);
    expect(browserPage, contains('登录成功'));
    expect(tokenRequest['grant_type'], 'authorization_code');
    expect(tokenRequest['code'], 'the-code');
    expect(tokenRequest['client_id'], config.id);
    expect(tokenRequest['client_secret'], config.secret);
    expect(tokenRequest['code_verifier'], hasLength(64));
    expect(tokenRequest['redirect_uri'], startsWith('http://127.0.0.1:'));
  });

  test('rejects a callback with the wrong state or a denial', () async {
    Future<Object?> callback(Map<String, String> query) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final result = GoogleAuth.waitForCode(server, 'expected').then<Object?>((code) => code, onError: (Object e) => e);
      final http = HttpClient();
      await (await (await http.getUrl(Uri.http('127.0.0.1:${server.port}', '/', query))).close()).drain<void>();
      http.close();
      final value = await result;
      await server.close(force: true);
      return value;
    }

    expect(await callback({'code': 'c', 'state': 'expected'}), 'c');
    expect('${await callback({'code': 'c', 'state': 'forged'})}', contains('校验失败'));
    expect('${await callback({'error': 'access_denied', 'state': 'expected'})}', '已取消授权');
  });

  test('refresh keeps the refresh token and reports a revoked grant', () async {
    var revoked = false;
    final auth = GoogleAuth(config, MockClient((request) async {
      final body = Uri.splitQueryString(request.body);
      expect(body['grant_type'], 'refresh_token');
      if (revoked) return http.Response('{"error":"invalid_grant","error_description":"Token has been expired or revoked."}', 400);
      return http.Response('{"access_token":"access-2","expires_in":3599}', 200);
    }));
    final tokens = await auth.refresh('refresh-1');
    expect(tokens.accessToken, 'access-2');
    expect(tokens.refreshToken, 'refresh-1');
    revoked = true;
    await expectLater(auth.refresh('refresh-1'), throwsA(isA<OAuthException>().having((e) => e.revoked, 'revoked', isTrue).having((e) => '$e', 'message', isNot(contains('refresh-1')))));
  });
}
