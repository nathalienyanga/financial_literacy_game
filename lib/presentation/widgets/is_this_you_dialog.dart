import 'package:financial_literacy_game/presentation/widgets/sign_in_dialog_with_code.dart';
import 'package:financial_literacy_game/presentation/widgets/welcome_back_dialog.dart';
import 'package:flutter/material.dart';
import 'package:financial_literacy_game/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/color_palette.dart';
import '../../domain/concepts/person.dart';
import '../../domain/game_data_notifier.dart';
import '../../domain/utils/database.dart';
import '../../domain/utils/device_and_personal_data.dart';
import '../../offline/progress_store.dart';
import 'menu_dialog.dart';

class IsThisYouDialog extends ConsumerStatefulWidget {
  final Person person;
  const IsThisYouDialog({required this.person, Key? key}) : super(key: key);

  @override
  ConsumerState<IsThisYouDialog> createState() => _IsThisYouDialogState();
}

class _IsThisYouDialogState extends ConsumerState<IsThisYouDialog> {
  bool isProcessing = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final firstName = widget.person.firstName ?? '';
    final lastName = widget.person.lastName ?? '';
    final hasName = firstName.isNotEmpty || lastName.isNotEmpty;
    final displayFirst = hasName ? firstName : (widget.person.uid ?? '');
    final displayLast = hasName ? lastName : '';
    return Stack(
      children: [
        MenuDialog(
          showCloseButton: false,
          title: AppLocalizations.of(context)!.confirmNameTitle,
          content: Text(AppLocalizations.of(context)!
              .confirmName(displayFirst, displayLast)),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                elevation: 5.0,
                backgroundColor: ColorPalette().buttonBackground,
                foregroundColor: ColorPalette().lightText,
              ),
              onPressed: () {
                Navigator.of(context).pop();
                showDialog(
                  barrierDismissible: false,
                  context: context,
                  builder: (context) {
                    return const SignInDialogNew();
                  },
                );
              },
              child: Text(
                AppLocalizations.of(context)!.noButton,
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                elevation: 5.0,
                backgroundColor: ColorPalette().buttonBackground,
                foregroundColor: ColorPalette().lightText,
              ),
              onPressed: isProcessing
                  ? null
                  : () async {
                      setState(() { isProcessing = true; });

                      final person = widget.person;

                      // Save person locally and set in state
                      ref.read(gameDataNotifierProvider.notifier).setPerson(person);
                      await savePersonLocally(person);

                      // Reconnect to the most recent Firestore game session so
                      // subsequent round writes land in the right document.
                      bool reconnected = false;
                      try {
                        reconnected = await reconnectToGameSession(person: person)
                            .timeout(const Duration(seconds: 3));
                      } catch (_) {}

                      // Read authoritative next level from ProgressStore.
                      // Checks Firestore first (server → SDK cache → local prefs)
                      // and resolves any cross-device conflict with "max level wins".
                      final progressLevel =
                          await ProgressStore.getNextLevel(person.uid ?? '');

                      bool isReturningUser = false;

                      if (progressLevel != null && progressLevel > 0) {
                        // Returning player with recorded progress.
                        ref.read(gameDataNotifierProvider.notifier).loadLevel(progressLevel);
                        isReturningUser = true;
                      } else if (reconnected) {
                        // Existing Firestore session but no progress doc yet —
                        // player is at or below Level 1.  Keep the resetGame()
                        // state (Level 1) and show the welcome-back screen.
                        isReturningUser = true;
                      } else {
                        // Brand-new player — register in Firestore when online.
                        saveUserInFirestore(person);
                        ref.read(gameDataNotifierProvider.notifier).resetGame();
                      }

                      if (context.mounted) {
                        // Push WelcomeBackDialog BEFORE popping so the game
                        // screen is never exposed between the two dialogs.
                        if (isReturningUser) {
                          showDialog(
                            barrierDismissible: false,
                            context: context,
                            builder: (_) => const WelcomeBackDialog(),
                          );
                        }
                        Navigator.of(context).pop();
                      }
                    },
              child: Text(AppLocalizations.of(context)!.yesButton),
            ),
          ],
        ),
        if (isProcessing)
          const Align(
            alignment: Alignment.center,
            child: CircularProgressIndicator(),
          ),
      ],
    );
  }
}
