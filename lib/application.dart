import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:fl_clash/bootstrap.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/common/network_recovery.dart';
import 'package:fl_clash/common/system_dns.dart';
import 'package:fl_clash/common/window.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/manager/hotkey_manager.dart';
import 'package:fl_clash/manager/manager.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/pages.dart';

Widget buildManagerStack({
  required bool isDesktop,
  required Future<void> Function(List<ConnectivityResult> results)
  onConnectivityChanged,
  Stream<ProcessSignal>? terminateSignals,
  VoidCallback? onHostNetworkChanged,
  required Widget child,
}) {
  final platformApp = isDesktop
      ? WindowHeaderContainer(child: child)
      : VpnManager(child: child);
  final state = AppStateManager(
    child: CoreManager(
      child: ConnectivityManager(
        onConnectivityChanged: onConnectivityChanged,
        onHostNetworkChanged: onHostNetworkChanged,
        child: platformApp,
      ),
    ),
  );
  final platformState = isDesktop
      ? WindowManager(
          terminateSignals: terminateSignals,
          child: TrayManager(
            child: HotKeyManager(child: ProxyManager(child: state)),
          ),
        )
      : AndroidManager(child: TileManager(child: state));
  return AppEnvManager(
    child: LocaleManager(child: ThemeManager(child: platformState)),
  );
}

class Application extends ConsumerStatefulWidget {
  const Application({super.key});

  @override
  ConsumerState<Application> createState() => ApplicationState();
}

class ApplicationState extends ConsumerState<Application> {
  Timer? _autoUpdateProfilesTaskTimer;
  bool _preHasVpn = false;
  NetworkRecovery? _networkRecovery;
  String? _previousNetwork;
  // Windows can only watch SIGINT and SIGHUP.
  final _terminateSignals = system.isDesktop && !system.isWindows
      ? ProcessSignal.sigterm.watch()
      : null;

  @override
  void initState() {
    super.initState();
    if (system.isMacOS) {
      _networkRecovery = NetworkRecovery(
        isEnabled: () => mounted && _canRecoverNetwork,
        recover: _recoverNetwork,
      );
      ref.listenManual(isStartProvider, (_, next) {
        if (!next) _networkRecovery?.cancel();
      });
      ref.listenManual(suspendProvider, (_, next) {
        if (next) _networkRecovery?.cancel();
      });
    }
    SystemNavigator.setFrameworkHandlesBack(true);
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) async {
      if (globalState.navigatorKey.currentContext != null) {
        await bootstrap.attach();
      } else {
        exit(0);
      }
      _autoUpdateProfilesTask();
      _initLink();
      if (!safeModeBuild) {
        unawaited(app?.initShortcuts());
      }
    });
  }

  void _initLink() {
    linkManager.initAppLinksListen((url) async {
      unawaited(window?.show());
      final message = currentAppLocalizations.createProfileFromUrlTip(url);
      final parts = message.split(url);
      final res = await dialogs.showMessage(
        title: currentAppLocalizations.addProfile,
        message: TextSpan(
          children: [
            TextSpan(text: parts.first),
            TextSpan(
              text: url,
              style: TextStyle(
                color: context.colorScheme.primary,
                decoration: TextDecoration.underline,
                decorationColor: context.colorScheme.primary,
              ),
            ),
            if (parts.length > 1) TextSpan(text: parts.last),
          ],
        ),
      );
      if (res != true) return;
      unawaited(
        ref.read(profilesActionProvider.notifier).addProfileFromLink(url),
      );
    });
  }

  void _autoUpdateProfilesTask() {
    _autoUpdateProfilesTaskTimer = Timer(const Duration(minutes: 20), () async {
      await ref.read(profilesActionProvider.notifier).autoUpdateProfiles();
      await ref.read(resourcesActionProvider.notifier).autoUpdate();
      await ref.read(mitmModulesActionProvider.notifier).autoUpdate();
      if (!mounted) {
        return;
      }
      _autoUpdateProfilesTask();
    });
  }

  Future<void> _handleConnectivityChanged(
    List<ConnectivityResult> results,
  ) async {
    commonPrint.log('connectivityChanged ${results.toString()}');
    unawaited(systemDnsCoordinator?.resync() ?? Future.value());
    unawaited(ref.read(systemActionProvider.notifier).updateLocalIp());
    if (_networkRecovery case final recovery?) {
      final network = _physicalNetwork(results);
      final previous = _previousNetwork;
      _previousNetwork = network;
      if (network.isEmpty) {
        recovery.cancel();
      } else if (previous != null && previous != network) {
        recovery.request();
      }
    }
    final hasVpn = results.contains(ConnectivityResult.vpn);
    if (_preHasVpn == hasVpn) {
      ref.read(routeTrackerProvider.notifier).bumpHostEpoch();
      // Android's NetworkObserver tells the Core about a new network itself.
      if (system.isDesktop && !system.isMacOS) {
        debouncer.call(
          FunctionTag.networkChange,
          ref.read(coreActionProvider.notifier).reportNetworkChange,
          duration: const Duration(milliseconds: 200),
        );
      }
    }
    _preHasVpn = hasVpn;
  }

  bool get _canRecoverNetwork =>
      ref.read(initProvider) &&
      ref.read(isStartProvider) &&
      !ref.read(suspendProvider) &&
      !ref.read(safeModeProvider);

  String _physicalNetwork(List<ConnectivityResult> results) {
    final networks =
        results
            .where(
              (result) =>
                  result != ConnectivityResult.none &&
                  result != ConnectivityResult.vpn,
            )
            .map((result) => result.name)
            .toSet()
            .toList()
          ..sort();
    return networks.join(',');
  }

  Future<bool> _recoverNetwork() async {
    try {
      final network = await Connectivity().checkConnectivity();
      if (!mounted || !_canRecoverNetwork) return true;
      if (_physicalNetwork(network).isEmpty) return false;
      if (ref.read(coreStatusProvider) == CoreStatus.connecting) return false;
      if (!await ref.read(coreActionProvider.notifier).recoverCore()) {
        return false;
      }
      if (!mounted || !_canRecoverNetwork) return true;
      ref.read(routeTrackerProvider.notifier).bumpHostEpoch();
      await systemProxyQueue?.apply(ref.read(proxyStateProvider));
      await systemDnsCoordinator?.resync();
      commonPrint.log('Network recovery completed');
      return true;
    } catch (error) {
      commonPrint.log(
        'Network recovery failed: $error',
        logLevel: LogLevel.warning,
      );
      return false;
    }
  }

  @override
  Widget build(context) {
    return Consumer(
      builder: (_, ref, child) {
        final locale = ref.watch(
          appSettingProvider.select((state) => state.locale),
        );
        final themeProps = ref.watch(themeSettingProvider);
        final textScale = themeProps.textScale;
        return PrismApp(
          debugShowCheckedModeBanner: false,
          navigatorKey: globalState.navigatorKey,
          onNavigationNotification: (_) => true,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            AppUiLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          builder: (context, child) {
            return buildManagerStack(
              isDesktop: system.isDesktop,
              onConnectivityChanged: _handleConnectivityChanged,
              onHostNetworkChanged: system.isMacOS
                  ? _networkRecovery?.request
                  : null,
              terminateSignals: _terminateSignals,
              child: child!,
            );
          },
          title: appName,
          locale: getLocaleForString(locale),
          supportedLocales: AppLocalizations.delegate.supportedLocales,
          themeMode: themeProps.themeMode,
          theme: watchAppTheme(ref, Brightness.light),
          darkTheme: watchAppTheme(ref, Brightness.dark),
          textScale: textScale.enable ? textScale.scale : null,
          minTextScale: minTextScale,
          maxTextScale: maxTextScale,
          liquidGlass: switch (themeProps.liquidGlass) {
            LiquidGlassMode.none => null,
            LiquidGlassMode.ultra => LiquidGlassQuality.ultra,
            LiquidGlassMode.standard => LiquidGlassQuality.standard,
          },
          emojiFont: (family: FontFamily.twEmoji.value, pattern: emojiPattern),
          stackedBanners: !ref.watch(isMobileViewProvider),
          bannerTopInset: ref.watch(overlayTopOffsetProvider),
          remoteFocus: system.isTV,
          floatingKeyboard: app?.floatingKeyboard,
          onGenerateRoute: (settings) => HomeRoute(
            settings: settings,
            builder: (_) => KeyboardInsetHold(child: child!),
          ),
        );
      },
      child: const HomePage(),
    );
  }

  @override
  void dispose() {
    _networkRecovery?.dispose();
    linkManager.destroy();
    _autoUpdateProfilesTaskTimer?.cancel();
    super.dispose();
  }
}
