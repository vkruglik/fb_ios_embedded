// fbprobe: a device test of the embedded Firebird engine on iOS.
//
// Each button runs one check of the embedded engine and writes the result to
// the screen and to Documents/fbprobe.log (visible in the Files app through
// UIFileSharingEnabled / LSSupportsOpeningDocumentsInPlace in Info.plist).
//
// The probe deliberately avoids EXECUTE BLOCK with RETURNS/SUSPEND through
// openCursor: it tests the engine, not that construct.
import 'dart:convert';
import 'dart:io';

import 'package:fb_ios_embedded/fb_ios_embedded.dart' as fb_embedded;
import 'package:fbdb/fbdb.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

void main() => runApp(const ProbeApp());

class ProbeApp extends StatelessWidget {
  const ProbeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'fbprobe',
        theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
        home: const ProbeScreen(),
      );
}

class ProbeScreen extends StatefulWidget {
  const ProbeScreen({super.key});

  @override
  State<ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends State<ProbeScreen> with WidgetsBindingObserver {
  final _lines = <String>[];
  FbDb? _db;
  bool _busy = false;
  String? _docs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _say('Probe started; mode: ${_mode()}');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Going to the background and back with an open connection: logged.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _say('App state: ${state.name}'
        '${_db != null ? ' (connection open)' : ''}');
  }

  static String _mode() {
    const release = bool.fromEnvironment('dart.vm.product');
    const profile = bool.fromEnvironment('dart.vm.profile');
    return release ? 'release' : (profile ? 'profile' : 'debug');
  }

  Future<String> _docsDir() async =>
      _docs ??= (await getApplicationDocumentsDirectory()).path;

  Future<String> get _dbPath async => p.join(await _docsDir(), 'probe.fdb');

  FbOptions get _options =>
      FbOptions(libFbClient: fb_embedded.getFbClientPath());

  void _say(String text) {
    final line = '${DateTime.now().toIso8601String().substring(11, 23)}  $text';
    setState(() => _lines.insert(0, line));
    // The log in Documents is written in sequence (one write after another:
    // concurrent appends overlapped and lost lines) and never throws: writing
    // the log must not break a check.
    final stamped = '${DateTime.now().toIso8601String()}  $text\n';
    _logTail = _logTail.then((_) async {
      try {
        final f = File(p.join(await _docsDir(), 'fbprobe.log'));
        await f.writeAsString(stamped, mode: FileMode.append, flush: true);
      } catch (_) {}
    });
  }

  Future<void> _logTail = Future.value();

  Future<void> _run(String title, Future<String> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    final sw = Stopwatch()..start();
    try {
      final result = await action();
      _say('✅ $title (${sw.elapsedMilliseconds} ms): $result');
    } catch (e, s) {
      _say('❌ $title (${sw.elapsedMilliseconds} ms): $e');
      final top = s.toString().split('\n').take(6).join('\n');
      _say('   stack: $top');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Buttons ──────────────────────────────────────────────────────────────

  Future<String> _paths() async {
    final info = await fb_embedded.describeSetup();
    return const JsonEncoder.withIndent('  ').convert(info);
  }

  Future<String> _deploy() async {
    await fb_embedded.setUpEmbedded();
    return 'setUpEmbedded() done; cwd=${Directory.current.path}';
  }

  FbDb _needDb() {
    final db = _db;
    if (db == null) throw StateError('no connection: use "Create database" or "Attach"');
    return db;
  }

  Future<String> _create() async {
    final path = await _dbPath;
    await _db?.detach();
    _db = null;
    final f = File(path);
    final existed = f.existsSync();
    if (existed) f.deleteSync();
    _db = await FbDb.createDatabase(
        database: path, user: 'SYSDBA', options: _options);
    return '${existed ? 'old file deleted, ' : ''}created $path '
        '(${File(path).lengthSync()} bytes)';
  }

  Future<String> _attach() async {
    final path = await _dbPath;
    await _db?.detach();
    _db = null;
    if (!File(path).existsSync()) throw StateError('no database file: $path');
    _db = await FbDb.attach(database: path, user: 'SYSDBA', options: _options);
    return 'attached to $path';
  }

  Future<String> _writeRead() async {
    final db = _needDb();
    final exists = await db.selectOne(
        sql: "SELECT COUNT(*) AS N FROM RDB\$RELATIONS "
            "WHERE RDB\$RELATION_NAME = 'PROBE'");
    if ((exists?['N'] as int? ?? 0) == 0) {
      await db.execute(
          sql: 'CREATE TABLE PROBE (ID INTEGER GENERATED BY DEFAULT AS IDENTITY '
              'PRIMARY KEY, S VARCHAR(60) CHARACTER SET UTF8, '
              'TS TIMESTAMP DEFAULT CURRENT_TIMESTAMP)');
    }
    await db.startTransaction();
    await db.execute(
        sql: 'INSERT INTO PROBE (S) VALUES (?)',
        parameters: ['row ${DateTime.now().toIso8601String()} ${_mode()}']);
    await db.commit();
    final row = await db.selectOne(
        sql: 'SELECT COUNT(*) AS N, MAX(ID) AS LAST_ID FROM PROBE');
    final last = await db.selectOne(
        sql: 'SELECT S FROM PROBE WHERE ID = ?', parameters: [row?['LAST_ID']]);
    return 'rows: ${row?['N']}, last: "${last?['S']}"';
  }

  // UNICODE_CI on Cyrillic text: proves that fbintl and ICU loaded, not only
  // the engine. 'Ёлка' and 'ёЛКА' differ only in case and must both match
  // 'ЁЛКА'.
  Future<String> _collation() async {
    final db = _needDb();
    await db.execute(
        sql: 'RECREATE TABLE T_COLL (S VARCHAR(20) CHARACTER SET UTF8 '
            'COLLATE UNICODE_CI)');
    await db.startTransaction();
    for (final s in ['Ёлка', 'ёЛКА', 'Апельсин']) {
      await db.execute(sql: 'INSERT INTO T_COLL VALUES (?)', parameters: [s]);
    }
    await db.commit();
    final cnt = await db.selectOne(
        sql: "SELECT COUNT(*) AS N FROM T_COLL WHERE S = 'ЁЛКА'");
    final order = await db.selectAll(sql: 'SELECT S FROM T_COLL ORDER BY S');
    final n = cnt?['N'];
    final sorted = order.map((r) => r['S']).join(', ');
    final attrs = await db.selectOne(
        sql: "SELECT CAST(RDB\$SPECIFIC_ATTRIBUTES AS VARCHAR(200)) AS A "
            "FROM RDB\$COLLATIONS WHERE RDB\$COLLATION_NAME = 'UNICODE'");
    final ok = n == 2;
    return '${ok ? 'UNICODE_CI works' : 'UNEXPECTED'}: matches for "ЁЛКА" '
        '$n (2 expected); order: $sorted; UNICODE: ${attrs?['A']}';
  }

  Future<String> _version() async {
    final db = _needDb();
    final row = await db.selectOne(
        sql: "SELECT RDB\$GET_CONTEXT('SYSTEM', 'ENGINE_VERSION') AS V, "
            "MON\$ODS_MAJOR AS ODS_MAJ, MON\$ODS_MINOR AS ODS_MIN "
            "FROM RDB\$DATABASE CROSS JOIN MON\$DATABASE");
    return 'Firebird ${row?['V']}, ODS ${row?['ODS_MAJ']}.${row?['ODS_MIN']}';
  }

  Future<String> _detach() async {
    final db = _db;
    if (db == null) return 'there was no connection';
    await db.detach();
    _db = null;
    return 'detached';
  }

  @override
  Widget build(BuildContext context) {
    final buttons = <(String, Future<String> Function())>[
      ('Paths', _paths),
      ('Deploy', _deploy),
      ('Create database', _create),
      ('Attach', _attach),
      ('Write/read', _writeRead),
      ('Collation', _collation),
      ('Version', _version),
      ('Detach', _detach),
    ];
    return Scaffold(
      appBar: AppBar(
        title: Text('fbprobe · ${_mode()}'),
        actions: [
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                  width: 20, height: 20, child: CircularProgressIndicator()),
            ),
          IconButton(
            tooltip: 'Clear the screen',
            icon: const Icon(Icons.clear_all),
            onPressed: () => setState(_lines.clear),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (title, action) in buttons)
                    FilledButton.tonal(
                      onPressed: _busy ? null : () => _run(title, action),
                      child: Text(title),
                    ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: _lines.length,
                itemBuilder: (_, i) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: SelectableText(_lines[i],
                      style: const TextStyle(fontFamily: 'Menlo', fontSize: 11)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
