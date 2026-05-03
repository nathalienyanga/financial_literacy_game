import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:financial_literacy_game/l10n/app_localizations.dart';

import '../../domain/concepts/person.dart';
import '../../domain/utils/database.dart';
import '../../domain/utils/utils.dart';
import '../../domain/game_data_notifier.dart';

import '../../offline/offline_storage.dart';
import '../../offline/offline_sync.dart';
import '../../offline/progress_store.dart';
import '../../offline/uid_cache.dart';

import 'is_this_you_dialog.dart';
import 'menu_dialog.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SignInDialogNew extends ConsumerStatefulWidget {
  const SignInDialogNew({super.key});

  @override
  ConsumerState<SignInDialogNew> createState() => _SignInDialogNewState();
}

class _SignInDialogNewState extends ConsumerState<SignInDialogNew> {
  late TextEditingController uidTextController;
  bool isProcessing = false;

  @override
  void initState() {
    super.initState();
    uidTextController = TextEditingController();
  }

  @override
  void dispose() {
    uidTextController.dispose();
    super.dispose();
  }

  Future<Person?> findPerson({required String uid}) async {
    if (uid.length != 7) {
      showErrorSnackBar(
        context: context,
        errorMessage: AppLocalizations.of(context)!.enterUID,
      );
      return null;
    }

    // Try Firestore first, with a timeout so offline mode falls through quickly
    bool networkTimedOut = false;
    try {
      final person = await searchUserbyUIDInFirestore(uid)
          .timeout(const Duration(seconds: 5));
      if (person != null) {
        // Pre-seed local progress so getNextLevel has a SharedPreferences
        // fallback even if the network drops before IsThisYouDialog runs.
        ProgressStore.getNextLevel(uid); // fire-and-forget
        return person;
      }
    } catch (e) {
      debugPrint("Firestore lookup failed or timed out: $e");
      networkTimedOut = e is TimeoutException;
      // Fall through to offline lookup
    }

    // Fallback to offline CSV cache
    if (UIDCache.isValidOffline(uid)) {
      debugPrint("UID found in offline cache: $uid");
      return Person(
        firstName: UIDCache.getFirstName(uid) ?? "",
        lastName: UIDCache.getLastName(uid) ?? "",
        uid: uid,
      );
    }

    // UID not found anywhere — distinguish network error from genuinely missing UID
    if (mounted) {
      showErrorSnackBar(
        context: context,
        errorMessage: networkTimedOut
            ? "Network too slow. Check connection and try again."
            : "Code not found. Please check and try again.",
      );
    }
    return null;
  }

  Future<void> handleLogin(Person person, WidgetRef ref) async {
    // 1. Clear saved state
    await OfflineStorage.clearSimpleState();

    // 2. Remove session-specific keys only — preserve languageCode and
    //    per-UID level cache (nextLevel_*) so offline tablets can restore
    //    returning participants to the correct level on week 2+.
    final prefs = await SharedPreferences.getInstance();
    for (final key in const [
      'uid', 'personExists', 'firstName', 'lastName',
      'lastRoundNumber', 'lastSessionId', 'lastPlayedLevelID',
    ]) {
      await prefs.remove(key);
    }

    // 3. Reset game
    ref.read(gameDataNotifierProvider.notifier).resetGame();

    // 4. Show confirmation
    if (mounted) {
      Navigator.of(context).pop();
      showDialog(
        barrierDismissible: false,
        context: context,
        builder: (_) => IsThisYouDialog(person: person),
      );
    }

    // 5. Sync in background — do NOT await so the IsThisYouDialog appears
    //    immediately rather than waiting for Firestore on slow networks.
    OfflineSync.sync(person.uid ?? "NOUID");
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        MenuDialog(
          showCloseButton: false,
          title: AppLocalizations.of(context)!.titleSignIn.capitalize(),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: uidTextController,
                maxLength: 7,
                decoration:
                InputDecoration(hintText: AppLocalizations.of(context)!.hintUID),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp('[A-Z0-9]')),
                ],
              ),
            ],
          ),
          actions: [
            ElevatedButton(
              onPressed: isProcessing
                  ? null
                  : () async {
                setState(() => isProcessing = true);

                Person? user =
                await findPerson(uid: uidTextController.text);

                if (user != null) {
                  await handleLogin(user, ref);
                } else {
                  setState(() => isProcessing = false);
                }
              },
              child: Text(AppLocalizations.of(context)!.continueButton),
            ),
          ],
        ),

        if (isProcessing)
          const Center(child: CircularProgressIndicator()),
      ],
    );
  }
}
