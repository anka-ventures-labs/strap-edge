import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/hub/digest.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late String dbPath;
  final now = DateTime(2026, 11, 21, 12);
  final today = todayLabel(now);
  final yesterday = dayLabelBefore(today, 1)!;
  final oldest = dayLabelBefore(today, 29)!;
  final older = dayLabelBefore(today, 30)!;

  Future<void> metric(String date, String key, num? value) async {
    await db.insert('metric_series', {
      'date': date,
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> night(
    String date,
    int version,
    String stage, {
    bool milliseconds = false,
  }) async {
    final start = localDayStartSec(date)! - 1800;
    final units = milliseconds ? 1000 : 1;
    await db.insert('day_result', {
      'day_id': date,
      'algo_version': version,
      'computed_at': now.millisecondsSinceEpoch,
      'payload_json': jsonEncode({
        'series': {
          'hypnogram': [
            {'start': start * units, 'end': (start + 1800) * units,
              'stage': stage},
          ],
        },
      }),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> workout(
    String id,
    String date, {
    bool private = false,
    String zones = '[5,20,0,0,0]',
  }) async {
    final start = localDayStartSec(date)! + 15;
    await db.insert('sessions', {
      'id': id,
      'start_ts': start,
      'end_ts': start + 2700,
      'type': 'running',
      'status': 'done',
      'duration_min': 45,
      'strain': 9.8,
      'calories': 410.0,
      'max_hr': 172,
      'hrr_bpm': 31.0,
      'steps': 6100,
      'zone_min_json': zones,
      'private': private ? 1 : 0,
      'trace_json': '{"route":[0,0]}',
      'created_at': start * 1000,
    });
  }

  Future<HubDigest> build([Map<String, String>? acknowledged]) =>
      const HubDigestBuilder().build(
        now: now,
        appVersion: '1.2.3',
        algoVersion: kAlgoVersion,
        generation: 'gen5',
        acknowledged: acknowledged,
      );

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_hub_digest_test.db';
    dbPath = p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName);
  });
  setUp(() async {
    await databaseFactory.deleteDatabase(dbPath);
    db = await LocalDb.instance;
  });
  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(dbPath);
  });

  test('projects schema 1, the served night and public workouts in UTC', () async {
    await metric(yesterday, 'rhr', 52);
    await metric(yesterday, 'future_key', 3.5);
    await metric(yesterday, 'absent', null);
    await night(yesterday, kAlgoVersion - 1, 'wake');
    await night(yesterday, kAlgoVersion, 'unobserved', milliseconds: true);
    await night(yesterday, kAlgoVersion + 1, 'rem');
    await workout('public-session', yesterday);
    await workout('private-session', yesterday, private: true);
    final frontier = localDayStartSec(today)!;
    await LocalDb.setCursor('rec_ts_hw', '$frontier');

    String utc(int sec) => DateTime.fromMillisecondsSinceEpoch(
      sec * 1000, isUtc: true,
    ).toIso8601String();
    final midnight = localDayStartSec(yesterday)!;
    final result = await build();
    expect(result.body, {
      'schema': 1,
      'sent_at': now.toUtc().toIso8601String(),
      'source': {
        'app': 'strap-edge',
        'app_version': '1.2.3',
        'algo_version': kAlgoVersion,
        'device_family': 'whoop5',
      },
      'freshness': {'last_band_record_at': utc(frontier)},
      'days': [
        {'date': yesterday, 'metrics': {'future_key': 3.5, 'rhr': 52}},
        {'date': today, 'metrics': {}},
      ],
      'nights': [
        {
          'date': yesterday,
          'segments': [
            {'start': utc(midnight - 1800), 'end': utc(midnight),
              'stage': 'unobserved'},
          ],
        },
      ],
      'workouts': [
        {
          'id': 'public-session', 'date': yesterday,
          'start': utc(midnight + 15), 'end': utc(midnight + 2715),
          'type': 'running', 'duration_min': 45, 'strain': 9.8,
          'calories': 410, 'max_hr': 172, 'hrr_bpm': 31, 'steps': 6100,
          'zone_min': {'z1': 5, 'z2': 20, 'z3': 0, 'z4': 0, 'z5': 0},
        },
      ],
    });
  });

  test('first delivery covers 30 local dates, later edits can be older', () async {
    await metric(older, 'steps', 123);
    await metric(oldest, 'steps', 456);
    await metric(today, 'steps', 789);
    await night(older, kAlgoVersion, 'light');
    await workout('older-session', older);
    await workout('today-session', today);

    final first = await build();
    expect(first.body['days'], [
      {'date': oldest, 'metrics': {'steps': 456}},
      {'date': today, 'metrics': {'steps': 789}},
    ]);
    expect(first.body['nights'], isEmpty);
    expect(first.body['workouts'], hasLength(1));

    final unchanged = await build(first.cursor);
    expect(unchanged.body['days'], [
      {'date': today, 'metrics': {'steps': 789}},
    ]);
    expect(unchanged.body['workouts'], hasLength(1));
    expect(unchanged.body['freshness'], {'last_band_record_at': null});

    await metric(older, 'steps', 124);
    await night(older, kAlgoVersion, 'deep');
    await LocalDb.setSessionType('older-session', 'cycling');
    final changed = await build(first.cursor);
    expect(changed.body['days'], [
      {'date': older, 'metrics': {'steps': 124}},
      {'date': today, 'metrics': {'steps': 789}},
    ]);
    expect(changed.body['nights'], [containsPair('date', older)]);
    expect(changed.body['workouts'], [
      allOf(containsPair('date', older), containsPair('type', 'cycling')),
      containsPair('date', today),
    ]);
  });

  test('empty or unreadable zones do not remove the workout', () async {
    await workout('empty-zones', yesterday, zones: '[]');
    await workout('malformed-zones', yesterday, zones: '[');
    final digest = await build();
    final workouts = digest.body['workouts'] as List;
    expect(workouts, hasLength(2));
    for (final row in workouts) {
      expect((row as Map).containsKey('zone_min'), isFalse);
    }
  });
}
