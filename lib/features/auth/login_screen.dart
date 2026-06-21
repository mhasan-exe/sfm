import 'package:flutter/material.dart';

import '../../core/services/auth_service.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_background.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool loading = false;

  Future<void> login() async {
    setState(() {
      loading = true;
    });

    try {
      final result = await AuthService().signInWithGoogle().timeout(
        const Duration(seconds: 60),
      );

      // User may cancel account selection / sign-in flow.
      if (result == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Sign-in cancelled. Please try again.'),
          ),
        );
        setState(() {
          loading = false;
        });
        return;
      }

      if (!mounted) return;
    } catch (e) {
      if (!mounted) return;

      final msg = e.toString();
      final lower = msg.toLowerCase();
      final isTimeout = lower.contains('timeout');

      final String message = isTimeout
          ? 'Login timed out. Check your internet connection and try again.'
          : lower.contains('only akesp')
              ? 'Please sign in using an approved AKESP account.'
              : 'Login failed. Please try again later.';

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
        ),
      );

      debugPrint('Login error: $e');
      setState(() {
        loading = false;
      });
      return;
    }

    setState(() {
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Center(
            child: Padding(
              padding: AppTheme.pagePadding(context),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.school,
                    size: 90,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'AKESP Timetable System',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 40),
                  SizedBox(
                    width: (MediaQuery.of(context).size.width * 0.85).clamp(0.0, 320.0),
                    height: 55,
                    child: ElevatedButton.icon(
                      onPressed: loading ? null : login,
                      icon: const Icon(Icons.login),
                      label: loading
                          ? const CircularProgressIndicator()
                          : const Text('Continue with Google'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

