import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_vless/flutter_vless.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

void main() => runApp(const ManotoVpnApp());

class ManotoVpnApp extends StatelessWidget {
  const ManotoVpnApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Manoto VPN',
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFEDEFFA),
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6C63FF)),
        fontFamily: 'Roboto',
      ),
      home: const ManotoVpn(),
    );
  }
}

class Server {
  final String name;
  final String protocol;
  final String uri;
  int? ping;
  bool custom;
  Server({
    required this.name,
    required this.protocol,
    required this.uri,
    this.ping,
    this.custom = false,
  });
}

// Curated pastel palette used to give each server row a distinct,
// consistent accent color (deterministic based on the server name).
const List<Color> _accentPalette = [
  Color(0xFF4C8BF5),
  Color(0xFFEF5350),
  Color(0xFF7E57C2),
  Color(0xFF26A69A),
  Color(0xFFFFA726),
  Color(0xFFEC407A),
  Color(0xFF5C6BC0),
  Color(0xFF66BB6A),
];

String _protocolFromUri(String uri) {
  final value = uri.toLowerCase();

  if (value.startsWith('vless://')) return 'VLESS';
  if (value.startsWith('vmess://')) return 'VMess';
  if (value.startsWith('trojan://')) return 'Trojan';
  if (value.startsWith('ss://')) return 'Shadowsocks';

  return 'Unknown';
}

Color _accentFor(String name) {
  final hash = name.codeUnits.fold<int>(0, (a, b) => a + b);
  return _accentPalette[hash % _accentPalette.length];
}

class ManotoVpn extends StatefulWidget {
  const ManotoVpn({super.key});
  @override
  State<ManotoVpn> createState() => _ManotoVpnState();
}

class _ManotoVpnState extends State<ManotoVpn> {
  late final FlutterVless _vless;
  VlessStatus? _status;

  List<Server> _servers = [];
  List<Server> _customServers = [];
  Server? _selectedServer;
  bool _initialized = false;
  bool _busy = false;

  bool get _isConnected => (_status?.state ?? '').toUpperCase() == 'CONNECTED';
  bool get _isConnecting =>
      (_status?.state ?? '').toUpperCase().contains('CONNECTING');

  @override
  void initState() {
    super.initState();
    _vless = FlutterVless(
      onStatusChanged: (status) {
        if (mounted) setState(() => _status = status);
      },
    );
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _vless.initializeVless();
    _initialized = true;
    await _loadServers();
  }

  Future<void> _loadServers() async {
    final raw =
        await rootBundle.loadString('assets/configs/default_servers.json');
    final defaults = (jsonDecode(raw) as List)
        .map((e) => Server(
              name: e['name'],
              protocol: e['protocol'],
              uri: e['uri'],
            ))
        .toList();

    final prefs = await SharedPreferences.getInstance();
    final customUris = prefs.getStringList('custom_servers') ?? [];
    final customs = customUris
        .map((uri) => Server(
              name: 'Custom Config',
              protocol: _protocolFromUri(uri),
              uri: uri,
              custom: true,
            ))
        .toList();

    final allServers = [...defaults, ...customs];
    Server? nextSelected;

    final previousUri = _selectedServer?.uri;

    if (previousUri != null) {
      for (final server in allServers) {
        if (server.uri == previousUri) {
          nextSelected = server;
          break;
        }
      }
    }

    nextSelected ??= allServers.isNotEmpty ? allServers.first : null;

    setState(() {
      _servers = defaults;
      _customServers = customs;
      _selectedServer = nextSelected;
    });

    _testPings(_servers);
    _testPings(_customServers);
  }

  Future<void> _testPings(List<Server> list) async {
    await Future.wait(list.map((s) async {
      try {
        final parsed = FlutterVless.parse(s.uri);
        final delay = await _vless.getServerDelay(
          config: parsed.getFullConfiguration(),
          url: 'https://www.gstatic.com/generate_204',
        );
        if (mounted) setState(() => s.ping = delay);
      } catch (_) {
        if (mounted) setState(() => s.ping = -1);
      }
    }));
    if (mounted) {
      setState(() {
        _servers.sort((a, b) => _rank(a.ping).compareTo(_rank(b.ping)));
      });
    }
  }

  int _rank(int? p) {
    if (p == null) return 999998;
    if (p < 0) return 999999;
    return p;
  }

  Color _pingColor(int? p) {
    if (p == null) return Colors.grey;
    if (p < 0) return Colors.red;
    if (p <= 150) return Colors.green;
    if (p <= 400) return Colors.orange;
    return Colors.red;
  }

  String _pingLabel(int? p) {
    if (p == null) return '...';
    if (p < 0) return 'timeout';
    return '$p ms';
  }

  Future<void> _toggleConnection() async {
    if (_busy || !_initialized) return;
    setState(() => _busy = true);
    try {
      if (_isConnected || _isConnecting) {
        await _vless.stopVless();
      } else {
        final server = _selectedServer;

        if (server == null) {
          _showSnack('No server selected');
          return;
        }

        final parsed = FlutterVless.parse(server.uri);
        final granted = await _vless.requestPermission();
        if (granted) {
          await _vless.startVless(
            remark: parsed.remark.isNotEmpty ? parsed.remark : server.name,
            config: parsed.getFullConfiguration(),
          );
        } else {
          _showSnack('VPN permission was not granted');
        }
      }
    } catch (e) {
      _showSnack('Connection error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _addConfigUri(String uri) async {
    uri = uri.trim();
    final valid = uri.startsWith('vless://') ||
        uri.startsWith('trojan://') ||
        uri.startsWith('vmess://') ||
        uri.startsWith('ss://');
    if (!valid) {
      _showSnack('Invalid config link');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('custom_servers') ?? [];
    if (!list.contains(uri)) {
      list.add(uri);
      await prefs.setStringList('custom_servers', list);
      _showSnack('Config added');
      await _loadServers();
    } else {
      _showSnack('This config was already added');
    }
  }

  Future<void> _addFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) {
      _showSnack('Clipboard is empty');
      return;
    }
    await _addConfigUri(text);
  }

  Future<void> _addManually() async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add Config'),
        content: TextField(
          controller: controller,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'vless://... or trojan://...',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      await _addConfigUri(result);
    }
  }

  Future<void> _scanQr() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const _QrScannerPage()),
    );
    if (result != null) {
      await _addConfigUri(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final selectedServer = _selectedServer;

    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFD9E6FB), Color(0xFFEFE7F7), Color(0xFFF7F7FB)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.menu),
                      onPressed: () {},
                    ),
                    const Expanded(
                      child: Text(
                        'Manoto VPN',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 20),
                      ),
                    ),
                    const SizedBox(width: 48),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    _ConnectCard(
                      connected: _isConnected,
                      connecting: _isConnecting || _busy,
                      serverName: selectedServer?.name ?? 'Loading...',
                      onTap: _toggleConnection,
                    ),
                    const SizedBox(height: 20),
                    ..._servers.map((s) => _ServerTile(
                          server: s,
                          selected: _selectedServer?.uri == s.uri,
                          pingColor: _pingColor(s.ping),
                          pingLabel: _pingLabel(s.ping),
                          accent: _accentFor(s.name),
                          onTap: () => setState(() => _selectedServer = s),
                        )),
                    const SizedBox(height: 20),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        'Custom Configurations',
                        style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (_customServers.isEmpty)
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: const Text(
                          'No custom configs added yet',
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    else
                      ..._customServers.map((s) => _ServerTile(
                            server: s,
                            selected: _selectedServer?.uri == s.uri,
                            pingColor: _pingColor(s.ping),
                            pingLabel: _pingLabel(s.ping),
                            accent: _accentFor(s.name),
                            onTap: () =>
                                setState(() => _selectedServer = s),
                          )),
                  ],
                ),
              ),
              _BottomBar(
                onAdd: _addManually,
                onPaste: _addFromClipboard,
                onScan: _scanQr,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ConnectCard extends StatelessWidget {
  final bool connected;
  final bool connecting;
  final String serverName;
  final VoidCallback onTap;
  const _ConnectCard({
    required this.connected,
    required this.connecting,
    required this.serverName,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 230,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF7FB8F0), Color(0xFF8C7BEB), Color(0xFFD98FC7)],
        ),
      ),
      child: Stack(
        children: [
          const Icon(Icons.shield_outlined, color: Colors.white70, size: 30),
          Center(
            child: GestureDetector(
              onTap: onTap,
              child: Container(
                width: 150,
                height: 150,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.6),
                    width: 6,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 20,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Center(
                  child: connecting
                      ? const CircularProgressIndicator(color: Color(0xFF6C63FF))
                      : Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              connected ? 'Connected' : 'Connect',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                                fontSize: 18,
                                color: Colors.black87,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              connected ? 'Disconnect' : 'Tap to connect',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Text(
              serverName,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServerTile extends StatelessWidget {
  final Server server;
  final bool selected;
  final Color pingColor;
  final String pingLabel;
  final Color accent;
  final VoidCallback onTap;
  const _ServerTile({
    required this.server,
    required this.selected,
    required this.pingColor,
    required this.pingLabel,
    required this.accent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: selected ? const Color(0xFFEFEBFF) : Colors.white,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ListTile(
        onTap: onTap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
        ),
        leading: CircleAvatar(
          radius: 18,
          backgroundColor: accent.withValues(alpha: 0.15),
          child: Icon(Icons.public, color: accent, size: 18),
        ),
        title: Text(
          server.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(pingLabel,
                style: TextStyle(color: pingColor, fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(color: pingColor, shape: BoxShape.circle),
            ),
          ],
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final VoidCallback onAdd;
  final VoidCallback onPaste;
  final VoidCallback onScan;
  const _BottomBar({
    required this.onAdd,
    required this.onPaste,
    required this.onScan,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Color(0xFFEDEDED))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _BarButton(icon: Icons.add_link, label: 'Add Config', onTap: onAdd),
          _BarButton(icon: Icons.content_paste, label: 'Paste', onTap: onPaste),
          _BarButton(
              icon: Icons.qr_code_scanner, label: 'Scan QR', onTap: onScan),
        ],
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _BarButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(
          children: [
            Icon(icon, color: const Color(0xFF6C63FF)),
            const SizedBox(height: 4),
            Text(label,
                style: const TextStyle(
                    color: Color(0xFF6C63FF),
                    fontWeight: FontWeight.w700,
                    fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _QrScannerPage extends StatelessWidget {
  const _QrScannerPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Config QR')),
      body: MobileScanner(
        onDetect: (capture) {
          final barcodes = capture.barcodes;
          if (barcodes.isNotEmpty) {
            final value = barcodes.first.rawValue;
            if (value != null && value.isNotEmpty) {
              Navigator.pop(context, value);
            }
          }
        },
      ),
    );
  }
}
