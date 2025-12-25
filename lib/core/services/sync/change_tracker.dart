/// Kelivo 多端同步 - 变更追踪服务
///
/// 追踪本地数据变更，生成待同步的变更队列

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/sync_config.dart';

/// 待同步的变更记录
class PendingChange {
  /// 唯一标识
  final String id;

  /// 实体类型
  final EntityType entityType;

  /// 实体 ID
  final String entityId;

  /// 变更类型
  final ChangeType changeType;

  /// 受影响的字段（仅 fieldUpdate 时有值）
  final List<String>? affectedFields;

  /// 变更时间
  final DateTime timestamp;

  /// 加密后的数据
  final String? encryptedData;

  const PendingChange({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.changeType,
    this.affectedFields,
    required this.timestamp,
    this.encryptedData,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'entityType': entityType.name,
      'entityId': entityId,
      'changeType': changeType.name,
      'affectedFields': affectedFields,
      'timestamp': timestamp.toIso8601String(),
      'encryptedData': encryptedData,
    };
  }

  factory PendingChange.fromJson(Map<String, dynamic> json) {
    return PendingChange(
      id: json['id'] as String,
      entityType: EntityType.values.firstWhere(
        (e) => e.name == json['entityType'],
      ),
      entityId: json['entityId'] as String,
      changeType: ChangeType.values.firstWhere(
        (e) => e.name == json['changeType'],
      ),
      affectedFields: json['affectedFields'] != null
          ? List<String>.from(json['affectedFields'] as List)
          : null,
      timestamp: DateTime.parse(json['timestamp'] as String),
      encryptedData: json['encryptedData'] as String?,
    );
  }
}

/// 变更追踪器
///
/// 负责追踪本地数据变更并生成待同步队列
class ChangeTracker {
  static const String _pendingChangesKey = 'sync_pending_changes';
  static const String _changeIdCounterKey = 'sync_change_id_counter';

  /// 待同步的变更队列
  final List<PendingChange> _pendingChanges = [];

  /// 变更 ID 计数器
  int _changeIdCounter = 0;

  /// 设备 ID
  final String deviceId;

  /// 变更聚合延迟（毫秒）
  final int aggregationDelayMs;

  /// 最后一次变更时间
  DateTime? _lastChangeTime;

  /// 聚合定时器是否运行中
  bool _aggregationTimerRunning = false;

  /// 变更回调
  void Function(List<PendingChange> changes)? onChangesReady;

  ChangeTracker({
    required this.deviceId,
    this.aggregationDelayMs = 500,
  });

  /// 获取待同步的变更数量
  int get pendingCount => _pendingChanges.length;

  /// 获取所有待同步的变更
  List<PendingChange> get pendingChanges => List.unmodifiable(_pendingChanges);

  /// 初始化，加载持久化的待同步变更
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();

    // 加载变更 ID 计数器
    _changeIdCounter = prefs.getInt(_changeIdCounterKey) ?? 0;

    // 加载待同步变更
    final changesJson = prefs.getString(_pendingChangesKey);
    if (changesJson != null) {
      try {
        final list = jsonDecode(changesJson) as List;
        _pendingChanges.clear();
        _pendingChanges.addAll(
          list.map((e) => PendingChange.fromJson(e as Map<String, dynamic>)),
        );
        debugPrint('ChangeTracker: Loaded ${_pendingChanges.length} pending changes');
      } catch (e) {
        debugPrint('ChangeTracker: Failed to load pending changes: $e');
      }
    }
  }

  /// 记录创建变更
  Future<void> trackCreate({
    required EntityType entityType,
    required String entityId,
    String? encryptedData,
  }) async {
    await _addChange(PendingChange(
      id: _generateChangeId(),
      entityType: entityType,
      entityId: entityId,
      changeType: ChangeType.create,
      timestamp: DateTime.now(),
      encryptedData: encryptedData,
    ));
  }

  /// 记录字段更新变更
  Future<void> trackFieldUpdate({
    required EntityType entityType,
    required String entityId,
    required List<String> affectedFields,
    String? encryptedData,
  }) async {
    await _addChange(PendingChange(
      id: _generateChangeId(),
      entityType: entityType,
      entityId: entityId,
      changeType: ChangeType.fieldUpdate,
      affectedFields: affectedFields,
      timestamp: DateTime.now(),
      encryptedData: encryptedData,
    ));
  }

  /// 记录删除变更
  Future<void> trackDelete({
    required EntityType entityType,
    required String entityId,
  }) async {
    await _addChange(PendingChange(
      id: _generateChangeId(),
      entityType: entityType,
      entityId: entityId,
      changeType: ChangeType.delete,
      timestamp: DateTime.now(),
    ));
  }

  /// 添加变更并触发聚合
  Future<void> _addChange(PendingChange change) async {
    _pendingChanges.add(change);
    _lastChangeTime = DateTime.now();

    // 持久化
    await _persistChanges();

    // 启动聚合定时器
    _startAggregationTimer();
  }

  /// 启动聚合定时器
  void _startAggregationTimer() {
    if (_aggregationTimerRunning) return;
    _aggregationTimerRunning = true;

    Future.delayed(Duration(milliseconds: aggregationDelayMs), () {
      _aggregationTimerRunning = false;

      // 检查是否还有新变更
      final now = DateTime.now();
      if (_lastChangeTime != null &&
          now.difference(_lastChangeTime!).inMilliseconds < aggregationDelayMs) {
        // 还有新变更，继续等待
        _startAggregationTimer();
      } else {
        // 变更已稳定，触发回调
        if (_pendingChanges.isNotEmpty && onChangesReady != null) {
          onChangesReady!(List.from(_pendingChanges));
        }
      }
    });
  }

  /// 标记变更已同步
  Future<void> markSynced(List<String> changeIds) async {
    _pendingChanges.removeWhere((c) => changeIds.contains(c.id));
    await _persistChanges();
  }

  /// 清除所有待同步变更
  Future<void> clearAll() async {
    _pendingChanges.clear();
    await _persistChanges();
  }

  /// 获取指定实体的待同步变更
  List<PendingChange> getChangesForEntity({
    required EntityType entityType,
    required String entityId,
  }) {
    return _pendingChanges
        .where((c) => c.entityType == entityType && c.entityId == entityId)
        .toList();
  }

  /// 合并相同实体的变更
  ///
  /// 将同一实体的多次变更合并为一次
  List<PendingChange> getMergedChanges() {
    final merged = <String, PendingChange>{};

    for (final change in _pendingChanges) {
      final key = '${change.entityType.name}:${change.entityId}';

      if (!merged.containsKey(key)) {
        merged[key] = change;
      } else {
        final existing = merged[key]!;

        // 如果有删除操作，以删除为准
        if (change.changeType == ChangeType.delete) {
          merged[key] = change;
        } else if (existing.changeType != ChangeType.delete) {
          // 合并字段更新
          final mergedFields = <String>{
            ...?existing.affectedFields,
            ...?change.affectedFields,
          };

          merged[key] = PendingChange(
            id: change.id,
            entityType: change.entityType,
            entityId: change.entityId,
            changeType: existing.changeType == ChangeType.create
                ? ChangeType.create
                : ChangeType.fieldUpdate,
            affectedFields: mergedFields.isEmpty ? null : mergedFields.toList(),
            timestamp: change.timestamp,
            encryptedData: change.encryptedData ?? existing.encryptedData,
          );
        }
      }
    }

    return merged.values.toList();
  }

  /// 生成变更 ID
  String _generateChangeId() {
    _changeIdCounter++;
    return '${deviceId}_${_changeIdCounter}_${DateTime.now().millisecondsSinceEpoch}';
  }

  /// 持久化变更队列
  Future<void> _persistChanges() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _pendingChangesKey,
      jsonEncode(_pendingChanges.map((c) => c.toJson()).toList()),
    );
    await prefs.setInt(_changeIdCounterKey, _changeIdCounter);
  }
}
