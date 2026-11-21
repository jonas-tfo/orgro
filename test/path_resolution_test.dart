import 'package:flutter_test/flutter_test.dart';
import 'package:orgro/src/native_search.dart';

void main() {
  test('pathLeavesFolder: climbing out or absolute', () {
    expect(pathLeavesFolder('images/x.png'), isFalse);
    expect(pathLeavesFolder('./images/x.png'), isFalse);
    expect(pathLeavesFolder('a/../images/x.png'), isFalse);
    expect(pathLeavesFolder('../images/x.png'), isTrue);
    expect(pathLeavesFolder('../../images/x.png'), isTrue);
    expect(pathLeavesFolder('a/../../x.png'), isTrue);
    expect(pathLeavesFolder('/home/jonas/notes/images/x.png'), isTrue);
    expect(pathLeavesFolder('~/notes/images/x.png'), isTrue);
  });
}
