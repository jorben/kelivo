/// Kelivo 数据同步页面
///
/// 展示同步状态、配置同步服务

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/models/sync_config.dart';
import '../../../core/providers/sync_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../shared/widgets/snackbar.dart';
import 'sync_wizard_page.dart';

/// 数据同步页面
class SyncPage extends StatelessWidget {
  const SyncPage({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final syncProvider = context.watch<SyncProvider>();

    Widget header(String text, {bool first = false}) => Padding(
          padding: EdgeInsets.fromLTRB(12, first ? 2 : 18, 12, 6),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withOpacity(0.8),
            ),
          ),
        );

    Widget sectionCard({required List<Widget> children}) {
      final bg = isDark ? Colors.white10 : Colors.white.withOpacity(0.96);
      return Container(
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: cs.outlineVariant.withOpacity(isDark ? 0.08 : 0.06),
            width: 0.6,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: children),
        ),
      );
    }

    Widget divider() => Divider(
          height: 1,
          thickness: 0.5,
          indent: 52,
          color: cs.outlineVariant.withOpacity(isDark ? 0.1 : 0.08),
        );

    Widget infoRow(String label, String value, {IconData? icon}) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 20, color: cs.primary),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  color: cs.onSurface,
                ),
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 14,
                color: cs.onSurface.withOpacity(0.6),
              ),
            ),
          ],
        ),
      );
    }

    // 状态指示器
    Widget statusIndicator() {
      Color statusColor;
      String statusText;
      IconData statusIcon;

      switch (syncProvider.status) {
        case SyncStatus.notConfigured:
          statusColor = cs.outline;
          statusText = l10n.syncStatusNotConfigured;
          statusIcon = Lucide.CircleDashed;
          break;
        case SyncStatus.idle:
          statusColor = Colors.green;
          statusText = l10n.syncStatusIdle;
          statusIcon = Lucide.CircleCheck;
          break;
        case SyncStatus.syncing:
          statusColor = cs.primary;
          statusText = l10n.syncStatusSyncing;
          statusIcon = Lucide.RefreshCw;
          break;
        case SyncStatus.synced:
          statusColor = Colors.green;
          statusText = l10n.syncStatusSynced;
          statusIcon = Lucide.CircleCheck;
          break;
        case SyncStatus.error:
          statusColor = cs.error;
          statusText = l10n.syncStatusError;
          statusIcon = Lucide.CircleX;
          break;
        case SyncStatus.offline:
          statusColor = cs.outline;
          statusText = l10n.syncStatusOffline;
          statusIcon = Lucide.WifiOff;
          break;
      }

      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (syncProvider.status == SyncStatus.syncing)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: statusColor,
              ),
            )
          else
            Icon(statusIcon, size: 16, color: statusColor),
          const SizedBox(width: 6),
          Text(
            statusText,
            style: TextStyle(
              fontSize: 14,
              color: statusColor,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        // 未配置状态 - 显示设置向导入口
        if (!syncProvider.isConfigured) ...[
          header(l10n.syncSetupTitle, first: true),
          sectionCard(
            children: [
              Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: cs.primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(
                        Lucide.CloudUpload,
                        size: 32,
                        color: cs.primary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n.syncSetupDescription,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: cs.onSurface.withOpacity(0.7),
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      child: CupertinoButton(
                        color: cs.primary,
                        borderRadius: BorderRadius.circular(10),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        onPressed: () {
                          Haptics.light();
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => ChangeNotifierProvider.value(
                                value: syncProvider,
                                child: const SyncWizardPage(),
                              ),
                            ),
                          );
                        },
                        child: Text(
                          l10n.syncSetupButton,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],

        // 已配置状态 - 显示同步状态和操作
        if (syncProvider.isConfigured) ...[
          // 同步状态
          header(l10n.syncStatusTitle, first: true),
          sectionCard(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    Icon(Lucide.Activity, size: 20, color: cs.primary),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l10n.syncCurrentStatus,
                        style: TextStyle(fontSize: 15, color: cs.onSurface),
                      ),
                    ),
                    statusIndicator(),
                  ],
                ),
              ),
              divider(),
              infoRow(
                l10n.syncLastSyncTime,
                syncProvider.config.lastSyncAt != null
                    ? _formatDateTime(syncProvider.config.lastSyncAt!)
                    : l10n.syncNeverSynced,
                icon: Lucide.Clock,
              ),
              if (syncProvider.pendingChangesCount > 0) ...[
                divider(),
                infoRow(
                  l10n.syncPendingChanges,
                  syncProvider.pendingChangesCount.toString(),
                  icon: Lucide.Upload,
                ),
              ],
            ],
          ),

          const SizedBox(height: 12),

          // 操作按钮
          sectionCard(
            children: [
              _ActionRow(
                icon: Lucide.RefreshCw,
                label: l10n.syncNowButton,
                onTap: syncProvider.busy
                    ? null
                    : () async {
                        Haptics.light();
                        final result = await syncProvider.syncNow();
                        if (context.mounted) {
                          showAppSnackBar(
                            context,
                            message: result.success
                                ? l10n.syncSuccess
                                : (result.errorMessage ?? l10n.syncFailed),
                            type: result.success
                                ? NotificationType.success
                                : NotificationType.error,
                          );
                        }
                      },
                trailing: syncProvider.busy
                    ? const CupertinoActivityIndicator(radius: 10)
                    : null,
              ),
            ],
          ),

          const SizedBox(height: 12),

          // 安全信息
          header(l10n.syncSecurityTitle),
          sectionCard(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Lucide.ShieldCheck,
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
                              fontSize: 15,
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
              ),
            ],
          ),

          const SizedBox(height: 12),

          // 设置
          header(l10n.syncSettingsTitle),
          sectionCard(
            children: [
              _ActionRow(
                icon: Lucide.Settings,
                label: l10n.syncModifySettings,
                onTap: () {
                  Haptics.light();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => ChangeNotifierProvider.value(
                        value: syncProvider,
                        child: const SyncWizardPage(),
                      ),
                    ),
                  );
                },
              ),
              divider(),
              _ActionRow(
                icon: Lucide.Trash2,
                label: l10n.syncResetButton,
                labelColor: cs.error,
                onTap: () async {
                  Haptics.light();
                  final confirm = await _showResetConfirmDialog(context);
                  if (confirm == true && context.mounted) {
                    await syncProvider.reset();
                    showAppSnackBar(context, message: l10n.syncResetSuccess);
                  }
                },
              ),
            ],
          ),
        ],

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
                Icon(Lucide.info, size: 18, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    syncProvider.message!,
                    style: TextStyle(
                      fontSize: 13,
                      color: cs.primary,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => syncProvider.clearMessage(),
                  child: Icon(
                    Lucide.X,
                    size: 16,
                    color: cs.primary.withOpacity(0.6),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
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

/// 操作行组件
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.labelColor,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? labelColor;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = labelColor ?? cs.onSurface;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: labelColor ?? cs.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(fontSize: 15, color: color),
              ),
            ),
            if (trailing != null)
              trailing!
            else
              Icon(
                Lucide.ChevronRight,
                size: 18,
                color: cs.onSurface.withOpacity(0.3),
              ),
          ],
        ),
      ),
    );
  }
}
