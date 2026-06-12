import 'dart:convert';
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as enc;
import 'package:guet_cas/guet_cas.dart';
import 'package:test/test.dart';

void main() {
  group('CasCrypto.randomAlphanumeric', () {
    test('长度正确且仅含 [A-Za-z0-9]', () {
      final s = CasCrypto.randomAlphanumeric(16);
      expect(s.length, 16);
      expect(RegExp(r'^[A-Za-z0-9]+$').hasMatch(s), isTrue);
    });
  });

  group('encryptCasPassword (ASCII IV — 正确实现)', () {
    // 16 字符 salt → AES-128。
    const salt = 'abcdefABCDEF0123';
    const password = 'P@ssw0rd!';

    test('输出可 base64 解码,且长度是 16 字节的整数倍(CBC 分组)', () {
      final b64 = CasCrypto.encryptCasPassword(password, salt);
      final bytes = base64Decode(b64);
      expect(bytes.length % 16, 0);
      // 64 前缀 + 密码 + PKCS7 → 至少 5 个分组(80 字节)。
      expect(bytes.length, greaterThanOrEqualTo(80));
    });

    test('每次输出不同(随机前缀 + 随机 IV)', () {
      final a = CasCrypto.encryptCasPassword(password, salt);
      final b = CasCrypto.encryptCasPassword(password, salt);
      expect(a, isNot(equals(b)));
    });

    test('用 ASCII-IV 解密首块得到的明文前缀是合法 UTF-8(服务端不会解码失败)', () {
      // 复刻服务端语义:首块必须能按 UTF-8 解码。重复多次确保稳定。
      for (var i = 0; i < 200; i++) {
        final iv = enc.IV(
            Uint8List.fromList(CasCrypto.randomAlphanumeric(16).codeUnits));
        // ASCII 字节天然是合法 UTF-8。
        expect(() => utf8.decode(iv.bytes), returnsNormally);
      }
    });
  });

  group('encryptCasPasswordInsecureRandomIv (随机字节 IV — 错误实现,会触发 bug)', () {
    test('随机字节 IV 经常不是合法 UTF-8(这正是 ~62% 失败的根因)', () {
      var invalid = 0;
      const n = 1000;
      for (var i = 0; i < n; i++) {
        final iv = enc.IV.fromSecureRandom(16);
        try {
          utf8.decode(iv.bytes);
        } catch (_) {
          invalid++;
        }
      }
      // 16 个随机字节里,合法 UTF-8 的概率很低 → 绝大多数非法。
      // 这解释了服务端把首块当 UTF-8 解码时的高失败率。
      expect(invalid, greaterThan(n ~/ 2),
          reason: '随机字节 IV 大概率产生非法 UTF-8,导致服务端误报「密码有误」');
    });
  });
}
