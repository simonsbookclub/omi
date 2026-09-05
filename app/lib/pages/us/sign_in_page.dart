import 'package:flutter/material.dart';

import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:provider/provider.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:omi/backend/preferences.dart';
import 'package:omi/env/env.dart';
import 'package:omi/providers/auth_provider.dart';
import 'package:omi/services/us_session.dart';
import 'package:omi/utils/logger.dart';

/// SIMONSBOOKCLUB ("Us"): the sign-in screen. Sign in with Apple, sign in
/// with Oura (browser round-trip back through chronicle://auth), or — on a
/// build that carries the owner token — continue as the owner.
class UsSignInPage extends StatefulWidget {
  const UsSignInPage({super.key});

  @override
  State<UsSignInPage> createState() => _UsSignInPageState();
}

class _UsSignInPageState extends State<UsSignInPage> {
  bool _busy = false;
  String? _error;

  Future<void> _apple() async {
    setState(() { _busy = true; _error = null; });
    try {
      final cred = await SignInWithApple.getAppleIDCredential(
        scopes: [AppleIDAuthorizationScopes.email, AppleIDAuthorizationScopes.fullName],
      );
      final token = cred.identityToken;
      if (token == null) throw Exception('Apple returned no identity token');
      final err = await UsSession.signInWithApple(identityToken: token, givenName: cred.givenName);
      if (err != null) throw Exception(err);
      _finish();
    } on SignInWithAppleAuthorizationException catch (e) {
      if (e.code != AuthorizationErrorCode.canceled) setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _oura() async {
    setState(() { _busy = true; _error = null; });
    try {
      final uri = Uri.parse('${UsSession.origin}/auth/oura/start');
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) setState(() => _error = 'Could not open the browser.');
      // The app comes back through chronicle://auth (app_shell.dart).
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _owner() async {
    setState(() { _busy = true; _error = null; });
    final ok = await UsSession.ensureSession();
    if (!ok) {
      setState(() { _busy = false; _error = 'The owner token was refused.'; });
      return;
    }
    _finish();
  }

  void _finish() {
    SharedPreferencesUtil().onboardingCompleted = true;
    SharedPreferencesUtil().aiConsentGiven = true;
    context.read<AuthenticationProvider>().refreshSignInState();
    Logger.debug('Us: signed in as ${UsSession.userId}');
  }

  @override
  Widget build(BuildContext context) {
    final hasOwnerToken = Env.nativeBackendToken.isNotEmpty;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('Chronicle', style: TextStyle(color: Colors.white, fontSize: 40, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              const Text(
                'Us: two rings and a pendant, one honest number each morning.',
                style: TextStyle(color: Colors.white70, fontSize: 17, height: 1.4),
              ),
              const SizedBox(height: 40),
              _button(
                icon: FontAwesomeIcons.apple,
                label: 'Sign in with Apple',
                onTap: _busy ? null : _apple,
                background: Colors.white,
                foreground: Colors.black,
              ),
              const SizedBox(height: 12),
              _button(
                icon: FontAwesomeIcons.ring,
                label: 'Sign in with Oura',
                onTap: _busy ? null : _oura,
                background: const Color(0xFF2A2A2E),
                foreground: Colors.white,
              ),
              if (hasOwnerToken) ...[
                const SizedBox(height: 12),
                _button(
                  icon: FontAwesomeIcons.key,
                  label: 'Continue as the owner',
                  onTap: _busy ? null : _owner,
                  background: const Color(0xFF1A1A1E),
                  foreground: Colors.white70,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 20),
                Text(_error!, style: const TextStyle(color: Color(0xFFE5785C), fontSize: 14)),
              ],
              if (_busy) const Padding(padding: EdgeInsets.only(top: 20), child: Center(child: CircularProgressIndicator(color: Colors.white54))),
              const SizedBox(height: 32),
              const Text(
                'Your conversations stay on your own server. Relationship analysis runs only on conversations where both partners are present and have consented.',
                style: TextStyle(color: Colors.white38, fontSize: 13, height: 1.4),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _button({required FaIconData icon, required String label, required VoidCallback? onTap, required Color background, required Color foreground}) {
    return SizedBox(
      height: 54,
      child: ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          backgroundColor: background,
          foregroundColor: foreground,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          elevation: 0,
        ),
        onPressed: onTap,
        icon: FaIcon(icon, size: 20),
        label: Text(label, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
