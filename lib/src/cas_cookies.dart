import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';

/// 给每个请求带上 `Referer = 当前请求 URI`(复刻 app 的 RefererInterceptor)。
/// 金智 CAS 的部分风控分支会校验 Referer,缺了它更容易被判异常。
class RefererInterceptor extends Interceptor {
  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.headers['Referer'] = options.uri.toString();
    handler.next(options);
  }
}

/// CAS 域上「无过期、纯会话」且**会污染下一次登录**的 cookie。
///
/// - `JSESSIONID`:单次交互式登录的 webflow 会话,串起本次 GET 拿到的
///   `pwdEncryptSalt` 与 `execution`。GET/POST 必须用同一个;**跨登录复用旧值会污染**。
/// - `route`:负载均衡节点粘性 cookie。浏览器整生命周期都留着它,一旦粘到某节点
///   就一直命中同一节点;客户端若复用上次的 `route`,可能被钉在陈旧/异常实例上。
///
/// 注意**不**包含 `CASTGC`(TGT 票根,Path=/authserver、有 Max-Age,驱动免密秒登)
/// 和各业务域(bkjw / pcportal …)的会话 cookie——那些要跨登录保留。
const kCasSessionCookieNames = {'JSESSIONID', 'route'};

/// 在一次全新登录**之前**,精准移除 CAS 的会话型 cookie(默认 [kCasSessionCookieNames]),
/// 保留 `CASTGC` 等带过期/业务域的 cookie 不动。
///
/// 按浏览器语义:无过期的会话 cookie 本就应在「新的一次交互式登录」前被丢弃,
/// 这样紧接着的 GET 会拿到全新的 `JSESSIONID`/`route`,避免「过期污染」。
///
/// cookie_jar 没有「按名删」的 API,这里采用
/// 「读出 → 滤掉目标名 → 按 host 整删 → 其余原样存回」,
/// 保留下来的 cookie 仍带着各自的 path/domain/Secure。
Future<void> removeCasSessionCookies(
  CookieJar jar, {
  Uri? casLoginUri,
  Set<String> names = kCasSessionCookieNames,
}) async {
  final uri = casLoginUri ?? Uri.parse('https://cas.guet.edu.cn/authserver/login');
  final existing = await jar.loadForRequest(uri);
  if (existing.isEmpty) return; // 空 jar(如冷启动/全新安装)无事可做
  final keep = existing.where((c) => !names.contains(c.name)).toList();
  await jar.delete(uri); // 按 host 整删(无按名删 API)
  if (keep.isNotEmpty) await jar.saveFromResponse(uri, keep); // 其余原样存回
}

/// 便捷重载:从 Dio 的 [CookieManager] 拿到 jar 后调用 [removeCasSessionCookies]。
/// 若该 Dio 未挂 [CookieManager],静默跳过。
Future<void> removeCasSessionCookiesFromDio(
  Dio dio, {
  Uri? casLoginUri,
  Set<String> names = kCasSessionCookieNames,
}) async {
  for (final i in dio.interceptors) {
    if (i is CookieManager) {
      await removeCasSessionCookies(i.cookieJar,
          casLoginUri: casLoginUri, names: names);
      return;
    }
  }
}

/// 读出当前 CAS 域上的 `route`(落到哪个后端节点),没有则返回空串——用于排查/日志。
Future<String> currentRoute(CookieJar jar, {Uri? casLoginUri}) async {
  final uri = casLoginUri ?? Uri.parse('https://cas.guet.edu.cn/authserver/login');
  final cookies = await jar.loadForRequest(uri);
  for (final c in cookies) {
    if (c.name == 'route') return c.value;
  }
  return '';
}

/// 构造一个忽略证书错误、不自动跟随重定向的 [HttpClient](方便观测 302/401 原始响应)。
HttpClient buildInsecureHttpClient() {
  final c = HttpClient();
  c.badCertificateCallback = (_, _, _) => true;
  return c;
}
