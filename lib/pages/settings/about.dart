part of 'settings_page.dart';

class AboutSettings extends StatefulWidget {
  const AboutSettings({super.key});

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  @override
  Widget build(BuildContext context) {
    return SmoothCustomScrollView(
      slivers: [
        SliverAppbar(title: Text("About".tl)),
        SizedBox(
          height: 112,
          width: double.infinity,
          child: Center(
            child: Container(
              width: 112,
              height: 112,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(136),
              ),
              clipBehavior: Clip.antiAlias,
              child: const Image(
                image: AssetImage("assets/app_icon.png"),
                filterQuality: FilterQuality.medium,
              ),
            ),
          ),
        ).paddingTop(16).toSliver(),
        Column(
          children: [
            const SizedBox(height: 8),
            Text("V${App.version}", style: const TextStyle(fontSize: 16)),
            Text(
              "Venera Prime is a free and open-source app for comic reading."
                  .tl,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
          ],
        ).paddingHorizontal(24).toSliver(),
        ListenableBuilder(
          listenable: BackgroundTasks.instance,
          builder: (context, _) => ListTile(
            title: Text("Check for updates".tl),
            subtitle: const TaskStatusText(taskKey: 'app-update-check'),
            trailing: Button.filled(
              child: Text(
                BackgroundTasks.instance
                            .latest('app-update-check')
                            ?.isRunning ==
                        true
                    ? "Checking".tl
                    : "Check".tl,
              ),
              onPressed: () => checkUpdateUi(),
            ).fixHeight(32),
          ),
        ).toSliver(),
        _SwitchSetting(
          title: "Check for updates on startup".tl,
          settingKey: "checkUpdateOnStart",
        ).toSliver(),
        ListTile(
          title: const Text("GitHub"),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://github.com/venera-app/venera-prime");
          },
        ).toSliver(),
        ListTile(
          title: const Text("Telegram"),
          trailing: const Icon(Icons.open_in_new),
          onTap: () {
            launchUrlString("https://t.me/venera_release");
          },
        ).toSliver(),
      ],
    );
  }
}

class LatestRelease {
  final String version;
  final String title;
  final String body;
  final String url;

  const LatestRelease({
    required this.version,
    required this.title,
    required this.body,
    required this.url,
  });
}

Future<LatestRelease?> checkUpdate() async {
  const url =
      "https://api.github.com/repos/venera-app/venera-prime/releases/latest";
  final res = await AppDio().get<Map<String, dynamic>>(
    url,
    options: Options(
      headers: {"Accept": "application/vnd.github+json", "cache-time": "no"},
      responseType: ResponseType.json,
    ),
  );
  if (res.statusCode != 200 || res.data == null) {
    throw StateError('Release request failed: ${res.statusCode}');
  }
  final data = res.data!;
  final tag = data["tag_name"]?.toString();
  if (tag == null || tag.isEmpty) {
    throw const FormatException('Release response is missing a version');
  }
  final version = tag.replaceFirst(RegExp(r"^[vV]"), '').split('+').first;
  return LatestRelease(
    version: version,
    title: data["name"]?.toString().trim().isNotEmpty == true
        ? data["name"].toString()
        : tag,
    body: data["body"]?.toString().trim() ?? '',
    url:
        data["html_url"]?.toString() ??
        "https://github.com/venera-app/venera-prime/releases/latest",
  );
}

Future<LatestRelease?> startAppUpdateCheck({
  Future<LatestRelease?> Function()? fetch,
}) => BackgroundTasks.instance.run<LatestRelease?>(
  'app-update-check',
  "Check for updates".tl,
  (task) async {
    final release = await (fetch ?? checkUpdate)();
    if (release == null) {
      throw const FormatException('Invalid release response');
    }
    if (_compareVersion(release.version, App.version)) {
      task.update(message: '${release.title} (${release.version})');
      task.resultLabel = "View update".tl;
      task.onOpenResult = () => showAppUpdateDialog(release);
    } else {
      task.update(message: "No new version available".tl);
    }
    return release;
  },
);

void showAppUpdateDialog(LatestRelease release) {
  showDialog<void>(
    context: App.rootContext,
    builder: (context) => ContentDialog(
      title: '${release.title} (${release.version})',
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text("A new version is available. Do you want to update now?".tl),
            if (release.body.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(release.body),
            ],
          ],
        ).paddingHorizontal(16),
      ),
      actions: [
        Button.text(
          onPressed: () {
            Navigator.pop(context);
            launchUrlString(release.url);
          },
          child: Text("Update".tl),
        ),
      ],
    ),
  );
}

Future<void> checkUpdateUi([
  bool showMessageIfNoUpdate = true,
  bool delay = false,
]) async {
  final future = startAppUpdateCheck();
  if (showMessageIfNoUpdate) {
    // Closing/minimizing this dialog never cancels the owned job.
    unawaited(
      showBackgroundTask(
        App.rootContext,
        BackgroundTasks.instance.latest('app-update-check')!,
      ),
    );
  }
  try {
    final release = await future;
    // Preserve the startup new-release notification, while manual checks keep
    // their result in the task dialog/center even when the page is closed.
    if (!showMessageIfNoUpdate &&
        release != null &&
        _compareVersion(release.version, App.version)) {
      if (delay) await Future<void>.delayed(const Duration(seconds: 2));
      showAppUpdateDialog(release);
    }
  } catch (error, stack) {
    Log.error('Check Update', error, stack);
  }
}

/// return true if version1 > version2
bool _compareVersion(String version1, String version2) {
  var v1 = version1.split(".");
  var v2 = version2.split(".");
  for (var i = 0; i < v1.length; i++) {
    if (int.parse(v1[i]) > int.parse(v2[i])) {
      return true;
    }
    if (int.parse(v1[i]) < int.parse(v2[i])) {
      return false;
    }
  }
  return false;
}
