import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../data/datasources/oauth_provider.dart';
import '../bloc/auth_bloc.dart';

class AuthScreen extends StatelessWidget {
  const AuthScreen({super.key, required this.signUp});
  final bool signUp;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              colors.primaryContainer.withValues(alpha: .6),
              colors.surface,
              colors.secondaryContainer.withValues(alpha: .3),
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(28),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: BlocBuilder<AuthBloc, AuthState>(
                  builder: (context, state) {
                    final busy = state is AuthLoading;
                    void submit(AuthProvider provider) =>
                        context.read<AuthBloc>().add(
                          signUp
                              ? AuthSignUpRequested(provider)
                              : AuthSignInRequested(provider),
                        );
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.all(18),
                            decoration: BoxDecoration(
                              color: colors.primary,
                              borderRadius: BorderRadius.circular(26),
                            ),
                            child: Icon(
                              Icons.forum_rounded,
                              size: 36,
                              color: colors.onPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'qLink',
                          style: text.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1,
                          ),
                        ),
                        const SizedBox(height: 44),
                        Text(
                          signUp
                              ? 'Good conversations\nstart here.'
                              : 'Your people.\nA little closer.',
                          style: text.displaySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            height: 1.12,
                            letterSpacing: -1.4,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Text(
                          signUp ? 'Create your account' : 'Welcome back',
                          style: text.titleLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          signUp
                              ? 'Make room for everyday moments. Join qLink with your preferred account.'
                              : 'Sign in to reconnect with the conversations that matter to you.',
                          style: text.bodyLarge?.copyWith(
                            color: colors.onSurfaceVariant,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 32),
                        AnimatedOpacity(
                          opacity: busy ? .55 : 1,
                          duration: const Duration(milliseconds: 180),
                          child: OutlinedButton.icon(
                            onPressed:
                                busy || !NativeOAuthProvider.supportsGoogle
                                ? null
                                : () => submit(AuthProvider.google),
                            // Google brand colors intentionally remain independent of app seed.
                            style: OutlinedButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: const Color(0xFF1F1F1F),
                              disabledBackgroundColor: Colors.white,
                              disabledForegroundColor: const Color(0xFF747775),
                              side: const BorderSide(color: Color(0xFF747775)),
                              minimumSize: const Size(double.infinity, 52),
                              shape: const StadiumBorder(),
                            ),
                            icon: Image.asset(
                              'assets/branding/google_g.png',
                              width: 20,
                              height: 20,
                            ),
                            label: const Text(
                              'Continue with Google',
                              style: TextStyle(fontWeight: FontWeight.w500),
                            ),
                          ),
                        ),
                        if (NativeOAuthProvider.supportsApple) ...[
                          const SizedBox(height: 12),
                          IgnorePointer(
                            ignoring: busy,
                            child: AnimatedOpacity(
                              opacity: busy ? .55 : 1,
                              duration: const Duration(milliseconds: 180),
                              child: SignInWithAppleButton(
                                onPressed: () => submit(AuthProvider.apple),
                                text: 'Continue with Apple',
                                height: 52,
                                borderRadius: BorderRadius.circular(26),
                                style:
                                    Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? SignInWithAppleButtonStyle.white
                                    : SignInWithAppleButtonStyle.black,
                              ),
                            ),
                          ),
                        ],
                        if (!NativeOAuthProvider.supportsGoogle)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              'Use the Android or iOS app to sign in.',
                              style: text.bodyMedium,
                            ),
                          ),
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          child: busy
                              ? const Padding(
                                  key: ValueKey('loading'),
                                  padding: EdgeInsets.all(20),
                                  child: Center(
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  ),
                                )
                              : state is AuthFailure
                              ? Padding(
                                  key: ValueKey(state.message),
                                  padding: const EdgeInsets.only(top: 20),
                                  child: Semantics(
                                    liveRegion: true,
                                    child: Text(
                                      state.message,
                                      style: TextStyle(color: colors.error),
                                    ),
                                  ),
                                )
                              : const SizedBox(height: 24),
                        ),
                        Wrap(
                          alignment: WrapAlignment.center,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              signUp
                                  ? 'Already part of qLink?'
                                  : 'New to qLink?',
                              style: text.bodyMedium,
                            ),
                            TextButton(
                              onPressed: busy
                                  ? null
                                  : () => context.go(
                                      signUp ? '/signin' : '/signup',
                                    ),
                              child: Text(
                                signUp ? 'Sign in' : 'Create an account',
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 32),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.lock_outline_rounded,
                              size: 14,
                              color: colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'A familiar account. A fresh connection.',
                                style: text.labelMedium?.copyWith(
                                  color: colors.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
