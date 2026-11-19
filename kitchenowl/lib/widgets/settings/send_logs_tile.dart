import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:kitchenowl/kitchenowl.dart';
import 'package:kitchenowl/services/app_log_upload.dart';

/// "Send logs" (fork only): asks the watch for its logs, writes a summary of the app's
/// state and sends everything new to the collector now. Hidden when the build has no
/// collector configured.
class SendLogsTile extends StatelessWidget {
  const SendLogsTile({super.key});

  @override
  Widget build(BuildContext context) {
    if (!AppLogUploader.isConfigured) return const SizedBox.shrink();

    return ListTile(
      title: Text(AppLocalizations.of(context)!.sendLogs),
      leading: const Icon(Icons.upload_file_rounded),
      onTap: () => showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => const _SendLogsDialog(),
      ),
    );
  }
}

class _SendLogsDialog extends StatefulWidget {
  const _SendLogsDialog();

  @override
  State<_SendLogsDialog> createState() => _SendLogsDialogState();
}

class _SendLogsDialogState extends State<_SendLogsDialog> {
  late final Future<UploadResult> _result = AppLogUploader.sendNow();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return FutureBuilder<UploadResult>(
      future: _result,
      builder: (context, snapshot) {
        final result = snapshot.data;
        final Widget content;
        if (result == null) {
          content = Row(children: [
            const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(width: 16),
            Expanded(child: Text(l10n.sendLogsSending)),
          ]);
        } else {
          content = Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(result.ok
                  ? l10n.sendLogsDone(result.records)
                  : l10n.sendLogsFailed(result.status ?? '?')),
              if (result.uploadId != null) ...[
                const SizedBox(height: 16),
                Text(l10n.sendLogsId,
                    style: Theme.of(context).textTheme.labelMedium),
                SelectableText(
                  result.uploadId!,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                ),
              ],
            ],
          );
        }

        return AlertDialog(
          title: Text(l10n.sendLogs),
          content: content,
          actions: [
            if (result?.uploadId != null)
              TextButton(
                onPressed: () => Clipboard.setData(
                  ClipboardData(text: result!.uploadId!),
                ),
                child: Text(MaterialLocalizations.of(context).copyButtonLabel),
              ),
            if (result != null)
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(MaterialLocalizations.of(context).okButtonLabel),
              ),
          ],
        );
      },
    );
  }
}
