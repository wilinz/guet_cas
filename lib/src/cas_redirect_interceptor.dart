import 'package:dio/dio.dart';

/// 重定向回调:在每次重定向前调用,返回 `false` 可中止默认重定向、自行接管。
typedef RedirectCallback = bool Function(
    Response response, ResponseInterceptorHandler handler);

/// 手动重定向拦截器。
///
/// dio 的 `followRedirects: true` 把重定向**交给底层 HTTP 库(dart:io 的 HttpClient)**处理,
/// 这会带来几个问题:
///
///  1. **多重重定向过程中的 `Set-Cookie` 可能失效** —— 中间各跳由底层直接跟随,
///     dio 的 [CookieManager] 不参与,沿途下发的 cookie 存不进 jar;
///  2. **重定向期间你挂的拦截器全部不触发** —— `CookieManager`/`Referer`/`User-Agent`
///     这些 `onRequest`/`onResponse` 都被跳过,既保存不了 cookie,也注入不了头;
///  3. **重定向请求头改不了、且是默认值** —— 底层用它自己的默认头发起下一跳,
///     拦截器注入的 UA / Referer 丢失;
///  4. **部分 HTTP 方法的重定向不被支持** —— 例如 dart:io 默认只自动跟随 GET/HEAD,
///     POST 收到 302 会直接抛 `RedirectException`。
///
/// 本拦截器的做法:把 `followRedirects` 关掉(底层不跟随),改为在 [onResponse] 里
/// **用同一个 dio 重新发起下一跳请求**。于是每一跳都重新走完整条拦截器链 ——
/// cookie 正常保存、请求头正常注入,POST 等方法的重定向也能跟随(统一按 GET 跟随,
/// 符合浏览器对 301/302/303 的行为)。
///
/// 改编自公开包 [`dio_redirect_interceptor`](https://pub.dev/packages/dio_redirect_interceptor)。
///
/// 用法:
/// ```dart
/// final dio = Dio(BaseOptions(followRedirects: false));
/// dio.interceptors.addAll([
///   CookieManager(jar),
///   RedirectInterceptor(() => dio),
/// ]);
/// ```
/// 对单个请求关闭跟随(自行读取 3xx):
/// ```dart
/// dio.post(url, options: Options(extra: {RedirectInterceptor.followRedirects: false}));
/// ```
class RedirectInterceptor extends Interceptor {
  /// 返回用于发起下一跳的 dio(通常就是挂着本拦截器的那个)。
  final Dio Function() dio;
  final RedirectCallback? _redirectCallback;

  /// `extra` 开关:置为 `false` 时本请求不跟随重定向。默认跟随。
  static const String followRedirects = 'followRedirects';

  /// `extra` 键:首个请求的原始 URI(整条重定向链共享)。
  static const String rawUri = 'rawUri';

  /// `extra` 键:首个请求的原始 [RequestOptions]。
  static const String rawRequestOption = 'rawRequestOption';

  /// `extra` 键:已发生的重定向跳数。
  static const String redirectCount = 'redirectCount';

  /// 最大跳数,超过则停止并返回当前响应。
  final int maxRedirects;

  RedirectInterceptor(
    this.dio, {
    RedirectCallback? onRedirect,
    this.maxRedirects = 10,
  }) : _redirectCallback = onRedirect;

  @override
  Future<void> onResponse(
      Response response, ResponseInterceptorHandler handler) async {
    final opts = response.requestOptions;

    final follow = opts.extra[followRedirects] as bool? ?? true;
    if (!follow) {
      handler.next(response);
      return;
    }

    // 记下整条链的起点(供调用方通过扩展读取)。
    opts.extra[rawUri] ??= opts.uri;
    opts.extra[rawRequestOption] ??= opts;

    if (!_isRedirect(response.statusCode ?? 0)) {
      handler.next(response);
      return;
    }

    try {
      final count = (opts.extra[redirectCount] as int?) ?? 0;
      if (count >= maxRedirects) {
        handler.next(response);
        return;
      }
      if (_redirectCallback != null && !_redirectCallback(response, handler)) {
        return; // 回调已接管
      }

      final location = response.headers.value('location');
      if (location == null) throw Exception('Redirect location is null');
      final newUri = Uri.parse(_resolveLocation(opts.uri.toString(), location));
      opts.extra[redirectCount] = count + 1;

      // 复用原请求的各项配置(沿用同一个 extra,把 rawUri/count 等带到下一跳)。
      final option = Options(
        sendTimeout: opts.sendTimeout,
        receiveTimeout: opts.receiveTimeout,
        extra: opts.extra,
        responseType: opts.responseType,
        validateStatus: opts.validateStatus,
        receiveDataWhenStatusError: opts.receiveDataWhenStatusError,
        followRedirects: opts.followRedirects,
        maxRedirects: opts.maxRedirects,
        persistentConnection: opts.persistentConnection,
        requestEncoder: opts.requestEncoder,
        responseDecoder: opts.responseDecoder,
        listFormat: opts.listFormat,
      );

      // 用 getUri 重新发起 → 重新走完整拦截器链(cookie/头都生效),
      // 同时跟随了底层会拒绝的 POST 等方法的重定向(按 GET 跟随)。
      final redirected = await dio().getUri(newUri, options: option);
      return handler.next(redirected);
    } on DioException catch (e) {
      return handler.reject(e);
    }
  }

  bool _isRedirect(int statusCode) =>
      statusCode == 301 ||
      statusCode == 302 ||
      statusCode == 303 ||
      statusCode == 307 ||
      statusCode == 308;

  /// 把 `Location`(可能是相对路径)解析成绝对 URI。
  String _resolveLocation(final String rawUri, final String location) {
    var loc = location;
    if (loc.contains('://')) return loc;

    final schemaEndIndex = rawUri.indexOf('://') + 3;
    var index = loc.startsWith('/')
        ? rawUri.indexOf('/', schemaEndIndex)
        : rawUri.substring(schemaEndIndex).lastIndexOf('/') + schemaEndIndex;
    if (index == -1) index = rawUri.length - 1;
    var baseUrl = rawUri.substring(0, index + 1);
    if (baseUrl.endsWith('/')) {
      baseUrl = baseUrl.substring(0, baseUrl.length - 1);
    }
    if (loc.startsWith('/')) loc = loc.substring(1);
    return '$baseUrl/$loc';
  }
}

/// 读取本拦截器写入 [Response] 的重定向元信息。
extension RedirectInterceptorResponseExtension on Response {
  /// 已发生的重定向跳数(没经过重定向则为 0)。
  int get redirectCount =>
      (requestOptions.extra[RedirectInterceptor.redirectCount] as int?) ?? 0;

  /// 整条重定向链的起始 URI。
  Uri get rawUri =>
      (requestOptions.extra[RedirectInterceptor.rawUri] as Uri?) ??
      requestOptions.uri;

  /// 整条重定向链的起始 [RequestOptions]。
  RequestOptions get rawRequestOption =>
      (requestOptions.extra[RedirectInterceptor.rawRequestOption]
          as RequestOptions?) ??
      requestOptions;
}
