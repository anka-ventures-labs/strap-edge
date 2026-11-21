import 'dart:async';
import 'dart:convert';
import 'dart:io' show IOException;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../compute/derivation_engine.dart' show kAlgoVersion;
import '../data/db.dart';
import '../sync/reset_gate.dart';
import 'digest.dart';
import 'hub_config.dart';

enum HubPushResult { disabled, deferred, acknowledged, rejected, unauthorized }

/// One delivery queue shared by the foreground and headless entry points.
class HubPush {
  HubPush({
    http.Client Function()? client,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
    Future<String> Function()? appVersion,
    void Function(String)? log,
  }) : _client = client ?? http.Client.new,
       _clock = clock ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed,
       _appVersion = appVersion ?? _platformVersion,
       _log = log ?? debugPrint;

  static final instance = HubPush();
  static const _stateKey = 'hub_digest_delivery_v1';
  static const _requestTimeout = Duration(seconds: 10);
  static const _config = HubConfigStore();

  final http.Client Function() _client;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;
  final Future<String> Function() _appVersion;
  final void Function(String) _log;
  Future<void> _tail = Future.value();
  int _configGeneration = 0;

  static Future<String> _platformVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  Future<void> setConfig({required String url, required String token}) {
    final resetGen = ResetGate.generation;
    if (ResetGate.active) {
      return Future.error(StateError('Data reset in progress.'));
    }
    _configGeneration++;
    return _serialize(() {
      if (ResetGate.changedSince(resetGen)) {
        throw StateError('Data reset in progress.');
      }
      return _config.set(url, token);
    });
  }

  Future<void> clearConfig() {
    _configGeneration++;
    return _serialize(() async {
      try {
        await _config.clear();
      } finally {
        await LocalDb.deleteCursor(_stateKey);
      }
    });
  }

  /// The current database plus the acknowledged fingerprints are the outbox.
  /// Rebuild each attempt so a workout made private since a failure stays local.
  Future<HubPushResult> pushNow({String? generation}) {
    final configGen = _configGeneration, resetGen = ResetGate.generation;
    bool current() =>
        configGen == _configGeneration && !ResetGate.changedSince(resetGen);
    return _serialize(() async {
      try {
        if (!current()) return HubPushResult.deferred;
        final config = await _config.load();
        if (config == null) return HubPushResult.disabled;
        return await _push(config, generation, current);
      } catch (_) {
        // Plugin/DB errors can contain personal data or the destination.
        _log('[hub-push] delivery deferred after a local failure');
        return HubPushResult.deferred;
      }
    });
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    final work = _tail.then((_) => action());
    _tail = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return work;
  }

  Future<HubPushResult> _push(
    HubConfig config,
    String? generation,
    bool Function() current,
  ) async {
    final destination = digestFingerprint(config.origin.toString());
    var state = _DeliveryState.load(
      await LocalDb.getCursor(_stateKey),
      destination,
    );
    if (_clock().millisecondsSinceEpoch < state.retryAtMs) {
      return HubPushResult.deferred;
    }
    final version = await _appVersion();
    final band = generation ??
        ((await LocalDb.deviceRow())?['adapter_id'] as String?);

    for (var attempt = 0; attempt < 2; attempt++) {
      final now = _clock();
      if (!current() || now.millisecondsSinceEpoch < state.retryAtMs) {
        return HubPushResult.deferred;
      }
      final digest = await const HubDigestBuilder().build(
        now: now,
        appVersion: version,
        algoVersion: kAlgoVersion,
        generation: band,
        acknowledged: state.acknowledged,
        previouslySentWorkouts: state.sentWorkouts,
      );
      if (!current()) return HubPushResult.deferred;
      final fingerprint = digest.fingerprint;
      if (state.rejected == fingerprint) return HubPushResult.rejected;

      final previousWorkouts = state.sentWorkouts;
      final attemptedWorkouts = {
        ...digest.sentWorkouts,
        ...previousWorkouts,
        for (final id in digest.revokedWorkouts) id: true,
      };
      if (!mapEquals(previousWorkouts, attemptedWorkouts)) {
        // A lost 200 can hide either an upsert or a revocation. Record newly
        // exposed IDs and possible tombstones before sending.
        state = state.withSentWorkouts(attemptedWorkouts);
        await _save(destination, state);
        if (!current()) return HubPushResult.deferred;
      }
      final status = await _send(config, digest.body);
      if (!current()) return HubPushResult.deferred;
      if (status == 200) {
        await _save(destination, _DeliveryState(
          acknowledged: digest.cursor, sentWorkouts: digest.sentWorkouts,
        ));
        return HubPushResult.acknowledged;
      }
      if (status == 401) {
        await _save(destination, _DeliveryState(
          acknowledged: state.acknowledged, rejected: state.rejected,
          sentWorkouts: previousWorkouts,
        ));
        _log('[hub-push] Hub authorization failed (401)');
        return HubPushResult.unauthorized;
      }
      if (status != null && (status < 500 || status >= 600)) {
        await _save(destination, _DeliveryState(
          acknowledged: state.acknowledged, rejected: fingerprint,
          sentWorkouts: previousWorkouts,
        ));
        _log('[hub-push] dropped digest after HTTP $status');
        return HubPushResult.rejected;
      }

      final backoff = Duration(seconds: math.min(300, 1 << state.failures));
      state = _DeliveryState(
        acknowledged: state.acknowledged,
        rejected: state.rejected,
        sentWorkouts: state.sentWorkouts,
        failures: math.min(state.failures + 1, 9),
        retryAtMs: _clock().add(backoff).millisecondsSinceEpoch,
      );
      await _save(destination, state);
      // Only the first, short delay waits in the queue. Later delays are
      // deadlines for future syncs so config changes can apply promptly.
      if (attempt != 0 || state.failures != 1 || !current()) break;
      await _delay(backoff);
    }
    _log('[hub-push] Hub unavailable, delivery queued');
    return HubPushResult.deferred;
  }

  Future<int?> _send(HubConfig config, Map<String, Object?> body) async {
    final request = http.Request('POST', config.origin.resolve('/v1/digest'))
      ..followRedirects = false
      ..headers['Authorization'] = 'Bearer ${config.token}'
      ..headers['Content-Type'] = 'application/json'
      ..bodyBytes = utf8.encode(jsonEncode(body));
    final client = _client();
    try {
      return await (() async {
        final response = await client.send(request);
        await response.stream.drain<void>();
        return response.statusCode;
      })().timeout(_requestTimeout);
    } on TimeoutException {
      return null;
    } on http.ClientException {
      return null;
    } on IOException {
      return null;
    } finally {
      client.close();
    }
  }

  Future<void> _save(String destination, _DeliveryState state) =>
      LocalDb.setCursor(_stateKey, jsonEncode({
        'destination': destination,
        'acknowledged': state.acknowledged,
        'rejected': state.rejected,
        'sent_workouts': state.sentWorkouts,
        'failures': state.failures,
        'retry_at_ms': state.retryAtMs,
      }));
}

class _DeliveryState {
  const _DeliveryState({
    this.acknowledged,
    this.rejected,
    this.sentWorkouts = const {},
    this.failures = 0,
    this.retryAtMs = 0,
  });

  final Map<String, String>? acknowledged;
  final String? rejected;
  // IDs that may be on the hub. True means a revocation was attempted, so an
  // otherwise unchanged public session must be sent again to clear a tombstone.
  final Map<String, bool> sentWorkouts;
  final int failures;
  final int retryAtMs;

  _DeliveryState withSentWorkouts(Map<String, bool> ids) => _DeliveryState(
    acknowledged: acknowledged,
    rejected: rejected,
    sentWorkouts: ids,
    failures: failures,
    retryAtMs: retryAtMs,
  );

  static _DeliveryState load(String? raw, String destination) {
    if (raw == null) return const _DeliveryState();
    final stored = jsonDecode(raw) as Map<String, dynamic>;
    if (stored['destination'] != destination) return const _DeliveryState();
    final cursor = stored['acknowledged'] as Map<String, dynamic>?;
    return _DeliveryState(
      acknowledged: cursor == null ? null : Map<String, String>.from(cursor),
      rejected: stored['rejected'] as String?,
      sentWorkouts: Map<String, bool>.from(stored['sent_workouts'] as Map),
      failures: math.min(9, math.max(0, stored['failures'] as int)),
      retryAtMs: stored['retry_at_ms'] as int,
    );
  }
}
