import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Service for managing embedded Bun runtime.
///
/// Bun can be used as an alternative to npx for running MCP servers,
/// solving Node.js environment issues (e.g., nvm paths not in PATH).
class BunRuntimeService {
  BunRuntimeService._();
  static final BunRuntimeService instance = BunRuntimeService._();

  /// Bun download URLs for each platform/architecture combination.
  /// Using GitHub releases for the latest stable version.
  static const Map<String, String> _downloadUrls = {
    'macos-arm64': 'https://github.com/oven-sh/bun/releases/latest/download/bun-darwin-aarch64.zip',
    'macos-x64': 'https://github.com/oven-sh/bun/releases/latest/download/bun-darwin-x64.zip',
    'linux-arm64': 'https://github.com/oven-sh/bun/releases/latest/download/bun-linux-aarch64.zip',
    'linux-x64': 'https://github.com/oven-sh/bun/releases/latest/download/bun-linux-x64.zip',
    'windows-x64': 'https://github.com/oven-sh/bun/releases/latest/download/bun-windows-x64.zip',
  };

  /// Mirror URLs for users in China (using npmmirror).
  static const Map<String, String> _mirrorUrls = {
    'macos-arm64': 'https://npmmirror.com/mirrors/bun/latest/bun-darwin-aarch64.zip',
    'macos-x64': 'https://npmmirror.com/mirrors/bun/latest/bun-darwin-x64.zip',
    'linux-arm64': 'https://npmmirror.com/mirrors/bun/latest/bun-linux-aarch64.zip',
    'linux-x64': 'https://npmmirror.com/mirrors/bun/latest/bun-linux-x64.zip',
    'windows-x64': 'https://npmmirror.com/mirrors/bun/latest/bun-windows-x64.zip',
  };

  String? _cachedBunPath;
  bool? _cachedInstalled;

  /// Get the platform key for download URL lookup.
  String? _getPlatformKey() {
    if (kIsWeb) return null;

    String os;
    String arch;

    if (Platform.isMacOS) {
      os = 'macos';
    } else if (Platform.isLinux) {
      os = 'linux';
    } else if (Platform.isWindows) {
      os = 'windows';
    } else {
      return null; // Unsupported platform
    }

    // Detect architecture
    // On macOS/Linux, we can check the process architecture
    // For simplicity, we'll use a heuristic based on the Dart runtime
    final isArm = Platform.version.contains('arm64') ||
        Platform.resolvedExecutable.contains('arm64') ||
        _isAppleSilicon();

    arch = isArm ? 'arm64' : 'x64';

    // Windows currently only supports x64
    if (Platform.isWindows) {
      arch = 'x64';
    }

    return '$os-$arch';
  }

  /// Check if running on Apple Silicon (M1/M2/M3).
  bool _isAppleSilicon() {
    if (!Platform.isMacOS) return false;
    try {
      final result = Process.runSync('uname', ['-m']);
      return result.stdout.toString().trim() == 'arm64';
    } catch (_) {
      return false;
    }
  }

  /// Get the directory where Bun will be installed.
  Future<Directory> getBunDirectory() async {
    final appSupport = await getApplicationSupportDirectory();
    return Directory('${appSupport.path}/bun');
  }

  /// Get the path to the Bun executable, or null if not installed.
  Future<String?> getBunExecutablePath() async {
    if (_cachedBunPath != null && _cachedInstalled == true) {
      // Verify cache is still valid
      if (await File(_cachedBunPath!).exists()) {
        return _cachedBunPath;
      }
      _cachedBunPath = null;
      _cachedInstalled = null;
    }

    final bunDir = await getBunDirectory();
    final execName = Platform.isWindows ? 'bun.exe' : 'bun';

    // Check direct path first
    final directPath = '${bunDir.path}/$execName';
    if (await File(directPath).exists()) {
      _cachedBunPath = directPath;
      _cachedInstalled = true;
      return directPath;
    }

    // Check in subdirectory (zip extraction creates a folder)
    if (await bunDir.exists()) {
      await for (final entity in bunDir.list(recursive: true)) {
        if (entity is File && entity.path.endsWith(execName)) {
          _cachedBunPath = entity.path;
          _cachedInstalled = true;
          return entity.path;
        }
      }
    }

    _cachedInstalled = false;
    return null;
  }

  /// Check if Bun is installed.
  Future<bool> isInstalled() async {
    if (_cachedInstalled != null) {
      // Verify cache
      if (_cachedInstalled! && _cachedBunPath != null) {
        if (await File(_cachedBunPath!).exists()) {
          return true;
        }
        _cachedInstalled = null;
        _cachedBunPath = null;
      }
    }
    return await getBunExecutablePath() != null;
  }

  /// Get the installed Bun version, or null if not installed.
  Future<String?> getVersion() async {
    final bunPath = await getBunExecutablePath();
    if (bunPath == null) return null;

    try {
      final result = await Process.run(bunPath, ['--version']);
      if (result.exitCode == 0) {
        return result.stdout.toString().trim();
      }
    } catch (_) {}
    return null;
  }

  /// Get the download URL for the current platform.
  String? getDownloadUrl({bool useMirror = false}) {
    final key = _getPlatformKey();
    if (key == null) return null;
    return useMirror ? _mirrorUrls[key] : _downloadUrls[key];
  }

  /// Check if the current platform supports Bun.
  bool isPlatformSupported() {
    return _getPlatformKey() != null;
  }

  /// Download and install Bun.
  ///
  /// [onProgress] is called with download progress (0.0 to 1.0).
  /// [useMirror] uses npmmirror for faster downloads in China.
  Future<void> downloadAndInstall({
    void Function(double progress, String status)? onProgress,
    bool useMirror = false,
  }) async {
    final url = getDownloadUrl(useMirror: useMirror);
    if (url == null) {
      throw UnsupportedError('Bun is not supported on this platform');
    }

    final bunDir = await getBunDirectory();

    // Clean up existing installation
    if (await bunDir.exists()) {
      onProgress?.call(0.0, 'Cleaning up...');
      await bunDir.delete(recursive: true);
    }
    await bunDir.create(recursive: true);

    // Download
    onProgress?.call(0.05, 'Downloading...');
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw HttpException('Failed to download Bun: HTTP ${response.statusCode}');
      }

      final contentLength = response.contentLength ?? 0;
      final bytes = <int>[];
      var received = 0;

      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        received += chunk.length;
        if (contentLength > 0) {
          final progress = 0.05 + (received / contentLength) * 0.7; // 5% to 75%
          onProgress?.call(progress, 'Downloading... ${(received / 1024 / 1024).toStringAsFixed(1)} MB');
        }
      }

      // Extract
      onProgress?.call(0.75, 'Extracting...');
      final archive = ZipDecoder().decodeBytes(bytes);

      for (final file in archive) {
        final filename = file.name;
        if (file.isFile) {
          final outFile = File('${bunDir.path}/$filename');
          await outFile.create(recursive: true);
          await outFile.writeAsBytes(file.content as List<int>);

          // Make executable on Unix
          if (!Platform.isWindows && (filename.endsWith('bun') || filename.endsWith('/bun'))) {
            await Process.run('chmod', ['+x', outFile.path]);
          }
        }
      }

      // Verify installation
      onProgress?.call(0.95, 'Verifying...');
      _cachedBunPath = null;
      _cachedInstalled = null;

      final bunPath = await getBunExecutablePath();
      if (bunPath == null) {
        throw StateError('Bun installation failed: executable not found');
      }

      final version = await getVersion();
      if (version == null) {
        throw StateError('Bun installation failed: could not get version');
      }

      onProgress?.call(1.0, 'Installed v$version');
    } finally {
      client.close();
    }
  }

  /// Uninstall Bun by removing the installation directory.
  Future<void> uninstall() async {
    final bunDir = await getBunDirectory();
    if (await bunDir.exists()) {
      await bunDir.delete(recursive: true);
    }
    _cachedBunPath = null;
    _cachedInstalled = null;
  }

  /// Clear cached state (useful after external changes).
  void clearCache() {
    _cachedBunPath = null;
    _cachedInstalled = null;
  }

  /// Open the Bun installation directory in the system file manager.
  Future<void> openInstallDirectory() async {
    final bunDir = await getBunDirectory();
    if (!await bunDir.exists()) {
      await bunDir.create(recursive: true);
    }

    if (Platform.isMacOS) {
      await Process.run('open', [bunDir.path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [bunDir.path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', [bunDir.path]);
    }
  }
}
