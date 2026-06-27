import 'dart:collection';

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
}
