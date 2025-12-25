/// Kelivo 数据管理页面
///
/// Tab 切换展示"数据同步"和"数据备份"两个子页面

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/app_localizations.dart';
import '../../../core/providers/sync_provider.dart';
import '../../backup/pages/backup_page.dart';
import 'sync_page.dart';

/// 数据管理页面（移动端）
///
/// 使用 Tab 切换展示数据同步和数据备份功能
class DataManagementPage extends StatefulWidget {
  const DataManagementPage({super.key});

  @override
  State<DataManagementPage> createState() => _DataManagementPageState();
}

class _DataManagementPageState extends State<DataManagementPage>
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

    return Scaffold(
      backgroundColor: isDark ? Colors.black : const Color(0xFFF2F2F7),
      appBar: AppBar(
        backgroundColor: isDark ? Colors.black : const Color(0xFFF2F2F7),
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          centerTitle: true,
          title: Text(
            l10n.settingsPageDataSync,
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
          ),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                color: isDark ? Colors.white10 : Colors.white.withOpacity(0.96),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: cs.outlineVariant.withOpacity(isDark ? 0.08 : 0.06),
                  width: 0.6,
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
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                tabs: [
                  Tab(text: l10n.settingsPageDataSync),
                  Tab(text: l10n.settingsPageBackup),
                ],
              ),
            ),
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: const [
            SyncPage(),
            BackupPageContent(),
          ],
        ),
      );
  }
}

/// 备份页面内容（不含 AppBar，用于嵌入 Tab）
class BackupPageContent extends StatelessWidget {
  const BackupPageContent({super.key});

  @override
  Widget build(BuildContext context) {
    // 复用原有的 BackupPage 内容
    // 由于 BackupPage 是完整页面，这里创建一个简化版本
    return const BackupPage();
  }
}
