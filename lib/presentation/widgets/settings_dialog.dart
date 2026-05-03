import 'package:financial_literacy_game/config/color_palette.dart';
import 'package:financial_literacy_game/domain/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:financial_literacy_game/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/game_data_notifier.dart';
import '../../domain/utils/database.dart';
import '../../offline/offline_storage.dart';
import '../../offline/offline_sync.dart';
import '../../offline/progress_store.dart';
import 'how_to_play_dialog.dart';
import 'language_selection_dialog.dart';
import 'menu_dialog.dart';
import 'sign_in_dialog_with_code.dart';

class SettingsDialog extends ConsumerWidget {
  const SettingsDialog({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MenuDialog(
      title: AppLocalizations.of(context)!.settings.capitalize(),
      content: SingleChildScrollView(
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              elevation: 5.0,
              backgroundColor: ColorPalette().buttonBackground,
              foregroundColor: ColorPalette().lightText,
            ),
            onPressed: () {
              Navigator.of(context).pop();
              showDialog(
                context: context,
                builder: (context) {
                  // returns the how to dialog
                  return const HowToPlayDialog();
                },
              );
            },
            child: Text(AppLocalizations.of(context)!.howToPlay),
          ),
          const SizedBox(height: 10),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              elevation: 5.0,
              backgroundColor: ColorPalette().buttonBackground,
              foregroundColor: ColorPalette().lightText,
            ),
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('New Player'),
                  content: const Text(
                    'This will save the current player\'s data and let a new player sign in.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('Continue'),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;

              // Sync current player's pending data before clearing
              final prefs = await SharedPreferences.getInstance();
              final uid = prefs.getString('uid');
              if (uid != null && uid.isNotEmpty) {
                await OfflineSync.sync(uid);
              }

              // Clear player identity but NOT the offline queue so that any
              // rounds that failed to sync can be retried on next sign-in.
              await OfflineStorage.clearSimpleState();
              await prefs.remove('uid');
              await prefs.remove('personExists');
              await prefs.remove('firstName');
              await prefs.remove('lastName');
              await prefs.remove('lastPlayedLevelID');
              await prefs.remove('lastRoundNumber');
              await prefs.remove('lastSessionId');
              clearSessionState();
              ref.read(gameDataNotifierProvider.notifier).resetGameLocalNoSave();

              if (context.mounted) {
                Navigator.of(context).pop(); // close settings
                showDialog(
                  barrierDismissible: false,
                  context: context,
                  builder: (_) => const SignInDialogNew(),
                );
              }
            },
            child: const Text('New Player'),
          ),
          const SizedBox(height: 10),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              elevation: 5.0,
              backgroundColor: Colors.green.shade700,
              foregroundColor: ColorPalette().lightText,
            ),
            onPressed: () async {
              // Show spinner while uploading
              showDialog(
                barrierDismissible: false,
                context: context,
                builder: (_) => const AlertDialog(
                  content: Row(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(width: 16),
                      Text('Uploading data…'),
                    ],
                  ),
                ),
              );
              final count = await OfflineSync.syncAll();
              if (context.mounted) Navigator.of(context).pop(); // close spinner
              if (context.mounted) {
                showDialog(
                  context: context,
                  builder: (_) => AlertDialog(
                    title: const Text('Upload Complete'),
                    content: Text(
                      count == 0
                          ? 'No pending data found.'
                          : 'Uploaded data for $count participant(s).',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(),
                        child: const Text('OK'),
                      ),
                    ],
                  ),
                );
              }
            },
            child: const Text('Upload All Data'),
          ),
          const SizedBox(height: 10),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              elevation: 5.0,
              backgroundColor: Colors.red.shade700,
              foregroundColor: ColorPalette().lightText,
            ),
            onPressed: () async {
              // Step 1 — warn if there is unsynced round data.
              final pendingCounts = await ProgressStore.allPendingCounts();
              if (!context.mounted) return;

              if (pendingCounts.isNotEmpty) {
                final totalRounds =
                    pendingCounts.values.fold(0, (a, b) => a + b);
                final choice = await showDialog<String>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('Unsynced Data Found'),
                    content: Text(
                      '~$totalRounds unsynced round(s) for '
                      '${pendingCounts.length} participant(s) '
                      'have not been uploaded yet.\n\n'
                      'Upload now to avoid losing research data.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(null),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop('skip'),
                        style: TextButton.styleFrom(
                            foregroundColor: Colors.red),
                        child: const Text('Clear Anyway'),
                      ),
                      ElevatedButton(
                        onPressed: () => Navigator.of(ctx).pop('sync'),
                        child: const Text('Upload & Clear'),
                      ),
                    ],
                  ),
                );
                if (!context.mounted || choice == null) return;

                if (choice == 'sync') {
                  showDialog(
                    barrierDismissible: false,
                    context: context,
                    builder: (_) => const AlertDialog(
                      content: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(width: 16),
                          Text('Uploading data…'),
                        ],
                      ),
                    ),
                  );
                  await OfflineSync.syncAll();
                  if (context.mounted) Navigator.of(context).pop();
                }
              }

              if (!context.mounted) return;

              // Step 2 — confirm.
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Clear Cache'),
                  content: const Text(
                    'Resets the current session.\n\n'
                    'Preserved: participant progress, language, '
                    'any remaining unsynced data.\n'
                    'Removed: current player identity and local '
                    'game state.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('Clear'),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;

              // Step 3 — scoped clear: remove only session-specific keys.
              // Preserved: offline_queue_*, nextLevel_*, languageCode,
              // countryCode, uid_cache* (all UID validation data).
              await OfflineStorage.clearSimpleState();
              await OfflineStorage.clearLastRound();
              final prefs = await SharedPreferences.getInstance();
              final keysToRemove = prefs.getKeys().where((k) =>
                !k.startsWith('offline_queue_') &&
                !k.startsWith('nextLevel_') &&
                !k.startsWith('uid_cache') &&
                k != 'languageCode' &&
                k != 'countryCode'
              ).toList();
              for (final k in keysToRemove) {
                await prefs.remove(k);
              }
              ref.read(gameDataNotifierProvider.notifier).resetGame();

              if (context.mounted) {
                Navigator.of(context).pop();
                showDialog(
                  barrierDismissible: false,
                  context: context,
                  builder: (_) => const SignInDialogNew(),
                );
              }
            },
            child: const Text('Clear Cache'),
          ),
          const SizedBox(height: 10),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              elevation: 5.0,
              backgroundColor: ColorPalette().buttonBackground,
              foregroundColor: ColorPalette().lightText,
            ),
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Restart Game'),
                  content: const Text(
                    'This will restart from the beginning for the current player.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('Restart'),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;
              ref.read(gameDataNotifierProvider.notifier).resetGame();
              if (context.mounted) Navigator.of(context).pop();
            },
            child: const Text('Restart Game'),
          ),
          const SizedBox(height: 10),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              elevation: 5.0,
              backgroundColor: ColorPalette().buttonBackground,
              foregroundColor: ColorPalette().lightText,
            ),
            onPressed: () {
              ref.read(gameDataNotifierProvider.notifier).moveToNextLevel();
              Navigator.of(context).pop();
            },
            child: Text(AppLocalizations.of(context)!.nextLevel.capitalize()),
          ),
          const SizedBox(height: 10),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              elevation: 5.0,
              backgroundColor: ColorPalette().buttonBackground,
              foregroundColor: ColorPalette().lightText,
            ),
            onPressed: () {
              Navigator.of(context).pop();
              showDialog(
                context: context,
                builder: (context) {
                  return LanguageSelectionDialog(
                    title: AppLocalizations.of(context)!
                        .languagesTitle
                        .capitalize(),
                  );
                },
              );
            },
            child:
                Text(AppLocalizations.of(context)!.languagesTitle.capitalize()),
          ),
        ],
      ),
      ),
    );
  }
}
