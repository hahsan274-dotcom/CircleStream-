import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:chewie/chewie.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:html/parser.dart' as hp;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

const defaultBase = 'http://new.circleftp.net/';
const videoExt = ['mp4', 'mkv', 'avi', 'mov', 'webm', 'm4v', 'ts', 'flv', 'wmv'];

class Entry {
  final String name;
  final Uri uri;
  final bool isDir;
  Entry(this.name, this.uri, this.isDir);
}

Future<List<Entry>> listDir(Uri dir) async {
  final res = await http.get(dir).timeout(const Duration(seconds: 25));
  if (res.statusCode != 200) throw 'Server returned ${res.statusCode}';
  final doc = hp.parse(utf8.decode(res.bodyBytes, allowMalformed: true));
  final seen = <String>{};
  final out = <Entry>[];
  for (final a in doc.querySelectorAll('a')) {
    final href = a.attributes['href'];
    if (href == null || href.isEmpty) continue;
    if (href.startsWith('?') || href.startsWith('#') || href.startsWith('javascript') || href.startsWith('mailto')) continue;
    final uri = dir.resolve(href);
    if (uri.host != dir.host) continue;
    if (!uri.path.startsWith(dir.path) || uri.path == dir.path) continue; // skips parent links
    final isDir = uri.path.endsWith('/');
    final segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (segs.isEmpty) continue;
    final name = segs.last;
    if (!isDir && !videoExt.contains(name.split('.').last.toLowerCase())) continue;
    if (!seen.add(uri.toString())) continue;
    out.add(Entry(name, uri, isDir));
  }
  out.sort((a, b) {
    if (a.isDir != b.isDir) return a.isDir ? -1 : 1;
    return a.name.toLowerCase().compareTo(b.name.toLowerCase());
  });
  return out;
}

String prettyName(String n) {
  var s = n.contains('.') && !n.endsWith('/') ? n.substring(0, n.lastIndexOf('.')) : n;
  return s.replaceAll(RegExp(r'[._]+'), ' ').trim();
}

Color cardColor(String name, [double v = 0.5]) {
  final h = (name.hashCode.abs() % 360).toDouble();
  return HSVColor.fromAHSV(1, h, 0.55, v).toColor();
}

Future<void> saveProgress(String name, String url, int pos, int dur) async {
  final p = await SharedPreferences.getInstance();
  final list = (p.getStringList('recent') ?? []).map((e) => jsonDecode(e) as Map<String, dynamic>).toList();
  list.removeWhere((e) => e['url'] == url);
  if (dur > 0 && pos < dur * 0.95 && pos > 5000) {
    list.insert(0, {'name': name, 'url': url, 'pos': pos, 'dur': dur});
  }
  await p.setStringList('recent', list.take(20).map(jsonEncode).toList());
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final p = await SharedPreferences.getInstance();
  runApp(App(initialBase: p.getString('base') ?? defaultBase));
}

class App extends StatefulWidget {
  final String initialBase;
  const App({super.key, required this.initialBase});
  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  late String base = widget.initialBase;

  Future<void> setBase(String b) async {
    if (!b.endsWith('/')) b = '$b/';
    final p = await SharedPreferences.getInstance();
    await p.setString('base', b);
    setState(() => base = b);
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoApp(
      debugShowCheckedModeBanner: false,
      title: 'Circle Play',
      theme: const CupertinoThemeData(
        brightness: Brightness.dark,
        primaryColor: Color(0xFFFF453A),
        scaffoldBackgroundColor: CupertinoColors.black,
      ),
      home: BrowsePage(
        key: ValueKey(base),
        uri: Uri.parse(base),
        title: 'Circle Play',
        root: true,
        base: base,
        onBaseChanged: setBase,
      ),
    );
  }
}

class BrowsePage extends StatefulWidget {
  final Uri uri;
  final String title;
  final bool root;
  final String base;
  final Future<void> Function(String)? onBaseChanged;
  const BrowsePage({super.key, required this.uri, required this.title, this.root = false, this.base = '', this.onBaseChanged});
  @override
  State<BrowsePage> createState() => _BrowsePageState();
}

class _BrowsePageState extends State<BrowsePage> {
  late Future<List<Entry>> fut = listDir(widget.uri);
  String q = '';
  List<Map<String, dynamic>> recent = [];

  @override
  void initState() {
    super.initState();
    if (widget.root) _loadRecent();
  }

  Future<void> _loadRecent() async {
    final p = await SharedPreferences.getInstance();
    final l = (p.getStringList('recent') ?? []).map((e) => jsonDecode(e) as Map<String, dynamic>).toList();
    if (mounted) setState(() => recent = l);
  }

  Future<void> _play(String name, Uri uri, {int start = 0}) async {
    await Navigator.of(context, rootNavigator: true).push(CupertinoPageRoute(
      fullscreenDialog: true,
      builder: (_) => PlayerPage(name: name, uri: uri, startMs: start),
    ));
    if (widget.root) _loadRecent();
  }

  void _open(Entry e) {
    if (e.isDir) {
      Navigator.of(context).push(CupertinoPageRoute(builder: (_) => BrowsePage(uri: e.uri, title: prettyName(e.name))));
    } else {
      _play(e.name, e.uri);
    }
  }

  void _settings() {
    final c = TextEditingController(text: widget.base);
    showCupertinoDialog(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: const Text('Server address'),
        content: Padding(
          padding: const EdgeInsets.only(top: 12),
          child: CupertinoTextField(controller: c, keyboardType: TextInputType.url, autocorrect: false),
        ),
        actions: [
          CupertinoDialogAction(child: const Text('Cancel'), onPressed: () => Navigator.pop(ctx)),
          CupertinoDialogAction(
            isDefaultAction: true,
            child: const Text('Save'),
            onPressed: () {
              Navigator.pop(ctx);
              widget.onBaseChanged?.call(c.text.trim());
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      child: FutureBuilder<List<Entry>>(
        future: fut,
        builder: (context, snap) {
          final slivers = <Widget>[
            CupertinoSliverNavigationBar(
              largeTitle: Text(widget.title),
              backgroundColor: const Color(0xCC000000),
              border: null,
              trailing: widget.root
                  ? CupertinoButton(padding: EdgeInsets.zero, onPressed: _settings, child: const Icon(CupertinoIcons.gear))
                  : null,
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: CupertinoSearchTextField(onChanged: (v) => setState(() => q = v.toLowerCase())),
              ),
            ),
          ];

          if (snap.connectionState != ConnectionState.done) {
            slivers.add(const SliverFillRemaining(hasScrollBody: false, child: Center(child: CupertinoActivityIndicator(radius: 14))));
          } else if (snap.hasError) {
            slivers.add(SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(CupertinoIcons.wifi_exclamationmark, size: 44, color: CupertinoColors.systemGrey),
                    const SizedBox(height: 12),
                    Text('${snap.error}', textAlign: TextAlign.center, style: const TextStyle(color: CupertinoColors.systemGrey)),
                    const SizedBox(height: 12),
                    CupertinoButton.filled(
                      child: const Text('Retry'),
                      onPressed: () => setState(() => fut = listDir(widget.uri)),
                    ),
                  ]),
                ),
              ),
            ));
          } else {
            final all = snap.data!;
            final items = q.isEmpty ? all : all.where((e) => e.name.toLowerCase().contains(q)).toList();
            final dirs = items.where((e) => e.isDir).toList();
            final files = items.where((e) => !e.isDir).toList();

            if (widget.root && recent.isNotEmpty && q.isEmpty) {
              slivers.add(_header('Continue Watching'));
              slivers.add(SliverToBoxAdapter(
                child: SizedBox(
                  height: 120,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: recent.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (_, i) {
                      final r = recent[i];
                      final frac = (r['pos'] as int) / max(1, r['dur'] as int);
                      return GestureDetector(
                        onTap: () => _play(r['name'], Uri.parse(r['url']), start: r['pos']),
                        child: Container(
                          width: 190,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            gradient: LinearGradient(colors: [cardColor(r['name']), cardColor(r['name'], 0.25)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                          ),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            const Icon(CupertinoIcons.play_circle_fill, size: 28),
                            const Spacer(),
                            Text(prettyName(r['name']), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                            const SizedBox(height: 6),
                            ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: SizedBox(height: 3, child: LinearProgressIndicator(value: frac.clamp(0.0, 1.0), backgroundColor: const Color(0x55FFFFFF), color: CupertinoColors.white)),
                            ),
                          ]),
                        ),
                      );
                    },
                  ),
                ),
              ));
            }

            if (dirs.isNotEmpty) {
              slivers.add(_header(widget.root ? 'Library' : 'Folders'));
              slivers.add(SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                sliver: SliverGrid(
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisSpacing: 12, crossAxisSpacing: 12, childAspectRatio: 1.5),
                  delegate: SliverChildBuilderDelegate((_, i) {
                    final e = dirs[i];
                    final n = prettyName(e.name);
                    return GestureDetector(
                      onTap: () => _open(e),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          gradient: LinearGradient(colors: [cardColor(e.name, 0.7), cardColor(e.name, 0.3)], begin: Alignment.topLeft, end: Alignment.bottomRight),
                        ),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(n.isEmpty ? '?' : n[0].toUpperCase(), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: Color(0xAAFFFFFF))),
                          const Spacer(),
                          Text(n, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                        ]),
                      ),
                    );
                  }, childCount: dirs.length),
                ),
              ));
            }

            if (files.isNotEmpty) {
              slivers.add(_header('Videos'));
              slivers.add(SliverList(
                delegate: SliverChildBuilderDelegate((_, i) {
                  final e = files[i];
                  return CupertinoListTile.notched(
                    backgroundColor: const Color(0xFF1C1C1E),
                    leading: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(color: cardColor(e.name), borderRadius: BorderRadius.circular(8)),
                      child: const Icon(CupertinoIcons.play_fill, size: 16),
                    ),
                    title: Text(prettyName(e.name), maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(e.name.split('.').last.toUpperCase()),
                    trailing: const CupertinoListTileChevron(),
                    onTap: () => _open(e),
                  );
                }, childCount: files.length),
              ));
            }

            if (dirs.isEmpty && files.isEmpty) {
              slivers.add(const SliverFillRemaining(hasScrollBody: false, child: Center(child: Text('Nothing found', style: TextStyle(color: CupertinoColors.systemGrey)))));
            }
            slivers.add(const SliverToBoxAdapter(child: SizedBox(height: 40)));
          }

          return CustomScrollView(slivers: slivers);
        },
      ),
    );
  }

  Widget _header(String t) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(t, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
        ),
      );
}

class PlayerPage extends StatefulWidget {
  final String name;
  final Uri uri;
  final int startMs;
  const PlayerPage({super.key, required this.name, required this.uri, this.startMs = 0});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late VideoPlayerController vc;
  ChewieController? cc;
  String? error;
  Timer? timer;

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    vc = VideoPlayerController.networkUrl(widget.uri);
    vc.initialize().then((_) {
      cc = ChewieController(
        videoPlayerController: vc,
        autoPlay: true,
        startAt: Duration(milliseconds: widget.startMs),
        allowFullScreen: false,
        aspectRatio: vc.value.aspectRatio,
        materialProgressColors: ChewieProgressColors(playedColor: const Color(0xFFFF453A), handleColor: CupertinoColors.white),
      );
      if (mounted) setState(() {});
      timer = Timer.periodic(const Duration(seconds: 10), (_) => _save());
    }).catchError((e) {
      if (mounted) setState(() => error = 'Could not play this file.\nThe format/codec may not be supported on this phone.');
    });
  }

  void _save() {
    if (vc.value.isInitialized) {
      saveProgress(widget.name, widget.uri.toString(), vc.value.position.inMilliseconds, vc.value.duration.inMilliseconds);
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    _save();
    cc?.dispose();
    vc.dispose();
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.black,
      child: Stack(children: [
        Center(
          child: error != null
              ? Text(error!, textAlign: TextAlign.center, style: const TextStyle(color: CupertinoColors.systemGrey))
              : cc == null
                  ? const CupertinoActivityIndicator(radius: 16)
                  : Chewie(controller: cc!),
        ),
        Positioned(
          top: 12,
          left: 12,
          child: SafeArea(
            child: CupertinoButton(
              padding: const EdgeInsets.all(8),
              color: const Color(0x99000000),
              borderRadius: BorderRadius.circular(20),
              minSize: 0,
              onPressed: () => Navigator.of(context).pop(),
              child: const Icon(CupertinoIcons.xmark, size: 18, color: CupertinoColors.white),
            ),
          ),
        ),
      ]),
    );
  }
}
