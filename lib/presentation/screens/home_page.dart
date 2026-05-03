import 'dart:async';
import 'dart:math';
import 'package:confetti/confetti.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:financial_literacy_game/l10n/app_localizations.dart';

import '../../config/color_palette.dart';
import '../../config/constants.dart';
import '../../domain/entities/levels.dart';
import '../../domain/game_data_notifier.dart';
import '../../domain/utils/device_and_personal_data.dart';
import '../../l10n/l10n.dart';
import '../../offline/offline_storage.dart';
import '../../offline/offline_sync.dart';
import '../../offline/progress_store.dart';
import '../../offline/uid_cache.dart';

// UI
import '../widgets/asset_content.dart';
import '../widgets/game_app_bar.dart';
import '../widgets/language_selection_dialog.dart';
import '../widgets/level_info_card.dart';
import '../widgets/loan_content.dart';
import '../widgets/overview_content.dart';
import '../widgets/section_card.dart';
import '../widgets/sign_in_dialog_with_code.dart';
import '../widgets/welcome_back_dialog.dart';

import 'package:shared_preferences/shared_preferences.dart';

class Homepage extends ConsumerStatefulWidget {
  const Homepage({Key? key}) : super(key: key);

  @override
  ConsumerState<Homepage> createState() => _HomepageState();
}

class _HomepageState extends ConsumerState<Homepage> with WidgetsBindingObserver {
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  bool _wasOffline = false;

  @override
  void initState() {
    super.initState();

    // Add lifecycle observer
    WidgetsBinding.instance.addObserver(this);

    // Watch for connectivity changes and auto-upload the moment wifi returns.
    _startConnectivityWatcher();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        // Initialize offline storage and load UID cache
        await OfflineStorage.initialize();
        await UIDCache.loadFromCSV();
        debugPrint("UID cache loaded: ${UIDCache.cachedCount} UIDs");

        /// --------------------------------------------------------
        /// Step 1: Device info only
        /// --------------------------------------------------------
        await getDeviceInfo();

        /// --------------------------------------------------------
        /// Step 2: Language selection (always required)
        /// --------------------------------------------------------
        final prefs = await SharedPreferences.getInstance();
        final storedLocale = prefs.getString("languageCode");

        if (storedLocale == null && mounted) {
          await showDialog(
            barrierDismissible: false,
            context: context,
            builder: (_) => LanguageSelectionDialog(
              title: AppLocalizations.of(context)!.languagesTitle,
            ),
          );
        }

        /// Apply selected locale
        final chosenLocale = await L10n.getSystemLocale();
        ref.read(gameDataNotifierProvider.notifier).setLocale(chosenLocale);

        /// --------------------------------------------------------
        /// Step 3: Flush any offline data from previous sessions
        /// Fire-and-forget so it doesn't block the UI.
        /// --------------------------------------------------------
        OfflineSync.syncAll();

        /// --------------------------------------------------------
        /// Step 4: Check if person exists
        /// --------------------------------------------------------
        final savedUID = prefs.getString('uid');
        final savedPersonExists = prefs.getBool('personExists') ?? false;

        if (savedUID != null && savedPersonExists) {
          bool personLoaded = await loadPerson(ref: ref);

          if (personLoaded) {
            // Try fast local read first.
            bool levelLoaded = await loadLevelIDFromLocal(ref: ref);

            if (!levelLoaded) {
              // lastPlayedLevelID was cleared (e.g. previous logout) — fall
              // back to ProgressStore so we can still show the right level.
              final progressLevel = await ProgressStore.getNextLevel(savedUID);
              if (progressLevel != null && progressLevel > 0 && mounted) {
                ref.read(gameDataNotifierProvider.notifier).loadLevel(progressLevel);
              }
              // Even if progressLevel is null, player is logged in → show
              // WelcomeBackDialog at Level 1 rather than forcing re-entry of UID.
              levelLoaded = true;
            }

            if (levelLoaded && mounted) {
              showDialog(
                barrierDismissible: false,
                context: context,
                builder: (_) => const WelcomeBackDialog(),
              );
              return;
            }
          }
        }

        /// --------------------------------------------------------
        /// Step 5: If no user → show Sign-in (UID)
        /// -------------------------------------------------------
        if (mounted) {
          showDialog(
            barrierDismissible: false,
            context: context,
            builder: (_) => const SignInDialogNew(),
          );
        }
      } catch (e, stack) {
        // If any startup step throws, always show sign-in so the app remains
        // usable rather than leaving a blank screen.
        debugPrint('Startup error: $e\n$stack');
        if (mounted) {
          showDialog(
            barrierDismissible: false,
            context: context,
            builder: (_) => const SignInDialogNew(),
          );
        }
      }
    });
  }

  /// Listens for network connectivity changes. Fires syncAll() automatically
  /// the moment the device transitions from offline → online so no round data
  /// is left waiting for a manual upload.
  void _startConnectivityWatcher() async {
    // Seed initial offline state so we only trigger on genuine transitions.
    try {
      final initial = await Connectivity().checkConnectivity();
      _wasOffline = _isOffline(initial);
    } catch (_) {}

    _connectivitySub = Connectivity().onConnectivityChanged.listen((results) {
      final nowOffline = _isOffline(results);
      if (!nowOffline && _wasOffline) {
        debugPrint("Connectivity restored — auto-uploading pending data...");
        OfflineSync.syncAll();
      }
      _wasOffline = nowOffline;
    });
  }

  static bool _isOffline(List<ConnectivityResult> results) {
    return results.isEmpty ||
        results.every((r) => r == ConnectivityResult.none);
  }

  @override
  void dispose() {
    _connectivitySub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.inactive:
        // App going to background - save state
        _saveGameState();
        break;

      case AppLifecycleState.resumed:
        // App returning to foreground - trigger sync
        _triggerSync();
        break;

      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // No action needed
        break;
    }
  }

  void _saveGameState() {
    debugPrint("App backgrounded - saving game state...");
    try {
      final gameData = ref.read(gameDataNotifierProvider);
      OfflineStorage.saveSimpleState({
        "cash": gameData.cash,
        "levelId": gameData.levelId,
        "period": gameData.period,
        "locale": gameData.locale.languageCode,
      });
      // Checkpoint: queue session summary so data isn't lost if app is killed
      ref.read(gameDataNotifierProvider.notifier).checkpointSessionSummary();
      debugPrint("Game state saved successfully");
    } catch (e) {
      debugPrint("Failed to save game state: $e");
    }
  }

  void _triggerSync() {
    debugPrint("App resumed - syncing all pending offline data...");
    OfflineSync.syncAll();
  }

  @override
  Widget build(BuildContext context) {
    final levelId = ref.watch(gameDataNotifierProvider).levelId;

    return Stack(
      children: [
        Scaffold(
          backgroundColor: ColorPalette().background,
          resizeToAvoidBottomInset: false,
          appBar: const GameAppBar(),
          body: SafeArea(
            child: SingleChildScrollView(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: playAreaMaxWidth),
                  child: Padding(
                    padding: const EdgeInsets.all(15),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // Two-column layout on tablets / wide screens
                        final isWide = constraints.maxWidth >= 700;
                        final gap = isWide ? 16.0 : 10.0;

                        final levelCard = LevelInfoCard(
                          currentCash: ref.watch(gameDataNotifierProvider).cash,
                          levelId: levelId,
                          nextLevelCash: levels[levelId].cashGoal,
                        );
                        final overviewSection = SectionCard(
                          title: AppLocalizations.of(context)!.overview.toUpperCase(),
                          content: const OverviewContent(),
                        );
                        final assetsSection = SectionCard(
                          title: AppLocalizations.of(context)!.assets.toUpperCase(),
                          content: const AssetContent(),
                        );
                        final loanSection = levelId > 1
                            ? SectionCard(
                                title: AppLocalizations.of(context)!.loan(2).toUpperCase(),
                                content: const LoanContent(),
                              )
                            : null;

                        if (isWide) {
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Left: progress + financial overview + loans
                              Expanded(
                                child: Column(
                                  children: [
                                    levelCard,
                                    SizedBox(height: gap),
                                    overviewSection,
                                    if (loanSection != null) ...[
                                      SizedBox(height: gap),
                                      loanSection,
                                    ],
                                  ],
                                ),
                              ),
                              SizedBox(width: gap),
                              // Right: animals / assets
                              Expanded(child: assetsSection),
                            ],
                          );
                        }

                        // Narrow / phone: single column
                        return Column(
                          children: [
                            levelCard,
                            SizedBox(height: gap),
                            overviewSection,
                            SizedBox(height: gap),
                            assetsSection,
                            if (loanSection != null) ...[
                              SizedBox(height: gap),
                              loanSection,
                            ],
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),

        /// Confetti
        Align(
          alignment: Alignment.topCenter,
          child: ConfettiWidget(
            confettiController:
            ref.watch(gameDataNotifierProvider).confettiController,
            shouldLoop: true,
            emissionFrequency: 0.03,
            numberOfParticles: 20,
            maxBlastForce: 25,
            minBlastForce: 7,
            gravity: 0.2,
            particleDrag: 0.05,
            blastDirection: pi,
            blastDirectionality: BlastDirectionality.explosive,
          ),
        ),
      ],
    );
  }
}


