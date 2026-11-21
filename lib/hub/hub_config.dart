import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

typedef HubConfig = ({Uri origin, String token});

class HubConfigStore {
  const HubConfigStore();

  static const _urlKey = 'hub_push_url';
  static const _tokenKey = 'hub_push_token';
  static const _secure = FlutterSecureStorage();
  // Match Edge's other background-readable Keychain credentials.
  static const _ios = IOSOptions(accessibility: KeychainAccessibility.first_unlock);
  static const _mac = MacOsOptions(accessibility: KeychainAccessibility.first_unlock);

  static Uri _origin(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty ||
        uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw ArgumentError('Enter the HTTPS origin of the Hub.');
    }
    return Uri.parse(uri.origin);
  }

  Future<HubConfig?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_urlKey);
    if (url == null || url.isEmpty) return null;
    final token = await _secure.read(key: _tokenKey, iOptions: _ios, mOptions: _mac);
    if (token == null || token.isEmpty) return null;
    return (origin: _origin(url), token: token);
  }

  Future<void> set(String url, String bearerToken) async {
    final origin = _origin(url).toString();
    final token = bearerToken.trim();
    if (!RegExp(r'^[a-zA-Z0-9._~+/-]+=*$').hasMatch(token)) {
      throw ArgumentError('Enter a valid Hub bearer token.');
    }
    final prefs = await SharedPreferences.getInstance();
    final previous = prefs.getString(_urlKey);
    // Never pair a new token with the previous destination across a crash or
    // partial write. Publishing the URL last enables the new pair.
    if (previous != null && previous != origin) await _disable(prefs);
    await _secure.write(key: _tokenKey, value: token, iOptions: _ios, mOptions: _mac);
    if (!await prefs.setString(_urlKey, origin)) {
      throw StateError('Could not save the Hub URL.');
    }
  }

  Future<void> clear() async {
    await _disable(await SharedPreferences.getInstance());
    await _secure.delete(key: _tokenKey, iOptions: _ios, mOptions: _mac);
  }

  Future<void> _disable(SharedPreferences prefs) async {
    if (!await prefs.remove(_urlKey)) {
      throw StateError('Could not clear the Hub URL.');
    }
  }
}
