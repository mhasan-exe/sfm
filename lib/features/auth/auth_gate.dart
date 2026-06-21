import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../core/services/admin_service.dart';
import 'login_screen.dart';
import '../../core/widgets/app_background.dart';

class AuthGate extends StatefulWidget {
  final Widget child;

  const AuthGate({
    super.key,
    required this.child,
  });

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  final adminService = AdminService();
  bool _hasSeededAdmin = false;

  static const _seedAdminEmail = '2817783@students.akesp.net';
  static const _seedAdminUid = 'JWVBLS2n9fOIDejjeVWrecmdQRy1';

  Future<void> _seedAdminIfNeeded(User user) async {
    if (_hasSeededAdmin) return;
    final normalizedEmail = user.email?.toLowerCase();
    if (user.uid == _seedAdminUid && normalizedEmail == _seedAdminEmail) {
      await adminService.createAdmin(
        email: normalizedEmail!,
        uid: user.uid,
      );
      _hasSeededAdmin = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return AppBackground(
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
          );
        }

        if (snapshot.hasData) {
          final user = snapshot.data!;
          if (!_hasSeededAdmin) {
            Future.microtask(
              () => _seedAdminIfNeeded(user),
            );
          }
          return AppBackground(child: widget.child);

        }

        return const LoginScreen();
      },
    );
  }
}