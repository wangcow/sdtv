import 'package:flutter_test/flutter_test.dart';
import 'package:sdtv_player/src/play_error.dart';

void main() {
  test('HTTP codes win over stall kind', () {
    final e = classifyPlayError('HTTP error 403 Forbidden', stallKind: 'cache');
    expect(e.code, 'E403');
    expect(e.line, contains('403'));
  });

  test('app stall codes when log is empty', () {
    expect(classifyPlayError('', stallKind: 'cache').code, 'A-BUF');
    expect(classifyPlayError('', stallKind: 'eof').code, 'A-EOF');
    expect(classifyPlayError('', stallKind: 'clock').code, 'A-STALL');
    expect(classifyPlayError('', stallKind: 'mpv-missing').code, 'A-MPV');
  });

  test('unknown log + no stall is A-UNK', () {
    expect(classifyPlayError('hello').code, 'A-UNK');
  });
}
