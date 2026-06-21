import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'user_service.dart';

class AuthService {
  bool isAllowedEmail(String email) {
    email = email.toLowerCase();

    return email.endsWith('@akesp.net') ||
        email == '2817783@students.akesp.net';
  }

  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Lazy + non-web only: constructing GoogleSignIn() unconditionally used to
  // initialize the google_sign_in_web plugin on web even though the web
  // sign-in path below never calls it (web uses Firebase's signInWithPopup
  // instead) — that unwanted initialization was throwing an uncaught error
  // in the browser console on every app load.
  GoogleSignIn? _googleSignInInstance;
  GoogleSignIn get _googleSignIn {
    assert(!kIsWeb, 'google_sign_in package should never be touched on web');
    return _googleSignInInstance ??= GoogleSignIn(scopes: ['email']);
  }

  Future<UserCredential?> signInWithGoogle() async {
    if (kIsWeb) {
      final existingUser = _auth.currentUser;
      if (existingUser != null) {
        // Already signed in; don't start a new popup flow.
        return Future.value();
      }



      final provider = GoogleAuthProvider();
      provider.setCustomParameters({
        'prompt': 'select_account',
      });

      final userCredential = await _auth.signInWithPopup(provider);
      final email = userCredential.user?.email?.toLowerCase() ?? '';
      if (!isAllowedEmail(email)) {
        await signOut();
        throw Exception(
          'Only AKESP staff accounts are allowed.',
        );
      }

      await UserService().createUserIfNotExists();
      return userCredential;
    }


    final googleUser = await _googleSignIn.signIn();

    if (googleUser == null) {
      return null;
    }

    final googleAuth = await googleUser.authentication;

    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    final userCredential = await _auth.signInWithCredential(credential);
    final email = userCredential.user?.email?.toLowerCase() ?? '';

    if (!isAllowedEmail(email)) {
      await signOut();
      throw Exception(
        'Only AKESP staff accounts are allowed.',
      );
    }

    await UserService().createUserIfNotExists();
    return userCredential;
  }

  Future<void> signOut() async {
    if (!kIsWeb) {
      await _googleSignIn.signOut();
    }
    await _auth.signOut();
  }
}
