import 'package:flutter/material.dart';

String searchPreview(String text, String query) {
  final match = query.isEmpty
      ? null
      : RegExp(RegExp.escape(query), caseSensitive: false).firstMatch(text);
  final start = ((match?.start ?? 0) - 50).clamp(0, text.length);
  final end = (start + 220).clamp(0, text.length);
  return '${start > 0 ? '…' : ''}${text.substring(start, end)}${end < text.length ? '…' : ''}';
}

class SearchHighlight extends StatelessWidget {
  const SearchHighlight(this.text, this.query, {super.key, this.maxLines = 2});
  final String text, query;
  final int maxLines;
  @override
  Widget build(BuildContext context) {
    final spans = <TextSpan>[];
    var end = 0;
    if (query.isNotEmpty) {
      for (final match in RegExp(
        RegExp.escape(query),
        caseSensitive: false,
      ).allMatches(text)) {
        spans.add(TextSpan(text: text.substring(end, match.start)));
        spans.add(
          TextSpan(
            text: text.substring(match.start, match.end),
            style: TextStyle(
              backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
              color: Theme.of(context).colorScheme.onSecondaryContainer,
              fontWeight: FontWeight.bold,
            ),
          ),
        );
        end = match.end;
      }
    }
    spans.add(TextSpan(text: text.substring(end)));
    return Text.rich(
      TextSpan(children: spans),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}
