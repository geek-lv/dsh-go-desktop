// The drawer's conversation list once it has loaded:
// DS Bot's row, 置顶, the folders (opening and closing in place), then the
// rest by day; or, under a status filter, just the matches. Loading, error
// and empty-host states stay with the drawer (sessions_drawer.dart).

import 'dart:io';

import 'package:dsh_client/dsh_client.dart' show SessionSummary;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/l10n.dart';
import '../../../state/drawer_view_state.dart';
import '../../../state/session_attention_state.dart';
import '../../../state/session_created_state.dart';
import '../../../state/sessions_state.dart';
import '../../../state/workspaces_state.dart';
import '../../common/empty_view.dart';
import '../../theme/app_icons.dart';
import '../../theme/theme.dart';
import '../sessions_drawer.dart' show sessionTitle;
import 'drawer_actions.dart';
import 'folder_header.dart';
import 'session_tile.dart';

class DrawerConversationList extends ConsumerWidget {
  const DrawerConversationList({
    super.key,
    required this.onOpen,
    required this.onLongPress,
    this.onSecondaryTap,
    this.compact = false,
    this.onNewChat,
    this.leading,
    this.now,
    this.readOnly = false,
  });

  /// Opens a conversation (and closes the drawer).
  final ValueChanged<String> onOpen;

  /// Closes the drawer after choosing a folder for a new conversation.
  final VoidCallback? onNewChat;

  /// A conversation's actions.
  final void Function(SessionSummary session) onLongPress;

  /// 桌面端右键：带上指针位置。
  final void Function(SessionSummary session, Offset globalPosition)? onSecondaryTap;

  /// 一屏装不下时，行高收到 80%（见 [SessionTile.compactFactor]）。
  final bool compact;

  /// Above everything when nothing is filtered or chosen (DS Bot's row).
  final Widget? leading;

  /// Clock override for the day groups (tests).
  final DateTime? now;
  final bool readOnly;

  /// The list's padding: rows' edges on the drawer's 10 line.
  static const padding = EdgeInsets.fromLTRB(10, 4, 10, 16);

  static Widget? showLeadingLeading(Widget? leading, DrawerFilter filter, bool selecting) =>
      filter == DrawerFilter.all && !selecting ? leading : null;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final blocks = watchDrawerBlocks(ref, now: now);
    if (blocks == null) return const SizedBox.shrink();
    final selection = ref.watch(drawerSelectionProvider);
    final selecting = !readOnly && selection != null;
    final filter = ref.watch(drawerFilterProvider);
    final current = ref.watch(currentSessionProvider);
    final pending = ref.watch(pendingInteractionsProvider);
    final unread = ref.watch(unreadSessionIdsProvider);
    final pinned = ref.watch(workspacesProvider.select((s) => s.pinnedSessionIds)).toSet();
    final sort = ref.watch(drawerViewProvider.select((v) => v.sort));
    if (!readOnly && sort == DrawerSort.created) {
      final ids = [
        for (final block in blocks)
          for (final s in block.items) s.sessionId,
      ];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) ref.read(sessionCreatedProvider.notifier).ensure(ids);
      });
    }
    final selectionNotifier = ref.read(drawerSelectionProvider.notifier);

    Widget tile(SessionSummary s, {bool inFolder = false}) {
      final id = s.sessionId;
      return SessionTile(
        key: ValueKey('session-$id'),
        title: sessionTitle(s),
        running: s.running,
        current: id == current,
        pending: readOnly ? null : pending[id],
        unread: !readOnly && unread.contains(id),
        pinned: inFolder && pinned.contains(id),
        indent: inFolder ? SessionTile.folderIndent : 0,
        selecting: selecting,
        selected: selection?.contains(id) ?? false,
        compact: compact,
        onTap: selecting ? () => selectionNotifier.toggle(id) : () => onOpen(id),
        onLongPress: readOnly
            ? null
            : selecting
            ? () => selectionNotifier.toggle(id)
            : () => onLongPress(s),
        onSecondaryTap: readOnly || selecting
            ? null
            : onSecondaryTap == null
            ? null
            : (position) => onSecondaryTap!(s, position),
      );
    }

    // Keep only builders for off-screen rows: preparing a title and a tile for
    // every conversation makes even a selection change scale with the history.
    final rows = <({Key key, WidgetBuilder builder})>[];
    void add(Key key, WidgetBuilder builder) => rows.add((key: key, builder: builder));
    void addSessions(List<SessionSummary> items) {
      for (final s in items) {
        add(ValueKey('session-${s.sessionId}'), (_) => tile(s));
      }
    }

    // 桌面端「全部工作区」：所有工作区在同一列表里，各自可折叠。
    final prefs = ref.watch(workspacePrefsProvider);
    final grouping = prefs.groupByWorkspace && prefs.selected == null && !readOnly && filter == DrawerFilter.all;
    if (grouping) {
      return _workspaceGroupedList(
        context: context,
        ref: ref,
        tile: tile,
        selecting: selecting,
        padding: padding,
        leading: showLeadingLeading(leading, filter, selecting),
      );
    }
    final showLeading = leading != null && filter == DrawerFilter.all && !selecting;
    if (showLeading) {
      const key = ValueKey('leading');
      add(key, (_) => KeyedSubtree(key: key, child: leading!));
    }
    var foldersLabelled = false;
    for (final block in blocks) {
      switch (block) {
        case FilteredBlock(filter: final matching, :final items) when items.isEmpty:
          const key = ValueKey('filter-empty');
          add(key, (_) => _FilterEmpty(matching, key: key));
        case FilteredBlock(:final items):
          addSessions(items);
        case PinnedBlock(:final items):
          const key = ValueKey('pinned-label');
          add(key, (_) => DrawerEyebrow(l10n.commonPin, key: key));
          addSessions(items);
        case FolderBlock(:final folder, :final items):
          if (!foldersLabelled) {
            foldersLabelled = true;
            const key = ValueKey('folders-label');
            add(key, (_) => DrawerEyebrow(l10n.shellFolders, key: key));
          }
          final headerKey = ValueKey('folder-${folder.id}');
          add(
            headerKey,
            (_) => DrawerFolderHeader(
              key: headerKey,
              folder: folder,
              count: items.length,
              onTap: () => ref.read(drawerViewProvider.notifier).toggleCollapsed(folder.id),
              onLongPress: () {
                if (!readOnly) folderActionsFlow(context, ref, folder, onNewChat: onNewChat);
              },
            ),
          );
          final bodyKey = ValueKey('folder-body-${folder.id}');
          add(
            bodyKey,
            (_) => DrawerFolderBody(
              key: bodyKey,
              open: !folder.collapsed,
              childrenBuilder: () => [for (final s in items) tile(s, inFolder: true)],
            ),
          );
        case DayBlock(:final day, :final items):
          final key = ValueKey('day-${day.name}');
          add(key, (_) => DrawerEyebrow(sessionDayLabels[day]!, key: key));
          addSessions(items);
      }
    }
    // Preserve keyed row/folder state when pinning, sorting or hiding the
    // leading row changes indices. A new filter still starts at the top.
    final indices = {for (var i = 0; i < rows.length; i++) rows[i].key: i};
    return ListView.builder(
      key: ValueKey(filter),
      physics: AppMotion.scrollPhysics(context),
      padding: padding,
      itemCount: rows.length,
      itemBuilder: (context, index) => rows[index].builder(context),
      findChildIndexCallback: (key) => indices[key],
    );
  }
  /// 「全部工作区」：一个列表里按工作区分组，组头可折叠展开。
  ///
  /// 会话与工作区的对应靠 `cwd`：DSH 的会话摘要里只有 `cwd`，而工作区就是那个目录。
  /// 对不上的（默认工作区、已删除的工作区）落到最后一组「其他」。
  Widget _workspaceGroupedList({
    required BuildContext context,
    required WidgetRef ref,
    required Widget Function(SessionSummary session, {bool inFolder}) tile,
    required bool selecting,
    required EdgeInsets padding,
    required Widget? leading,
  }) {
    final l10n = context.l10n;
    final sessions = ref.watch(drawerScopeProvider)?.sessions ?? const <SessionSummary>[];
    final registry = ref.watch(workspacesProvider);
    final collapsed = ref.watch(collapsedWorkspaceGroupsProvider);
    final groupsNotifier = ref.read(collapsedWorkspaceGroupsProvider.notifier);

    String normalize(String path) {
      var value = path.replaceAll(r'', '/');
      while (value.endsWith('/') && value.length > 1) {
        value = value.substring(0, value.length - 1);
      }
      return Platform.isWindows ? value.toLowerCase() : value;
    }

    final byWorkspace = <String, List<SessionSummary>>{};
    for (final s in sessions) {
      final cwd = s.cwd == null ? null : normalize(s.cwd!);
      String key = 'other';
      if (cwd != null) {
        for (final w in registry.workspaces) {
          if (normalize(w.path) == cwd) {
            key = w.workspaceId;
            break;
          }
        }
      }
      (byWorkspace[key] ??= <SessionSummary>[]).add(s);
    }

    final rows = <Widget>[];
    if (leading != null) rows.add(leading);
    for (final w in registry.workspaces) {
      final items = byWorkspace[w.workspaceId];
      if (items == null || items.isEmpty) continue;
      final isCollapsed = collapsed.contains(w.workspaceId);
      rows.add(
        _WorkspaceGroupHeader(
          key: ValueKey('workspace-group-${w.workspaceId}'),
          title: workspaceTitle(w),
          count: items.length,
          collapsed: isCollapsed,
          onTap: () => groupsNotifier.toggle(w.workspaceId),
        ),
      );
      if (!isCollapsed) {
        for (final s in items) {
          rows.add(tile(s));
        }
      }
    }
    final other = byWorkspace['other'];
    if (other != null && other.isNotEmpty) {
      final isCollapsed = collapsed.contains('other');
      rows.add(
        _WorkspaceGroupHeader(
          key: const ValueKey('workspace-group-other'),
          title: l10n.remoteWorkspaceOther,
          count: other.length,
          collapsed: isCollapsed,
          onTap: () => groupsNotifier.toggle('other'),
        ),
      );
      if (!isCollapsed) {
        for (final s in other) {
          rows.add(tile(s));
        }
      }
    }
    final indices = {for (var i = 0; i < rows.length; i++) rows[i].key ?? ValueKey(i): i};
    return ListView.builder(
      key: const ValueKey('grouped-by-workspace'),
      physics: AppMotion.scrollPhysics(context),
      padding: padding,
      itemCount: rows.length,
      itemBuilder: (context, index) => rows[index],
      findChildIndexCallback: (key) => indices[key],
    );
  }
}

/// 工作区分组的组头：图标 + 名字 + 数量 + 会转的箭头。
class _WorkspaceGroupHeader extends StatelessWidget {
  const _WorkspaceGroupHeader({
    super.key,
    required this.title,
    required this.count,
    required this.collapsed,
    required this.onTap,
  });

  final String title;
  final int count;
  final bool collapsed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        customBorder: Squircle.border(AppShape.sm),
        child: SizedBox(
          height: 32,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: collapsed ? -0.25 : 0,
                  duration: AppMotion.of(context, AppMotion.quick),
                  child: Icon(AppIcons.expand, size: 16, color: colors.textTertiary),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
                Text('$count', style: theme.textTheme.labelSmall?.copyWith(color: colors.textTertiary)),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A status filter with no matches.
class _FilterEmpty extends StatelessWidget {
  const _FilterEmpty(this.filter, {super.key});

  final DrawerFilter filter;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (icon, title) = switch (filter) {
      DrawerFilter.running => (AppIcons.running, l10n.shellNoRunningChats),
      DrawerFilter.pending => (AppIcons.toConfirm, l10n.shellNoPendingChats),
      DrawerFilter.unread => (AppIcons.allRead, l10n.shellNoUnreadChats),
      DrawerFilter.all => (AppIcons.chat, l10n.shellNoChatsYet),
    };
    return Padding(
      padding: const EdgeInsets.only(top: 56),
      child: EmptyView(compact: true, icon: icon, title: title),
    );
  }
}
