import 'package:financial_literacy_game/domain/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:financial_literacy_game/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/color_palette.dart';
import '../../domain/entities/levels.dart';
import '../../domain/game_data_notifier.dart';
import '../../domain/utils/database.dart';
import '../../offline/offline_storage.dart';
import '../../offline/offline_sync.dart';
import '../../offline/progress_store.dart';
import 'menu_dialog.dart';
import 'sign_in_dialog_with_code.dart';

class NextLevelDialog extends StatelessWidget {
  final WidgetRef ref;
  const NextLevelDialog({
    required this.ref,
    super.key,
  });

  Future<void> _endSession(BuildContext context) async {
    // Capture the NEXT level before any async work so the player can
    // continue from it when they sign in again.
    final completedLevelId = ref.read(gameDataNotifierProvider).levelId;
    final nextLevelId = (completedLevelId + 1).clamp(0, levels.length - 1);
    final weekNumber = completedLevelId + 1; // level 0 = week 1

    // Show "See you next week!" before clearing anything.
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('See you next week!'),
          content: Text(
            'Week $weekNumber is done. Great work! Your progress has been saved.',
          ),
          actions: [
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }

    if (!context.mounted) return;

    final prefs = await SharedPreferences.getInstance();
    final uid = prefs.getString('uid');

    // Persist next level to Firestore (offline-queued) + local prefs.
    if (uid != null && uid.isNotEmpty) {
      await ProgressStore.recordLevelComplete(uid: uid, nextLevelId: nextLevelId);
    }
    await prefs.setInt('lastCompletedWeek', weekNumber);

    // Clear player identity but NOT the offline queue so that any
    // rounds that failed to sync can be retried when this player signs in again.
    await OfflineStorage.clearSimpleState();
    await prefs.remove('uid');
    await prefs.remove('personExists');
    await prefs.remove('firstName');
    await prefs.remove('lastName');
    await prefs.remove('lastRoundNumber');
    await prefs.remove('lastSessionId');

    // Reset in memory immediately so the next player sees a clean state.
    ref.read(gameDataNotifierProvider.notifier).resetGameLocalNoSave();

    // Show sign-in BEFORE popping so the game board is never exposed between dialogs.
    if (context.mounted) {
      showDialog(
        barrierDismissible: false,
        context: context,
        builder: (_) => const SignInDialogNew(),
      );
      Navigator.of(context).pop();
    }

    // Background: sync queue and mark level complete in Firestore.
    if (uid != null && uid.isNotEmpty) {
      OfflineSync.sync(uid);
    }
    newLevelFirestore(
      levelID: nextLevelId,
      startingCash: levels[nextLevelId].startingCash,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MenuDialog(
      showCloseButton: false,
      title: AppLocalizations.of(context)!.congratulations.capitalize(),
      content: Text(
        AppLocalizations.of(context)!.reachedNextLevel.capitalize(),
        style: TextStyle(
          fontSize: 20,
          color: ColorPalette().darkText,
          fontStyle: FontStyle.normal,
        ),
      ),
      actions: [
        // Continue at current level — marks level solved as acknowledged so
        // the dialog does not re-appear on every subsequent round.
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: ColorPalette().buttonBackground,
            foregroundColor: ColorPalette().lightText,
          ),
          onPressed: () {
            Navigator.pop(context);
            ref
                .read(gameDataNotifierProvider.notifier)
                .acknowledgeCurrentLevelSolved();
          },
          child: const Text('Continue Playing'),
        ),
        Builder(builder: (context) {
          final currentLevelId = ref.read(gameDataNotifierProvider).levelId;
          final nextDisplay    = currentLevelId + 2; // 0-indexed → 1-indexed next
          return ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: ColorPalette().buttonBackground,
              foregroundColor: ColorPalette().lightText,
            ),
            onPressed: () {
              ref.read(gameDataNotifierProvider.notifier).moveToNextLevel();
              Navigator.pop(context);
            },
            child: Text('Go to Level $nextDisplay'),
          );
        }),
        TextButton(
          onPressed: () => _endSession(context),
          child: Text(
            'Done for the week',
            style: TextStyle(color: ColorPalette().darkText),
          ),
        ),
      ],
    );
  }
}
