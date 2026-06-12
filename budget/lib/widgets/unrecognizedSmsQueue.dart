import 'package:budget/colors.dart';
import 'package:budget/database/tables.dart';
import 'package:budget/functions.dart';
import 'package:budget/pages/addEmailTemplate.dart';
import 'package:budget/struct/databaseGlobal.dart';
import 'package:budget/struct/settings.dart';
import 'package:budget/widgets/button.dart';
import 'package:budget/widgets/globalSnackbar.dart';
import 'package:budget/widgets/openContainerNavigation.dart';
import 'package:budget/widgets/openPopup.dart';
import 'package:budget/widgets/openSnackbar.dart';
import 'package:budget/widgets/statusBox.dart';
import 'package:budget/widgets/tappable.dart';
import 'package:budget/widgets/textWidgets.dart';
import 'package:flutter/material.dart';

// Review queue for bank-sender SMS messages that were recognized as financial
// but could not be parsed. Lets the user review, dismiss, or turn an entry into
// a fallback scanner template by reusing the existing AddEmailTemplate flow.
class UnrecognizedSmsQueue extends StatelessWidget {
  const UnrecognizedSmsQueue({
    this.showEmptyState = false,
    super.key,
  });

  // When true, render a subtle StatusBox if there are no entries. Otherwise an
  // empty queue renders nothing (matching how scanner templates handle empty).
  final bool showEmptyState;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<UnrecognizedSm>>(
      stream: database.watchAllUnrecognizedSms(),
      builder: (context, snapshot) {
        if (snapshot.hasData == false) {
          return Container();
        }
        List<UnrecognizedSm> entries = snapshot.data!;
        if (entries.length <= 0) {
          if (showEmptyState == false) return Container();
          return Padding(
            padding: const EdgeInsetsDirectional.all(5),
            child: StatusBox(
              title: "No unrecognized messages",
              description:
                  "Messages that look like bank transactions but can't be parsed will show up here.",
              icon: appStateSettings["outlinedIcons"]
                  ? Icons.check_circle_outlined
                  : Icons.check_circle_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
          );
        }
        return Column(
          children: [
            for (UnrecognizedSm entry in entries)
              UnrecognizedSmsEntry(entry: entry),
          ],
        );
      },
    );
  }
}

class UnrecognizedSmsEntry extends StatelessWidget {
  const UnrecognizedSmsEntry({
    required this.entry,
    super.key,
  });
  final UnrecognizedSm entry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 15, end: 15, bottom: 10),
      child: OpenContainerNavigation(
        // Reuse the existing scanner-template editor. Passing the SMS body as
        // the only message lets the user build a fallback template from it,
        // exactly like building one from a captured email/notification.
        openPage: AddEmailTemplate(
          messagesList: [entry.body],
        ),
        borderRadius: 15,
        button: (openContainer) {
          return Tappable(
            borderRadius: 15,
            color: getColor(context, "lightDarkAccent"),
            onTap: openContainer,
            child: Padding(
              padding: const EdgeInsetsDirectional.only(
                start: 15,
                end: 7,
                top: 8,
                bottom: 8,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: TextFont(
                                text: entry.sender,
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                maxLines: 1,
                              ),
                            ),
                            SizedBox(width: 8),
                            TextFont(
                              text: getWordedDateShortMore(entry.dateCreated),
                              fontSize: 12,
                              textColor: getColor(context, "textLight"),
                            ),
                          ],
                        ),
                        SizedBox(height: 3),
                        TextFont(
                          text: entry.body,
                          fontSize: 13,
                          maxLines: 3,
                          textColor: getColor(context, "textLight"),
                        ),
                      ],
                    ),
                  ),
                  ButtonIcon(
                    onTap: () => _openActions(context),
                    icon: appStateSettings["outlinedIcons"]
                        ? Icons.more_vert_outlined
                        : Icons.more_vert_rounded,
                    size: 38,
                    iconPadding: 18,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _openActions(BuildContext context) async {
    DeletePopupAction? action = await openDeletePopup(
      context,
      title: "Dismiss message?",
      subtitle: entry.sender,
      description: entry.body,
      // The "Extra" action is surfaced as "Mark handled".
      extraLabel: "Mark handled",
    );
    if (action == DeletePopupAction.Delete) {
      await database.deleteUnrecognizedSms(entry.unrecognizedSmsPk);
      openSnackbar(
        SnackbarMessage(
          title: "Dismissed message",
          icon: appStateSettings["outlinedIcons"]
              ? Icons.delete_outlined
              : Icons.delete_rounded,
        ),
      );
    } else if (action == DeletePopupAction.Extra) {
      await database.markUnrecognizedSmsHandled(entry.unrecognizedSmsPk);
      openSnackbar(
        SnackbarMessage(
          title: "Marked as handled",
          icon: appStateSettings["outlinedIcons"]
              ? Icons.check_outlined
              : Icons.check_rounded,
        ),
      );
    }
  }
}
