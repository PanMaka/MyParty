import 'package:package_info_plus/package_info_plus.dart';

/// "1.0.0 (1)": the version and build number, as Settings and the support
/// email print them. A seam so widget tests need no platform channel.
typedef AppVersion = Future<String> Function();

Future<String> platformAppVersion() async {
  final info = await PackageInfo.fromPlatform();
  return '${info.version} (${info.buildNumber})';
}

/// Where Settings → Contact support writes to.
///
/// This mailbox has to exist and be read before launch. Nothing in this repo
/// can check that.
const supportEmail = 'support@mypartycorp.com';

/// A mailto with the app version filled in, so the first reply never has to
/// ask for it. The query is encoded by hand because `queryParameters` encodes
/// spaces as `+`, which mail apps print literally.
Uri supportMailUri({String? appVersion}) {
  final body = appVersion == null ? '' : '\n\n---\nMyParty $appVersion';
  return Uri(
    scheme: 'mailto',
    path: supportEmail,
    query: 'subject=${Uri.encodeComponent('MyParty support')}&body=${Uri.encodeComponent(body)}',
  );
}
