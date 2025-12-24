import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/bun_runtime_service.dart';

/// Status of the Bun runtime.
enum BunStatus {
  /// Initial state, not yet checked.
  unknown,

  /// Checking if Bun is installed.
  checking,

  /// Bun is installed and ready.
  ready,

  /// Bun is not installed.
  notInstalled,

  /// Bun is being downloaded/installed.
  installing,

  /// Installation failed.
  error,

  /// Platform does not support Bun.
  unsupported,
}

/// Provider for managing Bun runtime state.
///
/// This provider tracks whether Bun is installed and provides
/// methods for downloading/installing Bun. It also controls
/// whether MCP STDIO servers should wait for Bun to be ready.
class BunRuntimeProvider extends ChangeNotifier {
  static const String _prefsUseBunKey = 'bun_use_embedded_v1';
  static const String _prefsMirrorKey = 'bun_use_mirror_v1';

  final BunRuntimeService _service = BunRuntimeService.instance;

  BunStatus _status = BunStatus.unknown;
  String? _version;
  String? _error;
  double _installProgress = 0.0;
  String _installStatus = '';
  bool _useEmbeddedBun = true; // Default to using embedded Bun
  bool _useMirror = false; // Use mirror for downloads (China)

  BunRuntimeProvider() {
    _initialize();
  }

  BunStatus get status => _status;
  String? get version => _version;
  String? get error => _error;
  double get installProgress => _installProgress;
  String get installStatus => _installStatus;
  bool get useEmbeddedBun => _useEmbeddedBun;
  bool get useMirror => _useMirror;

  /// Whether Bun is ready to use.
  bool get isReady => _status == BunStatus.ready;

  /// Whether Bun is currently being installed.
  bool get isInstalling => _status == BunStatus.installing;

  /// Whether the platform supports Bun.
  bool get isPlatformSupported => _service.isPlatformSupported();

  /// Whether STDIO MCP servers should wait for Bun.
  ///
  /// Returns true if:
  /// - User has enabled "use embedded Bun" AND
  /// - Bun is not yet ready (still checking, installing, or not installed)
  bool get shouldWaitForBun {
    if (!_useEmbeddedBun) return false;
    if (!isPlatformSupported) return false;
    return _status == BunStatus.unknown ||
        _status == BunStatus.checking ||
        _status == BunStatus.installing;
  }

  /// Whether STDIO MCP servers can proceed.
  ///
  /// Returns true if:
  /// - User has disabled "use embedded Bun" OR
  /// - Platform doesn't support Bun OR
  /// - Bun is ready OR
  /// - Bun installation failed (fall back to system npx)
  bool get canProceedWithStdio {
    if (!_useEmbeddedBun) return true;
    if (!isPlatformSupported) return true;
    return _status == BunStatus.ready ||
        _status == BunStatus.notInstalled ||
        _status == BunStatus.error;
  }

  /// Get the Bun executable path if available.
  Future<String?> getBunPath() async {
    if (!_useEmbeddedBun) return null;
    if (_status != BunStatus.ready) return null;
    return await _service.getBunExecutablePath();
  }

  Future<void> _initialize() async {
    // Load preferences
    try {
      final prefs = await SharedPreferences.getInstance();
      _useEmbeddedBun = prefs.getBool(_prefsUseBunKey) ?? true;
      _useMirror = prefs.getBool(_prefsMirrorKey) ?? false;
    } catch (_) {}

    // Check platform support
    if (!_service.isPlatformSupported()) {
      _status = BunStatus.unsupported;
      notifyListeners();
      return;
    }

    // Check if Bun is installed
    await checkInstallation();
  }

  /// Check if Bun is installed and update status.
  Future<void> checkInstallation() async {
    if (!_service.isPlatformSupported()) {
      _status = BunStatus.unsupported;
      notifyListeners();
      return;
    }

    _status = BunStatus.checking;
    _error = null;
    notifyListeners();

    try {
      final installed = await _service.isInstalled();
      if (installed) {
        _version = await _service.getVersion();
        _status = BunStatus.ready;
      } else {
        _version = null;
        _status = BunStatus.notInstalled;
      }
    } catch (e) {
      _status = BunStatus.error;
      _error = e.toString();
    }

    notifyListeners();
  }

  /// Download and install Bun.
  Future<bool> install() async {
    if (_status == BunStatus.installing) return false;
    if (!_service.isPlatformSupported()) return false;

    _status = BunStatus.installing;
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
      _status = BunStatus.ready;
      notifyListeners();
      return true;
    } catch (e) {
      _status = BunStatus.error;
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// Uninstall Bun.
  Future<void> uninstall() async {
    try {
      await _service.uninstall();
      _version = null;
      _status = BunStatus.notInstalled;
      _error = null;
    } catch (e) {
      _error = e.toString();
    }
    notifyListeners();
  }

  /// Set whether to use embedded Bun for MCP STDIO servers.
  Future<void> setUseEmbeddedBun(bool value) async {
    if (_useEmbeddedBun == value) return;
    _useEmbeddedBun = value;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefsUseBunKey, value);
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

  /// Open the Bun installation directory.
  Future<void> openInstallDirectory() async {
    await _service.openInstallDirectory();
  }

  /// Refresh the installation status.
  Future<void> refresh() async {
    _service.clearCache();
    await checkInstallation();
  }
}
