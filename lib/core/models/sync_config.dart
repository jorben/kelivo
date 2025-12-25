/// Kelivo 多端同步配置模型

import 'dart:convert';

/// 同步状态枚举
enum SyncStatus {
  /// 未配置
  notConfigured,

  /// 空闲
  idle,

  /// 同步中
  syncing,

  /// 已同步
  synced,

  /// 同步失败
  error,

  /// 离线
  offline,
}

/// 冲突解决策略
enum ConflictStrategy {
  /// 保留本地版本
  keepLocal,

  /// 保留远程版本
  keepRemote,

  /// 保留最新版本（基于 changelog ID）
  keepNewest,

  /// 手动选择
  manual,
}

/// 同步配置
class SyncConfig {
  /// 是否启用同步
  final bool enabled;

  /// Supabase 服务地址
  final String? supabaseUrl;

  /// Supabase Anon Key
  final String? anonKey;

  /// 同步密钥（用于加密和签名）
  final String? syncKey;

  /// 设备 ID
  final String? deviceId;

  /// 自动同步
  final bool autoSync;

  /// 同步间隔（秒）
  final int syncIntervalSeconds;

  /// 启动时同步
  final bool syncOnStartup;

  /// 冲突解决策略
  final ConflictStrategy conflictStrategy;

  /// 上次同步时间
  final DateTime? lastSyncAt;

  /// 上次同步的 changelog ID
  final int lastChangelogId;

  /// 时钟偏移量（毫秒）
  final int clockOffset;

  const SyncConfig({
    this.enabled = false,
    this.supabaseUrl,
    this.anonKey,
    this.syncKey,
    this.deviceId,
    this.autoSync = true,
    this.syncIntervalSeconds = 10,
    this.syncOnStartup = true,
    this.conflictStrategy = ConflictStrategy.keepNewest,
    this.lastSyncAt,
    this.lastChangelogId = 0,
    this.clockOffset = 0,
  });

  /// 是否已配置（有完整的连接信息）
  bool get isConfigured =>
      supabaseUrl != null &&
      supabaseUrl!.isNotEmpty &&
      anonKey != null &&
      anonKey!.isNotEmpty &&
      syncKey != null &&
      syncKey!.isNotEmpty;

  SyncConfig copyWith({
    bool? enabled,
    String? supabaseUrl,
    String? anonKey,
    String? syncKey,
    String? deviceId,
    bool? autoSync,
    int? syncIntervalSeconds,
    bool? syncOnStartup,
    ConflictStrategy? conflictStrategy,
    DateTime? lastSyncAt,
    int? lastChangelogId,
    int? clockOffset,
  }) {
    return SyncConfig(
      enabled: enabled ?? this.enabled,
      supabaseUrl: supabaseUrl ?? this.supabaseUrl,
      anonKey: anonKey ?? this.anonKey,
      syncKey: syncKey ?? this.syncKey,
      deviceId: deviceId ?? this.deviceId,
      autoSync: autoSync ?? this.autoSync,
      syncIntervalSeconds: syncIntervalSeconds ?? this.syncIntervalSeconds,
      syncOnStartup: syncOnStartup ?? this.syncOnStartup,
      conflictStrategy: conflictStrategy ?? this.conflictStrategy,
      lastSyncAt: lastSyncAt ?? this.lastSyncAt,
      lastChangelogId: lastChangelogId ?? this.lastChangelogId,
      clockOffset: clockOffset ?? this.clockOffset,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'enabled': enabled,
      'supabaseUrl': supabaseUrl,
      'anonKey': anonKey,
      'syncKey': syncKey,
      'deviceId': deviceId,
      'autoSync': autoSync,
      'syncIntervalSeconds': syncIntervalSeconds,
      'syncOnStartup': syncOnStartup,
      'conflictStrategy': conflictStrategy.name,
      'lastSyncAt': lastSyncAt?.toIso8601String(),
      'lastChangelogId': lastChangelogId,
      'clockOffset': clockOffset,
    };
  }

  factory SyncConfig.fromJson(Map<String, dynamic> json) {
    return SyncConfig(
      enabled: json['enabled'] as bool? ?? false,
      supabaseUrl: json['supabaseUrl'] as String?,
      anonKey: json['anonKey'] as String?,
      syncKey: json['syncKey'] as String?,
      deviceId: json['deviceId'] as String?,
      autoSync: json['autoSync'] as bool? ?? true,
      syncIntervalSeconds: json['syncIntervalSeconds'] as int? ?? 10,
      syncOnStartup: json['syncOnStartup'] as bool? ?? true,
      conflictStrategy: ConflictStrategy.values.firstWhere(
        (e) => e.name == json['conflictStrategy'],
        orElse: () => ConflictStrategy.keepNewest,
      ),
      lastSyncAt: json['lastSyncAt'] != null
          ? DateTime.tryParse(json['lastSyncAt'] as String)
          : null,
      lastChangelogId: json['lastChangelogId'] as int? ?? 0,
      clockOffset: json['clockOffset'] as int? ?? 0,
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory SyncConfig.fromJsonString(String jsonString) {
    return SyncConfig.fromJson(jsonDecode(jsonString) as Map<String, dynamic>);
  }
}

/// 变更类型
enum ChangeType {
  /// 创建
  create,

  /// 字段更新
  fieldUpdate,

  /// 删除
  delete,
}

/// 实体类型
enum EntityType {
  message,
  conversation,
  assistant,
  assistantMemory,
  assistantTag,
  quickPhrase,
  instructionInjection,
  providerConfig,
  mcpConfig,
  userInfo,
}

/// 变更日志记录
class ChangelogEntry {
  final int id;
  final EntityType entityType;
  final String entityId;
  final ChangeType changeType;
  final List<String>? affectedFields;
  final DateTime timestamp;
  final String deviceId;

  const ChangelogEntry({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.changeType,
    this.affectedFields,
    required this.timestamp,
    required this.deviceId,
  });

  factory ChangelogEntry.fromJson(Map<String, dynamic> json) {
    return ChangelogEntry(
      id: json['id'] as int,
      entityType: EntityType.values.firstWhere(
        (e) => e.name == json['entity_type'],
        orElse: () => EntityType.message,
      ),
      entityId: json['entity_id'] as String,
      changeType: ChangeType.values.firstWhere(
        (e) =>
            e.name.toUpperCase() ==
            (json['change_type'] as String).replaceAll('_', ''),
        orElse: () => ChangeType.create,
      ),
      affectedFields: json['affected_fields'] != null
          ? List<String>.from(jsonDecode(json['affected_fields'] as String))
          : null,
      timestamp: DateTime.parse(json['timestamp'] as String),
      deviceId: json['device_id'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'entity_type': entityType.name,
      'entity_id': entityId,
      'change_type': changeType.name.toUpperCase(),
      'affected_fields':
          affectedFields != null ? jsonEncode(affectedFields) : null,
      'device_id': deviceId,
    };
  }
}

/// 同步结果
class SyncResult {
  final bool success;
  final String? errorCode;
  final String? errorMessage;
  final int uploadedCount;
  final int downloadedCount;
  final int conflictCount;
  final DateTime? syncedAt;

  const SyncResult({
    required this.success,
    this.errorCode,
    this.errorMessage,
    this.uploadedCount = 0,
    this.downloadedCount = 0,
    this.conflictCount = 0,
    this.syncedAt,
  });

  factory SyncResult.success({
    int uploadedCount = 0,
    int downloadedCount = 0,
    int conflictCount = 0,
  }) {
    return SyncResult(
      success: true,
      uploadedCount: uploadedCount,
      downloadedCount: downloadedCount,
      conflictCount: conflictCount,
      syncedAt: DateTime.now(),
    );
  }

  factory SyncResult.error(String code, String message) {
    return SyncResult(
      success: false,
      errorCode: code,
      errorMessage: message,
    );
  }
}

/// 初始化结果
class InitResult {
  final bool success;
  final bool? isFirstDevice;
  final String? errorCode;
  final String? errorMessage;

  const InitResult._({
    required this.success,
    this.isFirstDevice,
    this.errorCode,
    this.errorMessage,
  });

  factory InitResult.success({required bool isFirstDevice}) => InitResult._(
        success: true,
        isFirstDevice: isFirstDevice,
      );

  factory InitResult.error(String code, String message) => InitResult._(
        success: false,
        errorCode: code,
        errorMessage: message,
      );
}
