import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme.dart';
import '../../state/providers.dart';
import '../widgets/common.dart';

/// Filled in at build time with
/// `--dart-define=SONAR_SERVER=https://music.example.com`; empty otherwise.
const defaultServerUrl = String.fromEnvironment('SONAR_SERVER');

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _url = TextEditingController(text: defaultServerUrl);
  final _user = TextEditingController();
  final _pass = TextEditingController();
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_user.text.trim().isEmpty || _pass.text.isEmpty) {
      setState(() => _error = 'Enter your username and password.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(sessionProvider.notifier).login(url: _url.text, username: _user.text, password: _pass.text);
      // The router redirect takes us Home once the session is set.
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.center,
            colors: [Color(0xFF14361F), SonarColors.background],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              // A phone-width form, even in a wide desktop window.
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: AutofillGroup(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Icon(Icons.graphic_eq_rounded, size: 56, color: SonarColors.accentDefault),
                      const SizedBox(height: 16),
                      Text('Sonar', textAlign: TextAlign.center, style: text.headlineMedium),
                      const SizedBox(height: 6),
                      Text('Sign in to your Navidrome server', textAlign: TextAlign.center, style: text.bodyMedium),
                      const SizedBox(height: 36),
                      TextField(
                        controller: _url,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Server URL',
                          hintText: 'https://music.example.com',
                          prefixIcon: Icon(Icons.dns_rounded),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _user,
                        autocorrect: false,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.username],
                        decoration: const InputDecoration(
                          labelText: 'Username',
                          prefixIcon: Icon(Icons.person_rounded),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _pass,
                        obscureText: _obscure,
                        autofillHints: const [AutofillHints.password],
                        onSubmitted: (_) => _submit(),
                        decoration: InputDecoration(
                          labelText: 'Password',
                          prefixIcon: const Icon(Icons.lock_rounded),
                          suffixIcon: IconButton(
                            icon: Icon(_obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded),
                            onPressed: () => setState(() => _obscure = !_obscure),
                          ),
                        ),
                      ),
                      AnimatedSize(
                        duration: SonarMotion.fast,
                        child: _error == null
                            ? const SizedBox(height: 24)
                            : Padding(
                                padding: const EdgeInsets.symmetric(vertical: 14),
                                child: Row(
                                  children: [
                                    const Icon(Icons.error_outline_rounded, color: Color(0xFFFF7A7A), size: 20),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(_error!, style: const TextStyle(color: Color(0xFFFF9C9C))),
                                    ),
                                  ],
                                ),
                              ),
                      ),
                      FilledButton(
                        onPressed: _busy ? null : _submit,
                        child: _busy
                            ? const SizedBox.square(
                                dimension: 22,
                                child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black),
                              )
                            : const Text('Log in'),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        'Tip: use a non-admin Navidrome user for this app.',
                        textAlign: TextAlign.center,
                        style: text.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
