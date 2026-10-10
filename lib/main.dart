import 'dart:io';
import 'package:flutter/material.dart';
import 'package:health/health.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Public anon key only. NEVER put the service-role key in the app.
const supabaseUrl = 'https://rrwwoghnwfabqkqhgrsk.supabase.co';
const supabaseAnonKey = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJyd3dvZ2hud2ZhYnFrcWhncnNrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTAzNTI1MzksImV4cCI6MjEwNTkyODUzOX0.86vkPZcoAhqWJEIOJLWlSGe1fRIARNUcp090LGWRjPo';
SupabaseClient get sb => Supabase.instance.client;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  runApp(const NetwalkApp());
}

class NetwalkApp extends StatelessWidget {
  const NetwalkApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'NETWALK',
        theme: ThemeData(colorSchemeSeed: const Color(0xFF0A7D45), useMaterial3: true),
        home: StreamBuilder<AuthState>(
          stream: sb.auth.onAuthStateChange,
          builder: (_, __) => sb.auth.currentSession == null ? const AuthPage() : const HomePage(),
        ),
      );
}

void snack(BuildContext c, String m) => ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});
  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final email = TextEditingController(), pass = TextEditingController(), name = TextEditingController(), ref = TextEditingController();
  bool register = false, busy = false;

  Future<void> submit() async {
    final e = email.text.trim();
    if (!RegExp(r'^\S+@\S+\.\S+$').hasMatch(e)) return snack(context, 'Enter a valid email');
    if (pass.text.length < 8) return snack(context, 'Password must be at least 8 characters');
    if (register && name.text.trim().isEmpty) return snack(context, 'Enter your name');
    setState(() => busy = true);
    try {
      if (register) {
        final r = await sb.auth.signUp(email: e, password: pass.text, data: {'full_name': name.text.trim(), 'ref': ref.text.trim()});
        if (r.session == null && mounted) snack(context, 'Check your email to confirm, then sign in.');
      } else {
        await sb.auth.signInWithPassword(email: e, password: pass.text);
      }
    } on AuthException catch (x) {
      if (mounted) snack(context, x.message);
    } catch (_) {
      if (mounted) snack(context, 'Network problem. Try again.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> forgot() async {
    final e = email.text.trim();
    if (e.isEmpty) return snack(context, 'Enter your email first');
    try {
      await sb.auth.resetPasswordForEmail(e);
      if (mounted) snack(context, 'If that email exists, a reset link is on its way.');
    } on AuthException catch (x) {
      if (mounted) snack(context, x.message);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            const SizedBox(height: 40),
            Text('NETWALK', style: Theme.of(context).textTheme.headlineLarge),
            const Text('Walk. Earn points. Cash out in naira.'),
            const SizedBox(height: 20),
            if (register) TextField(controller: name, decoration: const InputDecoration(labelText: 'Full name')),
            TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
            TextField(controller: pass, obscureText: true, decoration: const InputDecoration(labelText: 'Password (min 8)')),
            if (register) TextField(controller: ref, decoration: const InputDecoration(labelText: 'Referral code (optional)')),
            const SizedBox(height: 16),
            FilledButton(onPressed: busy ? null : submit, child: Text(register ? 'Register' : 'Sign in')),
            TextButton(onPressed: () => setState(() => register = !register), child: Text(register ? 'I have an account' : 'Create account')),
            if (!register) TextButton(onPressed: forgot, child: const Text('Forgot password?')),
          ]),
        ),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  Map<String, dynamic>? wallet;
  String? loadError;
  bool busy = false;
  int? steps;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final w = await sb.from('wallets').select().eq('user_id', sb.auth.currentUser!.id).single();
      if (mounted) setState(() { wallet = w; loadError = null; });
    } catch (_) {
      if (mounted) setState(() => loadError = 'Could not load wallet. Pull to retry.');
    }
  }

  Future<void> claim() async {
    setState(() => busy = true);
    try {
      final r = await sb.rpc('claim_daily_reward');
      if (r is Map && r['error'] != null) throw r['error'];
      if (mounted) snack(context, 'Claimed ${r['points']} points (day ${r['streak']})');
      await load();
    } on PostgrestException catch (x) {
      if (mounted) snack(context, x.message);
    } catch (x) {
      if (mounted) snack(context, '$x');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> syncSteps() async {
    setState(() => busy = true);
    try {
      final h = Health();
      await h.configure();
      final ok = await h.requestAuthorization([HealthDataType.STEPS]);
      if (!ok) throw 'Health permission was not granted';
      final now = DateTime.now();
      final n = await h.getTotalStepsInInterval(DateTime(now.year, now.month, now.day), now) ?? 0;
      final r = await sb.functions.invoke('ingest-steps', body: {'steps': n, 'source': Platform.isIOS ? 'healthkit' : 'health_connect'});
      final d = r.data;
      if (d is Map && d['error'] != null) throw d['error'];
      if (mounted) { setState(() => steps = n); snack(context, d['earned'] > 0 ? 'Earned ${d['earned']} points' : 'Steps synced: $n'); }
      await load();
    } on FunctionException catch (x) {
      if (mounted) snack(context, '${(x.details is Map ? x.details['error'] : null) ?? 'Step sync failed'}');
    } catch (x) {
      if (mounted) snack(context, '$x');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = (wallet?['balance_points'] ?? 0) as int;
    return Scaffold(
      appBar: AppBar(title: const Text('NETWALK'), actions: [IconButton(icon: const Icon(Icons.logout), onPressed: () => sb.auth.signOut())]),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(padding: const EdgeInsets.all(20), children: [
          if (loadError != null) Text(loadError!, style: const TextStyle(color: Colors.red)),
          Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Available balance'),
            Text('$p pts', style: Theme.of(context).textTheme.headlineLarge),
            Text('₦${(p / 100).toStringAsFixed(2)}'),
          ]))),
          const SizedBox(height: 12),
          FilledButton(onPressed: busy ? null : claim, child: const Text('Claim daily reward')),
          const SizedBox(height: 8),
          FilledButton.tonal(onPressed: busy ? null : syncSteps, child: Text(steps == null ? 'Sync my steps' : 'Steps today: $steps (tap to sync)')),
        ]),
      ),
    );
  }
}
