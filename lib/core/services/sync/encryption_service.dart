/// Kelivo 多端同步 - 加密服务
///
/// 提供 AES-256-GCM 端到端加密，确保云端数据安全

import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

/// 加密数据格式
class EncryptedData {
  /// 加密版本
  final int version;

  /// 加密算法
  final String algorithm;

  /// 初始化向量 (Base64)
  final String iv;

  /// 加密数据 (Base64)
  final String data;

  /// 认证标签 (Base64)
  final String tag;

  /// 附加认证数据 (Base64, 可选)
  final String? aad;

  const EncryptedData({
    this.version = 1,
    this.algorithm = 'AES-256-GCM',
    required this.iv,
    required this.data,
    required this.tag,
    this.aad,
  });

  Map<String, dynamic> toJson() {
    return {
      'v': version,
      'alg': algorithm,
      'iv': iv,
      'data': data,
      'tag': tag,
      if (aad != null) 'aad': aad,
    };
  }

  factory EncryptedData.fromJson(Map<String, dynamic> json) {
    return EncryptedData(
      version: json['v'] as int? ?? 1,
      algorithm: json['alg'] as String? ?? 'AES-256-GCM',
      iv: json['iv'] as String,
      data: json['data'] as String,
      tag: json['tag'] as String,
      aad: json['aad'] as String?,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory EncryptedData.fromJsonString(String jsonString) {
    return EncryptedData.fromJson(
        jsonDecode(jsonString) as Map<String, dynamic>);
  }
}

/// 加密服务
///
/// 使用 AES-256-GCM 进行端到端加密
class EncryptionService {
  /// AES-GCM 算法实例
  final AesGcm _aesGcm = AesGcm.with256bits();

  /// 加密密钥
  SecretKey? _secretKey;

  /// 是否已初始化
  bool get isInitialized => _secretKey != null;

  /// 使用派生的加密密钥初始化
  Future<void> initialize(List<int> encryptionKey) async {
    if (encryptionKey.length != 32) {
      throw ArgumentError('Encryption key must be 32 bytes (256 bits)');
    }
    _secretKey = SecretKey(encryptionKey);
  }

  /// 清除密钥
  void dispose() {
    _secretKey = null;
  }

  /// 加密数据
  ///
  /// [plainText] 明文数据
  /// [aad] 附加认证数据（可选，用于绑定上下文信息）
  Future<String> encrypt(String plainText, {String? aad}) async {
    _ensureInitialized();

    // 生成随机 IV (12 bytes for GCM)
    final iv = _generateRandomBytes(12);

    // 准备 AAD
    final aadBytes = aad != null ? utf8.encode(aad) : <int>[];

    // 加密
    final secretBox = await _aesGcm.encrypt(
      utf8.encode(plainText),
      secretKey: _secretKey!,
      nonce: iv,
      aad: aadBytes,
    );

    // 构建加密数据结构
    final encryptedData = EncryptedData(
      iv: base64Encode(iv),
      data: base64Encode(secretBox.cipherText),
      tag: base64Encode(secretBox.mac.bytes),
      aad: aad != null ? base64Encode(aadBytes) : null,
    );

    return encryptedData.toJsonString();
  }

  /// 解密数据
  ///
  /// [encryptedString] 加密的 JSON 字符串
  Future<String> decrypt(String encryptedString) async {
    _ensureInitialized();

    final encryptedData = EncryptedData.fromJsonString(encryptedString);

    // 解析加密数据
    final iv = base64Decode(encryptedData.iv);
    final cipherText = base64Decode(encryptedData.data);
    final tag = base64Decode(encryptedData.tag);
    final aadBytes =
        encryptedData.aad != null ? base64Decode(encryptedData.aad!) : <int>[];

    // 构建 SecretBox
    final secretBox = SecretBox(
      cipherText,
      nonce: iv,
      mac: Mac(tag),
    );

    // 解密
    final plainBytes = await _aesGcm.decrypt(
      secretBox,
      secretKey: _secretKey!,
      aad: aadBytes,
    );

    return utf8.decode(plainBytes);
  }

  /// 加密 JSON 对象
  Future<String> encryptJson(Map<String, dynamic> json, {String? aad}) async {
    return encrypt(jsonEncode(json), aad: aad);
  }

  /// 解密为 JSON 对象
  Future<Map<String, dynamic>> decryptJson(String encryptedString) async {
    final plainText = await decrypt(encryptedString);
    return jsonDecode(plainText) as Map<String, dynamic>;
  }

  /// 验证加密数据是否有效（不解密，仅检查格式）
  bool isValidEncryptedData(String encryptedString) {
    try {
      final data = EncryptedData.fromJsonString(encryptedString);
      return data.iv.isNotEmpty && data.data.isNotEmpty && data.tag.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  void _ensureInitialized() {
    if (!isInitialized) {
      throw StateError('EncryptionService not initialized. Call initialize() first.');
    }
  }

  /// 生成随机字节
  List<int> _generateRandomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  /// 生成随机密钥（32 字节）
  static List<int> generateRandomKey() {
    final random = Random.secure();
    return List<int>.generate(32, (_) => random.nextInt(256));
  }

  /// 生成随机同步密钥字符串（Base64 URL 安全格式）
  static String generateSyncKey() {
    final bytes = generateRandomKey();
    return base64UrlEncode(bytes);
  }
}
