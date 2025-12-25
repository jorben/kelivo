/// Kelivo 多端同步 - 时钟校准服务
///
/// 解决客户端设备时间不准确导致签名验证失败的问题

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 时钟校准服务
///
/// 通过 HTTP 响应头校准客户端时钟，确保请求签名时间戳有效
class ClockCalibrationService {
  static const String _clockOffsetKey = 'sync_clock_offset';

  /// 时钟偏移量（毫秒），正值表示本地时间落后于服务器
  int _clockOffset = 0;

  /// 获取当前时钟偏移量
  int get clockOffset => _clockOffset;

  /// 获取校准后的时间戳（毫秒）
  int getCalibratedTimestamp() {
    return DateTime.now().millisecondsSinceEpoch + _clockOffset;
  }

  /// 初始化时加载持久化的偏移量
  Future<void> initialize() async {
    final prefs = await SharedPreferences.getInstance();
    _clockOffset = prefs.getInt(_clockOffsetKey) ?? 0;

    if (_clockOffset.abs() > 1000) {
      debugPrint('ClockCalibration: Loaded offset ${_clockOffset}ms');
    }
  }

  /// 从 HTTP 响应校准时钟
  Future<void> calibrateFromResponse(http.Response response) async {
    final dateHeader = response.headers['date'];
    if (dateHeader == null) return;

    try {
      // 解析 HTTP Date 头（RFC 7231 格式）
      final serverTime = HttpDate.parse(dateHeader);
      final localTime = DateTime.now();

      // 计算偏移量
      final newOffset = serverTime.millisecondsSinceEpoch -
          localTime.millisecondsSinceEpoch;

      // 只有偏移量变化较大时才更新（避免频繁写入）
      if ((newOffset - _clockOffset).abs() > 1000) {
        _clockOffset = newOffset;

        // 持久化存储
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_clockOffsetKey, _clockOffset);

        // 日志记录（仅在偏移量较大时）
        if (_clockOffset.abs() > 5000) {
          debugPrint('ClockCalibration: Offset updated to ${_clockOffset}ms');
        }
      }
    } catch (e) {
      debugPrint('ClockCalibration: Failed to parse date header: $e');
    }
  }

  /// 从 HTTP 响应头字符串校准时钟
  Future<void> calibrateFromDateString(String? dateString) async {
    if (dateString == null) return;

    try {
      final serverTime = HttpDate.parse(dateString);
      final localTime = DateTime.now();

      final newOffset = serverTime.millisecondsSinceEpoch -
          localTime.millisecondsSinceEpoch;

      if ((newOffset - _clockOffset).abs() > 1000) {
        _clockOffset = newOffset;

        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_clockOffsetKey, _clockOffset);

        if (_clockOffset.abs() > 5000) {
          debugPrint('ClockCalibration: Offset updated to ${_clockOffset}ms');
        }
      }
    } catch (e) {
      debugPrint('ClockCalibration: Failed to parse date string: $e');
    }
  }

  /// 检测是否需要重新校准
  ///
  /// 当检测到偏移量过大（超过 5 分钟）时返回 true
  bool needsRecalibration(int? serverTimestamp) {
    if (serverTimestamp == null) return false;
    final localTimestamp = DateTime.now().millisecondsSinceEpoch;
    final drift = (serverTimestamp - localTimestamp - _clockOffset).abs();
    return drift > 300000; // 超过 5 分钟认为需要重新校准
  }

  /// 检测时钟偏移是否过大（需要提示用户）
  bool get hasSignificantOffset => _clockOffset.abs() > 300000; // 5 分钟

  /// 重置时钟偏移
  Future<void> reset() async {
    _clockOffset = 0;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_clockOffsetKey);
  }
}
