import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

/// Records what url_launcher was asked to open instead of reaching a platform
/// channel, which `flutter test` does not have.
///
/// Install with `UrlLauncherPlatform.instance = FakeUrlLauncher()`; set
/// [result] to false to make every launch fail.
class FakeUrlLauncher extends UrlLauncherPlatform {
  final launched = <(String url, PreferredLaunchMode mode)>[];
  bool result = true;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> supportsMode(PreferredLaunchMode mode) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add((url, options.mode));
    return result;
  }
}
