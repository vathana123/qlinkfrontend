import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

import '../../../home/presentation/widgets/blur_app_bar.dart';
import '../../../auth/presentation/bloc/auth_bloc.dart';
import '../../data/models/chat_models.dart';
import '../../data/repositories/chat_repository.dart';
import '../bloc/chat_search_cubit.dart';
import '../widgets/chat_search_panel.dart';

class ChatSearchScreen extends StatelessWidget {
  const ChatSearchScreen({super.key});
  @override
  Widget build(BuildContext context) => BlocProvider(
    key: ValueKey(context.select((AuthBloc bloc) => bloc.state.user?.id)),
    create: (context) => ChatSearchCubit(context.read<ChatRepository>()),
    child: Scaffold(
      appBar: const BlurAppBar(title: 'Search chats'),
      body: SafeArea(
        child: ChatSearchPanel(
          onRoom: (room) async {
            await context.push(
              '/conversation',
              extra: Conversation.fromRoom(room),
            );
          },
          onMessage: (match) async {
            await context.push(
              '/conversation?message=${Uri.encodeQueryComponent(match.message.id)}',
              extra: Conversation.fromRoom(match.room),
            );
          },
        ),
      ),
    ),
  );
}
