import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Service for managing embedded UV runtime.
///
/// UV is a fast Python package and project manager written in Rust.
/// It can be used for running Python-based MCP servers.
class UvRuntimeService {
  UvRuntimeService._();
  static final UvRuntimeService instance = UvRuntimeService._();

  /// UV download URLs for each platform/architecture combination.
  /// Using GitHub releases for the latest stable version.
  static const Map<String, String> _downloadUrls = {
    'macos-arm64': 'https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-apple-darwin.tar.gz',
    'macos-x64': 'https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-apple-darwin.tar.gz',
    'linux-arm64': 'https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-unknown-linux-gnu.tar.gz',
    'linux-x64': 'https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz',
    'windows-x64': 'https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip',
  };

  /// Mirror URLs for users in China.
  static const Map<String, String> _mirrorUrls = {
    'macos-arm64': 'https://mirror.ghproxy.com/https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-apple-darwin.tar.gz',
    'macos-x64': 'https://mirror.ghproxy.com/https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-apple-darwin.tar.gz',
    'linux-arm64': 'https://mirror.ghproxy.com/https://github.com/astral-sh/uv/releases/latest/download/uv-aarch64-unknown-linux-gnu.tar.gz',
    'linux-x64': 'https://mirror.ghproxy.com/https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-unknown-linux-gnu.tar.gz',
    'windows-x64': 'https://mirror.ghproxy.com/https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip',
  };

  String? _cachedUvPath;
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

  /// Get the directory where UV will be installed.
  Future<Directory> getUvDirectory() async {
    final appSupport = await getApplicationSupportDirectory();
    return Directory('${appSupport.path}/uv');
  }

  /// Get the path to the UV executable, or null if not installed.
  Future<String?> getUvExecutablePath() async {
    if (_cachedUvPath != null && _cachedInstalled == true) {
      // Verify cache is still valid
      if (await File(_cachedUvPath!).exists()) {
        return _cachedUvPath;
      }
      _cachedUvPath = null;
      _cachedInstalled = null;
    }

    final uvDir = await getUvDirectory();
    final execName = Platform.isWindows ? 'uv.exe' : 'uv';

    // Check direct path first
    final directPath = '${uvDir.path}/$execName';
    if (await File(directPath).exists()) {
      _cachedUvPath = directPath;
      _cachedInstalled = true;
      return directPath;
    }

    // Check in subdirectory (tar extraction may create a folder)
    if (await uvDir.exists()) {
      await for (final entity in uvDir.list(recursive: true)) {
        if (entity is File && entity.path.endsWith(execName)) {
          _cachedUvPath = entity.path;
          _cachedInstalled = true;
          return entity.path;
        }
      }
    }

    _cachedInstalled = false;
    return null;
  }

  /// Check if UV is installed.
  Future<bool> isInstalled() async {
    if (_cachedInstalled != null) {
      // Verify cache
      if (_cachedInstalled! && _cachedUvPath != null) {
        if (await File(_cachedUvPath!).exists()) {
          return true;
        }
        _cachedInstalled = null;
        _cachedUvPath = null;
      }
    }
    return await getUvExecutablePath() != null;
  }

  /// Get the installed UV version, or null if not installed.
  Future<String?> getVersion() async {
    final uvPath = await getUvExecutablePath();
    if (uvPath == null) return null;

    try {
      final result = await Process.run(uvPath, ['--version']);
      if (result.exitCode == 0) {
        // Output format: "uv 0.5.x"
        final output = result.stdout.toString().trim();
        // Extract version number
        final match = RegExp(r'uv\s+(\S+)').firstMatch(output);
        return match?.group(1) ?? output;
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

  /// Check if the current platform supports UV.
  bool isPlatformSupported() {
    return _getPlatformKey() != null;
  }

  /// Download and install UV.
  ///
  /// [onProgress] is called with download progress (0.0 to 1.0).
  /// [useMirror] uses mirror for faster downloads in China.
  Future<void> downloadAndInstall({
    void Function(double progress, String status)? onProgress,
    bool useMirror = false,
  }) async {
    final url = getDownloadUrl(useMirror: useMirror);
    if (url == null) {
      throw UnsupportedError('UV is not supported on this platform');
    }

    final uvDir = await getUvDirectory();

    // Clean up existing installation
    if (await uvDir.exists()) {
      onProgress?.call(0.0, 'Cleaning up...');
      await uvDir.delete(recursive: true);
    }
    await uvDir.create(recursive: true);

    // Download
    onProgress?.call(0.05, 'Downloading...');
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);

      if (response.statusCode != 200) {
        throw HttpException('Failed to download UV: HTTP ${response.statusCode}');
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

      if (url.endsWith('.zip')) {
        // Windows uses ZIP
        final archive = ZipDecoder().decodeBytes(bytes);
        await _extractArchive(archive, uvDir);
      } else {
        // macOS/Linux uses tar.gz
        final decompressed = GZipDecoder().decodeBytes(bytes);
        final archive = TarDecoder().decodeBytes(decompressed);
        await _extractArchive(archive, uvDir);
      }

      // Verify installation
      onProgress?.call(0.95, 'Verifying...');
      _cachedUvPath = null;
      _cachedInstalled = null;

      final uvPath = await getUvExecutablePath();
      if (uvPath == null) {
        throw StateError('UV installation failed: executable not found');
      }

      final version = await getVersion();
      if (version == null) {
        throw StateError('UV installation failed: could not get version');
      }

      onProgress?.call(1.0, 'Installed v$version');
    } finally {
      client.close();
    }
  }

  /// Extract archive files to the target directory.
  Future<void> _extractArchive(Archive archive, Directory targetDir) async {
    for (final file in archive) {
      final filename = file.name;
      if (file.isFile) {
        final outFile = File('${targetDir.path}/$filename');
        await outFile.create(recursive: true);
        await outFile.writeAsBytes(file.content as List<int>);

        // Make executable on Unix
        if (!Platform.isWindows && (filename.endsWith('uv') || filename.endsWith('/uv'))) {
          await Process.run('chmod', ['+x', outFile.path]);
        }
        // Also handle uvx executable
        if (!Platform.isWindows && (filename.endsWith('uvx') || filename.endsWith('/uvx'))) {
          await Process.run('chmod', ['+x', outFile.path]);
        }
      }
    }
  }

  /// Uninstall UV by removing the installation directory.
  Future<void> uninstall() async {
    final uvDir = await getUvDirectory();
    if (await uvDir.exists()) {
      await uvDir.delete(recursive: true);
    }
    _cachedUvPath = null;
    _cachedInstalled = null;
  }

  /// Clear cached state (useful after external changes).
  void clearCache() {
    _cachedUvPath = null;
    _cachedInstalled = null;
  }

  /// Open the UV installation directory in the system file manager.
  Future<void> openInstallDirectory() async {
    final uvDir = await getUvDirectory();
    if (!await uvDir.exists()) {
      await uvDir.create(recursive: true);
    }

    if (Platform.isMacOS) {
      await Process.run('open', [uvDir.path]);
    } else if (Platform.isLinux) {
      await Process.run('xdg-open', [uvDir.path]);
    } else if (Platform.isWindows) {
      await Process.run('explorer', [uvDir.path]);
    }
  }
}
