part of 'settings_page.dart';

class _AppUpdateDialog extends StatefulWidget {
  const _AppUpdateDialog({required this.release});
  final LatestRelease release;

  @override
  State<_AppUpdateDialog> createState() => _AppUpdateDialogState();
}

class _AppUpdateDialogState extends State<_AppUpdateDialog> {
  bool _busy = false;
  bool _selecting = true;
  int _received = 0;
  ReleaseAsset? _asset;
  File? _downloaded;
  CancelToken? _cancel;
  String? _error;

  @override
  void initState() {
    super.initState();
    _selectAsset();
  }

  Future<void> _selectAsset() async {
    try {
      if (App.isAndroid) {
        final abis = await AndroidAppUpdater.supportedAbis();
        if (mounted) _asset = widget.release.androidAsset(abis);
      }
    } catch (e, s) {
      Log.error('App update', e, s);
      if (mounted) _error = 'Failed to prepare update'.tl;
    } finally {
      if (mounted) setState(() => _selecting = false);
    }
  }

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  Future<void> _update() async {
    if (_busy) return;
    final asset = _asset;
    if (asset == null) {
      await launchUrlString(widget.release.url);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _received = 0;
    });
    final token = _cancel = CancelToken();
    try {
      _downloaded ??= await AppUpdateDownloader().download(
        asset,
        AndroidAppUpdater.downloadDirectory,
        cancelToken: token,
        onProgress: (received, total) {
          if (mounted) setState(() => _received = received);
        },
      );
      if (!mounted || token.isCancelled) return;
      final launched = await AndroidAppUpdater.install(_downloaded!);
      if (!mounted) return;
      if (launched) {
        Navigator.pop(context);
      } else {
        setState(
          () => _error =
              'Allow app installs in system settings, then tap Install again.'
                  .tl,
        );
      }
    } catch (e, s) {
      if (e is! DioException || !CancelToken.isCancel(e)) {
        Log.error('App update', e, s);
        if (mounted) setState(() => _error = '${'Update failed'.tl}\n$e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: ContentDialog(
        dismissible: !_busy,
        title: '${widget.release.title} (${widget.release.version})',
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('A new version is available. Do you want to update now?'.tl),
            if (_asset != null)
              Text(
                'The app will download the update and open the system installer.'
                    .tl,
              ),
            if (widget.release.body.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(widget.release.body),
            ],
            if (_busy) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: _downloaded != null
                    ? null
                    : (_received / _asset!.size).clamp(0.0, 1.0),
              ),
              Text(
                _downloaded != null
                    ? 'Opening installer…'.tl
                    : '${'Downloading'.tl} ${(_received / _asset!.size * 100).clamp(0, 100).toStringAsFixed(0)}%',
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              SelectableText(
                _error!,
                style: TextStyle(color: context.colorScheme.error),
              ),
            ],
          ],
        ).paddingHorizontal(16),
        actions: [
          Button.text(
            onPressed: _busy
                ? () => _cancel?.cancel()
                : () => Navigator.pop(context),
            child: Text('Cancel'.tl),
          ),
          TextButton(
            onPressed: _busy || _selecting ? null : _update,
            child: Text(
              _downloaded != null
                  ? 'Install'.tl
                  : _asset != null
                  ? 'Download and install'.tl
                  : 'Open release page'.tl,
            ),
          ),
        ],
      ),
    );
  }
}
