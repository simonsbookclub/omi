import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';

import 'package:omi/backend/http/api/us.dart';
import 'package:omi/pages/us/voice_enroll_page.dart';
import 'package:omi/providers/auth_provider.dart';
import 'package:omi/providers/us_provider.dart';
import 'package:omi/services/us_session.dart';
import 'package:omi/widgets/dialog.dart';

/// SIMONSBOOKCLUB ("Us"): who am I, what is linked, which voice is mine.
class UsAccountPage extends StatefulWidget {
  const UsAccountPage({super.key});

  @override
  State<UsAccountPage> createState() => _UsAccountPageState();
}

class _UsAccountPageState extends State<UsAccountPage> {
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => context.read<UsProvider>().loadAccount());
  }

  Future<void> _run(Future<void> Function() fn) async {
    setState(() { _busy = true; _message = null; });
    try {
      await fn();
    } catch (e) {
      setState(() => _message = e.toString());
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        context.read<UsProvider>().loadAccount();
      }
    }
  }

  /// Sign in to Oura in the browser on this phone; [actAs] links the ring
  /// to the partner's profile instead of the owner's.
  Future<void> _linkOura(String? actAs) => _run(() async {
        await UsSession.ensureSession();
        final r = await UsApi.ouraLinkUrl(actAs: actAs);
        final url = r?['url'];
        if (url is! String) throw Exception(r?['error'] ?? 'Oura is not configured yet.');
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      });

  /// A sign-in link the partner opens on her own phone: she signs in to
  /// Oura there, the ring attaches to her profile here. Valid for a day.
  Future<void> _shareOuraLink(String actAs, String name) => _run(() async {
        await UsSession.ensureSession();
        final r = await UsApi.ouraLinkUrl(actAs: actAs, web: true);
        final url = r?['url'];
        if (url is! String) throw Exception(r?['error'] ?? 'Oura is not configured yet.');
        await SharePlus.instance.share(ShareParams(
          text: '$name, this links your Oura ring to Chronicle. Open it on your phone and sign in to Oura. It works for 24 hours.\n$url',
          subject: 'Link your Oura ring to Chronicle',
        ));
      });

  Future<void> _linkApple() => _run(() async {
        await UsSession.ensureSession();
        final cred = await SignInWithApple.getAppleIDCredential(scopes: [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName]);
        final token = cred.identityToken;
        if (token == null) throw Exception('Apple returned no identity token');
        final err = await UsSession.signInWithApple(identityToken: token, givenName: cred.givenName, link: UsSession.token);
        if (err != null) throw Exception(err);
        setState(() => _message = 'Apple ID linked.');
      });

  Future<void> _claimVoice() => _run(() async {
        await UsSession.ensureSession();
        final r = await UsApi.voices();
        final voices = ((r?['voices'] as List?) ?? const []).cast<Map<String, dynamic>>();
        if (!mounted) return;
        final chosen = await showModalBottomSheet<String>(
          context: context,
          backgroundColor: const Color(0xFF1F1F25),
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(padding: EdgeInsets.all(16), child: Text('Which voice is yours?', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600))),
                for (final v in voices)
                  ListTile(
                    title: Text(v['person_name'].toString(), style: const TextStyle(color: Colors.white)),
                    subtitle: Text('${v['sample_count']} samples${v['user_id'] != null ? ' · linked' : ''}', style: const TextStyle(color: Colors.white54)),
                    onTap: () => Navigator.of(ctx).pop(v['person_name'].toString()),
                  ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        );
        if (chosen == null) return;
        final res = await UsApi.claimVoice(chosen);
        if (res?['error'] != null) throw Exception(res!['error']);
        setState(() => _message = 'Your voice is "$chosen".');
        if (mounted) context.read<UsProvider>().refresh(force: true);
      });

  Future<void> _recordVoice() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VoiceEnrollPage()));
    if (!mounted) return;
    context.read<UsProvider>().loadAccount();
  }

  Future<void> _signOut() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => getDialog(c, () => Navigator.of(c).pop(false), () => Navigator.of(c).pop(true), 'Sign out', 'Sign out of Chronicle on this phone?', okButtonText: 'Sign out'),
    );
    if (ok != true) return;
    await UsApi.signOut();
    await UsSession.clear();
    if (!mounted) return;
    context.read<AuthenticationProvider>().refreshSignInState();
    Navigator.of(context).popUntil((r) => r.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final account = context.watch<UsProvider>().account;
    final user = account?['user'] as Map<String, dynamic>?;
    final identities = ((account?['identities'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final wearables = ((account?['wearables'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final oura = wearables.where((w) => w['provider'] == 'oura').firstOrNull;
    final partner = account?['partner'] as Map<String, dynamic>?;
    final partnerWearables = ((partner?['wearables'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final partnerOura = partnerWearables.where((w) => w['provider'] == 'oura').firstOrNull;
    final ouraAvailable = account?['oura_available'] == true;
    final voice = account?['voice'];
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('Account')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _card([
            _row('Name', (user?['given_name'] ?? UsSession.userName).toString().isEmpty ? '—' : (user?['given_name'] ?? UsSession.userName).toString()),
            _row('User id', (user?['id'] ?? UsSession.userId).toString()),
            _row('Time zone', (user?['timezone'] ?? 'Europe/Lisbon').toString()),
            if (account?['legacy_owner'] == true) _row('Signed in via', 'owner token'),
          ]),
          const SizedBox(height: 16),
          const _Header('Sign-in'),
          _card([
            for (final i in identities) _row(i['provider'].toString(), (i['email'] ?? 'linked').toString()),
            if (identities.isEmpty) _row('Linked', 'none yet'),
            _action(FontAwesomeIcons.apple, 'Link Apple ID', _busy ? null : _linkApple),
          ]),
          const SizedBox(height: 16),
          const _Header('Rings'),
          _ringCard('Your ring', oura, null, ouraAvailable),
          if (partner != null) ...[
            const SizedBox(height: 8),
            _ringCard("${partner['name']}'s ring", partnerOura, partner['user_id'].toString(), ouraAvailable, shareName: partner['name'].toString()),
          ],
          const SizedBox(height: 16),
          const _Header('Voice'),
          _card([
            _row('My voice', voice?.toString() ?? 'not chosen'),
            _action(FontAwesomeIcons.microphone, 'Record my voice (read a passage)', _busy ? null : _recordVoice),
            _action(FontAwesomeIcons.userCheck, 'This voice is me (pick a known voice)', _busy ? null : _claimVoice),
          ]),
          if (_message != null) Padding(padding: const EdgeInsets.all(12), child: Text(_message!, style: const TextStyle(color: Colors.white70))),
          const SizedBox(height: 24),
          TextButton(onPressed: _signOut, child: const Text('Sign out', style: TextStyle(color: Color(0xFFE5785C)))),
        ],
      ),
    );
  }

  /// One ring, one card: the owner's, or the partner's linked from this
  /// phone or from a link sent to hers.
  Widget _ringCard(String title, Map<String, dynamic>? oura, String? actAs, bool available, {String? shareName}) => _card([
        if (oura != null) ...[
          _row(title, oura['last_sync_at'] != null ? 'synced ${oura['last_sync_at']}' : 'linked, not synced yet'),
          if (oura['last_error'] != null) _row('Last error', oura['last_error'].toString()),
          _action(FontAwesomeIcons.rotate, 'Sync now', _busy ? null : () => _run(() async { await UsApi.ouraSync(actAs: actAs); })),
          _action(FontAwesomeIcons.linkSlash, 'Unlink', _busy ? null : () => _run(() async { await UsApi.ouraUnlink(actAs: actAs); })),
        ] else ...[
          _row(title, available ? 'not linked' : 'not configured on the server yet'),
          _action(FontAwesomeIcons.ring, actAs == null ? 'Link Oura ring' : 'Sign in to Oura on this phone', _busy || !available ? null : () => _linkOura(actAs)),
          if (shareName != null && actAs != null)
            _action(FontAwesomeIcons.paperPlane, 'Send $shareName a sign-in link', _busy || !available ? null : () => _shareOuraLink(actAs, shareName)),
        ],
      ]);

  Widget _card(List<Widget> children) => Container(
        decoration: BoxDecoration(color: const Color(0xFF1F1F25), borderRadius: BorderRadius.circular(14)),
        child: Column(children: children),
      );

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Text(k, style: const TextStyle(color: Colors.white54)),
            const SizedBox(width: 16),
            Expanded(child: Text(v, textAlign: TextAlign.right, style: const TextStyle(color: Colors.white))),
          ],
        ),
      );

  Widget _action(FaIconData icon, String label, VoidCallback? onTap) => ListTile(
        leading: FaIcon(icon, color: onTap == null ? Colors.white24 : Colors.white70, size: 18),
        title: Text(label, style: TextStyle(color: onTap == null ? Colors.white24 : Colors.white)),
        onTap: onTap,
      );
}

class _Header extends StatelessWidget {
  final String text;
  const _Header(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(text.toUpperCase(), style: const TextStyle(color: Colors.white38, fontSize: 12, letterSpacing: 1.2)),
      );
}
