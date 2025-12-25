/// Kelivo 多端同步 - Provider
///
/// 提供同步状态管理和 UI 交互

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/sync_config.dart';
import '../services/sync/encryption_service.dart';
import '../services/sync/sync_engine.dart';

/// 同步 Provider
///
/// 管理同步状态，提供 UI 交互接口
class SyncProvider extends ChangeNotifier {
  /// 同步引擎
  final SyncEngine _engine = SyncEngine();

  /// 状态订阅
  StreamSubscription? _statusSubscription;

  /// 是否正在操作中
  bool _busy = false;

  /// 操作消息
  String? _message;

  /// 获取当前配置
  SyncConfig get config => _engine.config;

  /// 获取当前状态
  SyncStatus get status => _engine.status;

  /// 是否正在操作中
  bool get busy => _busy;

  /// 操作消息
  String? get message => _message;

  /// 是否已配置
  bool get isConfigured => config.isConfigured;

  /// 是否已启用
  bool get isEnabled => config.enabled;

  /// 是否已初始化
  bool get isInitialized => _engine.isInitialized;

  /// 待同步变更数量
  int get pendingChangesCount => _engine.pendingChangesCount;

  /// 设置数据提供者回调
  void setDataProviders({
    Future<List<Map<String, dynamic>>> Function()? onGetAllConversations,
    Future<List<Map<String, dynamic>>> Function(String conversationId)? onGetMessagesForConversation,
    Future<List<Map<String, dynamic>>> Function()? onGetAllAssistants,
  }) {
    _engine.onGetAllConversations = onGetAllConversations;
    _engine.onGetMessagesForConversation = onGetMessagesForConversation;
    _engine.onGetAllAssistants = onGetAllAssistants;
  }

  /// 初始化
  Future<void> initialize() async {
    await _engine.initialize();

    // 监听状态变化
    _statusSubscription = _engine.statusStream.listen((_) {
      notifyListeners();
    });

    notifyListeners();
  }

  /// 配置同步服务
  Future<InitResult> configure({
    required String supabaseUrl,
    required String anonKey,
    required String syncKey,
  }) async {
    if (_busy) {
      return InitResult.error('busy', '操作进行中');
    }

    _busy = true;
    _message = '正在连接同步服务...';
    notifyListeners();

    try {
      final result = await _engine.configure(
        supabaseUrl: supabaseUrl,
        anonKey: anonKey,
        syncKey: syncKey,
      );

      if (result.success) {
        _message = result.isFirstDevice == true
            ? '同步服务初始化成功，正在上传本地数据...'
            : '已连接到同步服务';
      } else {
        _message = result.errorMessage ?? '配置失败';
      }

      return result;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 立即同步
  Future<SyncResult> syncNow() async {
    if (_busy) {
      return SyncResult.error('busy', '操作进行中');
    }

    _busy = true;
    _message = '正在同步...';
    notifyListeners();

    try {
      final result = await _engine.syncNow();

      if (result.success) {
        _message = '同步完成';
        if (result.uploadedCount > 0 || result.downloadedCount > 0) {
          _message = '同步完成：上传 ${result.uploadedCount}，下载 ${result.downloadedCount}';
        }
      } else {
        _message = result.errorMessage ?? '同步失败';
      }

      return result;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 全量同步（上传所有本地数据）
  Future<SyncResult> fullSync() async {
    if (_busy) {
      return SyncResult.error('busy', '操作进行中');
    }

    _busy = true;
    _message = '正在全量同步...';
    notifyListeners();

    try {
      final result = await _engine.fullSync();

      if (result.success) {
        _message = '全量同步完成';
      } else {
        _message = result.errorMessage ?? '全量同步失败';
      }

      return result;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 禁用同步
  Future<void> disable() async {
    if (_busy) return;

    _busy = true;
    _message = '正在禁用同步...';
    notifyListeners();

    try {
      await _engine.disable();
      _message = '同步已禁用';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 重置同步
  Future<void> reset() async {
    if (_busy) return;

    _busy = true;
    _message = '正在重置同步...';
    notifyListeners();

    try {
      await _engine.reset();
      _message = '同步已重置';
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// 生成随机同步密钥
  String generateSyncKey() {
    return EncryptionService.generateSyncKey();
  }

  /// 追踪实体创建
  Future<void> trackCreate({
    required EntityType entityType,
    required String entityId,
    required Map<String, dynamic> data,
  }) async {
    await _engine.trackCreate(
      entityType: entityType,
      entityId: entityId,
      data: data,
    );
  }

  /// 追踪实体更新
  Future<void> trackUpdate({
    required EntityType entityType,
    required String entityId,
    required List<String> affectedFields,
    required Map<String, dynamic> data,
  }) async {
    await _engine.trackUpdate(
      entityType: entityType,
      entityId: entityId,
      affectedFields: affectedFields,
      data: data,
    );
  }

  /// 追踪实体删除
  Future<void> trackDelete({
    required EntityType entityType,
    required String entityId,
  }) async {
    await _engine.trackDelete(
      entityType: entityType,
      entityId: entityId,
    );
  }

  /// 清除消息
  void clearMessage() {
    _message = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _statusSubscription?.cancel();
    _engine.dispose();
    super.dispose();
  }
}
