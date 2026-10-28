import 'package:flutter/material.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/utils/translations.dart';

class LocalRestoreConflictsPage extends StatefulWidget {
  const LocalRestoreConflictsPage({
    super.key,
    required this.conflicts,
    required this.previousRoot,
  });

  final List<LocalRestoreConflict> conflicts;
  final String previousRoot;

  @override
  State<LocalRestoreConflictsPage> createState() =>
      _LocalRestoreConflictsPageState();
}

class _LocalRestoreConflictsPageState extends State<LocalRestoreConflictsPage> {
  late final List<LocalRestoreConflict> _conflicts;
  bool _busy = false;

  @override
  void initState() {
    _conflicts = List.of(widget.conflicts);
    super.initState();
  }

  Future<bool> _confirm(String title, String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text('Cancel'.tl),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text('Delete'.tl),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  Future<String?> _delete(LocalRestoreConflict conflict) {
    return LocalManager().deleteLegacyDuplicate(
      conflict.duplicatePath,
      widget.previousRoot,
    );
  }

  Future<String?> _rename(LocalRestoreConflict conflict) {
    return LocalManager().renameLegacyDuplicate(
      conflict.duplicatePath,
      widget.previousRoot,
    );
  }

  Future<void> _deleteOne(LocalRestoreConflict conflict) async {
    if (_busy) return;
    final confirmed = await _confirm(
      'Delete duplicate copy?'.tl,
      'Delete the old copy at: @path'.tlParams({
        'path': conflict.duplicatePath,
      }),
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    final error = await _delete(conflict);
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      context.showMessage(message: error);
      return;
    }
    setState(() => _conflicts.remove(conflict));
    context.showMessage(message: 'Old copy deleted'.tl);
  }

  Future<void> _renameOne(LocalRestoreConflict conflict) async {
    if (_busy) return;
    setState(() => _busy = true);
    final error = await _rename(conflict);
    if (!mounted) return;
    setState(() => _busy = false);
    if (error != null) {
      context.showMessage(message: error);
      return;
    }
    setState(() => _conflicts.remove(conflict));
    context.showMessage(message: 'Old copy renamed'.tl);
  }

  Future<void> _deleteAll() async {
    if (_busy || _conflicts.isEmpty) return;
    final confirmed = await _confirm(
      'Delete all duplicate copies?'.tl,
      'This deletes @count old copies. The active copies are kept.'.tlParams({
        'count': _conflicts.length,
      }),
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    var failed = false;
    for (final conflict in List.of(_conflicts)) {
      final error = await _delete(conflict);
      if (error == null) {
        _conflicts.remove(conflict);
      } else {
        failed = true;
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (failed) {
      context.showMessage(
        message: 'Some duplicate copies could not be deleted'.tl,
      );
    } else {
      context.showMessage(message: 'Old copies deleted'.tl);
    }
  }

  Future<void> _renameAll() async {
    if (_busy || _conflicts.isEmpty) return;
    setState(() => _busy = true);
    var failed = false;
    for (final conflict in List.of(_conflicts)) {
      final error = await _rename(conflict);
      if (error == null) {
        _conflicts.remove(conflict);
      } else {
        failed = true;
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (failed) {
      context.showMessage(
        message: 'Some duplicate copies could not be renamed'.tl,
      );
    } else {
      context.showMessage(message: 'Old copies renamed'.tl);
    }
  }

  Widget _buildConflict(LocalRestoreConflict conflict) {
    return ListTile(
      isThreeLine: true,
      leading: const Icon(Icons.copy_all_outlined),
      title: Text(conflict.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 4),
          Text(
            'Active copy: @path'.tlParams({'path': conflict.activePath}),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            'Old copy: @path'.tlParams({'path': conflict.duplicatePath}),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      trailing: PopupMenuButton<String>(
        enabled: !_busy,
        onSelected: (value) {
          if (value == 'delete') {
            _deleteOne(conflict);
          } else {
            _renameOne(conflict);
          }
        },
        itemBuilder: (context) => [
          PopupMenuItem(value: 'delete', child: Text('Delete old copy'.tl)),
          PopupMenuItem(value: 'rename', child: Text('Rename and keep'.tl)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Duplicate copies'.tl)),
      body: _conflicts.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'All duplicate copies are resolved.'.tl,
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _conflicts.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) =>
                  _buildConflict(_conflicts[index]),
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              TextButton(
                onPressed: _busy || _conflicts.isEmpty ? null : _renameAll,
                child: Text('Rename all'.tl),
              ),
              TextButton(
                onPressed: _busy || _conflicts.isEmpty ? null : _deleteAll,
                child: Text('Delete all'.tl),
              ),
              const Spacer(),
              FilledButton(
                onPressed: _busy ? null : () => context.pop(),
                child: Text('Done'.tl),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
