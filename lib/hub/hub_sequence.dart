import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Installation metadata kept outside the health database and preferences.
/// A data reset, restored Edge backup, or Hub URL change cannot rewind it.
class HubSequence {
  const HubSequence({String? databasePath}) : _databasePath = databasePath;

  final String? _databasePath;

  Future<int> reserve() async {
    final file = _databasePath ??
        p.join(await getDatabasesPath(), 'hub_delivery_sequence.db');
    final db = await openDatabase(
      file,
      version: 1,
      singleInstance: false,
      onCreate: (db, _) => db.execute(
        'CREATE TABLE hub_sequence ('
        'id INTEGER PRIMARY KEY CHECK (id = 1), '
        'value INTEGER NOT NULL CHECK (value >= 1))',
      ),
    );
    try {
      return await db.transaction((txn) async {
        final rows = await txn.query('hub_sequence', columns: ['value']);
        final next = rows.isEmpty ? 1 : (rows.single['value'] as int) + 1;
        await txn.insert(
          'hub_sequence',
          {'id': 1, 'value': next},
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        return next;
      });
    } finally {
      await db.close();
    }
  }
}
