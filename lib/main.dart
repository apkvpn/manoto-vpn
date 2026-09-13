import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const ManotoVpnApp());

class ManotoVpnApp extends StatelessWidget {
  const ManotoVpnApp({super.key});
  @override
  Widget build(BuildContext context) => const ManotoVpn();
}

class Server {
  final String name;
  final String protocol;
  final String uri;
  int? ping;
  Server({required this.name, required this.protocol, required this.uri, this.ping});
}

class ManotoVpn extends StatefulWidget {
  const ManotoVpn({super.key});
  @override
  State<ManotoVpn> createState() => _ManotoVpnState();
}

class _ManotoVpnState extends State<ManotoVpn> {
  bool dark = true;
  bool connected = false;
  bool connecting = false;
  List<Server> servers = [];
  int selected = 0;

  @override
  void initState() {
    super.initState();
    _loadServers();
  }

  Future<void> _loadServers() async {
    final raw = await rootBundle.loadString('assets/configs/default_servers.json');
    final defaults = (jsonDecode(raw) as List).map((e) => Server(
      name: e['name'], protocol: e['protocol'], uri: e['uri'],
    )).toList();
    final prefs = await SharedPreferences.getInstance();
    final custom = prefs.getStringList('custom_servers') ?? [];
    for (final uri in custom) {
      defaults.add(Server(name: 'Custom Server', protocol: uri.startsWith('trojan://') ? 'Trojan' : 'VLESS', uri: uri));
    }
    setState(() => servers = defaults);
    _testAndSort();
  }

  Future<void> _testAndSort() async {
    // Production integration point: call the Xray/VLESS package latency test here.
    // The UI deliberately never exposes raw URIs.
    await Future.delayed(const Duration(milliseconds: 250));
    setState(() {
      for (var i = 0; i < servers.length; i++) {
        servers[i].ping = 70 + ((i * 37) % 241);
      }
      servers.sort((a, b) => (a.ping ?? 9999).compareTo(b.ping ?? 9999));
      if (selected >= servers.length) selected = 0;
    });
  }

  Future<void> _addFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final uri = data?.text?.trim() ?? '';
    if (!uri.startsWith('vless://') && !uri.startsWith('trojan://')) return;
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('custom_servers') ?? [];
    if (!list.contains(uri)) list.add(uri);
    await prefs.setStringList('custom_servers', list);
    await _loadServers();
  }

  Color _pingColor(int? p) {
    if (p == null) return Colors.grey;
    if (p <= 120) return Colors.green;
    if (p <= 220) return Colors.orange;
    return Colors.red;
  }

  void _toggle() async {
    if (connecting) return;
    setState(() => connecting = true);
    await Future.delayed(const Duration(milliseconds: 900));
    setState(() {
      connected = !connected;
      connecting = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final bg = dark ? const Color(0xFF090B0D) : Colors.white;
    final fg = dark ? Colors.white : const Color(0xFF111111);
    final green = const Color(0xFF22C55E);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: dark ? Brightness.dark : Brightness.light,
        scaffoldBackgroundColor: bg,
        colorScheme: ColorScheme.fromSeed(seedColor: green, brightness: dark ? Brightness.dark : Brightness.light),
        useMaterial3: true,
      ),
      home: Scaffold(
        appBar: AppBar(
          title: const Text('Manoto VPN', style: TextStyle(fontWeight: FontWeight.w800)),
          actions: [
            IconButton(onPressed: () => setState(() => dark = !dark), icon: Icon(dark ? Icons.light_mode : Icons.dark_mode)),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 18),
              Text(connected ? 'CONNECTED' : (connecting ? 'CONNECTING' : 'DISCONNECTED'),
                style: TextStyle(color: connected ? green : fg, fontWeight: FontWeight.w800, letterSpacing: 2)),
              const SizedBox(height: 10),
              GestureDetector(
                onTap: _toggle,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 500),
                  width: 210, height: 210,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: connected ? green : fg.withOpacity(.35), width: 2),
                    boxShadow: connected ? [BoxShadow(color: green.withOpacity(.22), blurRadius: 45, spreadRadius: 8)] : [],
                  ),
                  child: Center(
                    child: Text(
                      connected ? '🤝' : '✊   ✊',
                      style: TextStyle(fontSize: connected ? 72 : 42),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(servers.isEmpty ? 'Loading servers...' : '${servers[selected].name}  •  ${servers[selected].ping ?? '--'} ms',
                style: TextStyle(color: fg, fontWeight: FontWeight.w700)),
              const SizedBox(height: 18),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                  itemCount: servers.length,
                  itemBuilder: (_, i) {
                    final s = servers[i];
                    return Card(
                      child: ListTile(
                        onTap: () => setState(() => selected = i),
                        leading: CircleAvatar(
                          backgroundColor: _pingColor(s.ping).withOpacity(.15),
                          child: Icon(Icons.public, color: _pingColor(s.ping)),
                        ),
                        title: Text(s.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle: Text(s.protocol),
                        trailing: Text('${s.ping ?? '--'} ms',
                          style: TextStyle(color: _pingColor(s.ping), fontWeight: FontWeight.w900)),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _addFromClipboard,
          icon: const Icon(Icons.add_link),
          label: const Text('Add Config'),
        ),
        bottomNavigationBar: NavigationBar(
          selectedIndex: 0,
          destinations: const [
            NavigationDestination(icon: Icon(Icons.vpn_key), label: 'VPN'),
            NavigationDestination(icon: Icon(Icons.dns), label: 'Servers'),
            NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
          ],
          onDestinationSelected: (i) {
            if (i == 2) showModalBottomSheet(
              context: context,
              builder: (_) => ListTile(
                title: const Text('Privacy'),
                subtitle: const Text('Developer email: developer@example.com'),
              ),
            );
          },
        ),
      ),
    );
  }
}
