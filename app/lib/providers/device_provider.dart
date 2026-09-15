import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:omi/backend/http/api/device.dart';
import 'package:omi/backend/http/api/integrations.dart';
import 'package:omi/gen/pigeon_communicator.g.dart';
import 'package:omi/utils/l10n_extensions.dart';
import 'package:omi/backend/preferences.dart';
import 'package:omi/services/auth_service.dart';
import 'package:omi/services/devices/connectors/limitless_connection.dart';
import 'package:omi/services/capture/capture_controller.dart';
import 'package:omi/backend/schema/bt_device/bt_device.dart';
import 'package:omi/app_globals.dart';
import 'package:omi/pages/home/firmware_update.dart';
import 'package:omi/pages/home/omiglass_ota_update.dart';
import 'package:omi/providers/capture_provider.dart';
import 'package:omi/providers/local_recordings_provider.dart';
import 'package:omi/services/devices.dart';
import 'package:omi/services/devices/connectors/device_connection.dart';
import 'package:omi/services/devices/connectors/omi_connection.dart';
import 'package:omi/services/bridges/ble_bridge.dart';
import 'package:omi/services/services.dart';
import 'package:omi/services/battery_widget_service.dart';
import 'package:omi/services/wals/wal_syncs.dart';
import 'package:omi/services/wals/recording_transfer_coordinator.dart';
import 'package:omi/utils/device.dart';
import 'package:omi/utils/firmware_update_build_policy.dart';
import 'package:omi/utils/firmware_update_check_session.dart';
import 'package:omi/utils/firmware_update_prompt_coordinator.dart';
import 'package:omi/utils/logger.dart';
import 'package:omi/utils/other/debouncer.dart';
import 'package:omi/utils/platform/platform_manager.dart';
import 'package:omi/widgets/confirmation_dialog.dart';

typedef BleDiagnosticsLoader = Future<BleDeviceDiagnostics> Function(String deviceId);

class DeviceProvider extends ChangeNotifier implements IDeviceServiceSubsciption {
  CaptureProvider? captureProvider;
  LocalRecordingsProvider? localRecordingsProvider;

  bool isConnecting = false;
  bool isConnected = false;
  bool isDeviceStorageSupport = false;
  bool supportsMultiFileSync = SharedPreferencesUtil().deviceSupportsMultiFileSync;

  // Latest on-device ring-buffer storage snapshot (firmware 3.0.20+ only).
  // Surfaced on the Auto Sync page as a storage-usage indicator. Null when the
  // device predates the ring protocol or hasn't been read yet.
  RingStatus? _ringStatus;
  RingStatus? get ringStatus => _ringStatus;

  BtDevice? connectedDevice;
  BtDevice? pairedDevice;
  DateTime? _deviceSessionStartedAt;
  final BleDiagnosticsLoader _bleDiagnosticsLoader;
  StreamSubscription<List<int>>? _bleBatteryLevelListener;
  StreamSubscription? _bleChargingStatusListener;
  int batteryLevel = -1;
  bool isCharging = false;
  int _lastNotifiedBatteryLevel = -1;
  DateTime? _lastBatteryNotifyTime;
  bool _havingNewFirmware = false;
  bool get havingNewFirmware =>
      _havingNewFirmware && pairedDevice != null && isConnected && _allowsFirmwareUpdateForPairedDevice;

  // Track firmware update state to prevent showing dialog during updates
  final FirmwareUpdateCheckSessionGuard _firmwareUpdateCheckSessionGuard = FirmwareUpdateCheckSessionGuard();
  FirmwareUpdateCheckSession? _checkingFirmwareSession;
  String? _firmwareUpdateDeviceId;
  final FirmwareUpdatePromptCoordinator _firmwareUpdatePromptCoordinator = FirmwareUpdatePromptCoordinator();
  bool _pairingLostDialogShowing = false;
  bool _isFirmwareUpdateInProgress = false;
  bool get isFirmwareUpdateInProgress => _isFirmwareUpdateInProgress;

  // Current and latest firmware versions for UI display
  String get currentFirmwareVersion => pairedDevice?.firmwareRevision ?? 'Unknown';
  String _latestFirmwareVersion = '';
  String get latestFirmwareVersion => _latestFirmwareVersion;

  // Latest stable firmware version (for rollback comparison)
  String _latestStableFirmwareVersion = '';
  String get latestStableFirmwareVersion => _latestStableFirmwareVersion;

  // OmiGlass firmware update details from GitHub releases
  Map<String, dynamic> _latestOmiGlassFirmwareDetails = {};
  Map<String, dynamic> get latestOmiGlassFirmwareDetails => _latestOmiGlassFirmwareDetails;

  Timer? _discoveryTimer;

  // SIMONSBOOKCLUB: the link watchdog (2026-09-11).
  //
  // CaptureController's audio watchdog only runs while recordingState is
  // deviceRecord AND _recordingDevice is set, so it cannot help the state
  // Simon hit today: the app alive and uploading health for six hours with no
  // BLE link at all and nothing streaming. Meanwhile the pendant recorded to
  // its own flash until it filled and blinked red, and that audio never
  // reached anywhere.
  //
  // This one is independent of capture state and runs for the life of the
  // provider: if a device is paired and no audio has arrived for a while,
  // rebuild the transport. Backed off hard, because forcing cancels the
  // native auto-reconnect that usually does this job — and because a pendant
  // that is simply off should not be chased every minute.
  static const Duration _linkCheckEvery = Duration(minutes: 1);
  static const Duration _deafFor = Duration(minutes: 5);
  Timer? _linkWatchdogTimer;
  DateTime? _lastForcedRebuildAt;
  DateTime? _lastStorageCheckAt;

  // Overnight drain (2026-09-12).
  //
  // The pendant records to flash continuously and frees a page only when the
  // phone acknowledges it, so the drain has to keep pace with real life or the
  // device fills and stops recording — which is what kept happening. The Dart
  // drain is foreground-only, so it never runs while the phone is in a pocket
  // or on a nightstand. The NATIVE engine (LimitlessFlashDrainEngine) does
  // survive backgrounding, and it was gated behind Transcribe Later.
  //
  // The charger is the right moment to let it run: the pendant is not being
  // worn, so nothing live is lost by putting it in download mode. A Limitless
  // exposes no charging characteristic — only battery level — so charging is
  // inferred from the level going UP, which a worn device's never does.
  /// Last moment the pendant answered anything — a battery reading or a
  /// storage status. The drain must never arm on a link that merely looks
  /// connected.
  DateTime? _lastPendantReplyAt;
  static const Duration _proofOfLifeWithin = Duration(minutes: 15);
  /// When this provider came up. A fresh launch has no audio history, and
  /// "no audio yet" must not read as "idle for half an hour".
  final DateTime _startedAt = DateTime.now();
  /// Mirrored into SharedPreferences ('overnightDrainActive') so the capture
  /// controller and the native layer can read it without importing this.
  /// Forty-five minutes, and not before midnight.
  ///
  /// The drain takes the pendant's link over completely — while it runs, no
  /// live audio arrives, which also means the "live audio resumed" check below
  /// can never fire and it stays on until morning. So it must not be running
  /// while anyone is still talking. Simon and Masha say "What Went Well" as the
  /// last thing before sleep with the pendant on its charger beside them, and
  /// an 11pm window could arm on a quiet half-hour of reading and swallow the
  /// whole ritual. Midnight still leaves seven hours to drain in.
  static const Duration _idleForDrain = Duration(minutes: 45);
  bool _overnightDrainOn = false;
  static const Duration _storageCheckEvery = Duration(minutes: 10);
  int _forcedRebuilds = 0;
  final Debouncer _disconnectDebouncer = Debouncer(delay: const Duration(milliseconds: 500));
  final Debouncer _connectDebouncer = Debouncer(delay: const Duration(milliseconds: 100));

  void Function(BtDevice device)? onDeviceConnected;
  void Function(BtDevice device, int fileCount, int totalBytes)? onOfflineDataDetected;

  DeviceProvider({BleDiagnosticsLoader? bleDiagnosticsLoader})
      : _bleDiagnosticsLoader = bleDiagnosticsLoader ?? BleHostApi().getDeviceDiagnostics {
    // The drain flag outlives the process in SharedPreferences; the field that
    // owns it does not. After a relaunch the two disagree — memory says off,
    // so nothing ever turns the pref off — and the native engine keeps
    // consuming every packet all day. Every process starts with it off.
    SharedPreferencesUtil().saveBool('overnightDrainActive', false);
    ServiceManager.instance().device.subscribe(this, this);
    BleBridge.instance.pairingLostCallback = _showPairingLostDialog;
    _startLinkWatchdog();
  }

  void _startLinkWatchdog() {
    _linkWatchdogTimer?.cancel();
    _linkWatchdogTimer = Timer.periodic(_linkCheckEvery, (_) => _checkLink());
  }

  /// Rebuild a link that has gone quiet, whatever the app thinks its state is.
  ///
  /// Deliberately does NOT consult isConnected or connectedDevice: the whole
  /// failure is that both stay true through a half-dead link, which is why
  /// initiateConnection — the only other caller that forces — returns at its
  /// first line and never gets here. Audio arriving is the only honest
  /// evidence the link works.
  Future<void> _checkLink() async {
    final deviceId = SharedPreferencesUtil().btDevice.id;
    if (deviceId.isEmpty) return;
    if (!AuthService.instance.isSignedIn()) return;

    final now = DateTime.now();

    // Read how full the pendant is on a slow cadence, whatever the stream is
    // doing. Checking this only on a stall was wrong: a pendant worn all day
    // streams happily until the moment it is full, so the flag that lets the
    // drain run alongside live audio would never be set until recording had
    // already stopped. Simon's filled twice on 2026-09-11 with four days of
    // un-drained backlog on it.
    if (_lastStorageCheckAt == null || now.difference(_lastStorageCheckAt!) >= _storageCheckEvery) {
      _lastStorageCheckAt = now;
      unawaited(refreshLimitlessStoragePressure());
    }

    final lastAudioMs = CaptureController.lastLiveAudioAtMs;
    _considerOvernightDrain(now, lastAudioMs);

    // A pendant on its charger is silent by design. Rebuilding its link every
    // few minutes because no audio was arriving tore down the very drain that
    // silence exists for: 37 relay sessions on the night of 2026-09-12, zero
    // frames, zero chunks drained.
    if (_overnightDrainOn) return;

    if (lastAudioMs > 0 && now.millisecondsSinceEpoch - lastAudioMs < _deafFor.inMilliseconds) {
      _forcedRebuilds = 0;
      return;
    }

    // 2, 4, 8, then 15 minutes apart. A pendant left on the side table should
    // cost a handful of attempts an hour, not sixty.
    final backoff = Duration(minutes: min(15, 1 << (min(_forcedRebuilds, 3) + 1)));
    if (_lastForcedRebuildAt != null && now.difference(_lastForcedRebuildAt!) < backoff) return;
    _lastForcedRebuildAt = now;
    _forcedRebuilds++;

    // A stalled stream means the pendant is recording to its own flash. Read
    // how full it is before rebuilding, so the drain is allowed to run.
    unawaited(refreshLimitlessStoragePressure());
    Logger.warning('[LinkWatchdog] no BLE audio; rebuilding the link to $deviceId (attempt $_forcedRebuilds)');
    try {
      await ServiceManager.instance().device.ensureConnection(deviceId, force: true);
    } catch (e) {
      Logger.debug('[LinkWatchdog] forced rebuild failed: $e');
    }
  }

  void _showPairingLostDialog() {
    if (_pairingLostDialogShowing) return;
    final context = globalNavigatorKey.currentContext;
    if (context == null || !context.mounted) return;

    _pairingLostDialogShowing = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => ConfirmationDialog(
        title: dialogContext.l10n.bluetooth,
        description: dialogContext.l10n.deviceUnpairedMessage,
        confirmText: dialogContext.l10n.gotIt,
        onConfirm: () => Navigator.of(dialogContext).pop(),
        onCancel: () {},
      ),
    ).whenComplete(() => _pairingLostDialogShowing = false);
  }

  void setProviders(CaptureProvider provider, LocalRecordingsProvider recordingsProvider) {
    captureProvider = provider;
    localRecordingsProvider = recordingsProvider;
    notifyListeners();
  }

  Future<void> setConnectedDevice(BtDevice? device) async {
    final endedDevice = device == null ? (pairedDevice ?? connectedDevice) : null;
    final sessionStartedAt = _deviceSessionStartedAt;
    final now = DateTime.now();
    final isNewConnection = device != null && connectedDevice?.id != device.id;
    connectedDevice = device;
    pairedDevice = device;
    if (isNewConnection) {
      if (_firmwareUpdateDeviceId != null && _firmwareUpdateDeviceId != device.id) {
        _firmwareUpdatePromptCoordinator.clearAvailableVersion(invalidateDeferral: true);
      }
      _firmwareUpdateDeviceId = device.id;
      _firmwareUpdateCheckSessionGuard.start(device.id);
      _deviceSessionStartedAt = now;
    } else if (device == null) {
      _firmwareUpdateCheckSessionGuard.invalidate();
      _deviceSessionStartedAt = null;
    }
    await getDeviceInfo();
    if (isNewConnection) {
      PlatformManager.instance.analytics.deviceConnected(device);
    }
    if (device != null) {
      final firstPairedAt = await _markDevicePaired(device.id);
      if (firstPairedAt != null) {
        PlatformManager.instance.analytics.devicePaired(firstPairedAt);
      }
    }
    if (endedDevice != null && sessionStartedAt != null) {
      BleDisconnectEvent? disconnect;
      try {
        final diagnostics = await _bleDiagnosticsLoader(endedDevice.id);
        final sessionStartMs = sessionStartedAt.millisecondsSinceEpoch;
        for (final event in diagnostics.disconnectHistory.reversed) {
          if (event.timestamp >= sessionStartMs) {
            disconnect = event;
            break;
          }
        }
      } catch (_) {
        // Native diagnostics are best-effort; local timing still makes the event useful.
      }
      PlatformManager.instance.analytics.deviceSessionEnded(
        device: endedDevice,
        duration: disconnect != null && disconnect.connectionDurationMs > 0
            ? Duration(milliseconds: disconnect.connectionDurationMs)
            : now.difference(sessionStartedAt),
        reason: disconnect?.reason,
        hciReasonCode: disconnect?.reasonCode,
      );
    }
    Logger.debug('setConnectedDevice: $device');
    notifyListeners();
  }

  Future<String?> _markDevicePaired(String deviceId) async {
    final preferences = SharedPreferencesUtil();
    final uid = preferences.uid;
    if (uid.isEmpty || deviceId.isEmpty) return null;

    final pairedDevicesKey = 'pairedDeviceIds:$uid';
    final pairedDeviceIds = preferences.getStringList(pairedDevicesKey);
    if (pairedDeviceIds.contains(deviceId)) return null;

    final firstPairedAtKey = 'firstPairedAt:$uid';
    var firstPairedAt = preferences.getString(firstPairedAtKey);
    if (firstPairedAt.isEmpty) {
      firstPairedAt = DateTime.now().toUtc().toIso8601String();
      await preferences.saveString(firstPairedAtKey, firstPairedAt);
    }
    if (!await preferences.saveStringList(pairedDevicesKey, [...pairedDeviceIds, deviceId])) return null;
    return preferences.uid == uid ? firstPairedAt : null;
  }

  Future getDeviceInfo() async {
    if (connectedDevice != null) {
      if (pairedDevice?.firmwareRevision != null && pairedDevice?.firmwareRevision != 'Unknown') {
        SharedPreferencesUtil().btDevice = pairedDevice!;
        return;
      }
      var connection = await ServiceManager.instance().device.ensureConnection(connectedDevice!.id);
      pairedDevice = await connectedDevice?.getDeviceInfo(connection);
      SharedPreferencesUtil().btDevice = pairedDevice!;
    } else {
      if (SharedPreferencesUtil().btDevice.id.isEmpty) {
        pairedDevice = BtDevice.empty();
      } else {
        pairedDevice = SharedPreferencesUtil().btDevice;
      }
    }
    notifyListeners();
  }

  Future _bleDisconnectDevice(BtDevice btDevice) async {
    await ServiceManager.instance().device.disconnectDevice();
  }

  Future<int> _retrieveBatteryLevel(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return -1;
    }
    return connection.retrieveBatteryLevel();
  }

  Future<StreamSubscription<List<int>>?> _getBleBatteryLevelListener(
    String deviceId, {
    void Function(int)? onBatteryLevelChange,
  }) async {
    {
      var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
      if (connection == null) {
        return Future.value(null);
      }
      return connection.getBleBatteryLevelListener(onBatteryLevelChange: onBatteryLevelChange);
    }
  }

  Future<List<int>> _getStorageList(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return [];
    }
    return connection.getStorageList();
  }

  initiateBleBatteryListener() async {
    if (connectedDevice == null) {
      return;
    }
    _bleBatteryLevelListener?.cancel();
    _bleBatteryLevelListener = await _getBleBatteryLevelListener(
      connectedDevice!.id,
      onBatteryLevelChange: (int value) {
        batteryLevel = value;
        _noteBattery(value);
        BatteryWidgetService().updateBatteryInfo(
          deviceName: connectedDevice?.name ?? '',
          batteryLevel: value,
          deviceType: connectedDevice?.type.name ?? 'omi',
          isConnected: true,
        );
        // SIMONSBOOKCLUB: no pendant battery notifications, low or full.
        //
        // The low one fired far too often. Its guard cleared whenever the
        // reading rose above 20, and a battery hovering there reads 19, 21, 19
        // all evening — a fresh notification on every dip. Reconnecting rebuilt
        // this listener and cleared the guard as well, and the pendant
        // reconnects constantly. The level is still tracked everywhere it is
        // shown: the widget, the tile, the telemetry. It just does not interrupt.
        // Throttle notifyListeners to reduce battery drain from excessive UI rebuilds
        // Only notify when: first reading, >=5% change, 15min elapsed, or crosses 20% threshold
        final delta = (_lastNotifiedBatteryLevel - value).abs();
        final elapsed = _lastBatteryNotifyTime == null
            ? const Duration(minutes: 999)
            : DateTime.now().difference(_lastBatteryNotifyTime!);
        final crossedLowBatteryThreshold =
            (value < 20 && _lastNotifiedBatteryLevel >= 20) || (value >= 20 && _lastNotifiedBatteryLevel < 20);
        final shouldNotify =
            _lastNotifiedBatteryLevel == -1 || delta >= 5 || elapsed.inMinutes >= 15 || crossedLowBatteryThreshold;
        if (shouldNotify) {
          _lastNotifiedBatteryLevel = value;
          _lastBatteryNotifyTime = DateTime.now();
          notifyListeners();
        }
      },
    );
    notifyListeners();
  }

  /// The second way in, which does not depend on the battery at all.
  ///
  /// Night plus a long silence is the honest description of "on the
  /// nightstand", and it holds whether or not it is charging — Simon only
  /// charges when it is nearly dead, so "battery rising" was the wrong tell.
  ///
  /// Silence alone is not enough, though. A half-dead link — ACL up, nothing
  /// answering — looks exactly the same: connected, quiet. Arming on it would
  /// switch off the three watchdogs that exist to cure it, for the whole
  /// night and the whole morning. So the pendant must also have answered
  /// something recently, over a path the drain engine never touches.
  void _considerOvernightDrain(DateTime now, int lastAudioMs) {
    final sinceStart = now.difference(_startedAt);
    final quietMs = lastAudioMs > 0 ? now.millisecondsSinceEpoch - lastAudioMs : sinceStart.inMilliseconds;
    final night = now.hour >= 0 && now.hour < 7;
    if (!_overnightDrainOn) {
      final heard = _lastPendantReplyAt != null && now.difference(_lastPendantReplyAt!) <= _proofOfLifeWithin;
      if (night &&
          sinceStart >= _idleForDrain &&
          quietMs >= _idleForDrain.inMilliseconds &&
          connectedDevice != null &&
          heard) {
        _setOvernightDrain(true, 'night, no audio for ${quietMs ~/ 60000} min');
      }
      return;
    }
    // Morning ends it whatever else is true. Every other stop waits on a
    // notification the pendant may not send for hours (the battery moves
    // about 1%/h worn) or ever (a link gone deaf), and a flag left on into
    // the day mutes the pendant: the native engine consumes every packet.
    if (!night) {
      _setOvernightDrain(false, 'morning');
      return;
    }
    // Live audio coming back means it is on him again. The drain itself
    // produces no live audio, so this cannot be tripped by the drain.
    if (lastAudioMs > 0 && quietMs < const Duration(minutes: 2).inMilliseconds) {
      _setOvernightDrain(false, 'live audio resumed');
    }
  }

  /// A battery reading is proof the link is alive: it arrives over the
  /// standard battery service, which the drain engine never consumes.
  ///
  /// The battery used to arm and stop the drain too. "Rising" could arm it
  /// in daytime on a gauge blip and silence every watchdog for hours;
  /// "fell 2%" tripped on a nightstand's own slow discharge and flapped the
  /// drain a few times a night, each flap cutting a file. Neither survives.
  void _noteBattery(int level) {
    if (level < 0) return;
    _lastPendantReplyAt = DateTime.now();
  }

  void _setOvernightDrain(bool on, String why) {
    if (_overnightDrainOn == on) return;
    _overnightDrainOn = on;
    // The native engine reads this straight out of UserDefaults on its own
    // 90-second cycle; nothing else has to be running for it to act.
    SharedPreferencesUtil().saveBool('overnightDrainActive', on);
    Logger.warning('[OvernightDrain] ${on ? 'starting' : 'stopping'}: $why');
    // The phone's debug log never leaves the phone, which is why the first
    // overnight run could only be diagnosed by inference. Report each change
    // to the server so the next morning can be read, not guessed.
    unawaited(reportPendantDrainState({
      'on': on,
      'why': why,
      'battery': batteryLevel,
      'at': DateTime.now().toUtc().toIso8601String(),
    }).catchError((_) => false));
    notifyListeners();
  }

  /// Whether the pendant is currently draining itself on the charger.
  bool get overnightDrainRunning => _overnightDrainOn;

  Future<void> initiateChargingStatusListener() async {
    if (connectedDevice == null) return;
    _bleChargingStatusListener?.cancel();

    var connection = await ServiceManager.instance().device.ensureConnection(connectedDevice!.id);
    if (connection == null) return;
    if (connection is! OmiDeviceConnection) return;

    final currentStatus = await connection.readChargingStatus();
    if (isCharging != currentStatus) {
      isCharging = currentStatus;
      notifyListeners();
    }

    _bleChargingStatusListener = await connection.getChargingStatusListener(
      onChargingStatusChange: (bool charging) {
        if (isCharging != charging) {
          isCharging = charging;
          notifyListeners();
        }
      },
    );
  }

  /// Updates battery level with throttling logic. Returns true if notifyListeners was called.
  /// This method is exposed for testing the throttling behavior.
  @visibleForTesting
  bool updateBatteryLevelForTesting(int value, {DateTime? now}) {
    batteryLevel = value;
    final currentTime = now ?? DateTime.now();

    // Throttle notifyListeners to reduce battery drain from excessive UI rebuilds
    // Only notify when: first reading, >=5% change, 15min elapsed, or crosses 20% threshold
    final delta = (_lastNotifiedBatteryLevel - value).abs();
    final elapsed =
        _lastBatteryNotifyTime == null ? const Duration(minutes: 999) : currentTime.difference(_lastBatteryNotifyTime!);
    final crossedLowBatteryThreshold =
        (value < 20 && _lastNotifiedBatteryLevel >= 20) || (value >= 20 && _lastNotifiedBatteryLevel < 20);
    final shouldNotify =
        _lastNotifiedBatteryLevel == -1 || delta >= 5 || elapsed.inMinutes >= 15 || crossedLowBatteryThreshold;
    if (shouldNotify) {
      _lastNotifiedBatteryLevel = value;
      _lastBatteryNotifyTime = currentTime;
      notifyListeners();
      return true;
    }
    return false;
  }

  /// Resets battery throttling state for testing.
  @visibleForTesting
  void resetBatteryThrottlingForTesting() {
    _lastNotifiedBatteryLevel = -1;
    _lastBatteryNotifyTime = null;
  }

  /// Kicks off a single connection attempt. Native handles auto-reconnect after this.
  Future<void> initiateConnection(String caller, {bool boundDeviceOnly = false}) async {
    final pairedDeviceId = SharedPreferencesUtil().btDevice.id;

    // Already connected — nothing to do
    if (isConnected || connectedDevice != null) return;

    // No paired device (onboarding) — start periodic scanning so devices
    // turned on after the page loads are still discovered.
    if (pairedDeviceId.isEmpty) {
      if (boundDeviceOnly) return;
      _startDiscoveryScanning();
      return;
    }

    // Known device — use ensureConnection which creates the NativeBleTransport,
    // then connects natively. If native is already connected, it just re-notifies Dart.
    // force: true ensures we retry even if a previous attempt left a stale connection.
    try {
      await ServiceManager.instance().device.ensureConnection(pairedDeviceId, force: true);
    } catch (e) {
      // Timeout or transport failure — native keeps trying in the background.
      // NativeBleTransport's BleBridge registration persists, so auto-reconnect still works.
      Logger.debug('initiateConnection ($caller): ensureConnection failed: $e');
    }
  }

  void _startDiscoveryScanning() {
    _discoveryTimer?.cancel();
    _runDiscoveryScan();
    _discoveryTimer = Timer.periodic(const Duration(seconds: 10), (_) => _runDiscoveryScan());
  }

  Future<void> _runDiscoveryScan() async {
    if (SharedPreferencesUtil().btDevice.id.isNotEmpty || isConnected) {
      _discoveryTimer?.cancel();
      return;
    }
    final deviceService = ServiceManager.instance().device;
    if (deviceService.status == DeviceServiceStatus.ready) {
      try {
        await deviceService.discover();
      } catch (e) {
        Logger.debug('_runDiscoveryScan: discover failed: $e');
      }
    }
  }

  Future scanAndConnectToDevice() async {
    updateConnectingStatus(true);
    if (isConnected && connectedDevice != null) {
      updateConnectingStatus(false);
      return;
    }

    final pairedDeviceId = SharedPreferencesUtil().btDevice.id;
    if (pairedDeviceId.isEmpty) {
      updateConnectingStatus(false);
      return;
    }

    try {
      var connection = await ServiceManager.instance().device.ensureConnection(pairedDeviceId, force: true);
      if (connection != null) {
        await setConnectedDevice(connection.device);
        setisDeviceStorageSupport();
        SharedPreferencesUtil().deviceName = connection.device.name;
        setIsConnected(true);
      }
    } catch (e) {
      Logger.debug('scanAndConnectToDevice: connection failed: $e');
    }

    updateConnectingStatus(false);
    notifyListeners();
  }

  void updateConnectingStatus(bool value) {
    isConnecting = value;
    notifyListeners();
  }

  /// Process-wide mirror of [isConnected], for code with no BuildContext.
  /// SyncProvider reads it to keep the offline drain from starving live
  /// audio on the shared BLE link (see sync_provider.dart).
  static bool deviceIsConnected = false;

  /// True when the pendant's flash is close to full. SyncProvider drops the
  /// wait-for-a-quiet-link rule while this holds: a full pendant records
  /// NOTHING (it blinks red and stops — live 2026-09-01, after six hours
  /// with no app to drain it), which is strictly worse than the drain and
  /// live audio sharing bandwidth for a while.
  static bool deviceStorageUnderPressure = false;

  static const double _storagePressureThreshold = 0.75;

  static void _updateStoragePressure(RingStatus? status) {
    if (status == null) return;
    final used = status.usedBytes < 0 ? 0 : status.usedBytes;
    final free = status.freeBytes < 0 ? 0 : status.freeBytes;
    final total = used + free;
    if (total <= 0) return;
    deviceStorageUnderPressure = used / total >= _storagePressureThreshold;
  }

  /// The same judgement for a Limitless pendant, which reports pages rather
  /// than a RingStatus.
  ///
  /// This flag is the one thing that lets the drain run while live audio is
  /// arriving (sync_provider.dart's autoUploadEnabled), and it was written
  /// for "a nearly-full pendant blinks red". But it was only ever set from a
  /// RingStatus, which LimitlessDeviceConnection never returns — so on the
  /// pendant that actually blinks red it was permanently false. On
  /// 2026-09-11 the device filled with six hours on it and the escape hatch
  /// built for exactly that could not fire.
  static void _updateStoragePressureFromPages(Map<String, int>? status) {
    if (status == null) return;
    final free = status['free_capture_pages'];
    final total = status['total_capture_pages'];
    if (free == null || total == null || total <= 0) return;
    final used = (total - free).clamp(0, total);
    deviceStorageUnderPressure = used / total >= _storagePressureThreshold;
  }

  /// Read the pendant's own page counters and update the pressure flag.
  /// Cheap (one GATT round trip, 3s timeout) and safe to call on connect and
  /// whenever the audio stream stalls.
  Future<void> refreshLimitlessStoragePressure() async {
    final id = connectedDevice?.id ?? SharedPreferencesUtil().btDevice.id;
    if (id.isEmpty) return;
    try {
      final conn = await ServiceManager.instance().device.ensureConnection(id);
      if (conn is! LimitlessDeviceConnection) return;
      _updateStoragePressureFromPages(await conn.getStorageStatus());
      // getStorageStatus hands back its cached answer on a timeout, so the
      // return value is not evidence of life; the reply stamp is.
      final reply = conn.lastStatusReplyAt;
      if (reply != null && (_lastPendantReplyAt == null || reply.isAfter(_lastPendantReplyAt!))) {
        _lastPendantReplyAt = reply;
      }
      if (deviceStorageUnderPressure) {
        Logger.warning('[Storage] pendant flash is filling — letting the drain run alongside live audio');
      }
    } catch (e) {
      Logger.debug('refreshLimitlessStoragePressure: $e');
    }
  }

  void setIsConnected(bool value) {
    isConnected = value;
    deviceIsConnected = value;
    if (isConnected) {
      _discoveryTimer?.cancel();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _firmwareUpdatePromptCoordinator.invalidatePresentation();
    if (BleBridge.instance.pairingLostCallback == _showPairingLostDialog) {
      BleBridge.instance.pairingLostCallback = null;
    }
    _bleBatteryLevelListener?.cancel();
    _bleChargingStatusListener?.cancel();
    _discoveryTimer?.cancel();
    _linkWatchdogTimer?.cancel();
    _disconnectDebouncer.cancel();
    _connectDebouncer.cancel();
    ServiceManager.instance().device.unsubscribe(this);
    super.dispose();
  }

  void onDeviceDisconnected() async {
    _setOvernightDrain(false, 'device disconnected');
    _lastPendantReplyAt = null;
    Logger.debug('onDisconnected inside: $connectedDevice');
    _havingNewFirmware = false;
    _firmwareUpdatePromptCoordinator.invalidatePresentation();
    _bleChargingStatusListener?.cancel();
    isCharging = false;
    setConnectedDevice(null);
    setisDeviceStorageSupport();
    setIsConnected(false);
    updateConnectingStatus(false);

    captureProvider?.updateRecordingDevice(null);

    // Batch mode: the native writer finalizes the in-progress recording on
    // disconnect (.bin.part -> .bin). Rescan shortly after the rename completes
    // so the new recording shows up in the conversations list.
    Future.delayed(const Duration(seconds: 1), () {
      localRecordingsProvider?.refresh();
    });

    // Wals
    ServiceManager.instance().wal.getSyncs().sdcard.setDevice(null);
    ServiceManager.instance().wal.getSyncs().flashPage.setDevice(null);

    PlatformManager.instance.crashReporter.logInfo('Chronicle Device Disconnected');

    PlatformManager.instance.analytics.deviceDisconnected();
    BatteryWidgetService().updateBatteryInfo(
      deviceName: SharedPreferencesUtil().deviceName,
      batteryLevel: -1,
      deviceType: 'omi',
      isConnected: false,
    );

    // Notify interactive device onboarding of disconnect
    captureProvider?.deviceOnboardingProvider?.onDeviceDisconnected();
  }

  Future<(String, bool, String, Map)> shouldUpdateFirmware() async {
    if (pairedDevice == null || connectedDevice == null) {
      return ('No paired device is connected', false, '', {});
    }

    var device = pairedDevice!;
    if (device.firmwareRevision.isEmpty) {
      // BLE read of the firmware-revision characteristic failed. Skip the
      // upgrade check rather than asking the backend what's "newer than
      // unknown" — that path returns a misleading legacy version.
      return ('Unable to determine current firmware version', false, '', {});
    }
    var latestFirmwareDetails = await getLatestFirmwareVersion(
      deviceModelNumber: device.modelNumber,
      firmwareRevision: device.firmwareRevision,
      hardwareRevision: device.hardwareRevision,
      manufacturerName: device.manufacturerName,
    );

    // This backend has no firmware catalogue: the endpoint answers 200 with
    // an empty object, every field is optional, and the check therefore used
    // to report "your device is up to date" on every single connection —
    // a green tick that had checked nothing. Say what is true instead.
    if (latestFirmwareDetails.isEmpty || latestFirmwareDetails['version'] == null) {
      return ('Firmware updates are not managed by this app', false, '', {});
    }

    var (message, hasUpdate, version) = await DeviceUtils.shouldUpdateFirmware(
      currentFirmware: device.firmwareRevision,
      latestFirmwareDetails: latestFirmwareDetails,
    );
    return (message, hasUpdate, version, latestFirmwareDetails);
  }

  void _onDeviceConnected(BtDevice device) async {
    Logger.debug('_onConnected inside: $connectedDevice');
    final deviceSetup = setConnectedDevice(device);
    final connectionSession = _firmwareUpdateCheckSessionGuard.capture();
    await deviceSetup;
    if (connectionSession == null || !_isCurrentDeviceSession(connectionSession)) {
      Logger.debug('Discarding device setup continuation from a stale connection session');
      return;
    }

    if (captureProvider != null) {
      captureProvider?.updateRecordingDevice(device);
    }

    setisDeviceStorageSupport();
    setIsConnected(true);

    // Read initial battery level
    int currentLevel = await _retrieveBatteryLevel(device.id);
    if (currentLevel != -1) {
      batteryLevel = currentLevel;
      BatteryWidgetService().updateBatteryInfo(
        deviceName: device.name,
        batteryLevel: currentLevel,
        deviceType: device.type.name,
        isConnected: true,
      );
    }

    // Then set up listeners for battery changes and charging status
    await initiateBleBatteryListener();
    await initiateChargingStatusListener();
    if (batteryLevel != -1 && batteryLevel < 20) {
    }
    updateConnectingStatus(false);
    await captureProvider?.streamDeviceRecording(device: device);

    await getDeviceInfo();
    SharedPreferencesUtil().deviceName = device.name;

    // Wals — pass the firmware resolved by getDeviceInfo() above so background
    // discovery routes ring-buffer devices correctly; `device` here is the raw
    // connect object whose firmwareRevision is often still 'Unknown'.
    final syncs = ServiceManager.instance().wal.getSyncs();
    syncs.setDevice(device, firmwareVersion: currentFirmwareVersion);
    syncs.sdcard.setDevice(device);
    syncs.flashPage.setDevice(device);
    syncs.storage.setDevice(device);
    syncs.ring.setDevice(device);

    // Device connection and inventory are a recovery wake, even when the
    // home page is not mounted. The coordinator serializes it with every
    // other foreground trigger and applies the auto-sync preference itself.
    unawaited(RecordingTransferCoordinator.instance.wake(WakeTrigger.deviceConnected));

    // Auto-sync: check if device has offline files
    _checkAndStartAutoSync(device);

    notifyListeners();

    // Check firmware updates
    _checkFirmwareUpdates();

    if (Platform.isAndroid) {
      _ensureCompanionAssociation(device);
    }

    onDeviceConnected?.call(device);

    // Notify interactive device onboarding of reconnect
    captureProvider?.deviceOnboardingProvider?.onDeviceReconnected();
  }

  /// Check firmware version to determine multi-file sync support.
  /// Firmware >= 3.0.17 supports the new LittleFS multi-file protocol.
  static bool _isFirmwareVersionSupported(String? version) {
    if (version == null || version.isEmpty || version == 'Unknown') return false;
    final parts = version.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    if (parts.length < 3) return false;
    // Compare against 3.0.17
    if (parts[0] > 3) return true;
    if (parts[0] < 3) return false;
    if (parts[1] > 0) return true;
    if (parts[1] < 0) return false;
    return parts[2] >= 17;
  }

  Future<void> _checkAndStartAutoSync(BtDevice device) async {
    try {
      // Use firmware version as the reliable signal for multi-file support
      // Read from pairedDevice which has firmwareRevision populated by getDeviceInfo()
      final fwVersion = pairedDevice?.firmwareRevision ?? device.firmwareRevision;
      supportsMultiFileSync = _isFirmwareVersionSupported(fwVersion);
      SharedPreferencesUtil().deviceSupportsMultiFileSync = supportsMultiFileSync;
      notifyListeners();

      if (!supportsMultiFileSync) return;

      var connection = await ServiceManager.instance().device.ensureConnection(device.id);
      if (connection == null) return;

      // fw >= 3.0.20 speaks the ring-buffer protocol; auto-detect via the 16-byte
      // ring status read instead of the multi-file file-list endpoint (which the
      // ring firmware no longer serves).
      if (WalSyncs.isRingBufferFirmware(fwVersion)) {
        final ringStatus = await connection.getRingStatus();
        if (ringStatus != null) {
          _ringStatus = ringStatus;
          _updateStoragePressure(ringStatus);
          notifyListeners();
        }
        if (ringStatus == null || ringStatus.unreadPackets <= 0) return;
        Logger.debug(
          'DeviceProvider: Ring auto-sync detected ${ringStatus.unreadPackets} unread packets (${ringStatus.usedBytes} bytes)',
        );
        onOfflineDataDetected?.call(device, ringStatus.unreadPackets, ringStatus.usedBytes);
        return;
      }

      final status = await connection.getStorageFileStats();
      if (status == null || status.fileCount == 0) return;

      Logger.debug('DeviceProvider: Auto-sync detected ${status.fileCount} files (${status.totalUsedBytes} bytes)');
      onOfflineDataDetected?.call(device, status.fileCount, status.totalUsedBytes);
    } catch (e) {
      Logger.debug('DeviceProvider: Auto-sync check failed: $e');
    }
  }

  /// Refresh the on-device ring-buffer storage snapshot for the storage-usage
  /// indicator. No-op on firmware < 3.0.20 (the ring protocol isn't served) or
  /// when there's no active connection. Safe to call from UI (e.g. on page open).
  Future<void> refreshRingStorageStatus() async {
    try {
      final fwVersion = pairedDevice?.firmwareRevision ?? connectedDevice?.firmwareRevision;
      if (!WalSyncs.isRingBufferFirmware(fwVersion)) return;
      final deviceId = pairedDevice?.id ?? connectedDevice?.id;
      if (deviceId == null) return;
      final connection = await ServiceManager.instance().device.ensureConnection(deviceId);
      if (connection == null) return;
      final status = await connection.getRingStatus();
      if (status != null) {
        _ringStatus = status;
        _updateStoragePressure(status);
        notifyListeners();
      }
    } catch (e) {
      Logger.debug('DeviceProvider: refreshRingStorageStatus failed: $e');
    }
  }

  Future<void> _ensureCompanionAssociation(BtDevice device) async {
    try {
      if (SharedPreferencesUtil().companionAssociationPrompted) return;
      if (await BleHostApi().hasCompanionDeviceAssociation()) return;
      final ctx = globalNavigatorKey.currentContext;
      if (ctx == null || !ctx.mounted) return;
      SharedPreferencesUtil().companionAssociationPrompted = true;
      await showDialog(
        context: ctx,
        builder: (context) => AlertDialog(
          title: Text(context.l10n.improveConnectionTitle),
          content: Text(context.l10n.improveConnectionContent),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(context.l10n.improveConnectionAction, style: const TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    } catch (e) {
      Logger.debug('CompanionDevice association check failed: $e');
    }
  }

  void _handleDeviceConnected(String deviceId) async {
    var connection = await ServiceManager.instance().device.ensureConnection(deviceId);
    if (connection == null) {
      return;
    }
    _onDeviceConnected(connection.device);
  }

  void _checkFirmwareUpdates() async {
    if (!_allowsFirmwareUpdateForPairedDevice) {
      _havingNewFirmware = false;
      _firmwareUpdatePromptCoordinator.clearAvailableVersion(invalidateDeferral: true);
      return;
    }
    final checkSession = _firmwareUpdateCheckSessionGuard.capture();
    if (checkSession == null || !_isCurrentFirmwareCheckSession(checkSession)) {
      return;
    }
    if (_isFirmwareUpdateInProgress ||
        (_checkingFirmwareSession != null && _firmwareUpdateCheckSessionGuard.isCurrent(_checkingFirmwareSession!))) {
      return;
    }

    _checkingFirmwareSession = checkSession;
    try {
      final hasUpdate = await checkFirmwareUpdates(session: checkSession);
      if (!_isCurrentFirmwareCheckSession(checkSession)) {
        Logger.debug('Discarding firmware update prompt from a stale device session');
        return;
      }

      // Show firmware update dialog if needed
      if (hasUpdate && _havingNewFirmware) {
        // Use a small delay to ensure the UI is ready
        Future.delayed(const Duration(milliseconds: 500), () {
          if (!_isCurrentFirmwareCheckSession(checkSession)) return;
          final context = globalNavigatorKey.currentContext;
          if (context != null && context.mounted) {
            showFirmwareUpdateDialog(context);
          }
        });
      }
    } finally {
      if (identical(_checkingFirmwareSession, checkSession)) {
        _checkingFirmwareSession = null;
      }
    }
  }

  bool _isCurrentFirmwareCheckSession(FirmwareUpdateCheckSession session) {
    return _isCurrentDeviceSession(session) && isConnected;
  }

  bool _isCurrentDeviceSession(FirmwareUpdateCheckSession session) {
    return _firmwareUpdateCheckSessionGuard.isCurrent(session) &&
        connectedDevice?.id == session.deviceId &&
        pairedDevice?.id == session.deviceId;
  }

  bool get _isOmiGlassDevice => FirmwareUpdateBuildPolicy.current.isOpenGlassDevice(pairedDevice);

  bool get _allowsFirmwareUpdateForPairedDevice =>
      FirmwareUpdateBuildPolicy.current.allowsFirmwareUpdateForDevice(pairedDevice);

  Future<bool> checkFirmwareUpdates({FirmwareUpdateCheckSession? session}) async {
    final checkSession = session ?? _firmwareUpdateCheckSessionGuard.capture();
    if (checkSession == null || !_isCurrentFirmwareCheckSession(checkSession)) {
      return false;
    }
    if (!_allowsFirmwareUpdateForPairedDevice) {
      _havingNewFirmware = false;
      _firmwareUpdatePromptCoordinator.clearAvailableVersion(invalidateDeferral: true);
      return false;
    }
    int retryCount = 0;
    const maxRetries = 3;
    const retryDelay = Duration(seconds: 3);

    while (retryCount < maxRetries) {
      if (!_isCurrentFirmwareCheckSession(checkSession)) {
        return false;
      }
      try {
        var (message, hasUpdate, version, firmwareDetails) = await shouldUpdateFirmware();
        if (!_isCurrentFirmwareCheckSession(checkSession)) {
          Logger.debug('Discarding firmware update result from a stale device session');
          return false;
        }

        final latestFirmwareVersion = version.isNotEmpty ? version : message;
        Map<String, dynamic>? latestOmiGlassFirmwareDetails;

        // For OmiGlass devices, populate the firmware details for the OTA UI
        if (_isOmiGlassDevice && firmwareDetails.isNotEmpty) {
          // Map backend response to OmiGlass OTA UI expected format
          final versionStr = firmwareDetails['version']?.toString() ?? '';
          final cleanVersion = versionStr.startsWith('v') ? versionStr.substring(1) : versionStr;
          final changelog = firmwareDetails['changelog'];
          final changelogStr = changelog is List ? changelog.join('\n') : (changelog?.toString() ?? '');

          latestOmiGlassFirmwareDetails = {
            'version': cleanVersion,
            'download_url': firmwareDetails['zip_url'] ?? '',
            'changelog': changelogStr,
          };
        }

        // Fetch latest stable version for rollback comparison
        String? latestStableFirmwareVersion;
        try {
          var stableDetails = await getStableFirmwareVersion(deviceModelNumber: pairedDevice?.modelNumber ?? '');
          if (!_isCurrentFirmwareCheckSession(checkSession)) {
            Logger.debug('Discarding stable firmware result from a stale device session');
            return false;
          }
          var stableVersion = stableDetails['version']?.toString() ?? '';
          if (stableVersion.startsWith('v')) stableVersion = stableVersion.substring(1);
          latestStableFirmwareVersion = stableVersion;
        } catch (e) {
          if (!_isCurrentFirmwareCheckSession(checkSession)) {
            Logger.debug('Discarding firmware update result from a stale device session');
            return false;
          }
          Logger.debug('Error fetching stable firmware version: $e');
        }

        if (!_isCurrentFirmwareCheckSession(checkSession)) {
          return false;
        }
        _havingNewFirmware = hasUpdate;
        _latestFirmwareVersion = latestFirmwareVersion;
        if (hasUpdate) {
          _firmwareUpdatePromptCoordinator.setAvailableVersion(latestFirmwareVersion);
        } else {
          _firmwareUpdatePromptCoordinator.clearAvailableVersion();
        }
        if (latestOmiGlassFirmwareDetails != null) {
          _latestOmiGlassFirmwareDetails = latestOmiGlassFirmwareDetails;
        }
        if (latestStableFirmwareVersion != null) {
          _latestStableFirmwareVersion = latestStableFirmwareVersion;
        }
        notifyListeners();
        return hasUpdate;
      } catch (e) {
        if (!_isCurrentFirmwareCheckSession(checkSession)) {
          Logger.debug('Discarding firmware check failure from a stale device session');
          return false;
        }
        retryCount++;
        Logger.debug('Error checking firmware update (attempt $retryCount): $e');

        if (retryCount == maxRetries) {
          Logger.debug('Max retries reached, giving up');
          _havingNewFirmware = false;
          _firmwareUpdatePromptCoordinator.clearAvailableVersion();
          notifyListeners();
          return false;
        }

        await Future.delayed(retryDelay);
        if (!_isCurrentFirmwareCheckSession(checkSession)) {
          return false;
        }
      }
    }
    return false;
  }

  // Track if user is currently viewing a firmware update page
  bool _isOnFirmwareUpdatePage = false;
  void setOnFirmwareUpdatePage(bool value) {
    _isOnFirmwareUpdatePage = value;
    if (value) {
      _firmwareUpdatePromptCoordinator.invalidatePresentation();
    }
  }

  void showFirmwareUpdateDialog(BuildContext context) {
    if (!_allowsFirmwareUpdateForPairedDevice ||
        !_havingNewFirmware ||
        !SharedPreferencesUtil().showFirmwareUpdateDialog ||
        _isFirmwareUpdateInProgress ||
        _isOnFirmwareUpdatePage) {
      return;
    }

    final prompt = _firmwareUpdatePromptCoordinator.beginPresentation();
    if (prompt == null) return;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        final route = ModalRoute.of(dialogContext);
        final navigator = Navigator.of(dialogContext);
        _firmwareUpdatePromptCoordinator.attachDismissal(prompt, () {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!dialogContext.mounted || route == null || !route.isActive) return;
            if (route.isCurrent) {
              navigator.pop();
            } else {
              navigator.removeRoute(route);
            }
          });
        });

        return ConfirmationDialog(
          title: dialogContext.l10n.firmwareUpdateAvailable,
          description: dialogContext.l10n.firmwareUpdateAvailableDescription(_latestFirmwareVersion),
          confirmText: dialogContext.l10n.update,
          cancelText: dialogContext.l10n.later,
          onConfirm: () {
            if (!_firmwareUpdatePromptCoordinator.accept(prompt)) return;
            Logger.info('Firmware update prompt accepted');
            setFirmwareUpdateInProgress(true);
            if (_isOmiGlassDevice) {
              navigator.push(
                MaterialPageRoute(
                  builder: (context) =>
                      OmiGlassOtaUpdate(device: pairedDevice, latestFirmwareDetails: _latestOmiGlassFirmwareDetails),
                ),
              );
            } else {
              navigator.push(MaterialPageRoute(builder: (context) => FirmwareUpdate(device: pairedDevice)));
            }
          },
          onCancel: () {
            if (_firmwareUpdatePromptCoordinator.defer(prompt)) {
              Logger.info('Firmware update prompt deferred by user');
            }
          },
        );
      },
    ).whenComplete(() {
      _firmwareUpdatePromptCoordinator.complete(prompt);
    });
  }

  Future setisDeviceStorageSupport() async {
    if (connectedDevice == null) {
      isDeviceStorageSupport = false;
    } else {
      var storageFiles = await _getStorageList(connectedDevice!.id);
      isDeviceStorageSupport = storageFiles.isNotEmpty;
    }
    notifyListeners();
  }

  @override
  void onDeviceConnectionStateChanged(String deviceId, DeviceConnectionState state) async {
    Logger.debug("provider > device connection state changed...$deviceId...$state...${connectedDevice?.id}");
    switch (state) {
      case DeviceConnectionState.connected:
        _disconnectDebouncer.cancel();
        _connectDebouncer.run(() => _handleDeviceConnected(deviceId));
        break;
      case DeviceConnectionState.connecting:
        break;
      case DeviceConnectionState.disconnected:
        _connectDebouncer.cancel();
        // Check if this is the paired device or currently connected device
        // Coz connectedDevice and pairedDevice are the same but connectedDevice becomes null after disconnect
        if (deviceId == connectedDevice?.id || deviceId == pairedDevice?.id) {
          _disconnectDebouncer.run(onDeviceDisconnected);
        }
        break;
    }
  }

  @override
  void onDevices(List<BtDevice> devices) async {}

  @override
  void onStatusChanged(DeviceServiceStatus status) {}

  prepareDFU() {
    if (!FirmwareUpdateBuildPolicy.current.allowsOmiFirmwareUpdate || connectedDevice == null) {
      return;
    }
    setFirmwareUpdateInProgress(true);
    _bleDisconnectDevice(connectedDevice!);
  }

  // Reset firmware update state when update completes or fails
  void resetFirmwareUpdateState() {
    _isFirmwareUpdateInProgress = false;
    notifyListeners();
  }

  // Set firmware update state when starting an update
  void setFirmwareUpdateInProgress(bool inProgress) {
    _isFirmwareUpdateInProgress = inProgress;
    if (inProgress) {
      _firmwareUpdatePromptCoordinator.invalidatePresentation();
    }
    notifyListeners();
  }
}
