// 桂电 / 金智 CAS 登录示例 CLI。
//
//   dart run bin/login.dart <学号> <密码>
//
// 账号开启验证码时需要一个识别服务。本示例从环境变量读取其配置:
//
//   CAPTCHA_API=<识别服务URL> CAPTCHA_TOKEN=<token> [CAPTCHA_TYPE=...] \
//   dart run bin/login.dart <学号> <密码>
//
// 未配置 CAPTCHA_TOKEN 时,若服务端要求验证码会直接报错。
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:guet_cas/guet_cas.dart';

/// 通过环境变量配置的通用验证码识别器示例(POST JSON 接口)。
/// 返回 null 表示未配置,login 时若需验证码会抛错。
CaptchaSolver? buildEnvCaptchaSolver() {
  final api = Platform.environment['CAPTCHA_API'];
  final token = Platform.environment['CAPTCHA_TOKEN'];
  final type = Platform.environment['CAPTCHA_TYPE'] ?? '';
  if (api == null || token == null || api.isEmpty || token.isEmpty) return null;

  final dio = Dio()
    ..httpClientAdapter =
        IOHttpClientAdapter(createHttpClient: buildInsecureHttpClient);

  return (List<int> img) async {
    final r = await dio.post(api,
        data: {'token': token, 'type': type, 'image': base64Encode(img)},
        options: Options(
            contentType: 'application/json', responseType: ResponseType.json));
    final data = r.data is String ? jsonDecode(r.data) : r.data;
    return (data['data']?['data'] ?? '').toString();
  };
}

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('用法: dart run bin/login.dart <学号> <密码>');
    stderr.writeln('需要验证码时,用 CAPTCHA_API / CAPTCHA_TOKEN 环境变量配置识别服务。');
    exit(64);
  }
  final username = args[0];
  final password = args[1];

  final client = CasClient(captchaSolver: buildEnvCaptchaSolver());
  try {
    final r = await client.login(username, password);
    stdout.writeln('route=${r.route}  needCaptcha=${r.needCaptcha}');
    stdout.writeln('status=${r.status}');
    if (r.passwordAccepted) {
      stdout.writeln(r.needsMultiFactor ? '密码通过 → 需要多因子认证' : '密码通过 → ${r.location}');
    } else {
      stdout.writeln('登录失败: ${r.errorTip ?? '(无错误文案,status=${r.status})'}');
    }
  } on CasProtocolException catch (e) {
    stderr.writeln(e.message);
    exitCode = 1;
  } finally {
    client.close();
  }
}
