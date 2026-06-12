/// 桂电 / 金智(Wisedu)统一身份认证(Apereo CAS 定制版)的 Dart 实现。
///
/// 用法见 README 与 `bin/login.dart`。核心:
///   - [CasClient]   —— 登录流程编排;
///   - [CasCrypto]   —— 密码加密(ASCII IV,见 README「IV 坑」);
///   - [removeCasSessionCookies] —— `JSESSIONID`/`route` 过期污染防护;
///   - [RedirectInterceptor] —— 手动跟随重定向,避免 dio 原生重定向丢 cookie/请求头。
library;

export 'src/cas_client.dart';
export 'src/cas_cookies.dart';
export 'src/cas_crypto.dart';
export 'src/cas_models.dart';
export 'src/cas_redirect_interceptor.dart';
