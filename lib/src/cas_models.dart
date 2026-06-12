/// 验证码识别器:输入验证码图片字节,返回识别出的字符串。
/// 由调用方接入(本地识别、人工输入或第三方服务),例子见 `bin/login.dart`。
typedef CaptchaSolver = Future<String> Function(List<int> imageBytes);

/// CAS 登录配置。
class CasConfig {
  /// CAS 根地址,如 `https://cas.guet.edu.cn/`(末尾带 `/`)。
  final String casBaseUrl;

  /// 要登录的业务系统 service,如 `https://pcportal.guet.edu.cn/`。
  final String serviceUrl;

  /// User-Agent。
  final String userAgent;

  /// 是否上报浏览器指纹(`GET /authserver/bfp/info?bfp=...`)。金智 CAS 的真客户端会做。
  final bool reportFingerprint;

  /// 登录前是否先清掉陈旧的 `JSESSIONID`/`route`(避免「过期污染」)。默认开。
  final bool dropStaleSessionCookies;

  const CasConfig({
    this.casBaseUrl = 'https://cas.guet.edu.cn/',
    this.serviceUrl = 'https://pcportal.guet.edu.cn/',
    this.userAgent =
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36',
    this.reportFingerprint = true,
    this.dropStaleSessionCookies = true,
  });
}

/// 登录结果。只解析 POST `/authserver/login` 的**直接响应**,不跟进后续 302。
class CasLoginResult {
  /// HTTP 状态码:302 = 密码通过(可能跳多因子);401 = 失败。
  final int status;

  /// 302 时的 `Location`(可能是业务系统回跳,或多因子 `reAuthCheck`)。
  final String location;

  /// 本次会话落到的 `route` 节点(用于排查)。
  final String route;

  /// 本次是否要求了验证码。
  final bool needCaptcha;

  /// 401 时页面里 `#showErrorTip` 的文案(如「您提供的用户名或者密码有误」)。
  final String? errorTip;

  const CasLoginResult({
    required this.status,
    required this.location,
    required this.route,
    required this.needCaptcha,
    this.errorTip,
  });

  /// 密码校验是否通过(302)。注意:`true` 之后可能还需完成多因子。
  bool get passwordAccepted => status == 302;

  /// 是否跳转到了多因子/二次认证。
  bool get needsMultiFactor =>
      status == 302 && location.contains('reAuthCheck');

  @override
  String toString() => 'CasLoginResult(status=$status, route=$route, '
      'needCaptcha=$needCaptcha, location=$location, errorTip=$errorTip)';
}

/// 解析失败 / 协议异常。
class CasProtocolException implements Exception {
  final String message;
  const CasProtocolException(this.message);
  @override
  String toString() => 'CasProtocolException: $message';
}
