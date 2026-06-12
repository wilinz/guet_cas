import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;

/// 金智(Wisedu)统一身份认证登录密码加密。
///
/// 网页端 `encrypt.js`(CryptoJS)的算法:
///   ciphertext = AES-128-CBC( randomString(64) + password,
///                             key = pwdEncryptSalt,
///                             iv  = randomString(16) )
/// 然后 base64,放进表单的 `password` 字段提交。salt(`pwdEncryptSalt`)由登录页
/// 隐藏域下发,既当 key 又**不**随请求回传 IV——服务端用同一 salt 当 key,解密后
/// 先按 UTF-8 解码整段、再丢弃前 64 字符随机前缀,取剩余部分为真密码。
///
/// ⚠️ IV 必须是 **ASCII 可见字符**(CryptoJS 用 `Utf8.parse(randomString(16))`)。
/// 详见 [encryptCasPassword] 与 README「IV 坑」一节。
class CasCrypto {
  CasCrypto._();

  static const _alphanum =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  static final Random _rng = Random.secure();

  /// 生成 [n] 位 `[A-Za-z0-9]` 随机串(等价 CryptoJS 的 `randomString`)。
  static String randomAlphanumeric(int n) => String.fromCharCodes(
      Iterable.generate(n, (_) => _alphanum.codeUnitAt(_rng.nextInt(_alphanum.length))));

  /// 正确实现:IV 用 **ASCII 字符**,与网页 CryptoJS 一致 → 100% 被服务端接受。
  ///
  /// [password] 明文密码;[pwdEncryptSalt] 登录页下发的 salt(16 字符 → AES-128)。
  static String encryptCasPassword(String password, String pwdEncryptSalt) {
    final key = enc.Key(Uint8List.fromList(utf8.encode(pwdEncryptSalt)));
    // 关键:IV = ASCII 字符的字节,而不是 0–255 的随机字节。
    final iv = enc.IV(Uint8List.fromList(randomAlphanumeric(16).codeUnits));
    final encrypter =
        enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));
    return encrypter.encrypt(randomAlphanumeric(64) + password, iv: iv).base64;
  }

  /// ❌ 错误实现(仅供回归/对照):IV 用 [enc.IV.fromSecureRandom] 的随机字节。
  ///
  /// 在 CBC 下,密文首块被 IV 异或;服务端把解密结果整段按 UTF-8 解码时,这 16 字节
  /// 约 **62% 概率不是合法 UTF-8** → 解码抛错 → 误报「用户名或密码有误」。
  /// 实测随机字节 IV 成功率 ≈ 38%,ASCII IV = 100%。**生产中绝不要用这个。**
  static String encryptCasPasswordInsecureRandomIv(
      String password, String pwdEncryptSalt) {
    final key = enc.Key(Uint8List.fromList(utf8.encode(pwdEncryptSalt)));
    final iv = enc.IV.fromSecureRandom(16); // ← bug 源头:随机字节 IV
    final encrypter =
        enc.Encrypter(enc.AES(key, mode: enc.AESMode.cbc, padding: 'PKCS7'));
    return encrypter.encrypt(randomAlphanumeric(64) + password, iv: iv).base64;
  }
}
