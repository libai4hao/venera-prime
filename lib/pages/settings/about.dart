part of 'settings_page.dart';

class AboutSettings extends StatefulWidget {
  const AboutSettings({super.key});

  @override
  State<AboutSettings> createState() => _AboutSettingsState();
}

class _AboutSettingsState extends State<AboutSettings> {
  bool isCheckingUpdate = false;

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
        ListTile(
          title: Text("Check for updates".tl),
          trailing: Button.filled(
            isLoading: isCheckingUpdate,
            child: Text("Check".tl),
            onPressed: () {
              setState(() {
                isCheckingUpdate = true;
              });
              checkUpdateUi().then((value) {
                if (mounted) {
                  setState(() {
                    isCheckingUpdate = false;
                  });
                }
              });
            },
          ).fixHeight(32),
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
    return null;
  }
  return LatestRelease.fromJson(res.data!);
}

bool _appUpdateDialogOpen = false;

Future<void> checkUpdateUi([
  bool showMessageIfNoUpdate = true,
  bool delay = false,
]) async {
  if (_appUpdateDialogOpen) return;
  _appUpdateDialogOpen = true;
  try {
    var release = await checkUpdate();
    if (release != null && isNewerAppVersion(release.version, App.version)) {
      if (delay) {
        await Future.delayed(const Duration(seconds: 2));
      }
      await showDialog<void>(
        context: App.rootContext,
        barrierDismissible: false,
        builder: (_) => _AppUpdateDialog(release: release),
      );
    } else if (showMessageIfNoUpdate) {
      App.rootContext.showMessage(message: "No new version available".tl);
    }
  } catch (e, s) {
    Log.error("Check Update", e.toString(), s);
    if (showMessageIfNoUpdate) {
      App.rootContext.showMessage(message: "Failed to check for updates".tl);
    }
  } finally {
    _appUpdateDialogOpen = false;
  }
}
