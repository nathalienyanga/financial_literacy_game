import 'package:financial_literacy_game/domain/game_data_notifier.dart';
import 'package:financial_literacy_game/domain/utils/utils.dart';
import 'package:financial_literacy_game/presentation/widgets/sign_in_dialog_with_code.dart';
import 'package:flutter/material.dart';
import 'package:financial_literacy_game/l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../config/color_palette.dart';
import '../../domain/concepts/person.dart';
import '../../domain/entities/levels.dart';
import '../../domain/utils/database.dart';
import 'menu_dialog.dart';

class WelcomeBackDialog extends ConsumerStatefulWidget {
  const WelcomeBackDialog({Key? key}) : super(key: key);

  @override
  ConsumerState<WelcomeBackDialog> createState() => _WelcomeBackDialogState();
}

class _WelcomeBackDialogState extends ConsumerState<WelcomeBackDialog> {
  bool isClicked = false;
  @override
  Widget build(BuildContext context) {
    Person person = ref.read(gameDataNotifierProvider).person;

    // savedLevelId is the 0-indexed next level to play.
    // By design it coincides with the human-readable number of the last
    // completed level: completed Level 2 → savedLevelId = 2 → show
    // "Restart Level 2" and "Start Level 3".
    final int savedLevelId = ref.read(gameDataNotifierProvider).levelId;
    final bool hasCompletedAtLeastOne = savedLevelId > 0;
    final bool canPlayNext = savedLevelId < levels.length;

    final String displayFirst =
        (person.firstName?.isNotEmpty == true) ? person.firstName! : (person.uid ?? '');
    final String displayLast =
        (person.lastName?.isNotEmpty == true) ? person.lastName! : '';

    final buttonStyle = ElevatedButton.styleFrom(
      elevation: 5.0,
      backgroundColor: ColorPalette().buttonBackground,
      foregroundColor: ColorPalette().lightText,
    );

    return Stack(
      children: [
        MenuDialog(
          showCloseButton: false,
          title: AppLocalizations.of(context)!.welcomeBack(
              displayFirst.capitalize(), displayLast.capitalize()),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(AppLocalizations.of(context)!.sameUser(displayFirst)),
              const SizedBox(height: 10.0),
              if (hasCompletedAtLeastOne)
                Text(
                  'Your last session was Level $savedLevelId.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: ColorPalette().darkText,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              const SizedBox(height: 10.0),

              // ── START NEXT LEVEL button ───────────────────────────────
              // Game state is already loaded at savedLevelId (the next level).
              // Just reconnect and pop — do NOT call moveToNextLevel().
              if (canPlayNext) ...[
                ElevatedButton(
                  style: buttonStyle,
                  onPressed: isClicked
                      ? null
                      : () async {
                          setState(() { isClicked = true; });
                          try {
                            await reconnectToGameSession(person: person)
                                .timeout(const Duration(seconds: 2));
                          } catch (_) {}
                          if (context.mounted) Navigator.of(context).pop();
                        },
                  child: Text(
                    'Start Level ${savedLevelId + 1}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 10.0),
              ],

              // ── RESTART PREVIOUS LEVEL button ─────────────────────────
              // Only show when they have completed at least one level.
              if (hasCompletedAtLeastOne) ...[
                ElevatedButton(
                  style: buttonStyle,
                  onPressed: isClicked
                      ? null
                      : () async {
                          setState(() { isClicked = true; });
                          try {
                            await reconnectToGameSession(person: person)
                                .timeout(const Duration(seconds: 2));
                          } catch (_) {}
                          // savedLevelId used as the 1-indexed human level to restart;
                          // levels[savedLevelId - 1] is its 0-indexed Level config.
                          restartLevelFirebase(
                            level: savedLevelId,
                            startingCash: levels[savedLevelId - 1].startingCash,
                          );
                          ref
                              .read(gameDataNotifierProvider.notifier)
                              .loadLevel(savedLevelId - 1);
                          if (context.mounted) Navigator.of(context).pop();
                        },
                  child: Text(
                    'Restart Level $savedLevelId',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 10.0),
              ],

              // ── RESTART FROM LEVEL 1 button ───────────────────────────
              ElevatedButton(
                style: buttonStyle,
                onPressed: isClicked
                    ? null
                    : () async {
                        setState(() { isClicked = true; });
                        endCurrentGameSession(status: Status.abandoned, person: person);
                        ref.read(gameDataNotifierProvider.notifier).resetGame();
                        if (context.mounted) Navigator.of(context).pop();
                      },
                child: Text(AppLocalizations.of(context)!.restartGame.capitalize()),
              ),

              const SizedBox(height: 25.0),
              Text(AppLocalizations.of(context)!.signInDifferentPerson.capitalize()),
              const SizedBox(height: 10.0),

              // ── NOT ME button ─────────────────────────────────────────
              ElevatedButton(
                style: buttonStyle,
                onPressed: isClicked
                    ? null
                    : () {
                        setState(() { isClicked = true; });
                        Navigator.of(context).pop();
                        showDialog(
                          barrierDismissible: false,
                          context: context,
                          builder: (context) => const SignInDialogNew(),
                        );
                      },
                child: Text(AppLocalizations.of(context)!.notMe.capitalize()),
              ),
            ],
          ),
        ),
        if (isClicked) const Center(child: CircularProgressIndicator()),
      ],
    );
  }
}