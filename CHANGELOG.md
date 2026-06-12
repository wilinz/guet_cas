## 1.0.0

- 首个版本:桂电 / 金智(Wisedu)统一身份认证 CAS 登录的 Dart 实现。
- `CasClient`:GET 登录页 → 指纹上报 → checkNeedCaptcha → 验证码 → 加密 → POST。
- `CasCrypto`:AES-128-CBC 密码加密,**IV 用 ASCII 字符**(修复随机字节 IV 导致的偶发「密码有误」)。
- `removeCasSessionCookies`:登录前清掉陈旧 `JSESSIONID`/`route`,防过期污染,保留 `CASTGC`。
- 可插拔 `CaptchaSolver`(验证码识别由调用方接入)。
- `RedirectInterceptor`:手动跟随重定向,避免 dio 原生重定向丢 cookie / 请求头 / 不支持部分方法。
