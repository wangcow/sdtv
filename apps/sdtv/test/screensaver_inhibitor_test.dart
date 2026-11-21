import 'dart:io';

import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv/services/screensaver_inhibitor.dart';

/// Stand-in for the ScreenSaver service Steam provides in Game Mode.
class _FakeScreenSaver extends DBusObject {
  _FakeScreenSaver() : super(DBusObjectPath('/org/freedesktop/ScreenSaver'));

  final calls = <String>[];
  var _next = 1;

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface != 'org.freedesktop.ScreenSaver') {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (call.name) {
      case 'Inhibit':
        final cookie = _next++;
        calls.add('Inhibit ${call.values[0].asString()} -> $cookie');
        return DBusMethodSuccessResponse([DBusUint32(cookie)]);
      case 'UnInhibit':
        calls.add('UnInhibit ${call.values[0].asUint32()}');
        return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }
}

void main() {
  Process? daemon;
  String? address;

  setUpAll(() async {
    try {
      daemon = await Process.start('dbus-daemon', [
        '--session',
        '--nofork',
        '--print-address',
      ]);
      address =
          (await daemon!.stdout.transform(const SystemEncoding().decoder).first)
              .trim();
    } on ProcessException {
      address = null; // no dbus-daemon on this machine
    }
  });

  tearDownAll(() => daemon?.kill());

  DBusClient connect() => DBusClient(DBusAddress(address!));

  test(
    'inhibits while playing, releases the same cookie, and repeats',
    () async {
      if (address == null) return markTestSkipped('dbus-daemon not installed');
      final server = connect();
      final fake = _FakeScreenSaver();
      await server.requestName('org.freedesktop.ScreenSaver');
      await server.registerObject(fake);

      final inhibitor = DBusScreenSaverInhibitor(connect: connect);
      await inhibitor.setActive(true);
      await inhibitor.setActive(true); // already held: no second call
      await inhibitor.setActive(false);
      await inhibitor.setActive(true);
      await inhibitor.dispose();

      expect(fake.calls, [
        'Inhibit sdtv -> 1',
        'UnInhibit 1',
        'Inhibit sdtv -> 2',
        'UnInhibit 2',
      ]);
      await server.close();
    },
  );

  test('a session without the service is left alone', () async {
    if (address == null) return markTestSkipped('dbus-daemon not installed');
    final inhibitor = DBusScreenSaverInhibitor(connect: connect);
    await inhibitor.setActive(true); // no owner: logged, no throw
    await inhibitor.setActive(false);
    await inhibitor.dispose();
  });
}
