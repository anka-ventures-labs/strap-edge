import 'dart:convert';
import 'dart:isolate';

import 'package:crypto/crypto.dart';

import '../data/day_label.dart';
import '../data/db.dart';

String digestFingerprint(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

class HubDigest {
  const HubDigest(this.body, this.cursor, this.sentWorkouts, this.revokedWorkouts);

  final Map<String, Object?> body;
  final Map<String, String> cursor;
  final Map<String, bool> sentWorkouts;
  final List<String> revokedWorkouts;

  // Ignore the send time when identifying a previously rejected payload.
  String get fingerprint => digestFingerprint(
    Map<String, Object?>.of(body)..remove('sent_at'),
  );
}

/// Edge has no edit timestamp on metric_series or sessions. Compare the
/// published values themselves, including edits to older, unfinalized inputs.
class HubDigestBuilder {
  const HubDigestBuilder();

  Future<HubDigest> build({
    required DateTime now,
    required String appVersion,
    required int algoVersion,
    required String? generation,
    required Map<String, String>? acknowledged,
    Map<String, bool> previouslySentWorkouts = const {},
  }) async {
    final today = todayLabel(now);
    final firstDay = dayLabelBefore(today, 29)!;
    final db = await LocalDb.instance;
    final rows = await db.transaction((txn) async => (
      metrics: await txn.query(
        'metric_series',
        columns: ['date', 'key', 'value'],
        where: 'date <= ? AND value IS NOT NULL',
        whereArgs: [today],
        orderBy: 'date, key',
      ),
      // The coach views already implement the served-version ceiling and
      // private/session-score masking. Select only the wire fields.
      segments: await txn.query(
        'v_hypnogram',
        where: 'date <= ?',
        whereArgs: [today],
        orderBy: 'date, start_ts, end_ts, stage',
      ),
      workouts: await txn.query(
        'v_sessions',
        columns: [
          'id',
          'start_ts',
          'end_ts',
          'type',
          ..._workoutNumbers,
          'zone_min_json',
        ],
        orderBy: 'start_ts, id',
      ),
    ));
    final freshness = await LocalDb.getRecordFrontier();
    return _project((
      rows: rows,
      today: today,
      firstDay: firstDay,
      sentAt: now.toUtc().toIso8601String(),
      appVersion: appVersion,
      generation: generation,
      algoVersion: algoVersion,
      freshness: freshness,
      acknowledged: acknowledged,
      previouslySentWorkouts: previouslySentWorkouts,
    ));
  }
}

typedef _Rows = List<Map<String, Object?>>;
typedef _Projection = ({
  ({_Rows metrics, _Rows segments, _Rows workouts}) rows,
  String today,
  String firstDay,
  String sentAt,
  String appVersion,
  String? generation,
  int algoVersion,
  int? freshness,
  Map<String, String>? acknowledged,
  Map<String, bool> previouslySentWorkouts,
});

// Hashing a long history and shaping its JSON can run off the UI isolate.
Future<HubDigest> _project(_Projection input) =>
    Isolate.run(() => _build(input));

HubDigest _build(_Projection input) {
  final metrics = <String, Map<String, num>>{input.today: {}};
  final nights = <String, List<Map<String, String>>>{};
  for (final row in input.rows.metrics) {
    final value = row['value'];
    if (value is num && value.isFinite) {
      (metrics[row['date'] as String] ??= {})[row['key'] as String] = value;
    }
  }
  for (final row in input.rows.segments) {
    final stage = row['stage'];
    final start = _segmentMilliseconds(row['start_ts']);
    final end = _segmentMilliseconds(row['end_ts']);
    if (start == null ||
        end == null ||
        end <= start ||
        stage is! String ||
        !_stages.contains(stage)) {
      continue;
    }
    (nights[row['date'] as String] ??= []).add({
      'start': _utcMilliseconds(start),
      'end': _utcMilliseconds(end),
      'stage': stage,
    });
  }

  final cursor = <String, String>{};
  bool include(String key, Map<String, Object?> item) {
    final date = item['date'] as String;
    final signature = cursor[key] = digestFingerprint(item);
    if (date == input.today) return true;
    final previous = input.acknowledged;
    // Keep the initial fingerprints of older rows so later edits to them can
    // be detected without publishing pre-existing history outside 30 days.
    return previous == null
        ? date.compareTo(input.firstDay) >= 0
        : previous[key] != signature;
  }

  final days = <Map<String, Object?>>[];
  final dates = metrics.keys.toList()..sort();
  for (final date in dates) {
    final item = <String, Object?>{'date': date, 'metrics': metrics[date]};
    if (include('day:$date', item)) days.add(item);
  }
  final sleep = <Map<String, Object?>>[];
  for (final entry in nights.entries) {
    final item = <String, Object?>{'date': entry.key, 'segments': entry.value};
    if (include('night:${entry.key}', item)) sleep.add(item);
  }
  final workouts = <Map<String, Object?>>[];
  final publicIds = <String>{};
  final previouslySent = input.previouslySentWorkouts;
  final sentWorkouts = Map<String, bool>.of(previouslySent);
  for (final row in input.rows.workouts) {
    final start = row['start_ts'] as int;
    final end = row['end_ts'] as int?;
    final date = dayLabelOf(DateTime.fromMillisecondsSinceEpoch(start * 1000));
    final id = row['id'] as String;
    publicIds.add(id);
    if (date.compareTo(input.today) > 0) continue;
    final zones = _zones(row['zone_min_json']);
    final item = <String, Object?>{
      'id': id,
      'date': date,
      'start': _utc(start),
      'end': end == null ? null : _utc(end),
      'type': row['type'],
      for (final key in _workoutNumbers)
        if (row[key] case final num value when value.isFinite) key: value,
      if (zones != null) 'zone_min': zones,
    };
    if (include('workout:${digestFingerprint(id)}', item) ||
        previouslySent[id] == true) {
      workouts.add(item);
      sentWorkouts[id] = false;
    }
  }
  final revoked = previouslySent.keys
      .where((id) => !publicIds.contains(id))
      .toList()
    ..sort();
  for (final id in revoked) {
    sentWorkouts.remove(id);
  }

  final freshness = input.freshness;
  return HubDigest({
    'schema': 1,
    'sent_at': input.sentAt,
    'source': {
      'app': 'strap-edge',
      'app_version': input.appVersion,
      'algo_version': input.algoVersion,
      'device_family': switch (input.generation) {
        'gen4' => 'whoop4',
        'gen5' => 'whoop5',
        _ => 'unknown',
      },
    },
    'freshness': {
      'last_band_record_at': freshness == null ? null : _utc(freshness),
    },
    'days': days,
    'nights': sleep,
    'workouts': workouts,
    if (revoked.isNotEmpty) 'revoked_workout_ids': revoked,
  }, cursor, sentWorkouts, revoked);
}

const _stages = {'wake', 'light', 'deep', 'rem', 'unobserved'};
const _workoutNumbers = [
  'duration_min',
  'strain',
  'calories',
  'max_hr',
  'hrr_bpm',
  'steps',
];

String _utc(int seconds) => _utcMilliseconds(seconds * 1000);

String _utcMilliseconds(int ms) =>
    DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toIso8601String();

int? _segmentMilliseconds(Object? value) {
  if (value is! num || !value.isFinite) return null;
  return (value > 1e11 ? value : value * 1000).round();
}

Map<String, num>? _zones(Object? raw) {
  if (raw is! String) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return null;
  }
  final entries = switch (decoded) {
    final List<Object?> values => [
      // Edge stores Z1..Z5 at zero-based indices.
      for (var i = 0; i < values.length; i++) MapEntry('z${i + 1}', values[i]),
    ],
    final Map<String, Object?> values => (values.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key))),
    _ => const <MapEntry<String, Object?>>[],
  };
  final zones = <String, num>{
    for (final entry in entries)
      if (entry.value case final num minutes
          when _zoneKeys.contains(entry.key) && minutes.isFinite && minutes >= 0)
        entry.key: minutes,
  };
  return zones.isEmpty ? null : zones;
}

const _zoneKeys = {'z1', 'z2', 'z3', 'z4', 'z5'};
