import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../../core/error/app_exception.dart';
import '../../data/datasources/oauth_provider.dart';
import '../../data/models/app_user.dart';
import '../../data/repositories/auth_repository.dart';

sealed class AuthEvent extends Equatable {
  const AuthEvent();
  @override
  List<Object?> get props => [];
}

class AuthProfileUpdated extends AuthEvent {
  const AuthProfileUpdated(this.user);
  final AppUser user;
  @override
  List<Object?> get props => [user];
}

class AuthStarted extends AuthEvent {
  const AuthStarted();
}

class AuthSessionExpired extends AuthEvent {
  const AuthSessionExpired();
}

class AuthSignOutRequested extends AuthEvent {
  const AuthSignOutRequested();
}

class AuthSignInRequested extends AuthEvent {
  const AuthSignInRequested(this.provider);
  final AuthProvider provider;
  @override
  List<Object?> get props => [provider];
}

class AuthSignUpRequested extends AuthEvent {
  const AuthSignUpRequested(this.provider);
  final AuthProvider provider;
  @override
  List<Object?> get props => [provider];
}

sealed class AuthState extends Equatable {
  const AuthState();
  AppUser? get user => null;
  @override
  List<Object?> get props => [];
}

class AuthInitial extends AuthState {
  const AuthInitial();
}

class AuthLoading extends AuthState {
  const AuthLoading({this.user, this.startup = false});
  @override
  final AppUser? user;
  final bool startup;
  @override
  List<Object?> get props => [user, startup];
}

class AuthAuthenticated extends AuthState {
  const AuthAuthenticated(this.user);
  @override
  final AppUser user;
  @override
  List<Object?> get props => [user];
}

class AuthUnauthenticated extends AuthState {
  const AuthUnauthenticated({this.message});
  final String? message;
  @override
  List<Object?> get props => [message];
}

class AuthFailure extends AuthState {
  const AuthFailure(this.message, {this.user});
  final String message;
  @override
  final AppUser? user;
  @override
  List<Object?> get props => [message, user];
}

class AuthBloc extends Bloc<AuthEvent, AuthState> {
  AuthBloc(this.repository) : super(const AuthInitial()) {
    on<AuthEvent>(_handle);
  }
  final AuthRepository repository;
  bool _busy = false;
  int _generation = 0;

  Future<void> _handle(AuthEvent event, Emitter<AuthState> emit) async {
    if (event is AuthSessionExpired) {
      // The in-flight sign-out reports its more precise revocation warning.
      if (_signingOut) return;
      _generation++;
      emit(
        const AuthUnauthenticated(
          message: 'Your session expired. Please sign in again.',
        ),
      );
      return;
    }
    if (event is AuthProfileUpdated) {
      if (!_busy && state.user?.id == event.user.id) {
        emit(AuthAuthenticated(event.user));
      }
      return;
    }
    if (_busy) return;
    _busy = true;
    final generation = _generation;
    final previousUser = state.user;
    emit(AuthLoading(user: previousUser, startup: event is AuthStarted));
    try {
      if (event is AuthSignOutRequested) {
        _signingOut = true;
        final warning = await repository.signOut();
        emit(AuthUnauthenticated(message: warning));
      } else {
        final user = switch (event) {
          AuthStarted() => await repository.restore(),
          AuthSignInRequested(:final provider) => await repository.authenticate(
            provider,
            signUp: false,
          ),
          AuthSignUpRequested(:final provider) => await repository.authenticate(
            provider,
            signUp: true,
          ),
          _ => null,
        };
        if (generation == _generation) {
          emit(
            user == null
                ? const AuthUnauthenticated()
                : AuthAuthenticated(user),
          );
        }
      }
    } catch (error) {
      if (generation == _generation) {
        final failure = AppException.from(error);
        emit(
          failure.canceled
              ? const AuthUnauthenticated()
              : AuthFailure(failure.message, user: previousUser),
        );
      }
    } finally {
      _busy = false;
      _signingOut = false;
    }
  }

  bool _signingOut = false;
}
