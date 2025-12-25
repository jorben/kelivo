/// Kelivo 多端同步 - 传输层
///
/// 封装与 Supabase 的通信，处理签名、时钟校准等

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../models/sync_config.dart';
import 'clock_calibration_service.dart';
import 'encryption_service.dart';
import 'sync_auth.dart';

/// 同步传输层
///
/// 负责与 Supabase 的所有通信
class SyncTransport {
  final SyncAuth _auth;
  final EncryptionService _encryption;
  final ClockCalibrationService _clockService;
  final SupabaseClient _client;
  final String _supabaseUrl;
  final String _anonKey;

  SyncTransport({
    required SyncAuth auth,
    required EncryptionService encryption,
    required ClockCalibrationService clockService,
    required SupabaseClient client,
    required String supabaseUrl,
    required String anonKey,
  })  : _auth = auth,
        _encryption = encryption,
        _clockService = clockService,
        _client = client,
        _supabaseUrl = supabaseUrl,
        _anonKey = anonKey;

  /// 初始化同步服务
  ///
  /// 首台设备会自动初始化，其他设备验证密钥正确性
  Future<InitResult> initialize() async {
    try {
      // 1. 生成验证数据
      final verificationData =
          await _encryption.encrypt('KELIVO_SYNC_VERIFY');

      // 2. 调用初始化 RPC
      final timestamp = _clockService.getCalibratedTimestamp();
      final adminSignature = _auth.generateAdminSignature(
        timestamp: timestamp,
        verificationData: verificationData,
      );

      final response = await _client.rpc(
        'initialize_sync_service',
        params: {
          'p_auth_key_base64': _auth.authKeyBase64,
          'p_verification_data': verificationData,
          'p_admin_signature': adminSignature,
          'p_timestamp': timestamp,
        },
      );

      if (response['success'] == true) {
        // 首台设备，初始化成功
        return InitResult.success(isFirstDevice: true);
      } else if (response['error'] == 'already_initialized') {
        // 非首台设备，验证密钥正确性
        return await _verifyExistingSetup();
      } else {
        return InitResult.error(
          response['error'] as String? ?? 'unknown_error',
          response['message'] as String? ?? '初始化失败',
        );
      }
    } catch (e) {
      debugPrint('SyncTransport.initialize error: $e');
      return InitResult.error('network_error', e.toString());
    }
  }

  /// 验证已初始化服务的密钥正确性
  Future<InitResult> _verifyExistingSetup() async {
    try {
      // 使用 RPC 验证密钥（RPC 不受 RLS 限制）
      final timestamp = _clockService.getCalibratedTimestamp();
      final adminSignature = _auth.generateAdminSignature(
        timestamp: timestamp,
        verificationData: '', // 验证时不需要
      );

      final response = await _client.rpc(
        'verify_sync_key',
        params: {
          'p_auth_key_base64': _auth.authKeyBase64,
          'p_timestamp': timestamp,
          'p_signature': adminSignature,
        },
      );

      if (response['success'] == true) {
        // 密钥验证成功，尝试解密 verification_data
        final verificationData = response['verification_data'] as String?;
        if (verificationData != null) {
          try {
            final decrypted = await _encryption.decrypt(verificationData);
            if (decrypted == 'KELIVO_SYNC_VERIFY') {
              return InitResult.success(isFirstDevice: false);
            }
          } catch (e) {
            debugPrint('SyncTransport._verifyExistingSetup decrypt error: $e');
          }
        }
        return InitResult.error('invalid_key', '同步密钥不正确');
      } else {
        return InitResult.error(
          response['error'] as String? ?? 'verification_failed',
          response['message'] as String? ?? '验证失败',
        );
      }
    } catch (e) {
      debugPrint('SyncTransport._verifyExistingSetup error: $e');
      return InitResult.error('verification_failed', e.toString());
    }
  }

  /// 拉取变更日志
  ///
  /// [sinceId] 从此 ID 之后开始拉取
  /// [limit] 每次拉取的最大数量
  Future<List<ChangelogEntry>> fetchChangelog({
    required int sinceId,
    int limit = 500,
  }) async {
    try {
      final response = await _client
          .from('sync_changelog')
          .select()
          .gt('id', sinceId)
          .order('id', ascending: true)
          .limit(limit);

      return (response as List)
          .map((e) => ChangelogEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('SyncTransport.fetchChangelog error: $e');
      rethrow;
    }
  }

  /// 拉取消息
  Future<List<Map<String, dynamic>>> fetchMessages({
    required List<String> ids,
  }) async {
    if (ids.isEmpty) return [];

    try {
      final response = await _client
          .from('sync_messages')
          .select()
          .inFilter('id', ids);

      return (response as List).cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('SyncTransport.fetchMessages error: $e');
      rethrow;
    }
  }

  /// 拉取对话
  Future<List<Map<String, dynamic>>> fetchConversations({
    required List<String> ids,
  }) async {
    if (ids.isEmpty) return [];

    try {
      final response = await _client
          .from('sync_conversations')
          .select()
          .inFilter('id', ids);

      return (response as List).cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('SyncTransport.fetchConversations error: $e');
      rethrow;
    }
  }

  /// 拉取助手
  Future<List<Map<String, dynamic>>> fetchAssistants({
    required List<String> ids,
  }) async {
    if (ids.isEmpty) return [];

    try {
      final response = await _client
          .from('sync_assistants')
          .select()
          .inFilter('id', ids);

      return (response as List).cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('SyncTransport.fetchAssistants error: $e');
      rethrow;
    }
  }

  /// 拉取配置
  Future<List<Map<String, dynamic>>> fetchConfigs({
    required List<String> ids,
  }) async {
    if (ids.isEmpty) return [];

    try {
      final response = await _client
          .from('sync_configs')
          .select()
          .inFilter('id', ids);

      return (response as List).cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('SyncTransport.fetchConfigs error: $e');
      rethrow;
    }
  }

  /// 上传消息
  Future<void> upsertMessages(List<Map<String, dynamic>> messages) async {
    if (messages.isEmpty) return;
    await _signedUpsert('sync_messages', messages);
  }

  /// 上传对话
  Future<void> upsertConversations(List<Map<String, dynamic>> conversations) async {
    if (conversations.isEmpty) return;
    await _signedUpsert('sync_conversations', conversations);
  }

  /// 上传助手
  Future<void> upsertAssistants(List<Map<String, dynamic>> assistants) async {
    if (assistants.isEmpty) return;
    await _signedUpsert('sync_assistants', assistants);
  }

  /// 上传配置
  Future<void> upsertConfigs(List<Map<String, dynamic>> configs) async {
    if (configs.isEmpty) return;
    await _signedUpsert('sync_configs', configs);
  }

  /// 追加变更日志
  Future<void> appendChangelog(List<Map<String, dynamic>> entries) async {
    if (entries.isEmpty) return;
    await _signedInsert('sync_changelog', entries);
  }

  /// 带签名的 upsert 请求
  Future<void> _signedUpsert(String table, List<Map<String, dynamic>> data) async {
    final path = '/rest/v1/$table';
    final url = Uri.parse('$_supabaseUrl$path');
    final bodyBytes = utf8.encode(jsonEncode(data));
    final timestamp = _clockService.getCalibratedTimestamp();

    final headers = _auth.getAuthHeaders(
      method: 'POST',
      path: path,
      bodyBytes: bodyBytes,
      timestamp: timestamp,
    );

    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'apikey': _anonKey,
        'Authorization': 'Bearer $_anonKey',
        'Prefer': 'resolution=merge-duplicates',
        ...headers,
      },
      body: bodyBytes,
    );

    if (response.statusCode >= 400) {
      debugPrint('_signedUpsert $table error: ${response.statusCode} ${response.body}');
      throw PostgrestException(
        message: response.body,
        code: response.statusCode.toString(),
      );
    }
  }

  /// 带签名的 insert 请求
  Future<void> _signedInsert(String table, List<Map<String, dynamic>> data) async {
    final path = '/rest/v1/$table';
    final url = Uri.parse('$_supabaseUrl$path');
    final bodyBytes = utf8.encode(jsonEncode(data));
    final timestamp = _clockService.getCalibratedTimestamp();

    final headers = _auth.getAuthHeaders(
      method: 'POST',
      path: path,
      bodyBytes: bodyBytes,
      timestamp: timestamp,
    );

    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'apikey': _anonKey,
        'Authorization': 'Bearer $_anonKey',
        ...headers,
      },
      body: bodyBytes,
    );

    if (response.statusCode >= 400) {
      debugPrint('_signedInsert $table error: ${response.statusCode} ${response.body}');
      throw PostgrestException(
        message: response.body,
        code: response.statusCode.toString(),
      );
    }
  }

  /// 重置同步服务（更换密钥）
  Future<InitResult> resetSyncService({
    required SyncAuth newAuth,
    required EncryptionService newEncryption,
  }) async {
    try {
      // 生成新的验证数据
      final newVerificationData =
          await newEncryption.encrypt('KELIVO_SYNC_VERIFY');

      final timestamp = _clockService.getCalibratedTimestamp();
      final nonce = _generateNonce();

      final signature = _auth.generateResetSignature(
        timestamp: timestamp,
        newAuthKeyBase64: newAuth.authKeyBase64,
        newVerificationData: newVerificationData,
        nonce: nonce,
      );

      final response = await _client.rpc(
        'reset_sync_service',
        params: {
          'p_new_auth_key_base64': newAuth.authKeyBase64,
          'p_new_verification_data': newVerificationData,
          'p_signature': signature,
          'p_timestamp': timestamp,
          'p_nonce': nonce,
        },
      );

      if (response['success'] == true) {
        return InitResult.success(isFirstDevice: false);
      } else {
        return InitResult.error(
          response['error'] as String? ?? 'unknown_error',
          response['message'] as String? ?? '重置失败',
        );
      }
    } catch (e) {
      debugPrint('SyncTransport.resetSyncService error: $e');
      return InitResult.error('network_error', e.toString());
    }
  }

  String _generateNonce() {
    final random = Random.secure();
    final bytes = List<int>.generate(24, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }
}
