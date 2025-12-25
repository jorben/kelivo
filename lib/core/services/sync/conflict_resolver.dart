/// Kelivo 多端同步 - 冲突解决服务
///
/// 实现字段级 LWW (Last-Write-Wins) 合并策略

import '../../models/sync_config.dart';

/// 冲突信息
class ConflictInfo {
  /// 实体类型
  final EntityType entityType;

  /// 实体 ID
  final String entityId;

  /// 本地版本
  final Map<String, dynamic> localData;

  /// 远程版本
  final Map<String, dynamic> remoteData;

  /// 冲突字段
  final List<String> conflictFields;

  /// 本地 changelog ID
  final int localChangelogId;

  /// 远程 changelog ID
  final int remoteChangelogId;

  const ConflictInfo({
    required this.entityType,
    required this.entityId,
    required this.localData,
    required this.remoteData,
    required this.conflictFields,
    required this.localChangelogId,
    required this.remoteChangelogId,
  });
}

/// 合并结果
class MergeResult {
  /// 合并后的数据
  final Map<String, dynamic> mergedData;

  /// 是否有冲突被自动解决
  final bool hadConflict;

  /// 需要用户手动解决的冲突字段
  final List<String> manualConflictFields;

  const MergeResult({
    required this.mergedData,
    this.hadConflict = false,
    this.manualConflictFields = const [],
  });

  /// 是否需要用户手动解决
  bool get needsManualResolution => manualConflictFields.isNotEmpty;
}

/// 冲突解决器
///
/// 实现字段级 LWW 合并策略
class ConflictResolver {
  /// 冲突解决策略
  final ConflictStrategy strategy;

  ConflictResolver({this.strategy = ConflictStrategy.keepNewest});

  /// 检测是否存在冲突
  ///
  /// 当本地和远程都有修改，且修改了相同字段时，存在冲突
  bool hasConflict({
    required Map<String, dynamic> localData,
    required Map<String, dynamic> remoteData,
    required Map<String, dynamic>? baseData,
  }) {
    if (baseData == null) return false;

    // 找出本地修改的字段
    final localChangedFields = _getChangedFields(baseData, localData);
    // 找出远程修改的字段
    final remoteChangedFields = _getChangedFields(baseData, remoteData);

    // 检查是否有交集
    return localChangedFields.any((f) => remoteChangedFields.contains(f));
  }

  /// 获取冲突字段
  List<String> getConflictFields({
    required Map<String, dynamic> localData,
    required Map<String, dynamic> remoteData,
    required Map<String, dynamic>? baseData,
  }) {
    if (baseData == null) return [];

    final localChangedFields = _getChangedFields(baseData, localData);
    final remoteChangedFields = _getChangedFields(baseData, remoteData);

    return localChangedFields
        .where((f) => remoteChangedFields.contains(f))
        .toList();
  }

  /// 合并数据
  ///
  /// 使用字段级 LWW 策略，以 changelog ID 决定胜出
  MergeResult merge({
    required Map<String, dynamic> localData,
    required Map<String, dynamic> remoteData,
    required int localChangelogId,
    required int remoteChangelogId,
    Map<String, dynamic>? baseData,
    List<String>? fieldsToMerge,
  }) {
    final result = Map<String, dynamic>.from(localData);
    var hadConflict = false;
    final manualConflictFields = <String>[];

    // 确定要合并的字段
    final fields = fieldsToMerge ?? remoteData.keys.toList();

    for (final field in fields) {
      if (!remoteData.containsKey(field)) continue;

      final localValue = localData[field];
      final remoteValue = remoteData[field];

      // 值相同，无需处理
      if (_deepEquals(localValue, remoteValue)) continue;

      // 检查是否有冲突（本地和远程都修改了此字段）
      final isConflict = baseData != null &&
          !_deepEquals(baseData[field], localValue) &&
          !_deepEquals(baseData[field], remoteValue);

      if (isConflict) {
        hadConflict = true;

        switch (strategy) {
          case ConflictStrategy.keepLocal:
            // 保留本地值，不做任何操作
            break;

          case ConflictStrategy.keepRemote:
            result[field] = remoteValue;
            break;

          case ConflictStrategy.keepNewest:
            // 以 changelog ID 决定胜出
            if (remoteChangelogId > localChangelogId) {
              result[field] = remoteValue;
            }
            break;

          case ConflictStrategy.manual:
            // 标记为需要手动解决
            manualConflictFields.add(field);
            break;
        }
      } else {
        // 无冲突，直接使用远程值（如果远程有修改）
        if (baseData == null || !_deepEquals(baseData[field], remoteValue)) {
          result[field] = remoteValue;
        }
      }
    }

    return MergeResult(
      mergedData: result,
      hadConflict: hadConflict,
      manualConflictFields: manualConflictFields,
    );
  }

  /// 合并消息数据
  ///
  /// 消息以追加为主，但允许部分字段更新（如 translation）
  MergeResult mergeMessage({
    required Map<String, dynamic> localData,
    required Map<String, dynamic> remoteData,
    required int localChangelogId,
    required int remoteChangelogId,
  }) {
    // 消息的可变字段
    const mutableFields = ['translation', 'metadata'];

    return merge(
      localData: localData,
      remoteData: remoteData,
      localChangelogId: localChangelogId,
      remoteChangelogId: remoteChangelogId,
      fieldsToMerge: mutableFields,
    );
  }

  /// 合并对话元数据
  ///
  /// 使用字段级 LWW
  MergeResult mergeConversation({
    required Map<String, dynamic> localData,
    required Map<String, dynamic> remoteData,
    required int localChangelogId,
    required int remoteChangelogId,
    Map<String, dynamic>? baseData,
  }) {
    // 对话的可合并字段（不包括 messageIds，那是派生数据）
    const mergeableFields = [
      'title',
      'pinned',
      'archived',
      'assistantId',
      'versionSelections',
      'metadata',
    ];

    return merge(
      localData: localData,
      remoteData: remoteData,
      localChangelogId: localChangelogId,
      remoteChangelogId: remoteChangelogId,
      baseData: baseData,
      fieldsToMerge: mergeableFields,
    );
  }

  /// 合并 versionSelections
  ///
  /// 按 groupId 独立合并，每个 groupId 使用 LWW
  Map<String, int> mergeVersionSelections({
    required Map<String, int> local,
    required Map<String, int> remote,
    required Map<String, int> localChangelogIds,
    required Map<String, int> remoteChangelogIds,
  }) {
    final result = Map<String, int>.from(local);

    for (final entry in remote.entries) {
      final groupId = entry.key;
      final remoteVersion = entry.value;

      if (!result.containsKey(groupId)) {
        // 本地没有，直接使用远程
        result[groupId] = remoteVersion;
      } else {
        // 本地有，比较 changelog ID
        final localCid = localChangelogIds[groupId] ?? 0;
        final remoteCid = remoteChangelogIds[groupId] ?? 0;

        if (remoteCid > localCid) {
          result[groupId] = remoteVersion;
        }
      }
    }

    return result;
  }

  /// 合并助手配置
  ///
  /// 使用字段级合并
  MergeResult mergeAssistant({
    required Map<String, dynamic> localData,
    required Map<String, dynamic> remoteData,
    required int localChangelogId,
    required int remoteChangelogId,
    Map<String, dynamic>? baseData,
  }) {
    return merge(
      localData: localData,
      remoteData: remoteData,
      localChangelogId: localChangelogId,
      remoteChangelogId: remoteChangelogId,
      baseData: baseData,
    );
  }

  /// 获取变更的字段
  List<String> _getChangedFields(
    Map<String, dynamic> base,
    Map<String, dynamic> current,
  ) {
    final changedFields = <String>[];

    for (final key in current.keys) {
      if (!base.containsKey(key) || !_deepEquals(base[key], current[key])) {
        changedFields.add(key);
      }
    }

    return changedFields;
  }

  /// 深度比较两个值是否相等
  bool _deepEquals(dynamic a, dynamic b) {
    if (a == b) return true;
    if (a == null || b == null) return false;
    if (a.runtimeType != b.runtimeType) return false;

    if (a is Map && b is Map) {
      if (a.length != b.length) return false;
      for (final key in a.keys) {
        if (!b.containsKey(key) || !_deepEquals(a[key], b[key])) {
          return false;
        }
      }
      return true;
    }

    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) return false;
      }
      return true;
    }

    return false;
  }
}
