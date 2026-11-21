import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orgro/src/preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The default font must work offline (e.g. first launch on the go).
  // google_fonts picks up bundled assets named <Family>-<Variant>.ttf.
  test('Default font is bundled', () async {
    final family = kDefaultFontFamily.replaceAll(' ', '');
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final asset = manifest.listAssets().singleWhere(
      (a) => a.endsWith('/$family-Regular.ttf'),
    );
    final data = await rootBundle.load(asset);
    expect(data.lengthInBytes, greaterThan(0));
  });
}
