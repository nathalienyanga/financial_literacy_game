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

                      try {
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

                        if (progressLevel != null && progressLevel > 0) {
                          // Returning player — load their verified next level.
                          ref.read(gameDataNotifierProvider.notifier).loadLevel(progressLevel);
                        } else if (!reconnected && progressLevel == null) {
                          // No session and no saved progress anywhere — first-time player.
                          // Register in Firestore when online; game is already at Level 1
                          // from handleLogin's resetGame().
                          saveUserInFirestore(person);
                        }

                        // Always show WelcomeBackDialog so the player can choose their
                        // starting level.  When progress can't be determined (offline /
                        // new device), this shows "Start Level 1" as a safe fallback
                        // rather than silently resetting without any dialog.
                        if (context.mounted) {
                          showDialog(
                            barrierDismissible: false,
                            context: context,
                            builder: (_) => const WelcomeBackDialog(),
                          );
                          Navigator.of(context).pop();
                        }
                      } catch (_) {
                        // If anything unexpected fails, re-enable the button so the
                        // player can try again rather than being permanently stuck.
                        if (mounted) setState(() { isProcessing = false; });
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
