import 'package:flutter/material.dart';

import 'focus_ring.dart';
import 'motion/motion_widgets.dart';

class StatusView extends StatelessWidget {
  const StatusView({
    super.key,
    required this.title,
    this.message,
    this.icon = Icons.movie_filter_outlined,
    this.action,
    this.onAction,
    this.secondaryAction,
    this.onSecondaryAction,
    this.autofocus = false,
  }) : loading = false;

  const StatusView.loading({super.key, this.title = '正在加载'})
    : message = null,
      icon = null,
      action = null,
      onAction = null,
      secondaryAction = null,
      onSecondaryAction = null,
      autofocus = false,
      loading = true;

  final String title;
  final String? message;
  final IconData? icon;
  final String? action;
  final VoidCallback? onAction;
  final String? secondaryAction;
  final VoidCallback? onSecondaryAction;
  final bool autofocus;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FadeSwitcher(
              scale: true,
              child: loading
                  ? const CircularProgressIndicator(key: ValueKey(true))
                  : Icon(
                      icon,
                      key: const ValueKey(false),
                      size: 56,
                      color: theme.colorScheme.primary,
                    ),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            if (message case final message?) ...[
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (action != null || secondaryAction != null) ...[
              const SizedBox(height: 24),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  if (action case final action?)
                    FocusRing(
                      radius: 999,
                      child: FilledButton.tonal(
                        autofocus: autofocus,
                        onPressed: onAction,
                        child: Text(action),
                      ),
                    ),
                  if (secondaryAction case final secondary?)
                    FocusRing(
                      radius: 999,
                      child: OutlinedButton(
                        onPressed: onSecondaryAction,
                        child: Text(secondary),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
