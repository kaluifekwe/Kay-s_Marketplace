import 'dart:collection';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class CacheEntry<T> {
  final T data;
  final DateTime expiresAt;
  CacheEntry(this.data, this.expiresAt);
  bool get isExpired => DateTime.now().isAfter(expiresAt);
}

class CacheService {
  static final _cache = HashMap<String, CacheEntry<dynamic>>();
  static const _defaultTtl = Duration(minutes: 5);

  static T? get<T>(String key) {
    final entry = _cache[key];
    if (entry == null || entry.isExpired) {
      _cache.remove(key);
      return null;
    }
    return entry.data as T?;
  }

  static void set<T>(String key, T data, {Duration? ttl}) {
    _cache[key] = CacheEntry(data, DateTime.now().add(ttl ?? _defaultTtl));
  }

  static void remove(String key) {
    _cache.remove(key);
  }

  static void clear() {
    _cache.clear();
  }

  static void clearPrefix(String prefix) {
    _cache.removeWhere((key, _) => key.startsWith(prefix));
  }

  static Future<T> getOrFetch<T>(
    String key,
    Future<T> Function() fetcher, {
    Duration? ttl,
  }) async {
    final cached = get<T>(key);
    if (cached != null) return cached;
    final data = await fetcher();
    set(key, data, ttl: ttl);
    return data;
  }

  /// Persist a JSON-serialisable value across app restarts (for rarely-changing
  /// reference data like the bank list). Best-effort — never throws.
  static Future<void> setPersisted(String key, Object jsonValue, Duration ttl) async {
    set(key, jsonValue, ttl: ttl);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('cache:$key', jsonEncode({
        'exp': DateTime.now().add(ttl).toIso8601String(),
        'v': jsonValue,
      }));
    } catch (_) {
      // best-effort only
    }
  }

  /// Read a persisted value (memory first, then disk). Returns the decoded JSON
  /// (List/Map/primitive) or null on miss/expiry.
  static Future<dynamic> getPersisted(String key) async {
    final mem = get<dynamic>(key);
    if (mem != null) return mem;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('cache:$key');
      if (raw == null) return null;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final exp = DateTime.parse(decoded['exp'] as String);
      if (DateTime.now().isAfter(exp)) {
        await prefs.remove('cache:$key');
        return null;
      }
      set(key, decoded['v'] as Object, ttl: exp.difference(DateTime.now()));
      return decoded['v'];
    } catch (_) {
      return null;
    }
  }
}
