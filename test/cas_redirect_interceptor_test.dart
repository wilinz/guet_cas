import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:guet_cas/guet_cas.dart';
import 'package:test/test.dart';

void main() {
  late HttpServer server;
  late String base;

  setUp(() async {
    // 三跳重定向链,每跳各下发一个 cookie:/a →(302)→ /b →(302)→ /c(200)。
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://${server.address.host}:${server.port}';
    server.listen((req) {
      final res = req.response;
      switch (req.uri.path) {
        case '/a':
          res.cookies.add(Cookie('ca', '1')..path = '/');
          res.statusCode = HttpStatus.found; // 302
          res.headers.set(HttpHeaders.locationHeader, '/b');
          break;
        case '/b':
          res.cookies.add(Cookie('cb', '2')..path = '/');
          res.statusCode = HttpStatus.found;
          res.headers.set(HttpHeaders.locationHeader, '/c');
          break;
        case '/c':
          res.cookies.add(Cookie('cc', '3')..path = '/');
          res.statusCode = HttpStatus.ok;
          res.write('ok');
          break;
        default:
          res.statusCode = HttpStatus.notFound;
      }
      res.close();
    });
  });

  tearDown(() async => server.close(force: true));

  Dio buildDio(CookieJar jar) {
    final dio = Dio(BaseOptions(followRedirects: false, validateStatus: (_) => true));
    dio.interceptors.add(CookieManager(jar));
    dio.interceptors.add(RedirectInterceptor(() => dio));
    return dio;
  }

  test('跟随多重重定向,并保存沿途每一跳的 Set-Cookie', () async {
    final jar = CookieJar();
    final dio = buildDio(jar);

    final resp = await dio.get('$base/a');

    expect(resp.statusCode, 200);
    expect(resp.data, 'ok');
    expect(resp.redirectCount, 2); // a→b→c 共两跳
    expect(resp.rawUri.path, '/a'); // 链路起点

    // 关键:中间各跳下发的 cookie 都进了 jar(原生 followRedirects 会丢)。
    final cookies = await jar.loadForRequest(Uri.parse('$base/c'));
    final names = cookies.map((c) => c.name).toSet();
    expect(names, containsAll(<String>{'ca', 'cb', 'cc'}));
  });

  test('extra.followRedirects=false 时不跟随,直接拿到 302', () async {
    final jar = CookieJar();
    final dio = buildDio(jar);

    final resp = await dio.get('$base/a',
        options: Options(extra: {RedirectInterceptor.followRedirects: false}));

    expect(resp.statusCode, 302);
    expect(resp.headers.value('location'), '/b');
    expect(resp.redirectCount, 0);
  });
}
