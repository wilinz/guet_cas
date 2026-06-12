import 'dart:convert';
import 'dart:math';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:html/parser.dart' as html;

import 'cas_cookies.dart';
import 'cas_crypto.dart';
import 'cas_models.dart';
import 'cas_redirect_interceptor.dart';

/// 桂电 / 金智(Wisedu)统一身份认证(Apereo CAS 定制版)登录客户端。
///
/// 忠实复刻真实客户端的登录流程:
///   1. (可选)登录前清掉陈旧 `JSESSIONID`/`route`,避免过期污染;
///   2. `GET /authserver/login?service=...` → 解析 `pwdEncryptSalt` 与 `execution`;
///   3. (可选)`GET /authserver/bfp/info?bfp=...` 上报浏览器指纹;
///   4. `GET /authserver/checkNeedCaptcha.htl?username=...` 判断是否要验证码;
///   5. 要的话 `GET /authserver/getCaptcha.htl` 取图 → 交 [CaptchaSolver] 识别;
///   6. 用 [CasCrypto.encryptCasPassword] 加密密码(ASCII IV,见 README「IV 坑」);
///   7. `POST /authserver/login` 提交;302=密码通过,401=失败。
class CasClient {
  final CasConfig config;
  final CaptchaSolver? captchaSolver;
  final Dio dio;
  final CookieJar cookieJar;

  CasClient._(this.config, this.captchaSolver, this.dio, this.cookieJar);

  /// 创建一个自带 cookie jar 的客户端。传入 [cookieJar] 可跨次登录持久化
  /// `CASTGC`(免密秒登)等 cookie;不传则用内存 jar(每个实例独立会话)。
  factory CasClient({
    CasConfig config = const CasConfig(),
    CaptchaSolver? captchaSolver,
    CookieJar? cookieJar,
  }) {
    final jar = cookieJar ?? CookieJar();
    final dio = Dio(BaseOptions(
      baseUrl: config.casBaseUrl,
      followRedirects: false,
      validateStatus: (s) => s != null,
      headers: {'User-Agent': config.userAgent},
    ));
    dio.httpClientAdapter =
        IOHttpClientAdapter(createHttpClient: buildInsecureHttpClient);
    dio.interceptors.add(CookieManager(jar));
    dio.interceptors.add(RefererInterceptor());
    // 手动重定向:每一跳都重走拦截器链,cookie/请求头才不会在重定向中丢失。
    // 见 cas_redirect_interceptor.dart 顶部对 dio 原生重定向四个问题的说明。
    dio.interceptors.add(RedirectInterceptor(() => dio));
    return CasClient._(config, captchaSolver, dio, jar);
  }

  static final Random _rng = Random.secure();

  /// 执行一次密码登录。识别不到验证码时抛 [CasProtocolException]。
  Future<CasLoginResult> login(String username, String password) async {
    // 1) 清陈旧会话 cookie(过期污染防护)
    if (config.dropStaleSessionCookies) {
      await removeCasSessionCookies(cookieJar,
          casLoginUri: Uri.parse('${config.casBaseUrl}authserver/login'));
    }

    // 2) GET 登录页,解析 salt / execution
    final page = await dio.get('authserver/login',
        queryParameters: {'service': config.serviceUrl},
        options: Options(responseType: ResponseType.plain));
    final doc = html.parse(page.data as String);
    final salt = doc.getElementById('pwdEncryptSalt')?.attributes['value'];
    final execution = doc.getElementById('execution')?.attributes['value'];
    if (salt == null || execution == null) {
      // 可能已免密秒登(直接 302),或页面结构变化
      final route = await currentRoute(cookieJar,
          casLoginUri: Uri.parse('${config.casBaseUrl}authserver/login'));
      throw CasProtocolException(
          '未解析到 pwdEncryptSalt/execution(status=${page.statusCode}, route=$route);'
          '可能已免密登录或登录页结构变化');
    }

    // 3) 上报浏览器指纹
    if (config.reportFingerprint) {
      final bfp = List.generate(
              16, (_) => _rng.nextInt(256).toRadixString(16).padLeft(2, '0'))
          .join()
          .toUpperCase();
      await dio.get('authserver/bfp/info',
          queryParameters: {
            'bfp': bfp,
            '_': DateTime.now().millisecondsSinceEpoch
          },
          options: Options(responseType: ResponseType.plain));
    }

    final route = await currentRoute(cookieJar,
        casLoginUri: Uri.parse('${config.casBaseUrl}authserver/login'));

    // 4) 是否需要验证码
    final needResp = await dio.get('authserver/checkNeedCaptcha.htl',
        queryParameters: {
          'username': username,
          '_': DateTime.now().millisecondsSinceEpoch
        },
        options: Options(responseType: ResponseType.plain));
    final needCaptcha = jsonDecode(needResp.data as String)['isNeed'] == true;

    // 5) 取验证码并识别
    var captcha = '';
    if (needCaptcha) {
      if (captchaSolver == null) {
        throw const CasProtocolException('需要验证码但未提供 CaptchaSolver');
      }
      final img = await dio.get(
          'authserver/getCaptcha.htl?${DateTime.now().millisecondsSinceEpoch}',
          options: Options(responseType: ResponseType.bytes));
      captcha = await captchaSolver!(img.data as List<int>);
      if (captcha.isEmpty) {
        throw const CasProtocolException('验证码识别返回空');
      }
    }

    // 6) 加密密码(ASCII IV)
    final encrypted = CasCrypto.encryptCasPassword(password, salt);

    // 7) 提交登录。这一步要自己读 302(密码通过)/ 401(失败),
    //    所以单独关掉本请求的重定向跟随,不让 RedirectInterceptor 把 302 吃掉。
    final post = await dio.post('authserver/login',
        queryParameters: {'service': config.serviceUrl},
        options: Options(
            contentType: 'application/x-www-form-urlencoded',
            responseType: ResponseType.plain,
            extra: {RedirectInterceptor.followRedirects: false}),
        data: {
          'username': username,
          'password': encrypted,
          'rememberMe': true,
          'captcha': captcha,
          '_eventId': 'submit',
          'cllt': 'userNameLogin',
          'dllt': 'generalLogin',
          'lt': '',
          'execution': execution,
        });

    final status = post.statusCode ?? 0;
    final location = post.headers.value('location') ?? '';
    String? errorTip;
    if (status == 401) {
      errorTip = html
          .parse(post.data as String)
          .querySelector('#showErrorTip')
          ?.text
          .trim();
    }
    return CasLoginResult(
      status: status,
      location: location,
      route: route,
      needCaptcha: needCaptcha,
      errorTip: errorTip,
    );
  }

  /// 释放底层连接。
  void close() => dio.close(force: true);
}
