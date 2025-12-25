/// Kelivo 多端同步 - 同步引擎
///
/// 核心同步逻辑，协调各组件完成数据同步

import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../models/sync_config.dart';
import 'change_tracker.dart';
import 'clock_calibration_service.dart';
import 'conflict_resolver.dart';
import 'encryption_service.dart';
import 'sync_auth.dart';
import 'sync_transport.dart';

/// 同步引擎
///
/// 负责协调同步流程，管理同步状态
class SyncEngine {
  static const String _configKey = 'sync_config_v1';
  static const String _deviceIdKey = 'sync_device_id';

  /// 同步配置
  SyncConfig _config = const SyncConfig();

  /// 认证服务
  SyncAuth? _auth;

  /// 加密服务
  final EncryptionService _encryption = EncryptionService();

  /// 时钟校准服务
  final ClockCalibrationService _clockService = ClockCalibrationService();

  /// 变更追踪器
  ChangeTracker? _changeTracker;

  /// 冲突解决器
  ConflictResolver? _conflictResolver;

  /// 传输层
  SyncTransport? _transport;

  /// Supabase 客户端
  SupabaseClient? _supabaseClient;

  /// 当前同步状态
  SyncStatus _status = SyncStatus.notConfigured;

  /// 同步状态流
  final _statusController = StreamController<SyncStatus>.broadcast();

  /// 错误信息
  String? _errorMessage;

  /// 同步定时器
  Timer? _syncTimer;

  /// 网络连接监听
  StreamSubscription? _connectivitySubscription;

  /// 是否正在同步
  bool _isSyncing = false;

  /// 获取当前配置
  SyncConfig get config => _config;

  /// 获取当前状态
  SyncStatus get status => _status;

  /// 获取状态流
  Stream<SyncStatus> get statusStream => _statusController.stream;

  /// 获取错误信息
  String? get errorMessage => _errorMessage;

  /// 是否已初始化
  bool get isInitialized => _auth != null && _transport != null;

  /// 是否正在同步
  bool get isSyncing => _isSyncing;

  /// 获取待同步变更数量
  int get pendingChangesCount => _changeTracker?.pendingCount ?? 0;

  /// 初始化同步引擎
  Future<void> initialize() async {
    // 加载配置
    await _loadConfig();

    // 初始化时钟校准
    await _clockService.initialize();

    // 监听网络状态
    _connectivitySubscription = Connectivity()
        .onConnectivityChanged
        .listen(_onConnectivityChanged);

    // 如果已配置，尝试连接
    if (_config.isConfigured && _config.enabled) {
      await _setupServices();
    }
  }

  /// 配置同步服务
  Future<InitResult> configure({
    required String supabaseUrl,
    required String anonKey,
    required String syncKey,
  }) async {
    try {
      _setStatus(SyncStatus.syncing);

      // 生成或获取设备 ID
      final deviceId = await _getOrCreateDeviceId();

      // 创建认证服务
      _auth = await SyncAuth.create(syncKey: syncKey);

      // 初始化加密服务
      await _encryption.initialize(_auth!.encryptionKey);

      // 初始化 Supabase 客户端
      _supabaseClient = SupabaseClient(
        supabaseUrl,
        anonKey,
        headers: _auth!.getAuthHeaders(
          method: 'GET',
          path: '/rest/v1/',
          timestamp: _clockService.getCalibratedTimestamp(),
        ),
      );

      // 创建传输层
      _transport = SyncTransport(
        auth: _auth!,
        encryption: _encryption,
        clockService: _clockService,
        client: _supabaseClient!,
        supabaseUrl: supabaseUrl,
        anonKey: anonKey,
      );

      // 初始化同步服务
      final result = await _transport!.initialize();

      if (result.success) {
        // 保存配置
        _config = _config.copyWith(
          enabled: true,
          supabaseUrl: supabaseUrl,
          anonKey: anonKey,
          syncKey: syncKey,
          deviceId: deviceId,
        );
        await _saveConfig();

        // 初始化变更追踪器
        _changeTracker = ChangeTracker(deviceId: deviceId);
        await _changeTracker!.initialize();
        _changeTracker!.onChangesReady = _onLocalChangesReady;

        // 初始化冲突解决器
        _conflictResolver = ConflictResolver(strategy: _config.conflictStrategy);

        // 启动自动同步
        if (_config.autoSync) {
          _startAutoSync();
        }

        // 首次同步：如果是首台设备，全量上传本地数据
        if (result.isFirstDevice == true) {
          await _fullUploadLocalData();
        }

        // 首次同步
        if (_config.syncOnStartup) {
          await syncNow();
        }

        _setStatus(SyncStatus.idle);
        return result;
      } else {
        _setStatus(SyncStatus.error);
        _errorMessage = result.errorMessage;
        return result;
      }
    } catch (e) {
      debugPrint('SyncEngine.configure error: $e');
      _setStatus(SyncStatus.error);
      _errorMessage = e.toString();
      return InitResult.error('configure_error', e.toString());
    }
  }

  /// 立即同步
  Future<SyncResult> syncNow() async {
    if (_isSyncing) {
      return SyncResult.error('already_syncing', '同步正在进行中');
    }

    if (!isInitialized) {
      return SyncResult.error('not_initialized', '同步服务未初始化');
    }

    _isSyncing = true;
    _setStatus(SyncStatus.syncing);

    try {
      var uploadedCount = 0;
      var downloadedCount = 0;
      var conflictCount = 0;

      // 1. 推送本地变更
      final pushResult = await _pushLocalChanges();
      uploadedCount = pushResult.uploadedCount;

      // 2. 拉取远程变更
      final pullResult = await _pullRemoteChanges();
      downloadedCount = pullResult.downloadedCount;
      conflictCount = pullResult.conflictCount;

      // 3. 更新同步时间
      _config = _config.copyWith(lastSyncAt: DateTime.now());
      await _saveConfig();

      _setStatus(SyncStatus.synced);

      return SyncResult.success(
        uploadedCount: uploadedCount,
        downloadedCount: downloadedCount,
        conflictCount: conflictCount,
      );
    } catch (e) {
      debugPrint('SyncEngine.syncNow error: $e');
      _setStatus(SyncStatus.error);
      _errorMessage = e.toString();
      return SyncResult.error('sync_error', e.toString());
    } finally {
      _isSyncing = false;
    }
  }

  /// 推送本地变更
  Future<SyncResult> _pushLocalChanges() async {
    if (_changeTracker == null || _transport == null) {
      return SyncResult.success();
    }

    final changes = _changeTracker!.getMergedChanges();
    if (changes.isEmpty) {
      return SyncResult.success();
    }

    try {
      // 按实体类型分组
      final messageChanges = changes.where((c) => c.entityType == EntityType.message).toList();
      final conversationChanges = changes.where((c) => c.entityType == EntityType.conversation).toList();
      final assistantChanges = changes.where((c) => c.entityType == EntityType.assistant).toList();
      final configChanges = changes.where((c) =>
          c.entityType != EntityType.message &&
          c.entityType != EntityType.conversation &&
          c.entityType != EntityType.assistant).toList();

      // 上传各类数据
      if (messageChanges.isNotEmpty) {
        await _uploadMessages(messageChanges);
      }
      if (conversationChanges.isNotEmpty) {
        await _uploadConversations(conversationChanges);
      }
      if (assistantChanges.isNotEmpty) {
        await _uploadAssistants(assistantChanges);
      }
      if (configChanges.isNotEmpty) {
        await _uploadConfigs(configChanges);
      }

      // 追加 changelog
      final changelogEntries = changes.map((c) => c.toJson()..['device_id'] = _config.deviceId).toList();
      await _transport!.appendChangelog(changelogEntries);

      // 标记已同步
      await _changeTracker!.markSynced(changes.map((c) => c.id).toList());

      return SyncResult.success(uploadedCount: changes.length);
    } catch (e) {
      debugPrint('SyncEngine._pushLocalChanges error: $e');
      rethrow;
    }
  }

  /// 上传消息
  Future<void> _uploadMessages(List<PendingChange> changes) async {
    final messages = <Map<String, dynamic>>[];

    for (final change in changes) {
      if (change.changeType == ChangeType.delete) {
        // 软删除：标记 deleted = true
        // TODO: 实现软删除逻辑
        continue;
      }

      if (change.encryptedData != null) {
        messages.add({
          'id': change.entityId,
          'encrypted_data': change.encryptedData,
          'device_id': _config.deviceId,
          'updated_at': DateTime.now().toIso8601String(),
        });
      }
    }

    if (messages.isNotEmpty) {
      await _transport!.upsertMessages(messages);
    }
  }

  /// 上传对话
  Future<void> _uploadConversations(List<PendingChange> changes) async {
    final conversations = <Map<String, dynamic>>[];

    for (final change in changes) {
      if (change.encryptedData != null) {
        conversations.add({
          'id': change.entityId,
          'encrypted_data': change.encryptedData,
          'updated_at': DateTime.now().toIso8601String(),
          'deleted': change.changeType == ChangeType.delete,
        });
      }
    }

    if (conversations.isNotEmpty) {
      await _transport!.upsertConversations(conversations);
    }
  }

  /// 上传助手
  Future<void> _uploadAssistants(List<PendingChange> changes) async {
    final assistants = <Map<String, dynamic>>[];

    for (final change in changes) {
      if (change.encryptedData != null) {
        assistants.add({
          'id': change.entityId,
          'encrypted_data': change.encryptedData,
          'updated_at': DateTime.now().toIso8601String(),
          'deleted': change.changeType == ChangeType.delete,
        });
      }
    }

    if (assistants.isNotEmpty) {
      await _transport!.upsertAssistants(assistants);
    }
  }

  /// 上传配置
  Future<void> _uploadConfigs(List<PendingChange> changes) async {
    final configs = <Map<String, dynamic>>[];

    for (final change in changes) {
      if (change.encryptedData != null) {
        configs.add({
          'id': '${change.entityType.name}:${change.entityId}',
          'encrypted_data': change.encryptedData,
          'updated_at': DateTime.now().toIso8601String(),
        });
      }
    }

    if (configs.isNotEmpty) {
      await _transport!.upsertConfigs(configs);
    }
  }

  /// 拉取远程变更
  Future<SyncResult> _pullRemoteChanges() async {
    if (_transport == null) {
      return SyncResult.success();
    }

    try {
      var downloadedCount = 0;
      var conflictCount = 0;

      // 拉取 changelog
      final changelog = await _transport!.fetchChangelog(
        sinceId: _config.lastChangelogId,
      );

      if (changelog.isEmpty) {
        return SyncResult.success();
      }

      // 按实体类型分组
      final messageIds = <String>[];
      final conversationIds = <String>[];
      final assistantIds = <String>[];
      final configIds = <String>[];

      for (final entry in changelog) {
        // 跳过本设备的变更
        if (entry.deviceId == _config.deviceId) continue;

        switch (entry.entityType) {
          case EntityType.message:
            messageIds.add(entry.entityId);
            break;
          case EntityType.conversation:
            conversationIds.add(entry.entityId);
            break;
          case EntityType.assistant:
            assistantIds.add(entry.entityId);
            break;
          default:
            configIds.add('${entry.entityType.name}:${entry.entityId}');
        }
      }

      // 拉取实体数据
      if (messageIds.isNotEmpty) {
        final messages = await _transport!.fetchMessages(ids: messageIds);
        downloadedCount += messages.length;
        // TODO: 解密并合并到本地
      }

      if (conversationIds.isNotEmpty) {
        final conversations = await _transport!.fetchConversations(ids: conversationIds);
        downloadedCount += conversations.length;
        // TODO: 解密并合并到本地
      }

      if (assistantIds.isNotEmpty) {
        final assistants = await _transport!.fetchAssistants(ids: assistantIds);
        downloadedCount += assistants.length;
        // TODO: 解密并合并到本地
      }

      if (configIds.isNotEmpty) {
        final configs = await _transport!.fetchConfigs(ids: configIds);
        downloadedCount += configs.length;
        // TODO: 解密并合并到本地
      }

      // 更新 lastChangelogId
      if (changelog.isNotEmpty) {
        _config = _config.copyWith(lastChangelogId: changelog.last.id);
        await _saveConfig();
      }

      return SyncResult.success(
        downloadedCount: downloadedCount,
        conflictCount: conflictCount,
      );
    } catch (e) {
      debugPrint('SyncEngine._pullRemoteChanges error: $e');
      rethrow;
    }
  }

  /// 禁用同步
  Future<void> disable() async {
    _stopAutoSync();
    _config = _config.copyWith(enabled: false);
    await _saveConfig();
    _setStatus(SyncStatus.notConfigured);
  }

  /// 重置同步（清除所有同步数据）
  Future<void> reset() async {
    _stopAutoSync();
    await _changeTracker?.clearAll();

    _config = const SyncConfig();
    await _saveConfig();

    _auth = null;
    _encryption.dispose();
    _transport = null;
    _supabaseClient = null;
    _changeTracker = null;
    _conflictResolver = null;

    _setStatus(SyncStatus.notConfigured);
  }

  /// 释放资源
  void dispose() {
    _stopAutoSync();
    _connectivitySubscription?.cancel();
    _statusController.close();
    _encryption.dispose();
  }

  /// 设置同步状态
  void _setStatus(SyncStatus status) {
    _status = status;
    _statusController.add(status);
  }

  /// 加载配置
  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final configJson = prefs.getString(_configKey);
    if (configJson != null) {
      try {
        _config = SyncConfig.fromJsonString(configJson);
        if (_config.isConfigured) {
          _setStatus(SyncStatus.idle);
        }
      } catch (e) {
        debugPrint('SyncEngine._loadConfig error: $e');
      }
    }
  }

  /// 保存配置
  Future<void> _saveConfig() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_configKey, _config.toJsonString());
  }

  /// 获取或创建设备 ID
  Future<String> _getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var deviceId = prefs.getString(_deviceIdKey);
    if (deviceId == null) {
      deviceId = const Uuid().v4();
      await prefs.setString(_deviceIdKey, deviceId);
    }
    return deviceId;
  }

  /// 设置服务
  Future<void> _setupServices() async {
    if (!_config.isConfigured) return;

    try {
      _auth = await SyncAuth.create(syncKey: _config.syncKey!);
      await _encryption.initialize(_auth!.encryptionKey);

      _supabaseClient = SupabaseClient(
        _config.supabaseUrl!,
        _config.anonKey!,
        headers: _auth!.getAuthHeaders(
          method: 'GET',
          path: '/rest/v1/',
          timestamp: _clockService.getCalibratedTimestamp(),
        ),
      );

      _transport = SyncTransport(
        auth: _auth!,
        encryption: _encryption,
        clockService: _clockService,
        client: _supabaseClient!,
        supabaseUrl: _config.supabaseUrl!,
        anonKey: _config.anonKey!,
      );

      _changeTracker = ChangeTracker(deviceId: _config.deviceId!);
      await _changeTracker!.initialize();
      _changeTracker!.onChangesReady = _onLocalChangesReady;

      _conflictResolver = ConflictResolver(strategy: _config.conflictStrategy);

      if (_config.autoSync) {
        _startAutoSync();
      }
    } catch (e) {
      debugPrint('SyncEngine._setupServices error: $e');
    }
  }

  /// 启动自动同步
  void _startAutoSync() {
    _stopAutoSync();
    _syncTimer = Timer.periodic(
      Duration(seconds: _config.syncIntervalSeconds),
      (_) => syncNow(),
    );
  }

  /// 停止自动同步
  void _stopAutoSync() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  /// 本地变更就绪回调
  void _onLocalChangesReady(List<PendingChange> changes) {
    if (_config.autoSync && !_isSyncing) {
      syncNow();
    }
  }

  /// 网络状态变化回调
  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final hasConnection = results.any((r) => r != ConnectivityResult.none);

    if (hasConnection) {
      if (_status == SyncStatus.offline) {
        _setStatus(SyncStatus.idle);
        // 网络恢复，尝试同步
        if (_config.autoSync) {
          syncNow();
        }
      }
    } else {
      _setStatus(SyncStatus.offline);
    }
  }

  /// 追踪实体创建
  Future<void> trackCreate({
    required EntityType entityType,
    required String entityId,
    required Map<String, dynamic> data,
  }) async {
    if (_changeTracker == null || !_config.enabled) return;

    final encryptedData = await _encryption.encryptJson(data);
    await _changeTracker!.trackCreate(
      entityType: entityType,
      entityId: entityId,
      encryptedData: encryptedData,
    );
  }

  /// 追踪实体更新
  Future<void> trackUpdate({
    required EntityType entityType,
    required String entityId,
    required List<String> affectedFields,
    required Map<String, dynamic> data,
  }) async {
    if (_changeTracker == null || !_config.enabled) return;

    final encryptedData = await _encryption.encryptJson(data);
    await _changeTracker!.trackFieldUpdate(
      entityType: entityType,
      entityId: entityId,
      affectedFields: affectedFields,
      encryptedData: encryptedData,
    );
  }

  /// 追踪实体删除
  Future<void> trackDelete({
    required EntityType entityType,
    required String entityId,
  }) async {
    if (_changeTracker == null || !_config.enabled) return;

    await _changeTracker!.trackDelete(
      entityType: entityType,
      entityId: entityId,
    );
  }

  /// 本地数据提供者回调
  /// 
  /// 用于获取本地所有数据进行全量上传
  Future<List<Map<String, dynamic>>> Function()? onGetAllConversations;
  Future<List<Map<String, dynamic>>> Function(String conversationId)? onGetMessagesForConversation;
  Future<List<Map<String, dynamic>>> Function()? onGetAllAssistants;

  /// 全量上传本地数据
  /// 
  /// 首次同步时调用，将本地所有数据上传到服务端
  Future<void> _fullUploadLocalData() async {
    if (_transport == null || _encryption == null) return;

    debugPrint('SyncEngine: Starting full upload of local data...');

    try {
      // 1. 上传所有对话
      if (onGetAllConversations != null) {
        final conversations = await onGetAllConversations!();
        debugPrint('SyncEngine: Uploading ${conversations.length} conversations');
        
        if (conversations.isNotEmpty) {
          final encryptedConversations = <Map<String, dynamic>>[];
          final changelogEntries = <Map<String, dynamic>>[];
          
          for (final conv in conversations) {
            final encryptedData = await _encryption.encryptJson(conv);
            encryptedConversations.add({
              'id': conv['id'],
              'encrypted_data': encryptedData,
              'updated_at': DateTime.now().toIso8601String(),
              'deleted': false,
            });
            
            changelogEntries.add({
              'entity_type': EntityType.conversation.name,
              'entity_id': conv['id'],
              'change_type': ChangeType.create.name,
              'device_id': _config.deviceId,
              'timestamp': DateTime.now().toIso8601String(),
            });
          }
          
          await _transport!.upsertConversations(encryptedConversations);
          await _transport!.appendChangelog(changelogEntries);
        }
      }

      // 2. 上传所有消息
      if (onGetAllConversations != null && onGetMessagesForConversation != null) {
        final conversations = await onGetAllConversations!();
        var totalMessages = 0;
        
        for (final conv in conversations) {
          final messages = await onGetMessagesForConversation!(conv['id'] as String);
          if (messages.isEmpty) continue;
          
          debugPrint('SyncEngine: Uploading ${messages.length} messages for conversation ${conv['id']}');
          
          final encryptedMessages = <Map<String, dynamic>>[];
          final changelogEntries = <Map<String, dynamic>>[];
          
          for (final msg in messages) {
            final encryptedData = await _encryption.encryptJson(msg);
            encryptedMessages.add({
              'id': msg['id'],
              'conversation_id': conv['id'],
              'encrypted_data': encryptedData,
              'device_id': _config.deviceId,
              'updated_at': DateTime.now().toIso8601String(),
            });
            
            changelogEntries.add({
              'entity_type': EntityType.message.name,
              'entity_id': msg['id'],
              'change_type': ChangeType.create.name,
              'device_id': _config.deviceId,
              'timestamp': DateTime.now().toIso8601String(),
            });
          }
          
          await _transport!.upsertMessages(encryptedMessages);
          await _transport!.appendChangelog(changelogEntries);
          totalMessages += messages.length;
        }
        
        debugPrint('SyncEngine: Uploaded $totalMessages messages total');
      }

      // 3. 上传所有助手
      if (onGetAllAssistants != null) {
        final assistants = await onGetAllAssistants!();
        debugPrint('SyncEngine: Uploading ${assistants.length} assistants');
        
        if (assistants.isNotEmpty) {
          final encryptedAssistants = <Map<String, dynamic>>[];
          final changelogEntries = <Map<String, dynamic>>[];
          
          for (final assistant in assistants) {
            final encryptedData = await _encryption.encryptJson(assistant);
            encryptedAssistants.add({
              'id': assistant['id'],
              'encrypted_data': encryptedData,
              'updated_at': DateTime.now().toIso8601String(),
              'deleted': false,
            });
            
            changelogEntries.add({
              'entity_type': EntityType.assistant.name,
              'entity_id': assistant['id'],
              'change_type': ChangeType.create.name,
              'device_id': _config.deviceId,
              'timestamp': DateTime.now().toIso8601String(),
            });
          }
          
          await _transport!.upsertAssistants(encryptedAssistants);
          await _transport!.appendChangelog(changelogEntries);
        }
      }

      debugPrint('SyncEngine: Full upload completed');
    } catch (e) {
      debugPrint('SyncEngine: Full upload error: $e');
      rethrow;
    }
  }

  /// 手动触发全量上传
  /// 
  /// 用于用户手动触发全量同步
  Future<SyncResult> fullSync() async {
    if (!isInitialized) {
      return SyncResult.error('not_initialized', '同步服务未初始化');
    }

    if (_isSyncing) {
      return SyncResult.error('already_syncing', '同步正在进行中');
    }

    _isSyncing = true;
    _setStatus(SyncStatus.syncing);

    try {
      await _fullUploadLocalData();
      _setStatus(SyncStatus.synced);
      return SyncResult.success(uploadedCount: -1); // -1 表示全量同步
    } catch (e) {
      _setStatus(SyncStatus.error);
      _errorMessage = e.toString();
      return SyncResult.error('full_sync_error', e.toString());
    } finally {
      _isSyncing = false;
    }
  }
}
