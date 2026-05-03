import 'package:auto_size_text/auto_size_text.dart';
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
import 'sign_in_dialog_with_code.dart';

class WonGameDialog extends StatefulWidget {
  final WidgetRef ref;
  const WonGameDialog({
    required this.ref,
    super.key,
  });

  @override
  State<WonGameDialog> createState() => _WonGameDialogState();
}

class _WonGameDialogState extends State<WonGameDialog> {
  bool _isProcessing = false;

  Future<void> _returnToHomePage(BuildContext context) async {
    setState(() => _isProcessing = true);

    final prefs = await SharedPreferences.getInstance();
    final uid = prefs.getString('uid');

    await OfflineStorage.clearSimpleState();
    await prefs.remove('uid');
    await prefs.remove('personExists');
    await prefs.remove('firstName');
    await prefs.remove('lastName');
    await prefs.remove('lastRoundNumber');
    await prefs.remove('lastSessionId');
    await prefs.remove('lastPlayedLevelID');

    clearSessionState();
    widget.ref.read(gameDataNotifierProvider.notifier).resetGameLocalNoSave();

    // Show sign-in BEFORE popping so the game board is never exposed between dialogs.
    if (context.mounted) {
      showDialog(
        barrierDismissible: false,
        context: context,
        builder: (_) => const SignInDialogNew(),
      );
      Navigator.of(context).pop();
    }

    // Background: sync queue and mark session complete.
    if (uid != null && uid.isNotEmpty) {
      OfflineSync.sync(uid);
    }
    endCurrentGameSession(status: Status.won);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        AlertDialog(
          backgroundColor: ColorPalette().backgroundContentCard,
          title: Text(
            AppLocalizations.of(context)!.congratulations.capitalize(),
            style: TextStyle(
              color: ColorPalette().gameWinText,
              fontWeight: FontWeight.bold,
              fontSize: 22,
            ),
          ),
          content: SizedBox(
            height: 100,
            width: 100,
            child: AutoSizeText(
              AppLocalizations.of(context)!.gameFinished.capitalize(),
              style: TextStyle(
                fontSize: 20,
                height: 2,
                color: ColorPalette().gameWinText,
                fontStyle: FontStyle.normal,
              ),
            ),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: ColorPalette().buttonBackground,
                foregroundColor: ColorPalette().lightText,
              ),
              onPressed: _isProcessing
                  ? null
                  : () => _returnToHomePage(context),
              child: const Text('See You Next Week!'),
            ),
            TextButton(
              onPressed: _isProcessing
                  ? null
                  : () {
                      endCurrentGameSession(status: Status.won);
                      widget.ref.read(gameDataNotifierProvider.notifier).resetGame();
                      Navigator.pop(context);
                    },
              child: Text(
                AppLocalizations.of(context)!.restart.capitalize(),
                style: TextStyle(color: ColorPalette().darkText),
              ),
            ),
          ],
        ),
        if (_isProcessing)
          const Center(child: CircularProgressIndicator()),
      ],
    );
  }
}
