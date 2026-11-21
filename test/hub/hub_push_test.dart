import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/hub/hub_push.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const url = 'https://hub.example.invalid';
  const token = 'test-token';
  const ok = '{"accepted":{"days":1,"nights":0,"workouts":0},"freshness":null}';
  late String dbPath;
  late Database db;
  late DateTime now;
  late String yesterday;
  late List<Duration> delays;
  late List<String> logs;
  late List<http.Request> requests;
  late Future<http.Response> Function() respond;

  HubPush service() => HubPush(
    client: () => MockClient((request) {
      requests.add(request);
      return respond();
    }),
    clock: () => now,
    delay: (duration) async {
      delays.add(duration);
      now = now.add(duration);
    },
    appVersion: () async => '1.2.3',
    log: logs.add,
  );

  Map<String, dynamic> bodyOf(int index) =>
      jsonDecode(requests[index].body) as Map<String, dynamic>;

  Future<void> setSteps(int steps) async {
    await db.insert('metric_series', {
      'date': yesterday,
      'key': 'steps',
      'value': steps,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> addSession(String id, String day) async {
    final start = localDayStartSec(day)!;
    await db.insert('sessions', {
      'id': id,
      'start_ts': start,
      'end_ts': start + 60,
      'type': 'running',
      'status': 'done',
      'created_at': start * 1000,
    });
  }

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_hub_push_test.db';
    dbPath = p.join(await databaseFactory.getDatabasesPath(), LocalDb.dbName);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await databaseFactory.deleteDatabase(dbPath);
    db = await LocalDb.instance;
    now = DateTime(2026, 11, 21, 12);
    yesterday = dayLabelBefore(todayLabel(now), 1)!;
    delays = [];
    logs = [];
    requests = [];
    respond = () async => http.Response(ok, 200);
  });
  tearDown(() async {
    await LocalDb.close();
    await databaseFactory.deleteDatabase(dbPath);
  });

  test('opt-in requires both fields and clear disables delivery', () async {
    final push = service();
    final prefs = await SharedPreferences.getInstance();
    const secure = FlutterSecureStorage();

    expect(await push.pushNow(), HubPushResult.disabled);
    await prefs.setString('hub_push_url', url);
    expect(await push.pushNow(), HubPushResult.disabled);
    await prefs.remove('hub_push_url');
    await secure.write(key: 'hub_push_token', value: token);
    expect(await push.pushNow(), HubPushResult.disabled);
    expect(requests, isEmpty);

    await push.setConfig(url: url, token: token);
    expect(prefs.getKeys(), contains('hub_push_url'));
    expect(prefs.getKeys().map(prefs.get), isNot(contains(token)));
    expect(await secure.read(key: 'hub_push_token'), token);
    expect(await push.pushNow(), HubPushResult.acknowledged);
    final sent = requests.single;
    expect(sent.url, Uri.parse('$url/v1/digest'));
    expect(sent.method, 'POST');
    expect(sent.headers['Authorization'], 'Bearer $token');
    expect(sent.headers['Content-Type'], 'application/json');
    expect(sent.followRedirects, isFalse);

    await push.clearConfig();
    expect(await secure.read(key: 'hub_push_token'), isNull);
    expect(await push.pushNow(), HubPushResult.disabled);
    expect(requests, hasLength(1));
  });

  test('backs off across errors and resumes pending data after restart', () async {
    final push = service();
    await push.setConfig(url: url, token: token);
    await setSteps(120);
    respond = () async {
      if (requests.length == 1) throw http.ClientException('offline');
      return http.Response('', 503);
    };
    expect(await push.pushNow(), HubPushResult.deferred);
    expect(delays, [const Duration(seconds: 1)]);
    expect(requests, hasLength(2));

    final restarted = service();
    expect(await restarted.pushNow(), HubPushResult.deferred);
    expect(requests, hasLength(2));
    now = now.add(const Duration(seconds: 2));
    respond = () async => http.Response(ok, 200);
    expect(await restarted.pushNow(), HubPushResult.acknowledged);
    expect(bodyOf(2)['days'], [
      {'date': yesterday, 'metrics': {'steps': 120}},
      {'date': todayLabel(now), 'metrics': {}},
    ]);

    expect(await service().pushNow(), HubPushResult.acknowledged);
    expect(bodyOf(3)['days'], [
      {'date': todayLabel(now), 'metrics': {}},
    ]);
  });

  test('a retry uses current privacy and sends no cached workout', () async {
    final push = service();
    await push.setConfig(url: url, token: token);
    await addSession('session-to-hide', yesterday);
    respond = () async {
      if (requests.length > 1) return http.Response(ok, 200);
      await LocalDb.setSessionPrivate('session-to-hide', true);
      return http.Response('', 503);
    };

    expect(await push.pushNow(), HubPushResult.acknowledged);
    expect(bodyOf(0)['workouts'], hasLength(1));
    expect(bodyOf(1)['workouts'], isEmpty);
    expect(bodyOf(1)['revoked_workout_ids'], ['session-to-hide']);
  });

  test('acknowledges revocations for both private and deleted sessions', () async {
    final push = service();
    await push.setConfig(url: url, token: token);
    await addSession('made-private', yesterday);
    await addSession('deleted', yesterday);
    await addSession('outside-first-window', dayLabelBefore(yesterday, 30)!);
    expect(await push.pushNow(), HubPushResult.acknowledged);
    expect(bodyOf(0)['workouts'], hasLength(2));

    await LocalDb.setSessionPrivate('made-private', true);
    await LocalDb.setSessionPrivate('outside-first-window', true);
    await db.delete('sessions', where: 'id = ?', whereArgs: ['deleted']);
    expect(await service().pushNow(), HubPushResult.acknowledged);
    expect(bodyOf(1)['workouts'], isEmpty);
    expect(bodyOf(1)['revoked_workout_ids'], ['deleted', 'made-private']);

    expect(await push.pushNow(), HubPushResult.acknowledged);
    expect(bodyOf(2).containsKey('revoked_workout_ids'), isFalse);
    await LocalDb.setSessionPrivate('made-private', false);
    expect(await push.pushNow(), HubPushResult.acknowledged);
    expect(bodyOf(3)['workouts'], [containsPair('id', 'made-private')]);
  });

  test('a lost revocation acknowledgement forces republishing if public again', () async {
    final push = service();
    await push.setConfig(url: url, token: token);
    await addSession('published', yesterday);
    expect(await push.pushNow(), HubPushResult.acknowledged);
    await LocalDb.setSessionPrivate('published', true);
    respond = () async {
      if (requests.length > 2) return http.Response(ok, 200);
      await LocalDb.setSessionPrivate('published', false);
      throw http.ClientException('response lost');
    };

    expect(await push.pushNow(), HubPushResult.acknowledged);
    expect(bodyOf(1)['revoked_workout_ids'], ['published']);
    expect(bodyOf(2).containsKey('revoked_workout_ids'), isFalse);
    expect(bodyOf(2)['workouts'], [containsPair('id', 'published')]);
  });

  test('drops a permanent 4xx without advancing the acknowledged cursor', () async {
    final push = service();
    await push.setConfig(url: url, token: token);
    await setSteps(120);
    respond = () async => http.Response('ignored', 422);
    expect(await push.pushNow(), HubPushResult.rejected);
    expect(logs.single, contains('422'));
    expect(delays, isEmpty);

    now = now.add(const Duration(minutes: 1));
    expect(await service().pushNow(), HubPushResult.rejected);
    expect(requests, hasLength(1));
    await setSteps(121);
    respond = () async => http.Response(ok, 200);
    expect(await push.pushNow(), HubPushResult.acknowledged);
    expect(bodyOf(1)['days'], [
      {'date': yesterday, 'metrics': {'steps': 121}},
      {'date': todayLabel(now), 'metrics': {}},
    ]);
  });

  test('a 401 remains pending and a replacement token can deliver it', () async {
    final push = service();
    await push.setConfig(url: url, token: token);
    await setSteps(120);
    respond = () async => http.Response('', 401);
    expect(await push.pushNow(), HubPushResult.unauthorized);
    expect(requests, hasLength(1));
    expect(delays, isEmpty);

    await push.setConfig(url: url, token: 'replacement-token');
    respond = () async => http.Response(ok, 200);
    expect(await push.pushNow(), HubPushResult.acknowledged);
    expect(bodyOf(1)['days'], bodyOf(0)['days']);
    expect(requests.last.headers['Authorization'], 'Bearer replacement-token');
  });

  test('a new destination gets its own initial 30-day digest', () async {
    final push = service();
    await push.setConfig(url: url, token: token);
    await setSteps(120);
    expect(await push.pushNow(), HubPushResult.acknowledged);
    const replacement = 'https://second.example.invalid';
    await push.setConfig(url: replacement, token: token);
    expect(await push.pushNow(), HubPushResult.acknowledged);
    expect(requests.last.url, Uri.parse('$replacement/v1/digest'));
    expect(bodyOf(1)['days'], bodyOf(0)['days']);
  });
}
