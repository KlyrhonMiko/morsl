import 'package:google_sign_in/google_sign_in.dart';

/// Returns only the identity token; Supabase owns the app session.
abstract interface class GoogleAccountPicker {
  Future<String?> pickAccount();
  Future<void> signOut();
}

class NativeGoogleAccountPicker implements GoogleAccountPicker {
  NativeGoogleAccountPicker({
    this.webClientId = const String.fromEnvironment('GOOGLE_WEB_CLIENT_ID'),
  });

  final String webClientId;
  // GoogleSignIn is a singleton and must be initialized exactly once.
  static Future<void>? _initialization;

  Future<void> _initialize() async {
    if (!RegExp(
      r'^[\w-]+\.apps\.googleusercontent\.com$',
    ).hasMatch(webClientId)) {
      throw StateError(
        'Google sign-in needs the app’s Google client configuration.',
      );
    }
    await (_initialization ??= GoogleSignIn.instance.initialize(
      serverClientId: webClientId,
    ));
  }

  @override
  Future<String?> pickAccount() async {
    try {
      await _initialize();
      final account = await GoogleSignIn.instance.authenticate();
      final token = account.authentication.idToken;
      if (token == null || token.isEmpty) {
        throw StateError(
          'Google could not verify this account. Please try again.',
        );
      }
      return token;
    } on GoogleSignInException catch (error) {
      if (error.code == GoogleSignInExceptionCode.canceled) return null;
      // Never surface native exception details, which may contain credentials.
      throw StateError(
        'Google sign-in could not be completed. Please try again.',
      );
    }
  }

  @override
  Future<void> signOut() async {
    if (_initialization == null) return;
    await _initialization;
    await GoogleSignIn.instance.signOut();
  }
}
