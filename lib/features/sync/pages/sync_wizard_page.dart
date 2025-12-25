/// Kelivo 同步设置向导页面
///
/// 引导用户完成 Supabase 连接配置

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../icons/lucide_adapter.dart';
import '../../../l10n/app_localizations.dart';
import '../../../core/providers/sync_provider.dart';
import '../../../core/services/haptics.dart';
import '../../../shared/widgets/snackbar.dart';

/// 同步设置向导页面
class SyncWizardPage extends StatefulWidget {
  const SyncWizardPage({super.key});

  @override
  State<SyncWizardPage> createState() => _SyncWizardPageState();
}

class _SyncWizardPageState extends State<SyncWizardPage> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  final _anonKeyController = TextEditingController();
  final _syncKeyController = TextEditingController();

  bool _obscureSyncKey = true;
  int _currentStep = 0;

  @override
  void initState() {
    super.initState();
    // 如果已配置，加载现有配置
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final syncProvider = context.read<SyncProvider>();
      if (syncProvider.isConfigured) {
        _urlController.text = syncProvider.config.supabaseUrl ?? '';
        _anonKeyController.text = syncProvider.config.anonKey ?? '';
        _syncKeyController.text = syncProvider.config.syncKey ?? '';
      }
    });
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

    return Scaffold(
      backgroundColor: isDark ? Colors.black : const Color(0xFFF2F2F7),
      appBar: AppBar(
        backgroundColor: isDark ? Colors.black : const Color(0xFFF2F2F7),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Text(
          l10n.syncWizardTitle,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
        ),
      ),
      body: Form(
        key: _formKey,
        child: Stepper(
          currentStep: _currentStep,
          onStepContinue: () => _onStepContinue(syncProvider),
          onStepCancel: _onStepCancel,
          controlsBuilder: (context, details) {
            return Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Row(
                children: [
                  if (_currentStep < 2)
                    Expanded(
                      child: CupertinoButton(
                        color: cs.primary,
                        borderRadius: BorderRadius.circular(10),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        onPressed: syncProvider.busy
                            ? null
                            : details.onStepContinue,
                        child: Text(
                          l10n.syncWizardNext,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: CupertinoButton(
                        color: cs.primary,
                        borderRadius: BorderRadius.circular(10),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        onPressed: syncProvider.busy
                            ? null
                            : () => _onComplete(syncProvider),
                        child: syncProvider.busy
                            ? const CupertinoActivityIndicator(
                                color: Colors.white)
                            : Text(
                                l10n.syncWizardComplete,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                    ),
                  if (_currentStep > 0) ...[
                    const SizedBox(width: 12),
                    CupertinoButton(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(10),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                      onPressed: details.onStepCancel,
                      child: Text(
                        l10n.syncWizardBack,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
          steps: [
            // 步骤 1: Supabase 配置
            Step(
              title: Text(l10n.syncWizardStep1Title),
              subtitle: Text(l10n.syncWizardStep1Subtitle),
              isActive: _currentStep >= 0,
              state: _currentStep > 0 ? StepState.complete : StepState.indexed,
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildTextField(
                    controller: _urlController,
                    label: l10n.syncWizardUrlLabel,
                    hint: 'https://xxx.supabase.co',
                    icon: Lucide.Globe,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return l10n.syncWizardUrlRequired;
                      }
                      if (!value.startsWith('http')) {
                        return l10n.syncWizardUrlInvalid;
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  _buildTextField(
                    controller: _anonKeyController,
                    label: l10n.syncWizardAnonKeyLabel,
                    hint: 'eyJhbGciOiJIUzI1NiIs...',
                    icon: Lucide.KeyRound,
                    maxLines: 2,
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return l10n.syncWizardAnonKeyRequired;
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  _buildHelpText(
                    l10n.syncWizardStep1Help,
                    icon: Lucide.info,
                  ),
                ],
              ),
            ),

            // 步骤 2: 同步密钥
            Step(
              title: Text(l10n.syncWizardStep2Title),
              subtitle: Text(l10n.syncWizardStep2Subtitle),
              isActive: _currentStep >= 1,
              state: _currentStep > 1 ? StepState.complete : StepState.indexed,
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildTextField(
                    controller: _syncKeyController,
                    label: l10n.syncWizardSyncKeyLabel,
                    hint: l10n.syncWizardSyncKeyHint,
                    icon: Lucide.KeyRound,
                    obscureText: _obscureSyncKey,
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscureSyncKey ? Lucide.Eye : Lucide.EyeOff,
                        size: 20,
                      ),
                      onPressed: () {
                        setState(() => _obscureSyncKey = !_obscureSyncKey);
                      },
                    ),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return l10n.syncWizardSyncKeyRequired;
                      }
                      if (value.length < 8) {
                        return l10n.syncWizardSyncKeyTooShort;
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            final key = syncProvider.generateSyncKey();
                            _syncKeyController.text = key;
                            Haptics.light();
                          },
                          icon: const Icon(Lucide.Shuffle, size: 18),
                          label: Text(l10n.syncWizardGenerateKey),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final data =
                                await Clipboard.getData(Clipboard.kTextPlain);
                            if (data?.text != null) {
                              _syncKeyController.text = data!.text!;
                              Haptics.light();
                            }
                          },
                          icon: const Icon(Lucide.Clipboard, size: 18),
                          label: Text(l10n.syncWizardPasteKey),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _buildHelpText(
                    l10n.syncWizardStep2Help,
                    icon: Lucide.AlertTriangle,
                    color: cs.error,
                  ),
                ],
              ),
            ),

            // 步骤 3: 确认
            Step(
              title: Text(l10n.syncWizardStep3Title),
              subtitle: Text(l10n.syncWizardStep3Subtitle),
              isActive: _currentStep >= 2,
              state: _currentStep > 2 ? StepState.complete : StepState.indexed,
              content: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildSummaryCard(
                    icon: Lucide.Globe,
                    label: l10n.syncWizardUrlLabel,
                    value: _urlController.text,
                  ),
                  const SizedBox(height: 12),
                  _buildSummaryCard(
                    icon: Lucide.KeyRound,
                    label: l10n.syncWizardSyncKeyLabel,
                    value: '••••••••',
                  ),
                  const SizedBox(height: 16),
                  _buildHelpText(
                    l10n.syncWizardStep3Help,
                    icon: Lucide.info,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    String? Function(String?)? validator,
    bool obscureText = false,
    Widget? suffixIcon,
    int maxLines = 1,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return TextFormField(
      controller: controller,
      validator: validator,
      obscureText: obscureText,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, size: 20),
        suffixIcon: suffixIcon,
        filled: true,
        fillColor: isDark ? Colors.white10 : Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: cs.outlineVariant.withOpacity(0.2),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: cs.outlineVariant.withOpacity(0.2),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: cs.primary),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: cs.error),
        ),
      ),
    );
  }

  Widget _buildHelpText(String text, {IconData? icon, Color? color}) {
    final cs = Theme.of(context).colorScheme;
    final textColor = color ?? cs.onSurface.withOpacity(0.6);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 16, color: textColor),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 13,
              color: textColor,
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryCard({
    required IconData icon,
    required String label,
    required String value,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? Colors.white10 : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outlineVariant.withOpacity(0.2),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: cs.primary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: cs.onSurface.withOpacity(0.6),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 14,
                    color: cs.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _onStepContinue(SyncProvider syncProvider) {
    if (_currentStep == 0) {
      // 验证 Supabase 配置
      if (_urlController.text.isEmpty || _anonKeyController.text.isEmpty) {
        showAppSnackBar(
          context,
          message: AppLocalizations.of(context)!.syncWizardFillAllFields,
          type: NotificationType.error,
        );
        return;
      }
    } else if (_currentStep == 1) {
      // 验证同步密钥
      if (_syncKeyController.text.isEmpty) {
        showAppSnackBar(
          context,
          message: AppLocalizations.of(context)!.syncWizardSyncKeyRequired,
          type: NotificationType.error,
        );
        return;
      }
      if (_syncKeyController.text.length < 8) {
        showAppSnackBar(
          context,
          message: AppLocalizations.of(context)!.syncWizardSyncKeyTooShort,
          type: NotificationType.error,
        );
        return;
      }
    }

    if (_currentStep < 2) {
      setState(() => _currentStep++);
    }
  }

  void _onStepCancel() {
    if (_currentStep > 0) {
      setState(() => _currentStep--);
    }
  }

  Future<void> _onComplete(SyncProvider syncProvider) async {
    final l10n = AppLocalizations.of(context)!;

    Haptics.light();

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
      Navigator.of(context).pop();
    } else {
      showAppSnackBar(
        context,
        message: result.errorMessage ?? l10n.syncWizardFailed,
        type: NotificationType.error,
      );
    }
  }
}
