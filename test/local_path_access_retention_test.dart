import 'package:flutter_test/flutter_test.dart';
import 'package:venera/utils/io.dart';

void main() {
  test('a retained picker keeps access for the rest of the process', () {
    final picker = DirectoryPicker();
    expect(picker.accessRetained, isFalse);
    picker.retainAccess();
    // Adopting the directory twice must not release the access early.
    picker.retainAccess();
    expect(picker.accessRetained, isTrue);
  });

  test('persistent picks ask the platform for persistent access', () {
    expect(DirectoryPicker.persistentAccessArguments(true), {
      "persistent": true,
    });
    expect(DirectoryPicker.persistentAccessArguments(false), isNull);
  });
}
