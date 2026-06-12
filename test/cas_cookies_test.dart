import 'package:cookie_jar/cookie_jar.dart';
import 'package:guet_cas/guet_cas.dart';
import 'package:test/test.dart';

void main() {
  final casUri = Uri.parse('https://cas.guet.edu.cn/authserver/login');

  Cookie sessionCookie(String name, String value, {String? path}) {
    final c = Cookie(name, value);
    if (path != null) c.path = path;
    return c;
  }

  group('removeCasSessionCookies', () {
    test('删掉 JSESSIONID/route,保留 CASTGC 等', () async {
      final jar = CookieJar();
      await jar.saveFromResponse(casUri, [
        sessionCookie('JSESSIONID', 'STALE-SESSION', path: '/authserver'),
        sessionCookie('route', 'cfe4'),
        sessionCookie('CASTGC', 'TGT-12345', path: '/authserver'),
      ]);

      await removeCasSessionCookies(jar, casLoginUri: casUri);

      final after = await jar.loadForRequest(casUri);
      final names = after.map((c) => c.name).toSet();
      expect(names.contains('JSESSIONID'), isFalse);
      expect(names.contains('route'), isFalse);
      expect(names.contains('CASTGC'), isTrue);
      expect(
          after.firstWhere((c) => c.name == 'CASTGC').value, 'TGT-12345');
    });

    test('空 jar 不报错', () async {
      final jar = CookieJar();
      await removeCasSessionCookies(jar, casLoginUri: casUri);
      expect(await jar.loadForRequest(casUri), isEmpty);
    });

    test('只有要删的 cookie 时,删完为空', () async {
      final jar = CookieJar();
      await jar.saveFromResponse(casUri, [
        sessionCookie('JSESSIONID', 'X'),
        sessionCookie('route', 'Y'),
      ]);
      await removeCasSessionCookies(jar, casLoginUri: casUri);
      expect(await jar.loadForRequest(casUri), isEmpty);
    });
  });

  group('currentRoute', () {
    test('读出 route 值', () async {
      final jar = CookieJar();
      await jar.saveFromResponse(casUri, [sessionCookie('route', '092d')]);
      expect(await currentRoute(jar, casLoginUri: casUri), '092d');
    });

    test('没有 route 时返回空串', () async {
      final jar = CookieJar();
      expect(await currentRoute(jar, casLoginUri: casUri), '');
    });
  });
}
