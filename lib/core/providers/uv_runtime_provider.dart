import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/uv_runtime_service.dart';

/// Status of the UV runtime.
enum UvStatus {
  /// Initial state, not yet checked.
  unknown,

  /// Checking if UV is installed.
  checking,

  /// UV is installed and ready.
  ready,

  /// UV is not installed.
  notInstalled,

  /// UV is being downloaded/installed.
  installing,

  /// Installation failed.
  error,

  /// Platform does not support UV.
  unsupported,
}

/// Provider for managing UV runtime state.
///
/// This provider tracks whether UV is installed and provides
/// methods for downloading/installing UV. It also controls
/// whether Python-based MCP servers should use UV.
class UvRuntimeProvider extends ChangeNotifier {
  static const String _prefsUseUvKey = 'uv_use_embedded_v1';
  static const String _prefsMirrorKey = 'uv_use_mirror_v1';

  final UvRuntimeService _service = UvRuntimeService.instance;

  UvStatus _status = UvStatus.unknown;
  String? _version;
  String? _error;
  double _installProgress = 0.0;
  String _installStatus = '';
  bool _useEmbeddedUv = true; // Default to using embedded UV
  bool _useMirror = false; // Use mirror for downloads (China)

  UvRuntimeProvider() {
    _initialize();
  }

  UvStatus get status => _status;
  String? get version => _version;
  String? get error => _error;
  double get installProgress => _installProgress;
  String get installStatus => _installStatus;
  bool get useEmbeddedUv => _useEmbeddedUv;
  bool get useMirror => _useMirror;

  /// Whether UV is ready to use.
  bool get isReady => _status == UvStatus.ready;

  /// Whether UV is currently being installed.
  bool get isInstalling => _status == UvStatus.installing;

  /// Whether the platform supports UV.
  bool get isPlatformSupported => _service.isPlatformSupported();

  /// Whether Python MCP servers should wait for UV.
  ///
  /// Returns true if:
  /// - User has enabled "use embedded UV" AND
  /// - UV is not yet ready (still checking, installing, or not installed)
  bool get shouldWaitForUv {
    if (!_useEmbeddedUv) return false;
    if (!isPlatformSupported) return false;
    return _status == UvStatus.unknown ||
        _status == UvStatus.checking ||
        _status == UvStatus.installing;
  }

  /// Whether Python MCP servers can proceed.
  ///
  /// Returns true if:
  /// - User has disabled "use embedded UV" OR
  /// - Platform doesn't support UV OR
  /// - UV is ready OR
  /// - UV installation failed (fall back to system python)
  bool get canProceedWithPython {
    if (!_useEmbeddedUv) return true;
    if (!isPlatformSupported) return true;
    return _status == UvStatus.ready ||
        _status == UvStatus.notInstalled ||
        _status == UvStatus.error;
  }

  /// Get the UV executable path if available.
  Future<String?> getUvPath() async {
    if (!_useEmbeddedUv) return null;
    if (_status != UvStatus.ready) return null;
    return await _service.getUvExecutablePath();
  }

  Future<void> _initialize() async {
    // Load preferences
    try {
      final prefs = await SharedPreferences.getInstance();
      _useEmbeddedUv = prefs.getBool(_prefsUseUvKey) ?? true;
      _useMirror = prefs.getBool(_prefsMirrorKey) ?? false;
    } catch (_) {}

    // Check platform support
    if (!_service.isPlatformSupported()) {
      _status = UvStatus.unsupported;
      notifyListeners();
      return;
    }

    // Check if UV is installed
    await checkInstallation();
  }

  /// Check if UV is installed and update status.
  Future<void> checkInstallation() async {
    if (!_service.isPlatformSupported()) {
      _status = UvStatus.unsupported;
      notifyListeners();
      return;
    }

    _status = UvStatus.checking;
    _error = null;
    notifyListeners();

    try {
      final installed = await _service.isInstalled();
      if (installed) {
        _version = await _service.getVersion();
        _status = UvStatus.ready;
      } else {
        _version = null;
        _status = UvStatus.notInstalled;
      }
    } catch (e) {
      _status = UvStatus.error;
      _error = e.toString();
    }

    notifyListeners();
  }

  /// Download and install UV.
  Future<bool> install() async {
    if (_status == UvStatus.installing) return false;
    if (!_service.isPlatformSupported()) return false;

    _status = UvStatus.installing;
    _error = null;
    _installProgress = 0.0;
    _installStatus = '';
    notifyListeners();

    try {
      await _service.downloadAndInstall(
        useMirror: _useMirror,
        onProgress: (progress, status) {
          _installProgress = progress;
          _installStatus = status;
          notifyListeners();
        },
      );

      _version = await _service.getVersion();
      _status = UvStatus.ready;
      notifyListeners();
      return true;
    } catch (e) {
      _status = UvStatus.error;
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Uninstall UV.
  Future<void> uninstall() async {
    try {
      await _service.uninstall();
      _version = null;
      _status = UvStatus.notInstalled;
      _error = null;
    } catch (e) {
      _error = e.toString();
    }
    notifyListeners();
  }

  /// Set whether to use embedded UV for Python MCP servers.
  Future<void> setUseEmbeddedUv(bool value) async {
    if (_useEmbeddedUv == value) return;
    _useEmbeddedUv = value;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsUseUvKey, value);
    } catch (_) {}
  }

  /// Set whether to use mirror for downloads.
  Future<void> setUseMirror(bool value) async {
    if (_useMirror == value) return;
    _useMirror = value;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsMirrorKey, value);
    } catch (_) {}
  }

  /// Open the UV installation directory.
  Future<void> openInstallDirectory() async {
    await _service.openInstallDirectory();
  }

  /// Refresh the installation status.
  Future<void> refresh() async {
    _service.clearCache();
    await checkInstallation();
  }
}
