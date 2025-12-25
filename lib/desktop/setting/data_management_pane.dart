/// Kelivo 桌面端数据管理面板
///
/// Tab 切换展示"数据同步"和"数据备份"两个子面板

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import '../../icons/lucide_adapter.dart' as lucide;
import '../../l10n/app_localizations.dart';
import '../../core/models/sync_config.dart';
import '../../core/providers/sync_provider.dart';
import '../../core/services/sync/encryption_service.dart';
import '../../shared/widgets/snackbar.dart';
import 'backup_pane.dart';

/// 桌面端数据管理面板
class DesktopDataManagementPane extends StatefulWidget {
  const DesktopDataManagementPane({super.key});

  @override
  State<DesktopDataManagementPane> createState() =>
      _DesktopDataManagementPaneState();
}

class _DesktopDataManagementPaneState extends State<DesktopDataManagementPane>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 确保 SyncProvider 已初始化
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final syncProvider = context.read<SyncProvider>();
      if (!syncProvider.isInitialized && !syncProvider.busy) {
        syncProvider.initialize();
      }
    });

    return Container(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 标题行
              SizedBox(
                height: 36,
                child: Row(
                  children: [
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          l10n.settingsPageDataSync,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: cs.onSurface,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),

              // Tab 切换
              Container(
                height: 40,
                decoration: BoxDecoration(
                  color: isDark ? Colors.white10 : Colors.white.withOpacity(0.96),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: cs.outlineVariant.withOpacity(isDark ? 0.12 : 0.08),
                    width: 0.8,
                  ),
                ),
                child: TabBar(
                  controller: _tabController,
                  indicator: BoxDecoration(
                    color: cs.primary.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicatorPadding: const EdgeInsets.all(4),
                  dividerColor: Colors.transparent,
                  labelColor: cs.primary,
                  unselectedLabelColor: cs.onSurface.withOpacity(0.6),
                  labelStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  unselectedLabelStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  tabs: [
                    Tab(text: l10n.settingsPageDataSync),
                    Tab(text: l10n.settingsPageBackup),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Tab 内容
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: const [
                    _DesktopSyncPane(),
                    DesktopBackupPane(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 桌面端同步面板
class _DesktopSyncPane extends StatefulWidget {
  const _DesktopSyncPane();

  @override
  State<_DesktopSyncPane> createState() => _DesktopSyncPaneState();
}

class _DesktopSyncPaneState extends State<_DesktopSyncPane> {
  final _urlController = TextEditingController();
  final _anonKeyController = TextEditingController();
  final _syncKeyController = TextEditingController();
  bool _obscureSyncKey = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadConfig();
    });
  }

  void _loadConfig() {
    final syncProvider = context.read<SyncProvider>();
    if (syncProvider.isConfigured) {
      _urlController.text = syncProvider.config.supabaseUrl ?? '';
      _anonKeyController.text = syncProvider.config.anonKey ?? '';
      _syncKeyController.text = syncProvider.config.syncKey ?? '';
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _anonKeyController.dispose();
    _syncKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final syncProvider = context.watch<SyncProvider>();

    Widget sectionCard({required List<Widget> children}) {
      final baseBg = isDark ? Colors.white10 : Colors.white.withOpacity(0.96);
      return Container(
        decoration: BoxDecoration(
          color: baseBg,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: cs.outlineVariant.withOpacity(isDark ? 0.12 : 0.08),
            width: 0.8,
          ),
        ),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );
    }

    Widget sectionHeader(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withOpacity(0.8),
            ),
          ),
        );

    // 状态指示器
    Widget statusIndicator() {
      Color statusColor;
      String statusText;

      switch (syncProvider.status) {
        case SyncStatus.notConfigured:
          statusColor = cs.outline;
          statusText = l10n.syncStatusNotConfigured;
          break;
        case SyncStatus.idle:
          statusColor = Colors.green;
          statusText = l10n.syncStatusIdle;
          break;
        case SyncStatus.syncing:
          statusColor = cs.primary;
          statusText = l10n.syncStatusSyncing;
          break;
        case SyncStatus.synced:
          statusColor = Colors.green;
          statusText = l10n.syncStatusSynced;
          break;
        case SyncStatus.error:
          statusColor = cs.error;
          statusText = l10n.syncStatusError;
          break;
        case SyncStatus.offline:
          statusColor = cs.outline;
          statusText = l10n.syncStatusOffline;
          break;
      }

      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: statusColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            statusText,
            style: TextStyle(
              fontSize: 13,
              color: statusColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    }

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 同步状态卡片
              if (syncProvider.isConfigured) ...[
                sectionCard(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.syncCurrentStatus,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: cs.onSurface,
                                ),
                              ),
                              const SizedBox(height: 4),
                              statusIndicator(),
                            ],
                          ),
                        ),
                        if (syncProvider.config.lastSyncAt != null)
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                l10n.syncLastSyncTime,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: cs.onSurface.withOpacity(0.6),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _formatDateTime(syncProvider.config.lastSyncAt!),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: cs.onSurface,
                                ),
                              ),
                            ],
                          ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        _DeskButton(
                          label: l10n.syncNowButton,
                          icon: lucide.Lucide.RefreshCw,
                          onTap: syncProvider.busy
                              ? null
                              : () async {
                                  final result = await syncProvider.syncNow();
                                  if (context.mounted) {
                                    showAppSnackBar(
                                      context,
                                      message: result.success
                                          ? l10n.syncSuccess
                                          : (result.errorMessage ??
                                              l10n.syncFailed),
                                      type: result.success
                                          ? NotificationType.success
                                          : NotificationType.error,
                                    );
                                  }
                                },
                          busy: syncProvider.busy &&
                              syncProvider.status == SyncStatus.syncing,
                        ),
                        const SizedBox(width: 12),
                        _DeskButton(
                          label: l10n.syncResetButton,
                          icon: lucide.Lucide.Trash2,
                          outline: true,
                          danger: true,
                          onTap: () async {
                            final confirm =
                                await _showResetConfirmDialog(context);
                            if (confirm == true && context.mounted) {
                              await syncProvider.reset();
                              _urlController.clear();
                              _anonKeyController.clear();
                              _syncKeyController.clear();
                              showAppSnackBar(context, message: l10n.syncResetSuccess);
                            }
                          },
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],

              // 配置表单
              sectionCard(
                children: [
                  sectionHeader(l10n.syncConfigTitle),
                  _buildTextField(
                    controller: _urlController,
                    label: l10n.syncWizardUrlLabel,
                    hint: 'https://xxx.supabase.co',
                  ),
                  const SizedBox(height: 12),
                  _buildTextField(
                    controller: _anonKeyController,
                    label: l10n.syncWizardAnonKeyLabel,
                    hint: 'eyJhbGciOiJIUzI1NiIs...',
                    maxLines: 2,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _buildTextField(
                          controller: _syncKeyController,
                          label: l10n.syncWizardSyncKeyLabel,
                          hint: l10n.syncWizardSyncKeyHint,
                          obscureText: _obscureSyncKey,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: Icon(
                          _obscureSyncKey
                              ? lucide.Lucide.Eye
                              : lucide.Lucide.EyeOff,
                          size: 18,
                        ),
                        onPressed: () {
                          setState(() => _obscureSyncKey = !_obscureSyncKey);
                        },
                      ),
                      IconButton(
                        icon: const Icon(lucide.Lucide.Shuffle, size: 18),
                        tooltip: l10n.syncWizardGenerateKey,
                        onPressed: () {
                          _syncKeyController.text =
                              EncryptionService.generateSyncKey();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      _DeskButton(
                        label: syncProvider.isConfigured
                            ? l10n.syncUpdateConfig
                            : l10n.syncStartSync,
                        icon: lucide.Lucide.CloudUpload,
                        onTap: syncProvider.busy
                            ? null
                            : () => _onConnect(syncProvider),
                        busy: syncProvider.busy,
                      ),
                    ],
                  ),
                ],
              ),

              const SizedBox(height: 16),

              // 安全信息
              sectionCard(
                children: [
                  sectionHeader(l10n.syncSecurityTitle),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: Colors.green.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          lucide.Lucide.ShieldCheck,
                          size: 20,
                          color: Colors.green,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.syncE2EEncryption,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              l10n.syncE2EEncryptionDescription,
                              style: TextStyle(
                                fontSize: 13,
                                color: cs.onSurface.withOpacity(0.6),
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),

              // 消息提示
              if (syncProvider.message != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(lucide.Lucide.info, size: 18, color: cs.primary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          syncProvider.message!,
                          style: TextStyle(fontSize: 13, color: cs.primary),
                        ),
                      ),
                      GestureDetector(
                        onTap: () => syncProvider.clearMessage(),
                        child: Icon(
                          lucide.Lucide.X,
                          size: 16,
                          color: cs.primary.withOpacity(0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    bool obscureText = false,
    int maxLines = 1,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return TextField(
      controller: controller,
      obscureText: obscureText,
      maxLines: maxLines,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        filled: true,
        fillColor: isDark ? Colors.white.withOpacity(0.05) : Colors.grey.withOpacity(0.05),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: cs.outlineVariant.withOpacity(0.2),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(
            color: cs.outlineVariant.withOpacity(0.2),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: cs.primary),
        ),
      ),
    );
  }

  Future<void> _onConnect(SyncProvider syncProvider) async {
    final l10n = AppLocalizations.of(context)!;

    if (_urlController.text.isEmpty ||
        _anonKeyController.text.isEmpty ||
        _syncKeyController.text.isEmpty) {
      showAppSnackBar(context, message: l10n.syncWizardFillAllFields, type: NotificationType.error);
      return;
    }

    final result = await syncProvider.configure(
      supabaseUrl: _urlController.text.trim(),
      anonKey: _anonKeyController.text.trim(),
      syncKey: _syncKeyController.text,
    );

    if (!mounted) return;

    if (result.success) {
      showAppSnackBar(
        context,
        message: result.isFirstDevice == true
            ? l10n.syncWizardInitSuccess
            : l10n.syncWizardConnectSuccess,
        type: NotificationType.success,
      );
    } else {
      showAppSnackBar(
        context,
        message: result.errorMessage ?? l10n.syncWizardFailed,
        type: NotificationType.error,
      );
    }
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Future<bool?> _showResetConfirmDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;

    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: cs.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(l10n.syncResetConfirmTitle),
        content: Text(l10n.syncResetConfirmMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l10n.backupPageCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              l10n.syncResetButton,
              style: TextStyle(color: cs.error),
            ),
          ),
        ],
      ),
    );
  }
}

/// 桌面端按钮
class _DeskButton extends StatelessWidget {
  const _DeskButton({
    required this.label,
    required this.icon,
    this.onTap,
    this.outline = false,
    this.danger = false,
    this.busy = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final bool outline;
  final bool danger;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = danger ? cs.error : cs.primary;

    if (outline) {
      return OutlinedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16, color: color),
        label: Text(label, style: TextStyle(color: color)),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: color.withOpacity(0.5)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      );
    }

    return ElevatedButton.icon(
      onPressed: onTap,
      icon: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(icon, size: 16),
      label: Text(label),
      style: ElevatedButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }
}
