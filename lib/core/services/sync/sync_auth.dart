/// Kelivo 多端同步 - 认证服务
///
/// 提供密钥派生、请求签名等功能

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart' as cryptography;

/// 同步认证服务
///
/// 负责密钥派生和请求签名
class SyncAuth {
  /// 同步密钥
  final String syncKey;

  /// 派生的鉴权密钥（用于日常请求签名）
  late final List<int> _authKey;

  /// 派生的加密密钥（用于端到端加密）
  late final List<int> _encryptionKey;

  /// 派生的管理密钥（仅用于初始化签名）
  late final List<int> _adminKey;

  /// 是否已初始化
  bool _initialized = false;

  /// 固定的 salt
  static const String _salt = 'kelivo_sync_salt';

  SyncAuth._({required this.syncKey});

  /// 创建并初始化 SyncAuth 实例
  static Future<SyncAuth> create({required String syncKey}) async {
    final auth = SyncAuth._(syncKey: syncKey);
    await auth._deriveKeys();
    return auth;
  }

  /// 派生密钥
  Future<void> _deriveKeys() async {
    final hkdf = cryptography.Hkdf(
      hmac: cryptography.Hmac.sha256(),
      outputLength: 32,
    );
    final saltBytes = utf8.encode(_salt);

    // 派生鉴权密钥（用于日常请求签名 / RLS 验签）
    final authKeyResult = await hkdf.deriveKey(
      secretKey: cryptography.SecretKey(utf8.encode(syncKey)),
      nonce: saltBytes,
      info: utf8.encode('auth'),
    );
    _authKey = await authKeyResult.extractBytes();

    // 派生加密密钥（用于端到端加密）
    final encryptionKeyResult = await hkdf.deriveKey(
      secretKey: cryptography.SecretKey(utf8.encode(syncKey)),
      nonce: saltBytes,
      info: utf8.encode('encryption'),
    );
    _encryptionKey = await encryptionKeyResult.extractBytes();

    // 派生管理密钥（仅用于初始化签名）
    // admin_key = HMAC-SHA256(auth_key, "kelivo_admin_init")
    final hmacSha256 = Hmac(sha256, _authKey);
    final adminDigest = hmacSha256.convert(utf8.encode('kelivo_admin_init'));
    _adminKey = adminDigest.bytes;

    _initialized = true;
  }

  /// 获取加密密钥
  List<int> get encryptionKey {
    _ensureInitialized();
    return List.unmodifiable(_encryptionKey);
  }

  /// 获取 auth_key 的 Base64 编码（用于初始化 RPC）
  String get authKeyBase64 {
    _ensureInitialized();
    return base64Encode(_authKey);
  }

  /// 计算 SHA256 哈希（十六进制）
  String sha256Hex(List<int> bytes) {
    return sha256.convert(bytes).toString();
  }

  /// 生成请求签名
  ///
  /// 签名格式: HMAC-SHA256(auth_key, "{timestamp}\n{method}\n{path}\n{nonce}\n{body_sha256}")
  String generateSignature({
    required int timestamp,
    required String method,
    required String path,
    String nonce = '',
    String bodySha256 = '',
  }) {
    _ensureInitialized();

    final message = '$timestamp\n$method\n$path\n$nonce\n$bodySha256';
    final hmacSha256 = Hmac(sha256, _authKey);
    final digest = hmacSha256.convert(utf8.encode(message));
    return base64Encode(digest.bytes);
  }

  /// 生成初始化签名
  ///
  /// 签名格式: HMAC-SHA256(admin_key, "{timestamp}\nINITIALIZE\n{auth_key_base64}\n{verification_data}")
  String generateAdminSignature({
    required int timestamp,
    required String verificationData,
  }) {
    _ensureInitialized();

    final message =
        '$timestamp\nINITIALIZE\n$authKeyBase64\n$verificationData';
    final hmacSha256 = Hmac(sha256, _adminKey);
    final digest = hmacSha256.convert(utf8.encode(message));
    return base64Encode(digest.bytes);
  }

  /// 生成重置签名
  ///
  /// 签名格式: HMAC-SHA256(auth_key, "{timestamp}\nRESET\n{new_auth_key_base64}\n{new_verification_data}\n{nonce}")
  String generateResetSignature({
    required int timestamp,
    required String newAuthKeyBase64,
    required String newVerificationData,
    required String nonce,
  }) {
    _ensureInitialized();

    final message =
        '$timestamp\nRESET\n$newAuthKeyBase64\n$newVerificationData\n$nonce';
    final hmacSha256 = Hmac(sha256, _authKey);
    final digest = hmacSha256.convert(utf8.encode(message));
    return base64Encode(digest.bytes);
  }

  /// 获取请求头
  ///
  /// [method] HTTP 方法（GET/POST/PATCH/PUT/DELETE）
  /// [path] 请求路径（如 /rest/v1/sync_messages）
  /// [bodyBytes] 请求体字节（写请求必须传）
  /// [nonce] 一次性随机串（写请求必须传，如不传则自动生成）
  /// [timestamp] 时间戳（毫秒），如不传则使用当前时间
  Map<String, String> getAuthHeaders({
    required String method,
    required String path,
    List<int>? bodyBytes,
    String? nonce,
    int? timestamp,
  }) {
    _ensureInitialized();

    final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch;
    final isWrite = const {'POST', 'PATCH', 'PUT', 'DELETE'}.contains(method);

    final resolvedNonce = isWrite ? (nonce ?? _generateNonce()) : '';
    final bodySha256 = isWrite ? sha256Hex(bodyBytes ?? const <int>[]) : '';

    final headers = <String, String>{
      'x-timestamp': ts.toString(),
      'x-signature': generateSignature(
        timestamp: ts,
        method: method,
        path: path,
        nonce: resolvedNonce,
        bodySha256: bodySha256,
      ),
    };

    if (isWrite) {
      headers['x-nonce'] = resolvedNonce;
      headers['x-body-sha256'] = bodySha256;
    }

    return headers;
  }

  /// 生成随机 nonce（至少 16 字节）
  String _generateNonce() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('SyncAuth not initialized');
    }
  }
}
