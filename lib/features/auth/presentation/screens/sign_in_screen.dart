import 'package:flutter/material.dart';

import '../widgets/auth_screen.dart';

class SignInScreen extends StatelessWidget {
  const SignInScreen({super.key});
  @override
  Widget build(BuildContext context) => const AuthScreen(signUp: false);
}
