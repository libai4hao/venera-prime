import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera/components/background_tasks.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/background_tasks.dart';

import 'support/test_translations.dart';

class _PreservedChild extends StatefulWidget {
  const _PreservedChild(this.onInit);
  final VoidCallback onInit;
  @override
  State<_PreservedChild> createState() => _PreservedChildState();
}

class _PreservedChildState extends State<_PreservedChild> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Text('Private content'));
}

void main() {
  setUpAll(ensureTestTranslations);
  setUp(() {
    for (final task in BackgroundTasks.instance.tasks) {
      task.finish();
    }
    BackgroundTasks.instance.clearFinished();
    BackgroundTasks.instance.configure(history: {});
  });
  testWidgets(
    'root builder badge opens center and does not replace content when hidden',
    (tester) async {
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      var inits = 0;
      final task = BackgroundTasks.instance.start(
        'test-active',
        'Test operation',
      );
      task.update(completed: 1, total: 10);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: App.rootNavigatorKey,
          builder: (context, child) => ValueListenableBuilder<bool>(
            valueListenable: visible,
            child: child,
            builder: (context, enabled, child) =>
                BackgroundTaskOverlay(enabled: enabled, child: child!),
          ),
          home: _PreservedChild(() => inits++),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('background-task-badge')));
      await tester.pumpAndSettle();
      expect(find.text('Test operation'), findsOneWidget);
      expect(tester.takeException(), isNull);
      App.rootNavigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
      visible.value = false;
      await tester.pump();
      expect(find.byKey(const Key('background-task-badge')), findsNothing);
      visible.value = true;
      await tester.pump();
      expect(inits, 1);
      task.finish();
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('badge docks within safe edges and survives resize during drag', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(padding: const EdgeInsets.only(left: 64, right: 20)),
          child: BackgroundTaskOverlay(child: child!),
        ),
        home: const Scaffold(),
      ),
    );
    final badge = find.byKey(const Key('background-task-badge'));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(tester.getCenter(badge));
    await gesture.moveTo(const Offset(70, 150));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(tester.getCenter(badge).dx, greaterThanOrEqualTo(64));
    final drag = await tester.startGesture(tester.getCenter(badge));
    await drag.moveTo(const Offset(700, 160));
    await tester.pump();
    tester.view.physicalSize = const Size(360, 800);
    await tester.pump();
    expect(tester.getCenter(badge).dx, lessThan(360));
    await drag.up();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'badge starts at the bottom corner and snaps to either corner without gesture-inset gaps',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              padding: const EdgeInsets.only(top: 24, bottom: 32),
              viewPadding: const EdgeInsets.only(top: 24, bottom: 32),
              systemGestureInsets: const EdgeInsets.only(
                left: 32,
                right: 32,
                bottom: 32,
              ),
            ),
            child: BackgroundTaskOverlay(child: child!),
          ),
          home: const Scaffold(),
        ),
      );
      final badge = find.byKey(const Key('background-task-badge'));
      await tester.pumpAndSettle();
      expect(tester.getRect(badge).bottom, 768);
      expect(tester.getRect(badge).right, greaterThan(400));
      expect(tester.getCenter(badge).dx, lessThan(400));
      final toTop = await tester.startGesture(tester.getCenter(badge));
      await toTop.moveTo(const Offset(40, 60));
      await tester.pump();
      await toTop.up();
      await tester.pumpAndSettle();
      expect(tester.getRect(badge).top, 24);
      expect(tester.getRect(badge).left, lessThan(0));
      final toBottom = await tester.startGesture(tester.getCenter(badge));
      await toBottom.moveTo(const Offset(360, 738));
      await tester.pump();
      await toBottom.up();
      await tester.pumpAndSettle();
      expect(tester.getRect(badge).bottom, 768);
      expect(tester.getRect(badge).right, greaterThan(400));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failed outcomes remain selectable and copyable in small dialogs',
    (tester) async {
      tester.view.physicalSize = const Size(640, 320);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = call.arguments['text'];
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final task = BackgroundTasks.instance.start(
        'test-failed',
        'Long comic title ' * 20,
      );
      task.addError('日本語の作品名\nHTTP 503');
      task.finish();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  const TaskStatusText(taskKey: 'test-failed'),
                  TextButton(
                    onPressed: () => showBackgroundTask(context, task),
                    child: const Text('Open'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('Last failed:'), findsOneWidget);
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsWidgets);
      await tester.ensureVisible(
        find.byKey(const Key('background-task-copy-errors')),
      );
      await tester.tap(find.byKey(const Key('background-task-copy-errors')));
      await tester.pump();
      expect(copied, task.errors.single);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
