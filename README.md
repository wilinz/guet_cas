# guet_cas

桂电(GUET)/ **金智教育(Wisedu)** 统一身份认证 —— 基于 **Apereo CAS** 的定制版 —— 的 Dart 客户端实现。

把真实客户端的登录流程**忠实抽出**成一个透明、自包含、可直接跑的库,并沉淀了两个排查了很久才定位到的坑:**密码加密的 IV 坑** 与 **`JSESSIONID`/`route` 过期污染**。

> 用于作者自己学校 app 的登录对接与协议研究。

## 这是哪家的协议?

登录页用 `pwdEncryptSalt`(隐藏域下发的动态 salt)+ `encrypt.js`(CryptoJS `AES-128-CBC`)加密密码、`/authserver/login` 作为登录端点 —— 这是 **金智教育(Wisedu)** 对 Apereo CAS 定制版的明确指纹,国内大量高校的「统一身份认证」都是这套。本仓库针对 `cas.guet.edu.cn`(桂电),但对其它金智部署的高校应当大同小异。

## 安装 / 使用

```yaml
dependencies:
  guet_cas:
    git: https://github.com/<you>/guet_cas.git
```

```dart
import 'package:guet_cas/guet_cas.dart';

final client = CasClient(
  config: const CasConfig(
    casBaseUrl: 'https://cas.guet.edu.cn/',
    serviceUrl: 'https://pcportal.guet.edu.cn/',
  ),
  // 可选:账号开了验证码时才需要
  captchaSolver: (imageBytes) async => await recognize(imageBytes),
);

final r = await client.login('学号', '密码');
if (r.passwordAccepted) {
  print(r.needsMultiFactor ? '密码通过,需要多因子' : '登录成功 → ${r.location}');
} else {
  print('失败:${r.errorTip}');
}
```

命令行示例见 [`bin/login.dart`](bin/login.dart):

```bash
dart run bin/login.dart <学号> <密码>
# 需要验证码时(可选,凭据只走环境变量):
CAPTCHA_API=<识别服务URL> CAPTCHA_TOKEN=<token> \
  dart run bin/login.dart <学号> <密码>
```

## 登录流程

`CasClient.login()` 一步步复刻真实客户端(见 [`lib/src/cas_client.dart`](lib/src/cas_client.dart)):

```
┌─ 0. 清陈旧会话 cookie ── removeCasSessionCookies(): 删 JSESSIONID/route,保留 CASTGC
│
├─ 1. GET /authserver/login?service=<业务系统>
│        └─ 解析 HTML:#pwdEncryptSalt(密码加密 key)、#execution(webflow 令牌)
│        └─ 响应里 Set-Cookie: JSESSIONID、route(本次会话从这里确定)
│
├─ 2. GET /authserver/bfp/info?bfp=<32位HEX>     上报浏览器指纹(真客户端会做)
│        └─ 拿到 MULTIFACTOR_BROWSER_FINGERPRINT cookie
│
├─ 3. GET /authserver/checkNeedCaptcha.htl?username=<学号>   → {"isNeed": true/false}
│
├─ 4. (若需要) GET /authserver/getCaptcha.htl → 图片字节 → CaptchaSolver 识别
│
├─ 5. 加密密码:CasCrypto.encryptCasPassword(密码, salt)
│        AES-128-CBC( randomString(64)+密码, key=salt, iv=ASCII随机16字符 ) → base64
│
└─ 6. POST /authserver/login?service=<业务系统>
         username / password(密文)/ captcha / execution / _eventId=submit
         cllt=userNameLogin / dllt=generalLogin / rememberMe / lt=''
         ├─ 302 → 密码通过(Location 含 reAuthCheck 则要多因子,否则回跳业务系统)
         └─ 401 → 失败,页面 #showErrorTip 给出文案(如「用户名或者密码有误」)
```

> 本库只解析 POST 的**直接响应**(302/401),不自动跟进后续重定向、不发短信/不完成多因子。

### 相关 cookie 用途

| Cookie | Path / 域 | 过期 | 作用 | 跨登录要不要留 |
|---|---|---|---|---|
| `JSESSIONID` | `/authserver` | 无(会话) | 单次**交互式登录**的 webflow 会话,串起本次 GET 拿到的 `pwdEncryptSalt` 与 `execution`。同一次登录的 GET 与 POST **必须用同一个**。 | ❌ 登录前应丢弃,见下「过期污染」 |
| `route` | CAS 域 | 无(会话) | 负载均衡的**节点粘性** cookie,把你钉到某个后端实例。 | ❌ 同上 |
| `CASTGC` | `/authserver` | **有 Max-Age** | CAS 的 **TGT 票根**,认人用;驱动「免密秒登」(下次 `GET /authserver/login` 直接 302)。 | ✅ 必须持久化保留 |
| `MULTIFACTOR_BROWSER_FINGERPRINT` | CAS 域 | 视下发 | 浏览器指纹,多因子风控用;由第 2 步的 `bfp/info` 下发。 | 随会话 |
| 业务域 cookie(`pcportal`/`bkjw` 等) | 各业务域 | 视下发 | 业务系统**自己域**上的会话,靠 CAS 回跳发的 **ST 票**建立,和 CAS 的 `JSESSIONID` 无关。 | ✅ 跨重启保留业务登录态靠它们 |

要点:**免密秒登靠 `CASTGC`(TGT),不靠 `JSESSIONID`**;丢/刷 `JSESSIONID` 不会让你登出。所以「登录前只清 `JSESSIONID`+`route`、不碰 `CASTGC` 与业务域」是安全的。

---

## 坑一:密码加密的 IV 必须是 ASCII 字符

**症状**:偶发「您提供的用户名或者密码有误」——前几次失败、重试几次又好了,很多人都中。

**真因**:密码加密的 **IV 用了随机字节**。

机理:网页 `encrypt.js`(CryptoJS)对密码做

```
AES-128-CBC( randomString(64) + 密码,  key = pwdEncryptSalt,  iv = randomString(16) )
```

IV **不随请求回传**。服务端用同一个 salt 当 key 解密,然后**先把整段结果按 UTF-8 解码、再截掉前 64 字符随机前缀**,取剩余为真密码。CBC 下密文首块(16 字节)受 IV 异或——若 IV 是**随机字节(0–255)**,这 16 字节约 **62% 概率不是合法 UTF-8** → 服务端 UTF-8 解码抛错 → 误报「密码有误」。

CryptoJS 用的是 `Utf8.parse(randomString(16))`,也就是 **ASCII 可见字符的字节**,首块永远能被 UTF-8 解码 → 100% 成功。

**实测**(63 个全新账户,三向交错,同一时间窗口):

| IV 方式 | 成功率 |
|---|---|
| 随机字节 IV(错误) | 8/21 ≈ **38%** |
| **ASCII 字符 IV(正确)** | **21/21 = 100%** |
| 网页 CryptoJS | 19/21(2 个失败是改过密码的号 → 有效 100%) |

**修复**:[`CasCrypto.encryptCasPassword`](lib/src/cas_crypto.dart) 用 ASCII 字符 IV:

```dart
final iv = enc.IV(Uint8List.fromList(randomAlphanumeric(16).codeUnits)); // ✅
// 不要:enc.IV.fromSecureRandom(16)  ← 随机字节,~62% 失败                  // ❌
```

错误实现保留为 `CasCrypto.encryptCasPasswordInsecureRandomIv`,仅供对照/回归。`test/cas_crypto_test.dart` 用「首块能否 UTF-8 解码」量化了两者差异。

---

## 坑二:`JSESSIONID` / `route` 过期污染 + 节点粘性

排查这个 bug 时一度怀疑是「落到坏后端节点」导致失败,后来证明**根因是坑一的 IV**,但下面这两点是真实存在的协议行为,值得作为登录前的卫生措施处理:

**`route` 的节点粘性,解释了为什么浏览器几乎不中招。** `route` 是无过期的粘性 cookie:浏览器整个生命周期都带着它,第一次落到某节点后,**之后每次登录都确定性命中同一节点**。老用户的浏览器早就「粘」在一个能用的节点上,自然感觉不到偶发失败;而且人手动登录失败了会自然重输重试,不会注意。客户端如果**复用上一次的 `route`**,则可能被钉在一个陈旧/异常的实例上。

**`JSESSIONID` 的过期污染。** `JSESSIONID` 是单次交互式登录的 webflow 会话(承载 salt + execution)。它无过期、纯会话级,本就应该在「新的一次登录」前被丢弃——若把上一次残留的 `JSESSIONID` 带进新登录,会和本次 GET 重新下发的流程状态不一致而产生污染。

**处理**:[`removeCasSessionCookies`](lib/src/cas_cookies.dart) 在每次登录**之前**精准移除 CAS 域上的 `JSESSIONID` 与 `route`,让紧接着的 GET 拿到全新的值,同时**不动** `CASTGC`(免密秒登)和业务域 cookie:

```dart
// cookie_jar 没有「按名删」的 API,所以:读出 → 滤掉目标名 → 按 host 整删 → 其余原样存回
await removeCasSessionCookies(cookieJar); // 默认删 {JSESSIONID, route}
```

按浏览器语义,这等价于「会话 cookie 在新会话开始前丢弃」。`CasConfig.dropStaleSessionCookies`(默认开)控制是否在 `login()` 里自动执行。`test/cas_cookies_test.dart` 验证了它**删对了**(`JSESSIONID`/`route`)且**留对了**(`CASTGC`)。

> 诚实说明:在全新安装、空 jar 的场景下仍能复现失败 → 证明偶发失败的**根因是坑一(IV)**,不是过期污染。清会话 cookie 是正确的卫生措施(也修掉了「节点粘到坏实例」这类长尾),但单靠它治不了 IV 那个根。

---

## 坑三:滑块验证码 —— 真正的校验是「时间」,不是轨迹

部分金智部署的验证码不是字符图,而是**滑块**(`captchaType == "slider"`),例如**华侨大学**(`id.hqu.edu.cn`)。端点也不同:

```
GET  /authserver/common/openSliderCaptcha.htl    → { smallImage, bigImage }(都是 base64)
POST /authserver/common/verifySliderCaptcha.htl  → 提交 sign,errorCode==1 即通过
```

流程里有两个**一般人想不到**的点:

**1)签名 key 藏在小图的尾巴里。** 提交的 `sign` 是把滑动轨迹 JSON 用 AES-CBC 加密得到的,而那个 key **不是 salt、也不在表单里**,而是 **base64 解码 `smallImage` 后的最后 16 字节**当作 ASCII 字符:

```
key      = base64Decode(smallImage).takeLast(16) as ASCII
sign     = AES-CBC( toJson(轨迹), key )
moveLen  = 缺口px / 大图宽 × canvas(280)    // 缺口px 由外部识别得到
```

**2)真正的关卡是「滑动总耗时」,不是轨迹的真假。** 它的**轨迹校验很弱**——随便造一条像样的轨迹(加减速、几十个点)就能过;但**服务端要求整个滑动过程 ≥ 5 秒**。所以拿到 `sign` 之后**不能立刻提交**,必须先凑够时间再 POST:

```
sleepTime = 5000 + random(0, 1000)   // 凑够 5 秒以上再提交
sleep(sleepTime)          // ← 关键:滑太快 = 直接判机器人
POST verifySliderCaptcha.htl(sign)
```

绝大多数人调滑块都死磕「缺口识别准不准、轨迹像不像人」,**没人会想到「你滑得太快」才是被拒的真因**——把提交前的等待补到 5 秒以上,过验证率立刻上来。

> 本库的 `CaptchaSolver(imageBytes)` 接口针对**字符图**;滑块是另一对端点 + sign + 时间门,需单独处理(欢迎 PR)。

---

## 重定向:为什么不交给 dio 原生跟随

CAS 登录链里到处是 302(免密秒登、跨域回跳业务系统、http→https…),而 dio 的 `followRedirects: true` 是把重定向**甩给底层 HTTP 库(dart:io 的 `HttpClient`)**自己跟随的,这会出四类问题:

1. **多重重定向中的 `Set-Cookie` 会丢** —— 中间各跳由底层直接跟随,dio 的 `CookieManager` 不参与,沿途下发的 cookie 进不了 jar(CAS 一条链能种好几个 cookie,丢了就登不上);
2. **重定向期间你挂的拦截器全部不触发** —— `CookieManager`/`Referer`/`User-Agent` 的 `onRequest`/`onResponse` 都被跳过,既存不了 cookie 也注入不了头;
3. **重定向请求头改不了、且是默认值** —— 底层用它自己的默认头发下一跳,拦截器注入的 UA / Referer 全丢(CAS 风控会因此把你判成机器人);
4. **部分 HTTP 方法的重定向不被支持** —— dart:io 默认只自动跟随 GET/HEAD,POST 收到 302 直接抛 `RedirectException`。

本库改用 [`RedirectInterceptor`](lib/src/cas_redirect_interceptor.dart)(改编自公开包 [`dio_redirect_interceptor`](https://pub.dev/packages/dio_redirect_interceptor)):把 `followRedirects` 关掉,在 `onResponse` 里**用同一个 dio 重新发起下一跳**——于是每一跳都重新走完整条拦截器链,cookie 正常保存、UA/Referer 正常注入,POST 等方法的重定向也能跟随。

```dart
final dio = Dio(BaseOptions(followRedirects: false));
dio.interceptors.addAll([
  CookieManager(jar),
  RefererInterceptor(),
  RedirectInterceptor(() => dio),   // ← 每跳重走拦截器链
]);
```

只有登录提交那一步要**自己读 302/401**(判断密码通过还是失败),所以单独对该请求关掉跟随:

```dart
dio.post('authserver/login',
    options: Options(extra: {RedirectInterceptor.followRedirects: false}));
```

跟随完成后,可从响应上读到链路信息:`resp.redirectCount` / `resp.rawUri` / `resp.rawRequestOption`。`test/cas_redirect_interceptor_test.dart` 用本地三跳重定向服务器验证了「沿途每一跳的 cookie 都被保存」。

## 目录结构

```
lib/
  guet_cas.dart            导出入口
  src/
    cas_client.dart        CasClient —— 登录流程编排
    cas_crypto.dart        密码加密(ASCII IV)+ 错误实现对照
    cas_cookies.dart       removeCasSessionCookies / Referer / route 读取
    cas_redirect_interceptor.dart  手动重定向(保住 cookie/请求头)
    cas_models.dart        CasConfig / CasLoginResult / CaptchaSolver
bin/login.dart             命令行示例(识别服务走环境变量)
test/                      加密 / cookie 卫生 / 重定向的单元测试
```

## 测试

```bash
dart pub get
dart test      # all passing
dart analyze   # No issues found
```

## 免责声明

本仓库是对作者所在学校统一身份认证登录协议的客户端实现与研究记录,请在你拥有的账号、被授权访问的系统上使用。

## 许可证

[BSD-3-Clause](LICENSE) © 2026 wilinz
