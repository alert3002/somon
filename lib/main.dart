import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'client_request_filters.dart';

String _fcmDeviceType() {
  if (kIsWeb) return 'web';
  final p = defaultTargetPlatform;
  if (p == TargetPlatform.iOS) return 'ios';
  if (p == TargetPlatform.android) return 'android';
  return 'unknown';
}

class _FcmRegistrar {
  static bool _initialized = false;
  static StreamSubscription<String>? _tokenSub;

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    // Web requires extra config; keep app runnable.
    if (kIsWeb) return;

    try {
      await Firebase.initializeApp();
    } catch (_) {
      // ignore: may already be initialized
    }

    try {
      await FirebaseMessaging.instance.requestPermission();
    } catch (_) {
      // ignore
    }
  }

  static Future<void> registerForSession({required String accessToken}) async {
    if (kIsWeb) return;
    await init();

    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && token.trim().isNotEmpty) {
        unawaited(AuthApi().saveFcmDevice(
          accessToken: accessToken,
          registrationId: token.trim(),
          type: _fcmDeviceType(),
          name: '',
        ));
      }
    } catch (_) {
      // ignore
    }

    _tokenSub ??= FirebaseMessaging.instance.onTokenRefresh.listen((t) {
      final token = t.trim();
      if (token.isEmpty) return;
      unawaited(AuthApi().saveFcmDevice(
        accessToken: accessToken,
        registrationId: token,
        type: _fcmDeviceType(),
        name: '',
      ));
    });
  }

  static Future<void> dispose() async {
    await _tokenSub?.cancel();
    _tokenSub = null;
  }
}

class _LocalPrefs {
  static const _kFranchiseJoinCode = 'franchise_join_code';
  static const _kSessionAccess = 'session_access';
  static const _kSessionRefresh = 'session_refresh';
  static const _kSessionRole = 'session_role';
  static const _kDeviceScope = 'cache_device_scope_v1';
  static const _kRequestDraft = 'request_draft_v1';

  static Future<String> getFranchiseJoinCode() async {
    final p = await SharedPreferences.getInstance();
    return (p.getString(_kFranchiseJoinCode) ?? '').trim();
  }

  static Future<void> setFranchiseJoinCode(String code) async {
    final v = code.trim();
    final p = await SharedPreferences.getInstance();
    if (v.isEmpty) {
      await p.remove(_kFranchiseJoinCode);
    } else {
      await p.setString(_kFranchiseJoinCode, v);
    }
  }

  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  static Future<String> getDeviceScope() async {
    try {
      final p = await SharedPreferences.getInstance();
      final existing = (p.getString(_kDeviceScope) ?? '').trim();
      if (existing.isNotEmpty) return existing;
      final v = '${DateTime.now().millisecondsSinceEpoch}-${math.Random().nextInt(1 << 30)}';
      await p.setString(_kDeviceScope, v);
      return v;
    } catch (_) {
      return 'na';
    }
  }

  static Future<Map<String, dynamic>?> getRequestDraft() async {
    try {
      final scope = await getDeviceScope();
      final p = await SharedPreferences.getInstance();
      final raw = (p.getString('$_kRequestDraft:$scope') ?? '').trim();
      if (raw.isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return null;
    }
  }

  static Future<void> setRequestDraft(Map<String, dynamic> draft) async {
    try {
      final scope = await getDeviceScope();
      final p = await SharedPreferences.getInstance();
      await p.setString('$_kRequestDraft:$scope', jsonEncode(draft));
    } catch (_) {}
  }

  static Future<void> clearRequestDraft() async {
    try {
      final scope = await getDeviceScope();
      final p = await SharedPreferences.getInstance();
      await p.remove('$_kRequestDraft:$scope');
    } catch (_) {}
  }

  static Future<AuthSession?> getSession() async {
    if (kIsWeb) {
      final p = await SharedPreferences.getInstance();
      final access = (p.getString(_kSessionAccess) ?? '').trim();
      final refresh = (p.getString(_kSessionRefresh) ?? '').trim();
      final roleRaw = (p.getString(_kSessionRole) ?? '').trim();
      if (access.isEmpty || refresh.isEmpty) return null;
      return AuthSession(access: access, refresh: refresh, role: _roleFromString(roleRaw));
    }
    final access = (await _secure.read(key: _kSessionAccess) ?? '').trim();
    final refresh = (await _secure.read(key: _kSessionRefresh) ?? '').trim();
    final roleRaw = (await _secure.read(key: _kSessionRole) ?? '').trim();
    if (access.isEmpty || refresh.isEmpty) return null;
    return AuthSession(access: access, refresh: refresh, role: _roleFromString(roleRaw));
  }

  static Future<void> setSession(AuthSession s) async {
    if (kIsWeb) {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kSessionAccess, s.access);
      await p.setString(_kSessionRefresh, s.refresh);
      await p.setString(_kSessionRole, s.role.name);
      return;
    }
    await _secure.write(key: _kSessionAccess, value: s.access);
    await _secure.write(key: _kSessionRefresh, value: s.refresh);
    await _secure.write(key: _kSessionRole, value: s.role.name);
  }

  static Future<void> clearSession() async {
    if (kIsWeb) {
      final p = await SharedPreferences.getInstance();
      await p.remove(_kSessionAccess);
      await p.remove(_kSessionRefresh);
      await p.remove(_kSessionRole);
      return;
    }
    await _secure.delete(key: _kSessionAccess);
    await _secure.delete(key: _kSessionRefresh);
    await _secure.delete(key: _kSessionRole);
  }
}

class _JsonCache {
  static Future<String> _scope() => _LocalPrefs.getDeviceScope();

  static Future<List<Map<String, dynamic>>?> getList(String key) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(key);
      if (raw == null || raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return null;
      return decoded
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList(growable: false);
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> getMap(String key) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(key);
      if (raw == null || raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return null;
    }
  }

  static Future<void> setJson(String key, Object value) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(key, jsonEncode(value));
    } catch (_) {}
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _FcmRegistrar.init();
  runApp(const SomonLogisticsApp());
}

class AppColors {
  static const Color primary = Color(0xFF007D72);
  static const Color navy = Color(0xFF09355F);
  static Color surface = const Color(0xFFF4F8FB);
}

enum AppRole { client, driver }

/// Режим трекинга на экране «Маршрут по карте».
enum RouteMapTrackingMode {
  none,
  viewer,
  driver,
}

AppRole _roleFromString(String? role) {
  if ((role ?? '').toLowerCase() == 'driver') return AppRole.driver;
  return AppRole.client;
}

String _roleApiValue(AppRole role) => role == AppRole.driver ? 'driver' : 'client';

String _requestStatusRu(String? code) {
  switch ((code ?? '').toLowerCase()) {
    case 'draft':
      return 'Черновик';
    case 'pending':
      return 'На рассмотрении';
    case 'active':
      return 'Актив';
    case 'awaiting_confirmation':
      return 'Ожидает рассмотрения';
    case 'awaiting':
      return 'Ожидание';
    case 'in_transit':
      return 'В пути';
    case 'closed':
      return 'Закрыт';
    default:
      return (code == null || code.isEmpty) ? '—' : code;
  }
}

String _accountRoleRu(String? role) {
  switch ((role ?? '').toLowerCase()) {
    case 'client':
      return 'Клиент';
    case 'driver':
      return 'Водитель';
    default:
      return role == null || role.isEmpty ? '—' : role;
  }
}

DateTime? _parseApiDateOnly(dynamic raw) {
  if (raw == null) return null;
  final s = raw.toString().trim();
  if (s.isEmpty || s == 'null') return null;
  return DateTime.tryParse(s.split('T').first);
}

DateTime? _parseNotificationDate(String raw) {
  final t = DateTime.tryParse(raw);
  if (t != null) return t.toLocal();
  try {
    return DateFormat('dd.MM.yyyy HH:mm').parseStrict(raw.trim());
  } catch (_) {
    try {
      return DateFormat('dd.MM.yyyy').parseStrict(raw.trim());
    } catch (_) {
      return null;
    }
  }
}

String notificationRelativeRu(String? iso) {
  if (iso == null || iso.isEmpty) return '';
  final t = _parseNotificationDate(iso);
  if (t == null) return iso;
  final local = t.toLocal();
  final d = DateTime.now().difference(local);
  if (d.isNegative || d.inSeconds < 45) return 'только что';
  if (d.inMinutes < 60) return '${d.inMinutes} мин. назад';
  if (d.inHours < 24) return '${d.inHours} ч. назад';
  if (d.inDays < 7) return '${d.inDays} дн. назад';
  return DateFormat('dd.MM.yyyy HH:mm').format(local);
}

String _formatApiDate(String? raw) {
  if (raw == null || raw.isEmpty) return '—';
  final d = raw.split('T').first;
  final p = d.split('-');
  if (p.length == 3) return '${p[2]}.${p[1]}.${p[0]}';
  return raw;
}

String _formatApiDateTimeRu(String? raw) {
  if (raw == null || raw.isEmpty) return '—';
  final t = DateTime.tryParse(raw);
  if (t == null) return raw;
  return DateFormat('dd.MM.yyyy HH:mm').format(t.toLocal());
}

bool _showPhoneContactsForStatus(String? statusCode) {
  final s = (statusCode ?? '').toString().toLowerCase();
  return s == 'awaiting' || s == 'in_transit';
}

String _firstNonEmptyStr(List<dynamic> parts) {
  for (final p in parts) {
    final s = (p ?? '').toString().trim();
    if (s.isNotEmpty && s != 'null' && s != '—') return s;
  }
  return '';
}

double _bearingBetweenLatLng(LatLng a, LatLng b) {
  final lat1 = a.latitude * math.pi / 180.0;
  final lat2 = b.latitude * math.pi / 180.0;
  final dLon = (b.longitude - a.longitude) * math.pi / 180.0;
  final y = math.sin(dLon) * math.cos(lat2);
  final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
  final br = math.atan2(y, x) * 180.0 / math.pi;
  return (br + 360.0) % 360.0;
}

/// Телефон администратора (доставка / ошибки)
const String kAdminSupportDisplayPhone = '+992 77 700 0570';
const String _kAdminSupportTelDigits = '+992777000570';

Future<void> launchExternalUri(BuildContext context, Uri uri) async {
  try {
    if (!await canLaunchUrl(uri)) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Не удалось открыть ссылку')),
        );
      }
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть ссылку')),
      );
    }
  }
}

void showAdminSupportDialog(BuildContext context) {
  final rootCtx = context;
  final telUri = Uri.parse('tel:$_kAdminSupportTelDigits');
  final tgUri = Uri.parse('https://t.me/+992777000570');
  final waUri = Uri.parse('https://wa.me/992777000570');

  showDialog<void>(
    context: context,
    builder: (ctx) {
      return AlertDialog(
        title: Text(
          'Контакт администратора',
          textAlign: TextAlign.center,
          style: GoogleFonts.montserrat(
            fontWeight: FontWeight.w700,
            fontSize: 16,
            height: 1.25,
          ),
        ),
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Если при доставке произошла ошибка, задержка или возник вопрос по заказу, '
              'обратитесь к администратору.',
              style: GoogleFonts.montserrat(height: 1.35),
            ),
            const SizedBox(height: 14),
            Text(
              kAdminSupportDisplayPhone,
              textAlign: TextAlign.center,
              style: GoogleFonts.montserrat(fontWeight: FontWeight.w900, fontSize: 16),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: _SupportChannel(
                    icon: Icons.phone_rounded,
                    label: 'Телефон',
                    onTap: () {
                      Navigator.pop(ctx);
                      unawaited(launchExternalUri(rootCtx, telUri));
                    },
                  ),
                ),
                Expanded(
                  child: _SupportChannel(
                    icon: Icons.send_rounded,
                    label: 'Telegram',
                    onTap: () {
                      Navigator.pop(ctx);
                      unawaited(launchExternalUri(rootCtx, tgUri));
                    },
                  ),
                ),
                Expanded(
                  child: _SupportChannel(
                    icon: Icons.chat_rounded,
                    label: 'WhatsApp',
                    onTap: () {
                      Navigator.pop(ctx);
                      unawaited(launchExternalUri(rootCtx, waUri));
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Закрыть'),
          ),
        ],
      );
    },
  );
}

class _SupportChannel extends StatelessWidget {
  const _SupportChannel({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 26, color: AppColors.primary),
            const SizedBox(height: 4),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.montserrat(fontWeight: FontWeight.w700, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

Widget phoneTappableRow(BuildContext context, String label, String phoneRaw) {
  final p = phoneRaw.trim();
  if (p.isEmpty || p == '—' || p == 'null') return const SizedBox.shrink();
  final cs = Theme.of(context).colorScheme;
  final compact = p.replaceAll(RegExp(r'[\s\-\(\)]'), '');
  final uri = Uri.parse(compact.startsWith('+') ? 'tel:$compact' : 'tel:$compact');
  return Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 2,
          child: Text(
            label,
            style: GoogleFonts.montserrat(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ),
        Expanded(
          flex: 3,
          child: Align(
            alignment: Alignment.centerRight,
            child: InkWell(
              onTap: () => unawaited(launchExternalUri(context, uri)),
              child: Text(
                p,
                textAlign: TextAlign.right,
                style: GoogleFonts.montserrat(
                  fontSize: 12.6,
                  fontWeight: FontWeight.w800,
                  color: AppColors.primary,
                  decoration: TextDecoration.underline,
                  height: 1.3,
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
}

List<Map<String, dynamic>> _parseStopList(dynamic raw) {
  if (raw is! List) return const [];
  return raw
      .whereType<Map>()
      .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
      .toList(growable: false);
}

LatLng? _latLngFromRequestStop(Map<String, dynamic> s) {
  final la = double.tryParse((s['lat'] ?? '').toString());
  final lo = double.tryParse((s['lng'] ?? '').toString());
  if (la == null || lo == null) return null;
  return LatLng(la, lo);
}

List<LatLng> _requestStopsToLatLngs(
  List<Map<String, dynamic>> origins,
  List<Map<String, dynamic>> dests,
) {
  final out = <LatLng>[];
  for (final s in origins) {
    final ll = _latLngFromRequestStop(s);
    if (ll != null) out.add(ll);
  }
  for (final s in dests) {
    final ll = _latLngFromRequestStop(s);
    if (ll != null) out.add(ll);
  }
  return out;
}

/// Сатрҳои «лейбл чап / қимат рост» дар рӯйхати заявкаҳо (клиент + ронанда).
Widget requestOrderListLrRow(
  BuildContext context,
  String label,
  String value, {
  int maxLines = 3,
}) {
  final cs = Theme.of(context).colorScheme;
  return Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: GoogleFonts.montserrat(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: cs.onSurface.withValues(alpha: 0.55),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            textAlign: TextAlign.right,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.montserrat(
              fontSize: 12.6,
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
              height: 1.25,
            ),
          ),
        ),
      ],
    ),
  );
}

String _fmtRequestListField(String? raw) {
  if (raw == null || raw.isEmpty || raw == 'null') return '—';
  final d = double.tryParse(raw);
  if (d == null) return raw;
  if ((d - d.round()).abs() < 1e-9) return d.round().toString();
  return d.toStringAsFixed(2);
}

bool _rqListIsCountrySegment(String p) {
  final l = p.toLowerCase().replaceAll('ё', 'е').trim();
  if (l.isEmpty) return false;
  return l.contains('таджикистан') ||
      l.contains('точикистон') ||
      l.contains('тоҷикистон') ||
      l.contains('tajikistan') ||
      l.contains('tojikiston') ||
      l.contains('узбекистан') ||
      l.contains('uzbekistan') ||
      l.contains('кыргыз') ||
      l.contains('kyrgyzstan');
}

bool _rqListIsRegionProvinceLabel(String p) {
  final l = p.toLowerCase().replaceAll('ё', 'е').replaceAll('ғ', 'г').trim();
  if (l.isEmpty) return false;
  if (l.contains('вилоят') || l.contains('viloyat')) return true;
  if (l.contains('область')) return true;
  if (l == 'край' || l.endsWith(' край')) return true;
  return false;
}

String _rqListStripAdminPlacePrefixes(String raw) {
  var s = raw.trim();
  if (s.isEmpty || s == '—') return s;

  final prefixRes = <RegExp>[
    RegExp(r'^(шаҳри|шахри|шаһри|шаҳр|шахр)\s+', caseSensitive: false),
    RegExp(r'^(город\s+|города\s+|городу\s+|городской\s+|г\.\s*)', caseSensitive: false),
    RegExp(r'^(ноҳияи|нохияи|ноҳия|нохия)\s+', caseSensitive: false),
    RegExp(r'^(тумани|туман)\s+', caseSensitive: false),
    RegExp(r'^район\s+', caseSensitive: false),
    RegExp(r'^(микрорайон|мкр\.?)\s+', caseSensitive: false),
    RegExp(r'^(посёлок|поселок|пгт|село|деревня|аул|кишлак)\s+', caseSensitive: false),
    RegExp(r'^(жамоати|жамоат)\s+', caseSensitive: false),
    RegExp(r'^(шахристон|шаҳристон)\s+', caseSensitive: false),
  ];

  for (var k = 0; k < 10; k++) {
    final before = s;
    for (final re in prefixRes) {
      s = s.replaceFirst(re, '');
    }
    s = s.trim();
    if (s == before) break;
  }

  return s.isEmpty ? '—' : s;
}

String _rqListInferCityOrDistrictFromAddress(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '—';

  bool looksLikeStreetOrHouse(String p) {
    final l = p.toLowerCase();
    if (l.startsWith('куча') ||
        l.startsWith('кучаи') ||
        l.startsWith('улиц') ||
        l.startsWith('ул.') ||
        l.startsWith('проспект') ||
        l.startsWith('пр-т') ||
        l.startsWith('просп') ||
        l.startsWith('дом ') ||
        l.startsWith('д.') ||
        l.startsWith('шоссе') ||
        l.startsWith('переул')) {
      return true;
    }
    if (RegExp(r'^\d+[/\\]').hasMatch(p) && p.length < 24) return true;
    if (RegExp(r'^\d+\s*$').hasMatch(p)) return true;
    return false;
  }

  bool looksLikeDistrict(String p) {
    final l = p.toLowerCase();
    return l.contains('мкр') || l.contains('микрорайон') || l.contains('район');
  }

  var parts = trimmed
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .where((s) => !_rqListIsCountrySegment(s))
      .where((s) => !_rqListIsRegionProvinceLabel(s))
      .toList();
  if (parts.isEmpty) return '—';

  while (parts.isNotEmpty && _rqListIsRegionProvinceLabel(parts.last)) {
    parts = parts.sublist(0, parts.length - 1);
  }
  if (parts.isEmpty) return '—';

  for (var i = parts.length - 1; i >= 0; i--) {
    final p = parts[i];
    if (p.length < 2) continue;
    if (_rqListIsCountrySegment(p)) continue;
    if (_rqListIsRegionProvinceLabel(p)) continue;
    if (looksLikeStreetOrHouse(p)) continue;
    return p;
  }

  for (var i = parts.length - 1; i >= 0; i--) {
    final p = parts[i];
    if (_rqListIsCountrySegment(p)) continue;
    if (_rqListIsRegionProvinceLabel(p)) continue;
    if (looksLikeDistrict(p)) return p;
  }

  return '—';
}

String _rqListRoutePlaceLabel(Map<String, dynamic> s) {
  final c = (s['city'] ?? '').toString().trim();
  if (c.isNotEmpty && !_rqListIsCountrySegment(c) && !_rqListIsRegionProvinceLabel(c)) {
    return _rqListStripAdminPlacePrefixes(c);
  }
  final addr = (s['address'] ?? '').toString().trim();
  final inferred = _rqListInferCityOrDistrictFromAddress(addr);
  if (_rqListIsRegionProvinceLabel(inferred)) return '—';
  return _rqListStripAdminPlacePrefixes(inferred);
}

String _rqListRoutePlacesSummary(List<Map<String, dynamic>> stops) {
  final labels = <String>[];
  for (final s in stops) {
    final t = _rqListRoutePlaceLabel(s);
    if (t.isNotEmpty && t != '—' && !_rqListIsRegionProvinceLabel(t)) labels.add(t);
  }
  if (labels.isEmpty) return '—';
  final out = <String>[];
  for (final t in labels) {
    if (out.isEmpty || out.last != t) out.add(t);
  }
  return out.join(', ');
}

String _rqListRouteCitiesLine(Map<String, dynamic> r) {
  final origins = _parseStopList(r['origin_stops']);
  final dests = _parseStopList(r['destination_stops']);
  final from = _rqListRoutePlacesSummary(origins);
  final to = _rqListRoutePlacesSummary(dests);
  return '$from → $to';
}

const String _trackingShareCaption = 'Маршрут и машина на карте (Somon):';

Future<void> shareTrackingLinkWhatsApp(String link) async {
  final text = '$_trackingShareCaption\n$link';
  final uri = Uri.parse('https://wa.me/?text=${Uri.encodeComponent(text)}');
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

Future<void> shareTrackingLinkTelegram(String link) async {
  final uri = Uri.parse(
    'https://t.me/share/url?url=${Uri.encodeComponent(link)}&text=${Uri.encodeComponent(_trackingShareCaption)}',
  );
  if (await canLaunchUrl(uri)) {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}

class AuthSession {
  const AuthSession({
    required this.access,
    required this.refresh,
    required this.role,
  });
  final String access;
  final String refresh;
  final AppRole role;
}

class AuthApi {
  const AuthApi();

  static const String _configuredBaseUrl = String.fromEnvironment('API_BASE_URL', defaultValue: '');

  static String get baseUrl {
    if (_configuredBaseUrl.isNotEmpty) return _configuredBaseUrl;
    return 'https://app.somonlogistics.com';
  }

  static Future<AuthSession?> refreshSessionFromStorage() async {
    try {
      final s = await _LocalPrefs.getSession();
      if (s == null) return null;
      final uri = Uri.parse('$baseUrl/api/token/refresh/');
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'refresh': s.refresh}),
          )
          .timeout(const Duration(seconds: 25));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return null;
      final access = (decoded['access'] ?? '').toString().trim();
      final refresh = (decoded['refresh'] ?? s.refresh).toString().trim();
      if (access.isEmpty) return null;
      final next = AuthSession(
        access: access,
        refresh: refresh.isEmpty ? s.refresh : refresh,
        role: s.role,
      );
      await _LocalPrefs.setSession(next);
      return next;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _decodeJson(String body) {
    try {
      final data = jsonDecode(body);
      if (data is Map<String, dynamic>) return data;
      return {};
    } catch (_) {
      return {};
    }
  }

  Future<(String?, int?)> sendOtp({
    required String phone,
    required AppRole role,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/send_otp/');
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'phone': phone,
              'role': _roleApiValue(role),
            }),
          )
          .timeout(const Duration(seconds: 25));

      final data = _decodeJson(response.body);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final resendIn = data['resend_available_in'];
        return (null, resendIn is int ? resendIn : null);
      }
      final resendIn = data['resend_available_in'];
      return (
        (data['message'] ?? 'Не удалось отправить код').toString(),
        resendIn is int ? resendIn : null,
      );
    } catch (_) {
      return ('Не удалось подключиться к серверу', null);
    }
  }

  Future<(bool?, String?)> checkPhoneExists({required String phone}) async {
    try {
      final uri = Uri.parse('$baseUrl/api/check_phone/');
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'phone': phone}),
          )
          .timeout(const Duration(seconds: 25));
      final data = _decodeJson(response.body);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (data['exists'] is bool) {
          return (data['exists'] as bool, null);
        }
        return (null, null);
      }
      return (null, (data['message'] ?? 'Не удалось проверить номер').toString());
    } catch (_) {
      return (null, 'Не удалось подключиться к серверу');
    }
  }

  Future<(AuthSession?, String?)> verifyOtp({
    required String phone,
    required String code,
    required AppRole role,
    String? franchiseJoinCode,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/verify_otp/');
      final payload = <String, dynamic>{
        'phone': phone,
        'code': code,
        'role': _roleApiValue(role),
      };
      final fj = (franchiseJoinCode ?? '').trim();
      if (fj.isNotEmpty) {
        payload['franchise_join_code'] = fj;
      }
      final response = await http
          .post(
            uri,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 25));
      final data = _decodeJson(response.body);
      if (response.statusCode >= 200 &&
          response.statusCode < 300 &&
          data['access'] != null &&
          data['refresh'] != null) {
        return (
          AuthSession(
            access: data['access'].toString(),
            refresh: data['refresh'].toString(),
            role: _roleFromString(data['role']?.toString()),
          ),
          null,
        );
      }
      return (null, (data['message'] ?? 'Неверный код').toString());
    } catch (_) {
      return (null, 'Не удалось подключиться к серверу');
    }
  }

  Future<(bool, String?)> saveFcmDevice({
    required String accessToken,
    required String registrationId,
    required String type,
    required String name,
  }) async {
    try {
      final uri = Uri.parse('$baseUrl/api/fcm/device/');
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $accessToken',
            },
            body: jsonEncode({
              'registration_id': registrationId,
              'type': type,
              'name': name,
            }),
          )
          .timeout(const Duration(seconds: 25));
      final data = _decodeJson(response.body);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return (true, null);
      }
      return (false, (data['message'] ?? 'Не удалось сохранить FCM token').toString());
    } catch (_) {
      return (false, 'Не удалось подключиться к серверу');
    }
  }
}

class TransportCategoryDto {
  const TransportCategoryDto({required this.id, required this.name});
  final int id;
  final String name;
}

class RequestsApi {
  const RequestsApi();
  Future<(double?, List<LatLng>)> roadDistanceWithRoute({
    required String accessToken,
    required List<LatLng> points,
  }) async {
    try {
      if (points.length < 2) return (null, <LatLng>[]);
      final pointsParam = points.map((p) => '${p.latitude},${p.longitude}').join(';');
      final uri = Uri.parse(
        '${AuthApi.baseUrl}/api/road-distance/'
        '?points=${Uri.encodeQueryComponent(pointsParam)}',
      );
      final response = await http.get(
        uri,
        headers: {'Authorization': 'Bearer $accessToken'},
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) return (null, <LatLng>[]);
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return (null, <LatLng>[]);

      final kmRaw = decoded['distance_km'];
      final km = kmRaw == null ? null : double.tryParse(kmRaw.toString());
      final pointsRaw = decoded['route_points'];
      final routePolyline = <LatLng>[];
      if (pointsRaw is List) {
        for (final p in pointsRaw) {
          if (p is List && p.length >= 2) {
            final lat = double.tryParse(p[0].toString());
            final lon = double.tryParse(p[1].toString());
            if (lat != null && lon != null) routePolyline.add(LatLng(lat, lon));
          }
        }
      }
      return (km, routePolyline);
    } catch (_) {
      return (null, <LatLng>[]);
    }
  }


  Future<List<TransportCategoryDto>> getTransports() async {
    try {
      final uri = Uri.parse('${AuthApi.baseUrl}/api/transports/');
      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) return const [];
      final decoded = jsonDecode(response.body);
      final List list = decoded is List
          ? decoded
          : (decoded is Map && decoded['results'] is List)
              ? (decoded['results'] as List)
              : const [];
      return list
          .whereType<Map>()
          .map((e) => TransportCategoryDto(
                id: int.tryParse(e['id']?.toString() ?? '') ?? 0,
                name: (e['name'] ?? '').toString(),
              ))
          .where((e) => e.id > 0 && e.name.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<(bool, String?)> createRequest({
    required String accessToken,
    required Map<String, dynamic> payload,
  }) async {
    try {
      final uri = Uri.parse('${AuthApi.baseUrl}/api/requests/create/');
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $accessToken',
            },
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 20));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return (true, null);
      }

      // DRF validation errors often come as a nested JSON map.
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) {
          List<String> collect(dynamic v) {
            if (v == null) return const [];
            if (v is String) return [v];
            if (v is num || v is bool) return [v.toString()];
            if (v is List) {
              return v.expand(collect).toList(growable: false);
            }
            if (v is Map) {
              return v.values.expand(collect).toList(growable: false);
            }
            return [v.toString()];
          }

          final parts = <String>[];
          for (final v in decoded.values) {
            parts.addAll(collect(v));
          }
          final msg = parts.map((s) => s.trim()).where((s) => s.isNotEmpty).toSet().join('\n');
          return (false, msg.isEmpty ? 'Ошибка запроса' : msg);
        }
      } catch (_) {}

      return (false, 'Ошибка запроса (${response.statusCode})');
    } catch (_) {
      return (false, 'Не удалось подключиться к серверу');
    }
  }

  /// Для водителя: все открытые заявки (pending/active/awaiting_confirmation).
  Future<(List<Map<String, dynamic>>, String?)> listActiveAll({
    required String accessToken,
  }) async {
    try {
      final uri = Uri.parse('${AuthApi.baseUrl}/api/zayavki/');
      final response = await http
          .get(
            uri,
            headers: {'Authorization': 'Bearer $accessToken'},
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (<Map<String, dynamic>>[], 'Не удалось загрузить заявки');
      }
      final decoded = jsonDecode(response.body);
      final List list = decoded is List
          ? decoded
          : (decoded is Map && decoded['results'] is List)
              ? (decoded['results'] as List)
              : const [];
      final out = <Map<String, dynamic>>[];
      for (final item in list) {
        if (item is Map) out.add(item.map((k, v) => MapEntry(k.toString(), v)));
      }
      return (out, null);
    } catch (_) {
      return (<Map<String, dynamic>>[], 'Не удалось подключиться к серверу');
    }
  }

  Future<(List<Map<String, dynamic>>, String?)> listMyRequests({
    required String accessToken,
  }) async {
    try {
      var token = accessToken;
      final uri = Uri.parse('${AuthApi.baseUrl}/api/requests/');
      http.Response response = await http
          .get(
            uri,
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 401) {
        final s = await AuthApi.refreshSessionFromStorage();
        if (s != null) {
          token = s.access;
          response = await http
              .get(uri, headers: {'Authorization': 'Bearer $token'})
              .timeout(const Duration(seconds: 20));
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (<Map<String, dynamic>>[], 'Не удалось загрузить заявки');
      }
      final decoded = jsonDecode(response.body);
      final List list = decoded is List
          ? decoded
          : (decoded is Map && decoded['results'] is List)
              ? (decoded['results'] as List)
              : const [];
      final out = <Map<String, dynamic>>[];
      for (final item in list) {
        if (item is Map) {
          out.add(Map<String, dynamic>.from(item));
        }
      }
      return (out, null);
    } catch (_) {
      return (<Map<String, dynamic>>[], 'Не удалось подключиться к серверу');
    }
  }

  Future<(Map<String, dynamic>?, String?)> getRequestDetail({
    required String accessToken,
    required int id,
  }) async {
    try {
      final uri = Uri.parse('${AuthApi.baseUrl}/api/detail/?id=$id');
      final response = await http
          .get(
            uri,
            headers: {'Authorization': 'Bearer $accessToken'},
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (null, 'Не удалось загрузить заявку');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return (null, 'Неверный ответ');
      return (decoded.map((k, v) => MapEntry(k.toString(), v)), null);
    } catch (_) {
      return (null, 'Не удалось подключиться к серверу');
    }
  }

  Future<Map<String, dynamic>?> getRequestLiveTracking({
    required String accessToken,
    required int requestId,
  }) async {
    try {
      final uri = Uri.parse('${AuthApi.baseUrl}/api/requests/$requestId/live_tracking/');
      final response = await http
          .get(
            uri,
            headers: {'Authorization': 'Bearer $accessToken'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return null;
      return decoded.map((k, v) => MapEntry(k.toString(), v));
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> postDriverRequestLocation({
    required String accessToken,
    required int requestId,
    required double lat,
    required double lng,
    String? roadHint,
  }) async {
    try {
      final uri = Uri.parse('${AuthApi.baseUrl}/api/requests/$requestId/update_location/');
      final body = <String, dynamic>{'lat': lat, 'lng': lng};
      final hint = roadHint?.trim();
      if (hint != null && hint.isNotEmpty) {
        body['road_hint'] = hint.length > 500 ? hint.substring(0, 500) : hint;
      }
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $accessToken',
            },
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 25));
      Map<String, dynamic>? decoded;
      try {
        final d = jsonDecode(response.body);
        if (d is Map) decoded = d.map((k, v) => MapEntry(k.toString(), v));
      } catch (_) {}
      return decoded;
    } catch (_) {
      return null;
    }
  }

  Future<(bool, String?)> respondToRequest({
    required String accessToken,
    required int requestId,
    required double price,
  }) async {
    try {
      final uri = Uri.parse('${AuthApi.baseUrl}/api/requests/$requestId/respond/');
      final response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $accessToken',
            },
            body: jsonEncode({'price': price}),
          )
          .timeout(const Duration(seconds: 20));
      Map<String, dynamic>? decoded;
      try {
        final d = jsonDecode(response.body);
        if (d is Map) decoded = d.map((k, v) => MapEntry(k.toString(), v));
      } catch (_) {}

      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (decoded != null && decoded['success'] == false) {
          return (false, (decoded['message'] ?? 'Ошибка').toString());
        }
        return (true, null);
      }
      final msg = decoded?['message']?.toString();
      return (false, msg ?? 'Ошибка (${response.statusCode})');
    } catch (_) {
      return (false, 'Не удалось подключиться к серверу');
    }
  }

  /// Закрытие заказа заказчиком (`pk` в URL — id заявки / Request).
  Future<(bool, String?)> clientCloseOrder({
    required String accessToken,
    required int requestId,
  }) async {
    try {
      final uri = Uri.parse('${AuthApi.baseUrl}/api/orders/$requestId/client_close/');
      final response = await http
          .post(
            uri,
            headers: {'Authorization': 'Bearer $accessToken'},
          )
          .timeout(const Duration(seconds: 20));
      Map<String, dynamic>? decoded;
      try {
        final d = jsonDecode(response.body);
        if (d is Map) decoded = d.map((k, v) => MapEntry(k.toString(), v));
      } catch (_) {}
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (decoded != null && decoded['success'] == false) {
          return (false, (decoded['message'] ?? 'Ошибка').toString());
        }
        return (true, null);
      }
      final msg = decoded?['message']?.toString();
      return (false, msg ?? 'Ошибка (${response.statusCode})');
    } catch (_) {
      return (false, 'Не удалось подключиться к серверу');
    }
  }

  Future<(List<Map<String, dynamic>>, String?)> listMyOrdersDriver({
    required String accessToken,
  }) async {
    try {
      var token = accessToken;
      final uri = Uri.parse('${AuthApi.baseUrl}/api/my_orders/driver/');
      http.Response response = await http
          .get(
            uri,
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 401) {
        final s = await AuthApi.refreshSessionFromStorage();
        if (s != null) {
          token = s.access;
          response = await http
              .get(uri, headers: {'Authorization': 'Bearer $token'})
              .timeout(const Duration(seconds: 20));
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (<Map<String, dynamic>>[], 'Не удалось загрузить заказы');
      }
      final decoded = jsonDecode(response.body);
      final List list = decoded is List
          ? decoded
          : (decoded is Map && decoded['results'] is List)
              ? (decoded['results'] as List)
              : const [];
      final out = <Map<String, dynamic>>[];
      for (final item in list) {
        if (item is Map) out.add(item.map((k, v) => MapEntry(k.toString(), v)));
      }
      return (out, null);
    } catch (_) {
      return (<Map<String, dynamic>>[], 'Не удалось подключиться к серверу');
    }
  }

  Future<List<OsmHit>> osmSearch({
    required String accessToken,
    required String query,
  }) async {
    try {
      final uri = Uri.parse('${AuthApi.baseUrl}/api/osm/search/?q=${Uri.encodeQueryComponent(query)}');
      final response = await http
          .get(
            uri,
            headers: {'Authorization': 'Bearer $accessToken'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) return const [];
      final decoded = jsonDecode(response.body);
      if (decoded is! Map || decoded['results'] is! List) return const [];
      final list = decoded['results'] as List;
      return list
          .whereType<Map>()
          .map((e) => OsmHit.fromJson(e))
          .where((h) => h.displayName.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }

  Future<String?> osmReverse({
    required String accessToken,
    required double lat,
    required double lon,
  }) async {
    try {
      final uri = Uri.parse('${AuthApi.baseUrl}/api/osm/reverse/?lat=$lat&lon=$lon');
      final response = await http
          .get(
            uri,
            headers: {'Authorization': 'Bearer $accessToken'},
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return null;
      return (decoded['display_name'] ?? '').toString();
    } catch (_) {
      return null;
    }
  }

  Future<double?> roadDistanceKm({
    required String accessToken,
    required double aLat,
    required double aLng,
    required double bLat,
    required double bLng,
  }) async {
    try {
      final uri = Uri.parse(
        '${AuthApi.baseUrl}/api/road-distance/'
        '?a_lat=$aLat&a_lng=$aLng&b_lat=$bLat&b_lng=$bLng',
      );
      final response = await http.get(
        uri,
        headers: {'Authorization': 'Bearer $accessToken'},
      ).timeout(const Duration(seconds: 15));
      if (response.statusCode < 200 || response.statusCode >= 300) return null;
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return null;
      final km = decoded['distance_km'];
      return km == null ? null : double.tryParse(km.toString());
    } catch (_) {
      return null;
    }
  }
}

class ProfileApi {
  const ProfileApi();

  Future<(Map<String, dynamic>?, String?)> fetchMeProfile({
    required String accessToken,
  }) async {
    try {
      var token = accessToken;
      final uri = Uri.parse('${AuthApi.baseUrl}/api/me/');
      http.Response response = await http
          .get(
            uri,
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode == 401) {
        final s = await AuthApi.refreshSessionFromStorage();
        if (s != null) {
          token = s.access;
          response = await http
              .get(uri, headers: {'Authorization': 'Bearer $token'})
              .timeout(const Duration(seconds: 20));
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (null, 'Не удалось загрузить профиль');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map) return (null, 'Неверный ответ');
      return (
        Map<String, dynamic>.from(
          decoded.map((k, v) => MapEntry(k.toString(), v)),
        ),
        null,
      );
    } catch (_) {
      return (null, 'Нет соединения с сервером');
    }
  }

  /// PATCH `api/me/` — `full_name`, `birth_date`, `photo` (multipart).
  Future<(bool, String?)> updateMeProfile({
    required String accessToken,
    required String fullName,
    DateTime? birthDate,
    List<int>? photoBytes,
    String? photoFilename,
    String? franchiseJoinCode,
  }) async {
    try {
      final uri = Uri.parse('${AuthApi.baseUrl}/api/me/');
      final req = http.MultipartRequest('PATCH', uri);
      req.headers['Authorization'] = 'Bearer $accessToken';
      req.fields['full_name'] = fullName;
      final fj = (franchiseJoinCode ?? '').trim();
      if (fj.isNotEmpty) {
        req.fields['franchise_join_code'] = fj;
      }
      if (birthDate != null) {
        req.fields['birth_date'] = DateFormat('yyyy-MM-dd').format(birthDate);
      }
      if (photoBytes != null && photoBytes.isNotEmpty) {
        req.files.add(
          http.MultipartFile.fromBytes(
            'photo',
            photoBytes,
            filename: photoFilename ?? 'photo.jpg',
          ),
        );
      }
      final streamed = await req.send().timeout(const Duration(seconds: 90));
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return (true, null);
      }
      var msg = 'Ошибка сохранения (${response.statusCode})';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) {
          final parts = <String>[];
          for (final e in decoded.entries) {
            final v = e.value;
            if (v is List) {
              parts.add(v.map((x) => x.toString()).join(', '));
            } else {
              parts.add(v.toString());
            }
          }
          if (parts.isNotEmpty) msg = parts.join('\n');
        }
      } catch (_) {}
      return (false, msg);
    } catch (_) {
      return (false, 'Не удалось отправить данные');
    }
  }

  /// Самоудаление: сервер гузошта `is_active=false`, маълумот дар админ мемонад.
  Future<(bool, String?)> deactivateAccount({required String accessToken}) async {
    try {
      final uri = Uri.parse('${AuthApi.baseUrl}/api/account/deactivate/');
      final response = await http
          .post(
            uri,
            headers: {'Authorization': 'Bearer $accessToken'},
          )
          .timeout(const Duration(seconds: 25));
      Map<String, dynamic>? decoded;
      try {
        final d = jsonDecode(response.body);
        if (d is Map) decoded = d.map((k, v) => MapEntry(k.toString(), v));
      } catch (_) {}
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (decoded != null && decoded['success'] == false) {
          return (false, (decoded['message'] ?? 'Ошибка').toString());
        }
        return (true, null);
      }
      return (false, (decoded?['message'] ?? 'Ошибка (${response.statusCode})').toString());
    } catch (_) {
      return (false, 'Нет соединения с сервером');
    }
  }

  /// PATCH `api/me/` (multipart) — driver fields + documents.
  Future<(bool, String?)> updateDriverProfile({
    required String accessToken,
    required String fullName,
    DateTime? birthDate,
    int? cityId,
    String? passport,
    String? inn,
    int? transportCategoryId,
    String? carNumber,
    List<int>? photoBytes,
    String? photoFilename,
    List<int>? passportFrontBytes,
    String? passportFrontFilename,
    List<int>? passportBackBytes,
    String? passportBackFilename,
    List<int>? transportPhotoBytes,
    String? transportPhotoFilename,
    List<int>? techPassportFrontBytes,
    String? techPassportFrontFilename,
    List<int>? techPassportBackBytes,
    String? techPassportBackFilename,
    List<int>? permissionBytes,
    String? permissionFilename,
    List<int>? pravoBytes,
    String? pravoFilename,
    String? franchiseJoinCode,
  }) async {
    try {
      final uri = Uri.parse('${AuthApi.baseUrl}/api/me/');
      final req = http.MultipartRequest('PATCH', uri);
      req.headers['Authorization'] = 'Bearer $accessToken';
      req.fields['full_name'] = fullName;
      final fj = (franchiseJoinCode ?? '').trim();
      if (fj.isNotEmpty) {
        req.fields['franchise_join_code'] = fj;
      }
      if (birthDate != null) req.fields['birth_date'] = DateFormat('yyyy-MM-dd').format(birthDate);
      if (cityId != null) req.fields['city'] = cityId.toString();
      if ((passport ?? '').trim().isNotEmpty) req.fields['passport'] = passport!.trim();
      if ((inn ?? '').trim().isNotEmpty) req.fields['inn'] = inn!.trim();
      if (transportCategoryId != null) req.fields['transport_category'] = transportCategoryId.toString();
      if ((carNumber ?? '').trim().isNotEmpty) req.fields['car_number'] = carNumber!.trim();

      void addBytes(String field, List<int>? bytes, String? filename, String fallbackName) {
        if (bytes == null || bytes.isEmpty) return;
        req.files.add(http.MultipartFile.fromBytes(field, bytes, filename: filename ?? fallbackName));
      }

      addBytes('photo', photoBytes, photoFilename, 'photo.jpg');
      addBytes('passport_front', passportFrontBytes, passportFrontFilename, 'passport_front.jpg');
      addBytes('passport_back', passportBackBytes, passportBackFilename, 'passport_back.jpg');
      addBytes('transport_photo', transportPhotoBytes, transportPhotoFilename, 'transport.jpg');
      addBytes('tech_passport_front', techPassportFrontBytes, techPassportFrontFilename, 'tech_front.jpg');
      addBytes('tech_passport_back', techPassportBackBytes, techPassportBackFilename, 'tech_back.jpg');
      addBytes('permission', permissionBytes, permissionFilename, 'permission.jpg');
      addBytes('pravo', pravoBytes, pravoFilename, 'pravo.jpg');

      final streamed = await req.send().timeout(const Duration(seconds: 120));
      final response = await http.Response.fromStream(streamed);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return (true, null);
      }
      var msg = 'Ошибка сохранения (${response.statusCode})';
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map) {
          final parts = <String>[];
          for (final e in decoded.entries) {
            final v = e.value;
            if (v is List) {
              parts.add(v.map((x) => x.toString()).join(', '));
            } else {
              parts.add(v.toString());
            }
          }
          if (parts.isNotEmpty) msg = parts.join('\n');
        }
      } catch (_) {}
      return (false, msg);
    } catch (_) {
      return (false, 'Не удалось отправить данные');
    }
  }
}

class CityDto {
  const CityDto({required this.id, required this.name});
  final int id;
  final String name;
}

class CitiesApi {
  const CitiesApi();

  Future<List<CityDto>> list() async {
    try {
      final uri = Uri.parse('${AuthApi.baseUrl}/api/cities/');
      final response = await http.get(uri).timeout(const Duration(seconds: 20));
      if (response.statusCode < 200 || response.statusCode >= 300) return const [];
      final decoded = jsonDecode(response.body);
      final List list = decoded is List
          ? decoded
          : (decoded is Map && decoded['results'] is List)
              ? (decoded['results'] as List)
              : const [];
      return list
          .whereType<Map>()
          .map((e) => CityDto(
                id: int.tryParse(e['id']?.toString() ?? '') ?? 0,
                name: (e['name'] ?? '').toString(),
              ))
          .where((e) => e.id > 0 && e.name.isNotEmpty)
          .toList(growable: false);
    } catch (_) {
      return const [];
    }
  }
}

class NotificationsApi {
  const NotificationsApi();

  Future<(List<Map<String, dynamic>>, String?)> list({
    required String accessToken,
  }) async {
    try {
      var token = accessToken;
      final uri = Uri.parse('${AuthApi.baseUrl}/api/notifications/');
      http.Response response = await http
          .get(
            uri,
            headers: {'Authorization': 'Bearer $token'},
          )
          .timeout(const Duration(seconds: 25));
      if (response.statusCode == 401) {
        final s = await AuthApi.refreshSessionFromStorage();
        if (s != null) {
          token = s.access;
          response = await http
              .get(uri, headers: {'Authorization': 'Bearer $token'})
              .timeout(const Duration(seconds: 25));
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (<Map<String, dynamic>>[], 'Не удалось загрузить уведомления');
      }
      final decoded = jsonDecode(response.body);
      List<dynamic> rawList;
      if (decoded is List) {
        rawList = decoded;
      } else if (decoded is Map && decoded['results'] is List) {
        rawList = decoded['results'] as List<dynamic>;
      } else {
        return (<Map<String, dynamic>>[], 'Неверный ответ');
      }
      final out = <Map<String, dynamic>>[];
      for (final item in rawList) {
        if (item is Map) {
          out.add(Map<String, dynamic>.from(
            item.map((k, v) => MapEntry(k.toString(), v)),
          ));
        }
      }
      return (out, null);
    } catch (_) {
      return (<Map<String, dynamic>>[], 'Нет соединения с сервером');
    }
  }
}

class ClientReviewsApi {
  const ClientReviewsApi();

  Future<(List<Map<String, dynamic>>, String?)> listMine({required String accessToken}) async {
    try {
      final uri = Uri.parse('${AuthApi.baseUrl}/api/my_client_reviews/');
      final response = await http
          .get(
            uri,
            headers: {'Authorization': 'Bearer $accessToken'},
          )
          .timeout(const Duration(seconds: 25));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return (<Map<String, dynamic>>[], 'Не удалось загрузить отзывы');
      }
      final decoded = jsonDecode(response.body);
      List<dynamic> rawList;
      if (decoded is List) {
        rawList = decoded;
      } else if (decoded is Map && decoded['results'] is List) {
        rawList = decoded['results'] as List<dynamic>;
      } else {
        return (<Map<String, dynamic>>[], 'Неверный ответ');
      }
      final list = rawList
          .whereType<Map>()
          .map((e) => e.map((k, v) => MapEntry(k.toString(), v)))
          .toList(growable: false);
      return (list, null);
    } catch (_) {
      return (<Map<String, dynamic>>[], 'Нет соединения с сервером');
    }
  }
}

class OsmHit {
  const OsmHit({
    required this.displayName,
    required this.lat,
    required this.lon,
  });
  final String displayName;
  final double? lat;
  final double? lon;

  static OsmHit fromJson(Map e) {
    final displayName = (e['display_name'] ?? e['name'] ?? '').toString();
    double? toDouble(dynamic v) => v == null ? null : double.tryParse(v.toString());
    return OsmHit(
      displayName: displayName,
      lat: toDouble(e['lat']),
      lon: toDouble(e['lon'] ?? e['lng']),
    );
  }
}

class SomonLogisticsApp extends StatefulWidget {
  const SomonLogisticsApp({super.key});

  @override
  State<SomonLogisticsApp> createState() => _SomonLogisticsAppState();
}

class _SomonLogisticsAppState extends State<SomonLogisticsApp> {
  AuthSession? _session;
  bool _darkMode = false;
  bool _sessionLoading = true;

  void setDarkMode(bool value) => setState(() => _darkMode = value);
  void toggleDarkMode() => setState(() => _darkMode = !_darkMode);

  @override
  void initState() {
    super.initState();
    unawaited(_loadSession());
  }

  Future<void> _loadSession() async {
    try {
      final s = await _LocalPrefs.getSession();
      if (!mounted) return;
      setState(() {
        _session = s;
        _sessionLoading = false;
      });
      if (s != null) {
        unawaited(_FcmRegistrar.registerForSession(accessToken: s.access));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _sessionLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final textTheme = GoogleFonts.montserratTextTheme();
    AppColors.surface = _darkMode ? const Color(0xFF0F141A) : const Color(0xFFF4F8FB);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Somon Logistics',
      locale: const Locale('ru', 'RU'),
      supportedLocales: const [Locale('ru', 'RU')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          primary: AppColors.primary,
          secondary: AppColors.navy,
          surface: Colors.white,
        ),
        scaffoldBackgroundColor: AppColors.surface,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0x6609355F)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.primary, width: 1.4),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        textTheme: textTheme,
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          brightness: Brightness.dark,
          primary: AppColors.primary,
          secondary: AppColors.primary,
          surface: const Color(0xFF121A22),
        ),
        scaffoldBackgroundColor: AppColors.surface,
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: const Color(0xFF121A22),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: Color(0x668CA3B8)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppColors.primary, width: 1.4),
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
        ),
        textTheme: textTheme.apply(bodyColor: Colors.white, displayColor: Colors.white),
      ),
      themeMode: _darkMode ? ThemeMode.dark : ThemeMode.light,
      home: _sessionLoading
          ? const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            )
          : _session == null
          ? AuthPage(
              onAuthenticated: (session) {
                setState(() {
                  _session = session;
                });
                unawaited(_LocalPrefs.setSession(session));
                unawaited(_FcmRegistrar.registerForSession(accessToken: session.access));
              },
            )
          : LogisticsShell(
              session: _session!,
              role: _session!.role,
              initialIndex: _session!.role == AppRole.driver ? 2 : 0,
              driverVerified: _session!.role == AppRole.driver ? false : true,
              onLogout: () {
                unawaited(_FcmRegistrar.dispose());
                unawaited(_LocalPrefs.clearSession());
                setState(() => _session = null);
              },
            ),
    );
  }
}

/// Тексти хатогӣ аз сервер (англ.) → русӣ барои экрани OTP.
String _authErrorMessageRu(String text) {
  final t = text.trim();
  const known = <String, String>{
    'Invalid or expired code': 'Неверный или просроченный код.',
    'Invalid code': 'Неверный код.',
    'Invalid JSON': 'Неверный формат данных.',
    'Phone and Code required': 'Укажите номер телефона и код из SMS.',
    'Phone required': 'Укажите номер телефона.',
    'Invalid request': 'Неверный запрос.',
    'Too many requests': 'Слишком много запросов. Попробуйте позже.',
    'Failed to send code': 'Не удалось отправить код.',
    'Method Not Allowed': 'Метод не поддерживается.',
  };
  return known[t] ?? t;
}

class AuthPage extends StatefulWidget {
  const AuthPage({super.key, required this.onAuthenticated});
  final ValueChanged<AuthSession> onAuthenticated;

  @override
  State<AuthPage> createState() => AuthPageState();
}

class AuthPageState extends State<AuthPage> {
  final _api = const AuthApi();
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  final _franchiseJoinController = TextEditingController();
  bool _franchiseLoaded = false;

  AppRole _role = AppRole.client;
  bool _sending = false;
  bool _verifying = false;
  bool _codeSent = false;
  bool _phoneTouched = false;
  int _secondsLeft = 0;
  Timer? _timer;
  Timer? _autoVerifyDebounce;

  bool? _phoneExists;

  @override
  void initState() {
    super.initState();
    unawaited(_initFranchiseCode());
    _codeController.addListener(_maybeAutoVerify);
  }

  void _maybeAutoVerify() {
    if (!mounted) return;
    if (!_codeSent || _verifying) return;
    final code = _codeController.text.trim();
    if (!RegExp(r'^\d{4}$').hasMatch(code)) return;

    // Debounce: let user finish typing/paste.
    _autoVerifyDebounce?.cancel();
    _autoVerifyDebounce = Timer(const Duration(milliseconds: 180), () {
      if (!mounted || _verifying || !_codeSent) return;
      final code2 = _codeController.text.trim();
      if (!RegExp(r'^\d{4}$').hasMatch(code2)) return;
      FocusManager.instance.primaryFocus?.unfocus();
      unawaited(_verifyCode());
    });
  }

  Future<void> _initFranchiseCode() async {
    try {
      final v = await _LocalPrefs.getFranchiseJoinCode();
      if (!mounted) return;
      if (v.isNotEmpty) _franchiseJoinController.text = v;
      setState(() => _franchiseLoaded = true);
    } catch (_) {
      if (mounted) setState(() => _franchiseLoaded = true);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _autoVerifyDebounce?.cancel();
    _codeController.removeListener(_maybeAutoVerify);
    _phoneController.dispose();
    _codeController.dispose();
    _franchiseJoinController.dispose();
    super.dispose();
  }

  bool _isPhoneValid(String phone) => RegExp(r'^\d{9}$').hasMatch(phone);

  void _showAuthAlert(String text) {
    if (!mounted) return;
    final msg = _authErrorMessageRu(text);
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        final dcs = Theme.of(ctx).colorScheme;
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(
            'Сообщение',
            style: GoogleFonts.montserrat(fontWeight: FontWeight.w800, fontSize: 17),
          ),
          content: Text(
            msg,
            style: GoogleFonts.montserrat(
              fontWeight: FontWeight.w600,
              fontSize: 14,
              height: 1.35,
              color: dcs.onSurface.withValues(alpha: 0.88),
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('Понятно', style: GoogleFonts.montserrat(fontWeight: FontWeight.w700)),
            ),
          ],
        );
      },
    );
  }

  void _startCountdown([int seconds = 60]) {
    _timer?.cancel();
    setState(() => _secondsLeft = seconds);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsLeft <= 1) {
        timer.cancel();
        setState(() => _secondsLeft = 0);
      } else {
        setState(() => _secondsLeft -= 1);
      }
    });
  }

  Future<void> _sendCode() async {
    final phone = _phoneController.text.trim();
    if (!_isPhoneValid(phone)) {
      setState(() => _phoneTouched = true);
      _showAuthAlert('Номер должен состоять из 9 цифр');
      return;
    }
    if (_secondsLeft > 0) return;

    final (exists, checkError) = await _api.checkPhoneExists(phone: phone);
    if (checkError != null) {
      _showAuthAlert(checkError);
      return;
    }
    setState(() => _phoneExists = exists);

    setState(() => _sending = true);
    final (error, resendIn) = await _api.sendOtp(
      phone: phone,
      role: _role,
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (error == null) {
      setState(() => _codeSent = true);
      _startCountdown(resendIn ?? 60);
    } else {
      if (resendIn != null && resendIn > 0) {
        _startCountdown(resendIn);
      }
      _showAuthAlert(error);
    }
  }

  Future<void> _verifyCode() async {
    final phone = _phoneController.text.trim();
    final code = _codeController.text.trim();
    if (!_isPhoneValid(phone)) {
      setState(() => _phoneTouched = true);
      _showAuthAlert('Номер должен состоять из 9 цифр');
      return;
    }
    if (!_codeSent) return;
    if (!RegExp(r'^\d{4}$').hasMatch(code)) return;
    if (_verifying) return;

    setState(() => _verifying = true);
    // Persist franchise join code for next sessions/registrations.
    unawaited(_LocalPrefs.setFranchiseJoinCode(_franchiseJoinController.text));
    final (session, error) = await _api.verifyOtp(
      phone: phone,
      code: code,
      role: _role,
      franchiseJoinCode: _franchiseJoinController.text,
    );
    if (!mounted) return;
    setState(() => _verifying = false);
    if (session != null) {
      widget.onAuthenticated(session);
    } else {
      _showAuthAlert(error ?? 'Ошибка');
    }
  }

  Widget _roleSelectionCard(
    BuildContext context, {
    required AppRole role,
    required IconData icon,
    required String title,
    required String subtitle,
    EdgeInsetsGeometry padding = const EdgeInsets.only(bottom: 8),
  }) {
    final cs = Theme.of(context).colorScheme;
    final selected = _role == role;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: padding,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppColors.primary : cs.onSurface.withValues(alpha: isDark ? 0.28 : 0.16),
            width: selected ? 2.2 : 1,
          ),
          color: selected
              ? cs.primary.withValues(alpha: isDark ? 0.22 : 0.10)
              : cs.surface,
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => setState(() => _role = role),
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    icon,
                    size: 28,
                    color: selected ? AppColors.primary : cs.onSurface.withValues(alpha: 0.72),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.montserrat(
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                      color: selected ? AppColors.primary : cs.onSurface,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    subtitle,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.montserrat(
                      fontWeight: FontWeight.w600,
                      fontSize: 12.5,
                      height: 1.35,
                      color: cs.onSurface.withValues(alpha: 0.74),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final phone = _phoneController.text.trim();
    final showPhoneError = _phoneTouched && !_isPhoneValid(phone);
    final isNew = _phoneExists == false;
    final codeStr = _codeController.text.trim();
    final codeReady = _codeSent && RegExp(r'^\d{4}$').hasMatch(codeStr);
    final isExistingUserLogin = _phoneExists == true;
    final savedFranchiseCode = _franchiseJoinController.text.trim();
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight - 40),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 390),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: Image.asset(
                          'assets/images/logo.png',
                          height: 82,
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stack) => const SizedBox(
                            height: 82,
                            child: Center(
                              child: Icon(Icons.local_shipping_rounded, size: 44),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 20),
                      Container(
                        decoration: BoxDecoration(
                          color: cs.surface,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: cs.primary.withValues(alpha: 0.18)),
                          boxShadow: [
                            if (Theme.of(context).brightness != Brightness.dark)
                              BoxShadow(
                                color: cs.shadow.withValues(alpha: 0.10),
                                blurRadius: 14,
                                offset: const Offset(0, 6),
                              ),
                          ],
                        ),
                        padding: const EdgeInsets.all(18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Вход по номеру',
                              style: GoogleFonts.montserrat(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: cs.onSurface,
                              ),
                            ),
                            const SizedBox(height: 12),
                            if (isNew) ...[
                              Text(
                                'У вас сейчас нет доступа в приложение.\nПожалуйста, выберите роль и подтвердите номер.',
                                style: GoogleFonts.montserrat(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurface.withValues(alpha: 0.78),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _roleSelectionCard(
                                    context,
                                    role: AppRole.client,
                                    icon: Icons.person_rounded,
                                    title: 'Заказчик',
                                    subtitle: 'хочу найти перевозчика для своего груза',
                                  ),
                                  _roleSelectionCard(
                                    context,
                                    role: AppRole.driver,
                                    icon: Icons.local_shipping_rounded,
                                    title: 'Водитель',
                                    subtitle: 'Хочу перевозить грузы и получить заказы',
                                    padding: EdgeInsets.zero,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                            ],
                            if (!isExistingUserLogin) ...[
                              if (_franchiseLoaded && isNew && savedFranchiseCode.isEmpty) ...[
                                TextField(
                                  controller: _franchiseJoinController,
                                  textCapitalization: TextCapitalization.characters,
                                  decoration: InputDecoration(
                                    labelText: 'Код франшизы (необязательно)',
                                    hintText: 'Если вас подключил партнёр',
                                    prefixIcon: const Icon(Icons.storefront_outlined),
                                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                                  ),
                                ),
                                const SizedBox(height: 12),
                              ] else if (_franchiseLoaded && savedFranchiseCode.isNotEmpty) ...[
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        'Код франшизы сохранён',
                                        style: GoogleFonts.montserrat(
                                          fontWeight: FontWeight.w700,
                                          color: cs.onSurface.withValues(alpha: 0.75),
                                          fontSize: 12.5,
                                        ),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () async {
                                        final ctrl = TextEditingController(text: savedFranchiseCode);
                                        final v = await showDialog<String?>(
                                          context: context,
                                          builder: (ctx) => AlertDialog(
                                            title: const Text('Код франшизы'),
                                            content: TextField(
                                              controller: ctrl,
                                              textCapitalization: TextCapitalization.characters,
                                              decoration: const InputDecoration(
                                                labelText: 'Код (необязательно)',
                                                prefixIcon: Icon(Icons.storefront_outlined),
                                              ),
                                            ),
                                            actions: [
                                              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
                                              FilledButton(
                                                onPressed: () => Navigator.pop(ctx, ctrl.text),
                                                child: const Text('Сохранить'),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (!mounted || v == null) return;
                                        _franchiseJoinController.text = v;
                                        unawaited(_LocalPrefs.setFranchiseJoinCode(v));
                                        setState(() {});
                                      },
                                      child: const Text('Изменить'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 12),
                              ],
                            ],
                            TextField(
                              controller: _phoneController,
                              keyboardType: TextInputType.phone,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(9),
                              ],
                              onChanged: (_) {
                                setState(() => _phoneTouched = true);
                                setState(() {
                                  _phoneExists = null;
                                  _codeSent = false;
                                  _codeController.clear();
                                  _timer?.cancel();
                                  _secondsLeft = 0;
                                });
                              },
                              decoration: InputDecoration(
                                labelText: 'Номер телефон',
                                prefixIcon: const Icon(Icons.phone_rounded),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                    color: showPhoneError ? Colors.red : const Color(0x6609355F),
                                  ),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                  borderSide: BorderSide(
                                    color: showPhoneError ? Colors.red : AppColors.primary,
                                    width: 1.4,
                                  ),
                                ),
                                errorText: showPhoneError ? 'Номер должен состоять из 9 цифр' : null,
                              ),
                            ),
                            const SizedBox(height: 10),
                            if (!_codeSent) ...[
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton(
                                  onPressed: _sending ? null : _sendCode,
                                  child: Text(_sending ? 'Отправка...' : 'Отправить код'),
                                ),
                              ),
                            ] else ...[
                              TextField(
                                controller: _codeController,
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                  LengthLimitingTextInputFormatter(4),
                                ],
                                onChanged: (_) => setState(() {}),
                                decoration: InputDecoration(
                                  labelText: 'Подтвердить код',
                                  hintText: '4 цифры',
                                ),
                              ),
                              const SizedBox(height: 12),
                              SizedBox(
                                width: double.infinity,
                                child: FilledButton(
                                  onPressed: (codeReady && !_verifying) ? () => unawaited(_verifyCode()) : null,
                                  child: _verifying
                                      ? const SizedBox(
                                          width: 22,
                                          height: 22,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                        )
                                      : Text(
                                          isExistingUserLogin ? 'Вход' : 'Подтвердить',
                                          style: GoogleFonts.montserrat(fontWeight: FontWeight.w700),
                                        ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              InkWell(
                                onTap: _secondsLeft == 0 ? _sendCode : null,
                                child: Text(
                                  _secondsLeft == 0
                                      ? 'Ещё отправить код'
                                      : 'Ещё отправить код через $_secondsLeft секунд',
                                  style: GoogleFonts.montserrat(
                                    color: _secondsLeft == 0 ? AppColors.primary : Colors.grey,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


class LogisticsShell extends StatefulWidget {
  const LogisticsShell({
    super.key,
    required this.session,
    required this.role,
    required this.initialIndex,
    required this.driverVerified,
    required this.onLogout,
  });

  final AuthSession session;
  final AppRole role;
  final int initialIndex;
  final bool driverVerified;
  final VoidCallback onLogout;

  @override
  State<LogisticsShell> createState() => _LogisticsShellState();
}

class _LogisticsShellState extends State<LogisticsShell> {
  int _index = 0;
  String? _franchiseLabel;
  final GlobalKey<_RequestsContentState> _homeRequestsKey = GlobalKey<_RequestsContentState>();
  final GlobalKey<_RequestsContentState> _requestsContentKey = GlobalKey<_RequestsContentState>();
  final GlobalKey<_DriverActiveRequestsContentState> _driverHomeKey =
      GlobalKey<_DriverActiveRequestsContentState>();
  bool _driverVerified = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _driverVerified = widget.driverVerified;
    unawaited(_loadFranchiseLabel());
    if (widget.role == AppRole.driver) {
      unawaited(_refreshDriverVerification());
    }
  }

  Future<void> _loadFranchiseLabel() async {
    try {
      final api = const ProfileApi();
      final (data, _) = await api.fetchMeProfile(accessToken: widget.session.access);
      if (!mounted || data == null) return;
      final fr = data['franchise'];
      if (fr is Map) {
        final n = (fr['name'] ?? '').toString().trim();
        if (n.isNotEmpty) setState(() => _franchiseLabel = n);
      }
    } catch (_) {
      // ignore
    }
  }

  Future<void> _refreshDriverVerification() async {
    try {
      if (widget.role != AppRole.driver) return;
      final api = const ProfileApi();
      final (data, _) = await api.fetchMeProfile(accessToken: widget.session.access);
      if (!mounted) return;
      final status = (data?['status'] ?? '').toString().toLowerCase();
      final verified = status == 'active';
      if (_driverVerified != verified) {
        setState(() => _driverVerified = verified);
        // If just verified, optionally jump to Home.
        if (verified && _index == 2) setState(() => _index = 0);
        // If became unverified, force Profile.
        if (!verified && _index != 2) setState(() => _index = 2);
      }
    } catch (_) {
      // ignore network issues; keep last known state
    }
  }

  List<NavItem> get navItems {
    if (widget.role == AppRole.driver) {
      return const [
        NavItem('Главная', Icons.home_outlined),
        NavItem('Мои заказы', Icons.inventory_2_outlined),
        NavItem('Профиль', Icons.person_outline),
      ];
    }
    return const [
      NavItem('Главная', Icons.home_outlined),
      NavItem('Добавить', Icons.add_circle_outline),
      NavItem('Мои заявки', Icons.description_outlined),
      NavItem('Профиль', Icons.person_outline),
    ];
  }

  int get currentNavIndex => _index;

  void selectTab(int i) {
    if (i < 0 || i >= navItems.length) return;
    if (widget.role == AppRole.driver && !_driverVerified && i != 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Сначала пройдите верификацию в профиле')),
      );
      if (_index != 2) setState(() => _index = 2);
      return;
    }
    if (_index != i) setState(() => _index = i);
  }

  void _showRefreshedSnack() {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Обновлено')),
    );
  }

  void _onMainPageRefresh() {
    switch (_index) {
      case 0:
        if (widget.role == AppRole.client) _homeRequestsKey.currentState?.reload();
        if (widget.role == AppRole.driver) _driverHomeKey.currentState?.reload();
        if (widget.role == AppRole.driver) unawaited(_refreshDriverVerification());
        break;
      case 2:
        if (widget.role == AppRole.client) _requestsContentKey.currentState?.reload();
        if (widget.role == AppRole.driver) unawaited(_refreshDriverVerification());
        break;
      default:
        _showRefreshedSnack();
    }
  }

  Widget _buildPage() {
    if (widget.role == AppRole.driver) {
      switch (_index) {
        case 0:
          return _BasePageScaffold(
            onOpenPush: _openPush,
            onRefresh: _onMainPageRefresh,
            child: _driverVerified
                ? _DriverActiveRequestsContent(
                    key: _driverHomeKey,
                    accessToken: widget.session.access,
                  )
                : _DriverVerificationBlocked(
                    onGoProfile: () => setState(() => _index = 2),
                  ),
          );
        case 1:
          return _BasePageScaffold(
            onOpenPush: _openPush,
            onRefresh: _onMainPageRefresh,
            child: _driverVerified
                ? const _OrdersContent()
                : _DriverVerificationBlocked(
                    onGoProfile: () => setState(() => _index = 2),
                  ),
          );
        default:
          return _BasePageScaffold(
            onOpenPush: _openPush,
            onRefresh: _onMainPageRefresh,
            child: _ProfileContent(
              onLogout: widget.onLogout,
              accessToken: widget.session.access,
              role: widget.role,
              onProfileDataChanged: () => unawaited(_loadFranchiseLabel()),
            ),
          );
      }
    }

    switch (_index) {
      case 0:
        return _BasePageScaffold(
          onOpenPush: _openPush,
          onRefresh: _onMainPageRefresh,
          child: _RequestsContent(
            key: _homeRequestsKey,
            accessToken: widget.session.access,
            activeOnly: true,
            emptyMessage: 'Нет активных заявок',
          ),
        );
      case 1:
        return _BasePageScaffold(
          onOpenPush: _openPush,
          onRefresh: _onMainPageRefresh,
          child: _AddRequestContent(
            accessToken: widget.session.access,
            onNavigateMyRequests: () => setState(() => _index = 2),
          ),
        );
      case 2:
        return _BasePageScaffold(
          onOpenPush: _openPush,
          onRefresh: _onMainPageRefresh,
          child: _RequestsContent(
            key: _requestsContentKey,
            accessToken: widget.session.access,
            showStatusFilters: true,
            showStatusFilterHeading: false,
          ),
        );
      case 3:
        return _BasePageScaffold(
          onOpenPush: _openPush,
          onRefresh: _onMainPageRefresh,
          child: _ProfileContent(
            onLogout: widget.onLogout,
            accessToken: widget.session.access,
            role: widget.role,
            onProfileDataChanged: () => unawaited(_loadFranchiseLabel()),
          ),
        );
      default:
        return _BasePageScaffold(
          onOpenPush: _openPush,
          onRefresh: _onMainPageRefresh,
          child: _ProfileContent(
            onLogout: widget.onLogout,
            accessToken: widget.session.access,
            role: widget.role,
            onProfileDataChanged: () => unawaited(_loadFranchiseLabel()),
          ),
        );
    }
  }

  void openPushNotificationsPage() => _openPush();

  void _openPush() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (ctx) => PushNotificationsPage(
          accessToken: widget.session.access,
          navItems: navItems,
          selectedTabIndex: _index,
          onTabSelected: (i) {
            Navigator.of(ctx).pop();
            selectTab(i);
          },
          onRefresh: () {
            ScaffoldMessenger.of(ctx).showSnackBar(
              const SnackBar(content: Text('Уведомления обновлены')),
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: _AppDrawer(
        onLogout: widget.onLogout,
        accessToken: widget.session.access,
        role: widget.role,
        franchiseSubtitle: _franchiseLabel,
      ),
      body: _buildPage(),
      bottomNavigationBar: _BottomRoleNav(
        items: navItems,
        selectedIndex: _index,
        onTap: (value) => selectTab(value),
      ),
    );
  }
}

class _DriverVerificationBlocked extends StatelessWidget {
  const _DriverVerificationBlocked({required this.onGoProfile});

  final VoidCallback onGoProfile;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.verified_user_outlined, size: 52, color: cs.onSurface.withValues(alpha: 0.55)),
            const SizedBox(height: 14),
            Text(
              'Нужна верификация',
              textAlign: TextAlign.center,
              style: GoogleFonts.montserrat(fontWeight: FontWeight.w900, fontSize: 18, color: cs.onSurface),
            ),
            const SizedBox(height: 8),
            Text(
              'Чтобы откликаться и видеть заявки, заполните профиль и загрузите документы. '
              'После проверки администратор активирует аккаунт.',
              textAlign: TextAlign.center,
              style: GoogleFonts.montserrat(height: 1.35, color: cs.onSurface.withValues(alpha: 0.75)),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onGoProfile,
              child: const Text('Перейти в профиль'),
            ),
          ],
        ),
      ),
    );
  }
}

class NavItem {
  const NavItem(this.label, this.icon);
  final String label;
  final IconData icon;
}

class _BottomRoleNav extends StatelessWidget {
  const _BottomRoleNav({
    required this.items,
    required this.selectedIndex,
    required this.onTap,
  });

  final List<NavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: cs.shadow.withValues(alpha: 0.18),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
          ],
        ),
        child: Row(
          children: List.generate(items.length, (index) {
            final item = items[index];
            final isActive = index == selectedIndex;
            return Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => onTap(index),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
                  decoration: BoxDecoration(
                    color: isActive ? AppColors.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        item.icon,
                        color: isActive ? cs.onPrimary : cs.onSurface.withValues(alpha: 0.75),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.montserrat(
                          fontSize: 12,
                          fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                          color: isActive ? cs.onPrimary : cs.onSurface.withValues(alpha: 0.78),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

class _BasePageScaffold extends StatelessWidget {
  const _BasePageScaffold({
    required this.child,
    required this.onOpenPush,
    this.onRefresh,
  });

  final Widget child;
  final VoidCallback onOpenPush;
  final VoidCallback? onRefresh;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        children: [
          Builder(
            builder: (innerContext) => Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: _TopBar(
                onMenuTap: () => Scaffold.of(innerContext).openDrawer(),
                onNotificationsTap: onOpenPush,
                onRefreshTap: onRefresh,
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    this.onMenuTap,
    this.onBackTap,
    required this.onNotificationsTap,
    this.onRefreshTap,
  }) : assert(onMenuTap != null || onBackTap != null,
            'Укажите onMenuTap или onBackTap');

  final VoidCallback? onMenuTap;
  final VoidCallback? onBackTap;
  final VoidCallback onNotificationsTap;
  final VoidCallback? onRefreshTap;

  Widget _roundIconButton({required IconData icon, required VoidCallback onPressed}) {
    return Builder(
      builder: (context) {
        final cs = Theme.of(context).colorScheme;
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          if (!isDark)
            BoxShadow(
              color: cs.shadow.withValues(alpha: 0.14),
              blurRadius: 14,
              offset: const Offset(0, 5),
            ),
        ],
      ),
      child: IconButton(
        onPressed: onPressed,
        icon: Icon(icon, color: cs.onSurface),
        splashRadius: 22,
      ),
    );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        if (onBackTap != null)
          _roundIconButton(
            icon: Icons.arrow_back_ios_new_rounded,
            onPressed: onBackTap!,
          )
        else
          _roundIconButton(
            icon: Icons.menu_rounded,
            onPressed: onMenuTap!,
          ),
        const SizedBox(width: 10),
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.asset(
                'assets/images/logo.png',
                height: 36,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stack) => const SizedBox(
                  height: 36,
                  child: Center(
                    child: Icon(Icons.local_shipping_rounded, size: 22),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (onRefreshTap != null) ...[
          _roundIconButton(
            icon: Icons.refresh_rounded,
            onPressed: onRefreshTap!,
          ),
          const SizedBox(width: 8),
        ],
        _roundIconButton(
          icon: Icons.notifications_none_rounded,
          onPressed: onNotificationsTap,
        ),
      ],
    );
  }
}

class _AppDrawer extends StatelessWidget {
  const _AppDrawer({
    required this.onLogout,
    required this.accessToken,
    required this.role,
    this.franchiseSubtitle,
  });

  final VoidCallback onLogout;
  final String accessToken;
  final AppRole role;
  final String? franchiseSubtitle;

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final app = context.findAncestorStateOfType<_SomonLogisticsAppState>();
    final isDark = app?._darkMode ?? false;
    final tileBg = cs.primary.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.12 : 0.08);
    return Drawer(
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(24)),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset(
                'assets/images/logo.png',
                height: 56,
                fit: BoxFit.contain,
                errorBuilder: (context, error, stack) => const SizedBox(
                  height: 56,
                  child: Center(
                    child: Icon(Icons.local_shipping_rounded, size: 30),
                  ),
                ),
              ),
            ),
            if (franchiseSubtitle != null && franchiseSubtitle!.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Франшиза: ${franchiseSubtitle!.trim()}',
                textAlign: TextAlign.center,
                style: GoogleFonts.montserrat(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                  height: 1.25,
                ),
              ),
            ],
            const SizedBox(height: 18),
            ListTile(
              leading: const Icon(Icons.notifications_active_outlined, color: AppColors.primary),
              title: Text(
                'Push-уведомления',
                style: GoogleFonts.montserrat(
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              tileColor: tileBg,
              onTap: () {
                final shell = context.findAncestorStateOfType<_LogisticsShellState>();
                Navigator.pop(context);
                shell?.openPushNotificationsPage();
              },
            ),
            const SizedBox(height: 10),
            ListTile(
              leading: Icon(
                isDark ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
                color: AppColors.primary,
              ),
              title: Text(
                'Тема: ${isDark ? 'тёмная' : 'светлая'}',
                style: GoogleFonts.montserrat(
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                ),
              ),
              trailing: Switch(
                value: isDark,
                activeThumbColor: AppColors.primary,
                onChanged: (v) => app?.setDarkMode(v),
              ),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              tileColor: tileBg,
              onTap: () => app?.toggleDarkMode(),
            ),
            const SizedBox(height: 10),
            ListTile(
              leading: Icon(Icons.rate_review_outlined, color: cs.onSurface),
              title: Text(
                'Мои отзывы',
                style: GoogleFonts.montserrat(fontWeight: FontWeight.w600, color: cs.onSurface),
              ),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              onTap: () => _push(
                context,
                FeedbackPage(accessToken: accessToken, role: role),
              ),
            ),
            ListTile(
              leading: Icon(Icons.info_outline_rounded, color: cs.onSurface),
              title: Text(
                'О нас',
                style: GoogleFonts.montserrat(fontWeight: FontWeight.w600, color: cs.onSurface),
              ),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              onTap: () => _push(context, const AboutPage()),
            ),
            ListTile(
              leading: Icon(Icons.policy_outlined, color: cs.onSurface),
              title: Text(
                'Политика',
                style: GoogleFonts.montserrat(fontWeight: FontWeight.w600, color: cs.onSurface),
              ),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              onTap: () => _push(context, const PolicyPage()),
            ),
            ListTile(
              leading: Icon(Icons.contact_support_outlined, color: cs.onSurface),
              title: Text(
                'Контакт',
                style: GoogleFonts.montserrat(fontWeight: FontWeight.w600, color: cs.onSurface),
              ),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              onTap: () => _push(context, const ContactPage()),
            ),
            const SizedBox(height: 10),
            ListTile(
              leading: const Icon(Icons.logout_rounded, color: Colors.redAccent),
              title: Text(
                'Выйти',
                style: GoogleFonts.montserrat(
                  fontWeight: FontWeight.w600,
                  color: Colors.redAccent,
                ),
              ),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              onTap: () {
                Navigator.of(context).pop();
                onLogout();
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SimpleInfoPage extends StatelessWidget {
  const _SimpleInfoPage({
    required this.title,
    required this.body,
    this.actions,
  });

  final String title;
  final String body;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TopBar(
                onBackTap: () => Navigator.of(context).pop(),
                onMenuTap: null,
                onNotificationsTap: () {},
              ),
              const SizedBox(height: 12),
              Text(
                title,
                style: GoogleFonts.montserrat(
                  fontWeight: FontWeight.w800,
                  fontSize: 20,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: SingleChildScrollView(
                  child: Text(
                    body,
                    style: GoogleFonts.montserrat(
                      height: 1.35,
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.85),
                    ),
                  ),
                ),
              ),
              if (actions != null) ...[
                const SizedBox(height: 10),
                ...actions!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _SimpleInfoPage(
      title: 'О нас',
      body:
          'Добро пожаловать в SOMON Logistics!\n\n'
          'Мы — надёжная логистическая компания с большим опытом в сфере грузоперевозок по Таджикистану и странам СНГ.\n\n'
          'Наша команда и партнёры внимательно сопровождают ваш груз на каждом этапе пути — от оформления заявки до доставки.\n\n'
          'Заказать перевозку просто: оформите заявку в мобильном приложении — это удобно как для клиентов, так и для водителей.\n\n'
          'SOMON Logistics — логистика, на которую можно положиться.\n\n'
          'Будем рады долгосрочному сотрудничеству и новым клиентам. Следите за обновлениями и оставайтесь с нами!',
    );
  }
}

class PolicyPage extends StatelessWidget {
  const PolicyPage({super.key});

  @override
  Widget build(BuildContext context) {
    return const _SimpleInfoPage(
      title: 'Политика',
      body:
          'Политика конфиденциальности и условия использования.\n\n'
          'Ин ҷо мо метавонем матни пурраи сиёсати махфиятро гузорем (сбор данных, push, геолокация, удаление аккаунта). '
          'Агар матн/ссылка доред — меандозем.',
    );
  }
}

class ContactPage extends StatelessWidget {
  const ContactPage({super.key});

  @override
  Widget build(BuildContext context) {
    return _SimpleInfoPage(
      title: 'Контакт',
      body:
          'Алоқа бо дастгирӣ.\n\n'
          'Телефон: +992777000570\n',
      actions: [
        FilledButton.tonalIcon(
          onPressed: () async {
            await Clipboard.setData(const ClipboardData(text: 'support@somon.tj'));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Email скопирован')),
            );
          },
          icon: const Icon(Icons.copy_rounded),
          label: const Text('Скопировать Email'),
        ),
      ],
    );
  }
}

class FeedbackPage extends StatefulWidget {
  const FeedbackPage({
    super.key,
    required this.accessToken,
    required this.role,
  });

  final String accessToken;
  final AppRole role;

  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final _api = const ClientReviewsApi();
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.role != AppRole.client) {
      setState(() {
        _loading = false;
        _items = const [];
        _error = 'Отзывы доступны для клиента.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    final (list, err) = await _api.listMine(accessToken: widget.accessToken);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = err;
      _items = list;
    });
  }

  @override
  void dispose() {
    super.dispose();
  }

  Widget _stars(int rating) {
    final r = rating.clamp(0, 5);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        final filled = i < r;
        return Icon(
          filled ? Icons.star_rounded : Icons.star_border_rounded,
          size: 18,
          color: filled ? const Color(0xFFFFC107) : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.35),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TopBar(
                onBackTap: () => Navigator.of(context).pop(),
                onMenuTap: null,
                onNotificationsTap: () {},
              ),
              const SizedBox(height: 12),
              Text(
                'Мои отзывы',
                style: GoogleFonts.montserrat(
                  fontWeight: FontWeight.w800,
                  fontSize: 20,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Здесь отображаются отзывы водителей о вас.',
                style: GoogleFonts.montserrat(
                  color: cs.onSurface.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
                    : _error != null && _items.isEmpty
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    _error!,
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.montserrat(color: cs.onSurface),
                                  ),
                                  const SizedBox(height: 16),
                                  FilledButton(onPressed: _load, child: const Text('Повторить')),
                                ],
                              ),
                            ),
                          )
                        : _items.isEmpty
                            ? Center(
                                child: Text(
                                  'Пока нет отзывов',
                                  style: GoogleFonts.montserrat(
                                    fontWeight: FontWeight.w600,
                                    color: cs.onSurface.withValues(alpha: 0.6),
                                  ),
                                ),
                              )
                            : RefreshIndicator(
                                color: AppColors.primary,
                                onRefresh: _load,
                                child: ListView.separated(
                                  physics: const AlwaysScrollableScrollPhysics(),
                                  padding: const EdgeInsets.only(bottom: 12),
                                  itemCount: _items.length,
                                  separatorBuilder: (context, index) => const SizedBox(height: 10),
                                  itemBuilder: (context, index) {
                                    final row = _items[index];
                                    final rating = int.tryParse((row['rating'] ?? '').toString()) ?? 0;
                                    final comment = (row['comment'] ?? '').toString().trim();
                                    final orderName = (row['order_name'] ?? '').toString().trim();
                                    final created = (row['created_at'] ?? '').toString();
                                    final driver = row['driver'];
                                    final driverName = driver is Map ? (driver['full_name'] ?? '').toString() : '';

                                    return Container(
                                      padding: const EdgeInsets.all(14),
                                      decoration: BoxDecoration(
                                        color: cs.surface,
                                        borderRadius: BorderRadius.circular(18),
                                        border: Border.all(color: cs.primary.withValues(alpha: 0.16)),
                                      ),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  orderName.isEmpty ? 'Заявка' : orderName,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: GoogleFonts.montserrat(
                                                    fontWeight: FontWeight.w800,
                                                    color: cs.onSurface,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              _stars(rating),
                                            ],
                                          ),
                                          if (driverName.isNotEmpty) ...[
                                            const SizedBox(height: 6),
                                            Text(
                                              'Водитель: $driverName',
                                              style: GoogleFonts.montserrat(
                                                fontWeight: FontWeight.w600,
                                                fontSize: 12.5,
                                                color: cs.onSurface.withValues(alpha: 0.7),
                                              ),
                                            ),
                                          ],
                                          if (comment.isNotEmpty) ...[
                                            const SizedBox(height: 10),
                                            Text(
                                              comment,
                                              style: GoogleFonts.montserrat(
                                                height: 1.35,
                                                color: cs.onSurface.withValues(alpha: 0.85),
                                              ),
                                            ),
                                          ],
                                          const SizedBox(height: 10),
                                          Text(
                                            notificationRelativeRu(created),
                                            style: GoogleFonts.montserrat(
                                              fontWeight: FontWeight.w600,
                                              fontSize: 12,
                                              color: AppColors.primary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PushNotificationsPage extends StatefulWidget {
  const PushNotificationsPage({
    super.key,
    required this.accessToken,
    required this.navItems,
    required this.selectedTabIndex,
    required this.onTabSelected,
    this.onRefresh,
  });

  final String accessToken;
  final List<NavItem> navItems;
  final int selectedTabIndex;
  final ValueChanged<int> onTabSelected;
  final VoidCallback? onRefresh;

  @override
  State<PushNotificationsPage> createState() => _PushNotificationsPageState();
}

class _PushNotificationsPageState extends State<PushNotificationsPage> {
  final _api = const NotificationsApi();
  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final cacheKey = 'cache_notifications_v1:${await _JsonCache._scope()}';
    final cached = await _JsonCache.getList(cacheKey);
    if (mounted && cached != null && cached.isNotEmpty) {
      setState(() {
        _items = cached;
        _loading = false;
        _error = null;
      });
    } else {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final (list, err) = await _api.list(accessToken: widget.accessToken);
    if (!mounted) return;
    if (err == null) {
      unawaited(_JsonCache.setJson(cacheKey, list));
    }
    setState(() {
      _loading = false;
      _error = err;
      _items = list;
    });
  }

  Future<void> _onRefreshTap() async {
    widget.onRefresh?.call();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: _TopBar(
                onBackTap: () => Navigator.of(context).pop(),
                onNotificationsTap: () {},
                onRefreshTap: _onRefreshTap,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Push-уведомления',
                  style: GoogleFonts.montserrat(
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                    fontSize: 20,
                  ),
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: AppColors.primary))
                  : _error != null && _items.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(
                                  _error!,
                                  textAlign: TextAlign.center,
                                  style: GoogleFonts.montserrat(color: cs.onSurface),
                                ),
                                const SizedBox(height: 16),
                                FilledButton(onPressed: _load, child: const Text('Повторить')),
                              ],
                            ),
                          ),
                        )
                      : _items.isEmpty
                          ? Center(
                              child: Text(
                                'Нет уведомлений',
                                style: GoogleFonts.montserrat(
                                  fontWeight: FontWeight.w600,
                                  color: cs.onSurface.withValues(alpha: 0.60),
                                ),
                              ),
                            )
                          : RefreshIndicator(
                              color: AppColors.primary,
                              onRefresh: _load,
                              child: ListView.separated(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.all(16),
                                itemCount: _items.length,
                                separatorBuilder: (_, _) => const SizedBox(height: 10),
                                itemBuilder: (context, index) {
                                  final row = _items[index];
                                  final title = (row['title'] ?? '').toString();
                                  final body = (row['body'] ?? '').toString();
                                  final created = (row['created_at'] ?? '').toString();
                                  return Container(
                                    padding: const EdgeInsets.all(14),
                                    decoration: BoxDecoration(
                                      color: cs.surface,
                                      borderRadius: BorderRadius.circular(18),
                                      border: Border.all(color: cs.primary.withValues(alpha: 0.16)),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          title.isEmpty ? 'Уведомление' : title,
                                          style: GoogleFonts.montserrat(
                                            fontWeight: FontWeight.w700,
                                            color: cs.onSurface,
                                          ),
                                        ),
                                        if (body.isNotEmpty) ...[
                                          const SizedBox(height: 6),
                                          Text(
                                            body,
                                            style: GoogleFonts.montserrat(
                                              color: cs.onSurface.withValues(alpha: 0.78),
                                              fontSize: 13,
                                              height: 1.3,
                                            ),
                                          ),
                                        ],
                                        const SizedBox(height: 8),
                                        Text(
                                          notificationRelativeRu(created),
                                          style: GoogleFonts.montserrat(
                                            color: AppColors.primary,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _BottomRoleNav(
        items: widget.navItems,
        selectedIndex: widget.selectedTabIndex,
        onTap: widget.onTabSelected,
      ),
    );
  }
}

// (Было) _QuickActionCard/_HomeContent — demo-карточки. Сейчас водительская "Главная" показывает активные заявки.

class _DriverActiveRequestsContent extends StatefulWidget {
  const _DriverActiveRequestsContent({super.key, required this.accessToken});

  final String accessToken;

  @override
  State<_DriverActiveRequestsContent> createState() => _DriverActiveRequestsContentState();
}

class _DriverActiveRequestsContentState extends State<_DriverActiveRequestsContent> {
  final _api = const RequestsApi();
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = const [];
  int _filterIdx = 0; // 0=Все, 1=Международные, 2=Внутренние (UI-only for now)

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final (list, err) = await _api.listActiveAll(accessToken: widget.accessToken);
    if (!mounted) return;
    final keepStatuses = {'pending', 'active'};
    final visible = list.where((r) => keepStatuses.contains((r['status'] ?? '').toString().toLowerCase())).toList();
    setState(() {
      _loading = false;
      _error = err;
      _items = visible;
    });
  }

  bool _isInternational(Map<String, dynamic> r) {
    final origins = _parseStopList(r['origin_stops']);
    final dests = _parseStopList(r['destination_stops']);
    final all = [...origins, ...dests];
    bool hasTj = false;
    bool hasForeign = false;
    for (final s in all) {
      final a = (s['address'] ?? '').toString().toLowerCase();
      if (a.contains('тоҷикистон') || a.contains('таджикистан') || a.contains('tadjikistan')) {
        hasTj = true;
      }
      if (a.contains('россия') ||
          a.contains('russia') ||
          a.contains('казахстан') ||
          a.contains('kazakhstan') ||
          a.contains('узбекистан') ||
          a.contains('uzbekistan') ||
          a.contains('кыргызстан') ||
          a.contains('kyrgyzstan') ||
          a.contains('беларусь') ||
          a.contains('belarus') ||
          a.contains('польша') ||
          a.contains('poland') ||
          a.contains('китай') ||
          a.contains('china') ||
          a.contains('турция') ||
          a.contains('turkey')) {
        hasForeign = true;
      }
    }
    // International: clearly TJ + some other country mentioned
    return hasTj && hasForeign;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_error!, textAlign: TextAlign.center, style: GoogleFonts.montserrat(color: cs.onSurface)),
              const SizedBox(height: 16),
              FilledButton(onPressed: reload, child: const Text('Повторить')),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          'Пока нет заявок',
          style: GoogleFonts.montserrat(
            fontWeight: FontWeight.w600,
            color: cs.onSurface.withValues(alpha: 0.6),
          ),
        ),
      );
    }

    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: reload,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 20),
        itemCount: (() {
              final filtered = _filterIdx == 0
                  ? _items
                  : _items.where((r) => _filterIdx == 1 ? _isInternational(r) : !_isInternational(r)).toList();
              return filtered.length + 1;
            })(),
        itemBuilder: (context, i) {
          if (i == 0) {
            Widget chip(String label, int idx) {
              final selected = _filterIdx == idx;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => setState(() => _filterIdx = idx),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      color: selected
                          ? cs.primary.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.28 : 0.12)
                          : cs.surface,
                      border: Border.all(
                        color: selected
                            ? cs.primary.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.65 : 0.35)
                            : cs.onSurface.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.18 : 0.10),
                      ),
                    ),
                    child: Text(
                      label,
                      style: GoogleFonts.montserrat(
                        fontWeight: FontWeight.w800,
                        color: selected ? cs.onSurface : cs.onSurface.withValues(alpha: 0.75),
                      ),
                    ),
                  ),
                ),
              );
            }

            return Padding(
              padding: const EdgeInsets.only(bottom: 12, top: 4),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    chip('Все', 0),
                    chip('Международные', 1),
                    chip('Внутренние', 2),
                  ],
                ),
              ),
            );
          }
          final filtered = _filterIdx == 0
              ? _items
              : _items.where((r) => _filterIdx == 1 ? _isInternational(r) : !_isInternational(r)).toList();
          final r = filtered[i - 1];
          final id = int.tryParse((r['id'] ?? '').toString()) ?? 0;
          final name = (r['name'] ?? '').toString().trim();
          final title = name.isNotEmpty ? 'Заявка № $id — $name' : 'Заявка № $id';
          final status = _requestStatusRu(r['status']?.toString());
          final routeLine = _rqListRouteCitiesLine(r);
          final loadD = _formatApiDate(r['load_date']?.toString());
          final delD = _formatApiDate(r['delivery_date']?.toString());
          final dateLine = (loadD == '—' && delD == '—') ? '—' : 'от $loadD до $delD';
          final price = _fmtRequestListField(r['price_tjs']?.toString());
          final dist = _fmtRequestListField(r['distance_km']?.toString());
          final ton = _fmtRequestListField(r['tonnage_t']?.toString());
          final shell = context.findAncestorStateOfType<_LogisticsShellState>();

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: cs.surface,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: id > 0
                    ? () {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (detailCtx) => _MyRequestDetailPage(
                              accessToken: widget.accessToken,
                              requestId: id,
                              previewTitle: title,
                              role: AppRole.driver,
                              navItems: shell?.navItems ?? const [],
                              selectedTabIndex: shell?.currentNavIndex ?? 0,
                              onNavTabTap: (idx) {
                                Navigator.of(detailCtx).pop();
                                shell?.selectTab(idx);
                              },
                              onOpenPush: () => shell?.openPushNotificationsPage(),
                            ),
                          ),
                        );
                      }
                    : null,
                child: Ink(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: cs.primary.withValues(alpha: 0.16)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.montserrat(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 15,
                                  color: cs.onSurface,
                                  height: 1.25,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: cs.onSurface.withValues(alpha: 0.40),
                              size: 26,
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        requestOrderListLrRow(context, 'Маршрут:', routeLine, maxLines: 8),
                        requestOrderListLrRow(context, 'Дата:', dateLine),
                        requestOrderListLrRow(
                          context,
                          'Цена:',
                          price == '—' ? '—' : '$price смн',
                        ),
                        requestOrderListLrRow(
                          context,
                          'Расстояние:',
                          dist == '—' ? '—' : '$dist км',
                        ),
                        requestOrderListLrRow(
                          context,
                          'Общий вес:',
                          ton == '—' ? '—' : '$ton тон',
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: cs.primary.withValues(
                                  alpha: Theme.of(context).brightness == Brightness.dark ? 0.22 : 0.12,
                                ),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: cs.primary.withValues(
                                    alpha: Theme.of(context).brightness == Brightness.dark ? 0.55 : 0.30,
                                  ),
                                ),
                              ),
                              child: Text(
                                status,
                                style: GoogleFonts.montserrat(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: cs.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _OrdersContent extends StatelessWidget {
  const _OrdersContent();

  @override
  Widget build(BuildContext context) {
    final shell = context.findAncestorStateOfType<_LogisticsShellState>();
    final accessToken = shell?.widget.session.access ?? '';
    if (accessToken.isEmpty) {
      return Center(
        child: Text(
          'Не удалось загрузить заказы',
          style: GoogleFonts.montserrat(fontWeight: FontWeight.w600, color: Theme.of(context).colorScheme.onSurface),
        ),
      );
    }
    return _DriverOrdersList(accessToken: accessToken);
  }
}

class _DriverOrdersList extends StatefulWidget {
  const _DriverOrdersList({required this.accessToken});
  final String accessToken;

  @override
  State<_DriverOrdersList> createState() => _DriverOrdersListState();
}

class _DriverOrdersListState extends State<_DriverOrdersList> {
  final _api = const RequestsApi();
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _items = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final cacheKey = 'cache_driver_orders_v1:${await _JsonCache._scope()}';
    final cached = await _JsonCache.getList(cacheKey);
    if (mounted && cached != null && cached.isNotEmpty) {
      setState(() {
        _items = cached;
        _loading = false;
        _error = null;
      });
    } else {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final (list, err) = await _api.listMyOrdersDriver(accessToken: widget.accessToken);
    if (!mounted) return;
    if (err == null) {
      unawaited(_JsonCache.setJson(cacheKey, list));
    }
    setState(() {
      _loading = false;
      _error = err;
      _items = list;
    });
  }

  String _shortCity(Map<String, dynamic> o, String kind) {
    final v = (o[kind == 'from' ? 'from_city_short' : 'to_city_short'] ?? '').toString().trim();
    if (v.isNotEmpty && v != 'null') return v;
    // Fallback: old servers may not send *_short yet.
    return (o[kind == 'from' ? 'from_city' : 'to_city'] ?? '').toString().trim();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final shell = context.findAncestorStateOfType<_LogisticsShellState>();
    if (_loading) return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_error!, textAlign: TextAlign.center, style: GoogleFonts.montserrat(color: cs.onSurface)),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Повторить')),
            ],
          ),
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          'Пока нет заказов',
          style: GoogleFonts.montserrat(fontWeight: FontWeight.w600, color: cs.onSurface.withValues(alpha: 0.6)),
        ),
      );
    }

    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _load,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 20),
        itemCount: _items.length,
        itemBuilder: (context, i) {
          final o = _items[i];
          final id = int.tryParse((o['id'] ?? '').toString()) ?? 0;
          final requestId = int.tryParse((o['request_id'] ?? '').toString()) ?? 0;
          final displayId = requestId > 0 ? requestId : id;
          final reqName = (o['request_name'] ?? '').toString().trim();
          final title = reqName.isNotEmpty
              ? 'Заявка № $displayId — $reqName'
              : (displayId > 0 ? 'Заявка № $displayId' : 'Заявка');
          final fromCity = _shortCity(o, 'from');
          final toCity = _shortCity(o, 'to');
          final routeLine = (fromCity != '—' && toCity != '—') ? '$fromCity → $toCity' : '—';
          final loadD = _formatApiDate(o['load_date_display']?.toString());
          final delD = _formatApiDate(o['delivery_date_display']?.toString());
          final dateLine = (loadD == '—' && delD == '—') ? '—' : 'от $loadD до $delD';
          final price = _fmtRequestListField(o['order_sum']?.toString());
          final dist = _fmtRequestListField(o['distance_km']?.toString());
          final ton = _fmtRequestListField(o['weight_t']?.toString());
          final status = _requestStatusRu((o['request_status'] ?? o['status'] ?? '').toString());

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: cs.surface,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () {
                  final reqId = int.tryParse((o['request_id'] ?? '').toString()) ?? 0;
                  if (reqId > 0) {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (detailCtx) => _MyRequestDetailPage(
                          accessToken: widget.accessToken,
                          requestId: reqId,
                          previewTitle: title,
                          role: AppRole.driver,
                          navItems: shell?.navItems ?? const [],
                          selectedTabIndex: shell?.currentNavIndex ?? 1,
                          onNavTabTap: (idx) {
                            Navigator.of(detailCtx).pop();
                            shell?.selectTab(idx);
                          },
                          onOpenPush: () => shell?.openPushNotificationsPage(),
                        ),
                      ),
                    );
                  } else {
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (detailCtx) => _DriverOrderDetailPage(
                          accessToken: widget.accessToken,
                          order: o,
                          navItems: shell?.navItems ?? const [],
                          selectedTabIndex: shell?.currentNavIndex ?? 1,
                          onNavTabTap: (idx) {
                            Navigator.of(detailCtx).pop();
                            shell?.selectTab(idx);
                          },
                          onOpenPush: () => shell?.openPushNotificationsPage(),
                        ),
                      ),
                    );
                  }
                },
                child: Ink(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: cs.primary.withValues(alpha: 0.16)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.montserrat(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 15,
                                  color: cs.onSurface,
                                  height: 1.25,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: cs.onSurface.withValues(alpha: 0.40),
                              size: 26,
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        requestOrderListLrRow(context, 'Маршрут:', routeLine, maxLines: 8),
                        requestOrderListLrRow(context, 'Дата:', dateLine),
                        requestOrderListLrRow(
                          context,
                          'Цена:',
                          price == '—' ? '—' : '$price смн',
                        ),
                        requestOrderListLrRow(
                          context,
                          'Расстояние:',
                          dist == '—' ? '—' : '$dist км',
                        ),
                        requestOrderListLrRow(
                          context,
                          'Общий вес:',
                          ton == '—' ? '—' : '$ton тон',
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: cs.primary.withValues(
                                  alpha: Theme.of(context).brightness == Brightness.dark ? 0.22 : 0.12,
                                ),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: cs.primary.withValues(
                                    alpha: Theme.of(context).brightness == Brightness.dark ? 0.55 : 0.30,
                                  ),
                                ),
                              ),
                              child: Text(
                                status,
                                style: GoogleFonts.montserrat(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: cs.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DriverOrderDetailPage extends StatelessWidget {
  const _DriverOrderDetailPage({
    required this.accessToken,
    required this.order,
    required this.navItems,
    required this.selectedTabIndex,
    required this.onNavTabTap,
    required this.onOpenPush,
  });
  final String accessToken;
  final Map<String, dynamic> order;
  final List<NavItem> navItems;
  final int selectedTabIndex;
  final ValueChanged<int> onNavTabTap;
  final VoidCallback onOpenPush;

  @override
  Widget build(BuildContext context) {
    return _DriverOrderDetailBody(
      accessToken: accessToken,
      order: order,
      navItems: navItems,
      selectedTabIndex: selectedTabIndex,
      onNavTabTap: onNavTabTap,
      onOpenPush: onOpenPush,
    );
  }
}

class _DriverOrderDetailBody extends StatefulWidget {
  const _DriverOrderDetailBody({
    required this.accessToken,
    required this.order,
    required this.navItems,
    required this.selectedTabIndex,
    required this.onNavTabTap,
    required this.onOpenPush,
  });
  final String accessToken;
  final Map<String, dynamic> order;
  final List<NavItem> navItems;
  final int selectedTabIndex;
  final ValueChanged<int> onNavTabTap;
  final VoidCallback onOpenPush;

  @override
  State<_DriverOrderDetailBody> createState() => _DriverOrderDetailBodyState();
}

class _DriverOrderDetailBodyState extends State<_DriverOrderDetailBody> {
  final _api = const RequestsApi();
  bool _loading = false;
  String? _err;
  Map<String, dynamic>? _req;

  @override
  void initState() {
    super.initState();
    final reqId = int.tryParse((widget.order['request_id'] ?? '').toString()) ?? 0;
    if (reqId > 0) {
      _loading = true;
      unawaited(_loadRequest(reqId));
    }
  }

  Future<void> _loadRequest(int id) async {
    final (map, err) = await _api.getRequestDetail(accessToken: widget.accessToken, id: id);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _req = map;
      _err = err;
    });
  }

  Future<void> _openRouteOnMap() async {
    final r = _req;
    if (r == null) return;
    final origins = _parseStopList(r['origin_stops']);
    final dests = _parseStopList(r['destination_stops']);
    final stops = _requestStopsToLatLngs(origins, dests);
    if (stops.length < 2) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нет координат точек на карте.')),
      );
      return;
    }
    final reqId = int.tryParse((widget.order['request_id'] ?? '').toString()) ?? 0;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _RequestDetailRouteMapPage(
          accessToken: widget.accessToken,
          stops: stops,
          fallbackDistanceKm: double.tryParse((widget.order['distance_km'] ?? '').toString().replaceAll(',', '.')),
          requestId: reqId > 0 ? reqId : null,
          trackingMode: reqId > 0 ? RouteMapTrackingMode.driver : RouteMapTrackingMode.none,
          shareUrl: () {
            final u = (_req?['tracking_share_url'] ?? '').toString().trim();
            return u.isEmpty ? null : u;
          }(),
        ),
      ),
    );
  }

  String _fmtNum(dynamic raw) {
    if (raw == null) return '—';
    final s = raw.toString();
    if (s.isEmpty || s == 'null') return '—';
    final d = double.tryParse(s.replaceAll(',', '.'));
    if (d == null) return s;
    if ((d - d.round()).abs() < 1e-9) return d.round().toString();
    return d.toStringAsFixed(2);
  }

  String _fmtDate(dynamic raw) {
    final s = (raw ?? '').toString().trim();
    if (s.isEmpty || s == 'null') return '—';
    return _formatApiDate(s);
  }

  Widget _row(BuildContext context, String k, String v) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            k,
            style: GoogleFonts.montserrat(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              v,
              textAlign: TextAlign.right,
              style: GoogleFonts.montserrat(
                fontSize: 12.8,
                fontWeight: FontWeight.w800,
                color: cs.onSurface,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatStopLine(Map<String, dynamic> s) {
    final addr = (s['address'] ?? '').toString().trim();
    final wh = (s['warehouse'] ?? '').toString().trim();
    final city = (s['city'] ?? '').toString().trim();
    final parts = <String>[
      if (city.isNotEmpty) city,
      if (addr.isNotEmpty) addr,
      if (wh.isNotEmpty) 'Склад: $wh',
    ];
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  String _shortCityFromOrder(Map<String, dynamic> o, String kind) {
    final v = (o[kind == 'from' ? 'from_city_short' : 'to_city_short'] ?? '').toString().trim();
    if (v.isNotEmpty && v != 'null') return v;
    return (o[kind == 'from' ? 'from_city' : 'to_city'] ?? '').toString().trim();
  }

  Widget _deliveryAddresses(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final r = _req;
    final origins = r == null ? const <Map<String, dynamic>>[] : _parseStopList(r['origin_stops']);
    final dests = r == null ? const <Map<String, dynamic>>[] : _parseStopList(r['destination_stops']);

    List<String> parseSemiList(dynamic raw) {
      final s = (raw ?? '').toString().trim();
      if (s.isEmpty || s == 'null' || s == '—') return const [];
      return s
          .split(';')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && e != 'null' && e != '—')
          .toList(growable: false);
    }

    // Prefer "Order" model fields (used by /api/my_orders/driver/).
    final fromAddrRaw = widget.order['from_address'];
    final toAddrRaw = widget.order['to_address'];
    // Fallback to "Request create" payload style (used elsewhere).
    final originAddrRaw = widget.order['origin_address'] ?? fromAddrRaw;
    final destAddrRaw = widget.order['dest_address'] ?? toAddrRaw;
    final originWhRaw = widget.order['origin_warehouse'];
    final destWhRaw = widget.order['dest_warehouse'];

    final originAddrList = parseSemiList(originAddrRaw);
    final destAddrList = parseSemiList(destAddrRaw);
    final originWhList = parseSemiList(originWhRaw);
    final destWhList = parseSemiList(destWhRaw);

    final fromFallback = _shortCityFromOrder(widget.order, 'from');
    final toFallback = _shortCityFromOrder(widget.order, 'to');
    final hasFallback = (fromFallback.isNotEmpty && fromFallback != '—' && fromFallback != 'null') ||
        (toFallback.isNotEmpty && toFallback != '—' && toFallback != 'null');

    final hasOrderAddresses = originAddrList.isNotEmpty || destAddrList.isNotEmpty;
    if (origins.isEmpty && dests.isEmpty && !hasOrderAddresses && !hasFallback) return const SizedBox.shrink();

    Widget section(String title, List<Map<String, dynamic>> stops) {
      if (stops.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              style: GoogleFonts.montserrat(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 6),
            ...stops.asMap().entries.map((e) {
              final idx = e.key + 1;
              final line = _formatStopLine(e.value);
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${stops.length > 1 ? '$idx. ' : ''}$line',
                  style: GoogleFonts.montserrat(
                    fontSize: 12.2,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface.withValues(alpha: 0.78),
                    height: 1.25,
                  ),
                ),
              );
            }),
          ],
        ),
      );
    }

    Widget fallbackSection() {
      if (hasOrderAddresses) {
        Widget listBlock(String title, List<String> addrs, List<String> whs) {
          if (addrs.isEmpty) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  title,
                  style: GoogleFonts.montserrat(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
                ),
                const SizedBox(height: 6),
                ...addrs.asMap().entries.map((e) {
                  final idx = e.key;
                  final addr = e.value;
                  final wh = (idx < whs.length) ? whs[idx].trim() : '';
                  final line = wh.isNotEmpty ? '$addr · Склад: $wh' : addr;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text(
                      '${addrs.length > 1 ? '${idx + 1}. ' : ''}$line',
                      style: GoogleFonts.montserrat(
                        fontSize: 12.2,
                        fontWeight: FontWeight.w700,
                        color: cs.onSurface.withValues(alpha: 0.78),
                        height: 1.25,
                      ),
                    ),
                  );
                }),
              ],
            ),
          );
        }

        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              listBlock('Адрес погрузки', originAddrList, originWhList),
              listBlock('Адрес доставки', destAddrList, destWhList),
            ],
          ),
        );
      }

      if (!hasFallback) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Пункты',
              style: GoogleFonts.montserrat(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: cs.onSurface.withValues(alpha: 0.55),
              ),
            ),
            const SizedBox(height: 6),
            if (fromFallback.isNotEmpty && fromFallback != '—' && fromFallback != 'null')
              Text(
                'Отправление: $fromFallback',
                style: GoogleFonts.montserrat(
                  fontSize: 12.2,
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface.withValues(alpha: 0.78),
                  height: 1.25,
                ),
              ),
            if (toFallback.isNotEmpty && toFallback != '—' && toFallback != 'null')
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Назначение: $toFallback',
                  style: GoogleFonts.montserrat(
                    fontSize: 12.2,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface.withValues(alpha: 0.78),
                    height: 1.25,
                  ),
                ),
              ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          section('Адрес погрузки', origins),
          section('Адрес доставки', dests),
          if (origins.isEmpty && dests.isEmpty) fallbackSection(),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final order = widget.order;
    final id = int.tryParse((order['id'] ?? '').toString()) ?? 0;
    final sum = _fmtNum(order['order_sum']);
    final dist = _fmtNum(order['distance_km']);
    final w = _fmtNum(order['weight_t']);
    final statusRu = (order['status_ru'] ?? order['status'] ?? '—').toString();
    final statusCode = (order['status'] ?? '').toString();
    final showContactPhones = _showPhoneContactsForStatus(statusCode);
    var bidIso = (order['accepted_bid_at'] ?? '').toString().trim();
    if (_req != null) {
      final br = (_req!['accepted_bid_at'] ?? '').toString().trim();
      if (br.isNotEmpty && br != 'null') bidIso = br;
    }
    final clientPh = _firstNonEmptyStr([order['client_phone'], _req?['client_phone']]);
    final senderN = _firstNonEmptyStr([order['sender_name'], _req?['sender_name']]);
    final senderPh = _firstNonEmptyStr([order['sender_phone'], _req?['sender_phone']]);
    final loadDate = _fmtDate(order['load_date_display']);
    final deliveryDate = _fmtDate(order['delivery_date_display']);
    final reqName = (order['request_name'] ?? '').toString().trim();
    final reqDesc = (order['request_description'] ?? '').toString().trim();

    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: _TopBar(
                onBackTap: () => Navigator.of(context).pop(),
                onNotificationsTap: widget.onOpenPush,
                onRefreshTap: () {
                  final reqId = int.tryParse((widget.order['request_id'] ?? '').toString()) ?? 0;
                  if (reqId > 0) setState(() => _loading = true);
                  if (reqId > 0) unawaited(_loadRequest(reqId));
                },
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 18),
                children: [
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: cs.surface,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: cs.primary.withValues(alpha: 0.14)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (reqName.isNotEmpty) ...[
                          Text(
                            reqName,
                            style: GoogleFonts.montserrat(
                              fontWeight: FontWeight.w900,
                              fontSize: 17,
                              color: cs.primary,
                              height: 1.2,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            id > 0 ? 'Заказ № $id' : 'Заказ',
                            style: GoogleFonts.montserrat(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                              color: cs.onSurface.withValues(alpha: 0.55),
                            ),
                          ),
                        ] else
                          Text(
                            id > 0 ? 'Заказ № $id' : 'Заказ',
                            style: GoogleFonts.montserrat(
                              fontWeight: FontWeight.w900,
                              fontSize: 16,
                              color: cs.onSurface,
                            ),
                          ),
                        const SizedBox(height: 6),
                        _row(context, 'Статус:', statusRu),
                        if (bidIso.isNotEmpty && bidIso != 'null')
                          _row(context, 'Время отклика:', _formatApiDateTimeRu(bidIso)),
                        if (showContactPhones) ...[
                          phoneTappableRow(context, 'Телефон заказчика:', clientPh),
                          if (senderN.isNotEmpty) _row(context, 'Отправитель:', senderN),
                          phoneTappableRow(context, 'Телефон отправителя:', senderPh),
                        ],
                        _row(context, 'Цена:', sum == '—' ? '—' : '$sum смн'),
                        _row(context, 'Расстояние:', dist == '—' ? '—' : '$dist км'),
                        _row(context, 'Вес:', w == '—' ? '—' : '$w тон'),
                        _row(context, 'Погрузка:', loadDate),
                        _row(context, 'Доставка:', deliveryDate),
                        _deliveryAddresses(context),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.primary,
                        side: BorderSide(color: cs.primary.withValues(alpha: 0.35)),
                        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                      ),
                      icon: const Icon(Icons.map_rounded),
                      label: Text(
                        _loading ? 'Загрузка карты...' : 'Маршрут по карте',
                        style: GoogleFonts.montserrat(fontWeight: FontWeight.w800),
                      ),
                      onPressed: (_req == null || _loading) ? null : _openRouteOnMap,
                    ),
                  ),
                  if (_err != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _err!,
                      style: GoogleFonts.montserrat(
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  if (reqDesc.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: cs.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: cs.primary.withValues(alpha: 0.12)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('Заявка', style: GoogleFonts.montserrat(fontWeight: FontWeight.w900, color: cs.onSurface)),
                          const SizedBox(height: 8),
                          Text(
                            reqDesc,
                            style: GoogleFonts.montserrat(
                              fontWeight: FontWeight.w600,
                              color: cs.onSurface.withValues(alpha: 0.78),
                              height: 1.35,
                            ),
                          ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.primary,
                          side: BorderSide(color: cs.primary.withValues(alpha: 0.35)),
                          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                        ),
                        icon: const Icon(Icons.support_agent_rounded),
                        label: Text(
                          'Связаться с администратором',
                          style: GoogleFonts.montserrat(fontWeight: FontWeight.w800),
                        ),
                        onPressed: () => showAdminSupportDialog(context),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _BottomRoleNav(
        items: widget.navItems,
        selectedIndex: widget.selectedTabIndex,
        onTap: widget.onNavTabTap,
      ),
    );
  }
}

class _ClientRequestStatusChipDef {
  const _ClientRequestStatusChipDef(this.apiCode, this.labelRu, this.badgeBg, this.badgeFg);
  final String apiCode;
  final String labelRu;
  final Color badgeBg;
  final Color badgeFg;
}

const List<_ClientRequestStatusChipDef> _kClientMyRequestsChips = [
  _ClientRequestStatusChipDef('draft', 'Черновик', Color(0xFF6B7280), Colors.white),
  _ClientRequestStatusChipDef('pending', 'На проверке', Color(0xFFE8E8E8), Color(0xFF111827)),
  _ClientRequestStatusChipDef('closed', 'Закрыто', Color(0xFFE53935), Colors.white),
  _ClientRequestStatusChipDef('active', 'Опубликован', Color(0xFFFFC107), Color(0xFF3E2723)),
  _ClientRequestStatusChipDef('awaiting', 'Водитель назначен', Color(0xFF64B5F6), Color(0xFF0D47A1)),
  _ClientRequestStatusChipDef('in_transit', 'В пути', Color(0xFF1565C0), Colors.white),
  _ClientRequestStatusChipDef('awaiting_confirmation', 'Ожидает подтверждения', Color(0xFF8B5CF6), Colors.white),
];

class _RequestsContent extends StatefulWidget {
  const _RequestsContent({
    super.key,
    required this.accessToken,
    this.activeOnly = false,
    this.emptyMessage,
    this.showStatusFilters = false,
    this.showStatusFilterHeading = true,
  });
  final String accessToken;
  /// Агар [true] бошад, дар «Главная» танҳо заявкаҳо бо статуси [active].
  final bool activeOnly;
  final String? emptyMessage;
  /// Филтрҳои статус (вкладкаи «Мои заявки»).
  final bool showStatusFilters;
  /// Сарлавҳаи калони матнӣ болои чипҳо; дар вкладка «Мои заявки» ғайрифаъол аст.
  final bool showStatusFilterHeading;

  @override
  State<_RequestsContent> createState() => _RequestsContentState();
}

class _RequestsContentState extends State<_RequestsContent> {
  final _api = const RequestsApi();
  List<Map<String, dynamic>> _items = const [];
  bool _loading = true;
  String? _error;
  String? _selectedStatusFilter;
  bool _hasDraft = false;
  Map<String, dynamic>? _draft;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final cacheKey = 'cache_my_requests_v1:${await _JsonCache._scope()}';
    final cached = await _JsonCache.getList(cacheKey);
    final d = await _LocalPrefs.getRequestDraft();
    _draft = d;
    _hasDraft = d != null && d.isNotEmpty;
    if (mounted && cached != null && cached.isNotEmpty) {
      setState(() {
        _items = cached;
        _loading = false;
        _error = null;
      });
    } else {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final (list, err) = await _api.listMyRequests(accessToken: widget.accessToken);
    if (!mounted) return;
    if (err == null) {
      unawaited(_JsonCache.setJson(cacheKey, list));
    }
    setState(() {
      _loading = false;
      _items = list;
      _error = err;
      _draft = _draft;
      _hasDraft = _draft != null && _draft!.isNotEmpty;
    });
  }

  Future<void> reload() async {
    await _load();
  }

  int _countForChip(String apiCode) {
    if (apiCode == 'draft') return _hasDraft ? 1 : 0;
    return _items.where((r) => normRequestStatusCode(r['status']) == apiCode).length;
  }

  Map<String, dynamic>? _draftAsRequest() {
    final d = _draft;
    if (d == null || d.isEmpty) return null;
    final name = (d['name'] ?? '').toString().trim();
    final origin = (d['origin_address'] ?? '').toString().trim();
    final dest = (d['dest_address'] ?? '').toString().trim();
    final loadDate = (d['load_date'] ?? '').toString().trim();
    final deliveryDate = (d['delivery_date'] ?? '').toString().trim();
    final price = (d['price_tjs'] ?? '').toString().trim();
    final ton = (d['tonnage_t'] ?? '').toString().trim();
    final dist = d['distance_km'];
    return <String, dynamic>{
      'id': 0,
      'status': 'draft',
      'name': name.isEmpty ? 'Черновик' : name,
      'origin_address': origin,
      'dest_address': dest,
      'load_date_display': loadDate,
      'delivery_date_display': deliveryDate,
      'price_tjs': price,
      'tonnage_t': ton,
      'distance_km': dist,
      '_isDraft': true,
    };
  }

  List<Map<String, dynamic>> _baseItems() {
    final draftItem = _draftAsRequest();
    if (widget.activeOnly) {
      final base = _items.where((r) => isRequestActiveOnClientHome(r['status']?.toString())).toList(growable: false);
      return [
        ...?(draftItem == null ? null : [draftItem]),
        ...base,
      ];
    }
    return [
      ...?(draftItem == null ? null : [draftItem]),
      ...List<Map<String, dynamic>>.from(_items),
    ];
  }

  List<Map<String, dynamic>> _displayItems() {
    final base = _baseItems();
    if (!widget.showStatusFilters || _selectedStatusFilter == null) return base;
    return base.where((r) => normRequestStatusCode(r['status']) == _selectedStatusFilter).toList(growable: false);
  }

  Widget _buildStatusFilterHeader(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showStatusFilterHeading) ...[
            Text(
              'Мои заявки',
              textAlign: TextAlign.center,
              style: GoogleFonts.montserrat(
                fontWeight: FontWeight.w800,
                fontSize: 18,
                color: cs.onSurface,
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (_selectedStatusFilter != null) ...[
            TextButton(
              onPressed: () => setState(() => _selectedStatusFilter = null),
              child: Text(
                'Показать все',
                style: GoogleFonts.montserrat(
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                  color: AppColors.primary,
                ),
              ),
            ),
            const SizedBox(height: 4),
          ],
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 2.55,
            ),
            itemCount: _kClientMyRequestsChips.length,
            itemBuilder: (context, index) {
              final def = _kClientMyRequestsChips[index];
              final count = _countForChip(def.apiCode);
              final selected = _selectedStatusFilter == def.apiCode;
              return Material(
                color: isDark ? const Color(0xFF2C2C2E) : cs.surface,
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () {
                    setState(() {
                      _selectedStatusFilter = selected ? null : def.apiCode;
                    });
                  },
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: selected ? AppColors.primary : cs.outline.withValues(alpha: isDark ? 0.35 : 0.22),
                        width: selected ? 2 : 1,
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Row(
                      children: [
                        Container(
                          width: 30,
                          height: 30,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: def.badgeBg,
                            shape: BoxShape.circle,
                          ),
                          child: Text(
                            '$count',
                            style: GoogleFonts.montserrat(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                              color: def.badgeFg,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            def.labelRu,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.montserrat(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: cs.onSurface,
                              height: 1.15,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final displayItems = _displayItems();

    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: GoogleFonts.montserrat(color: cs.onSurface),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Повторить')),
            ],
          ),
        ),
      );
    }

    if (_items.isEmpty) {
      if (widget.showStatusFilters) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStatusFilterHeader(context),
            Expanded(
              child: Center(
                child: Text(
                  widget.emptyMessage ?? 'У вас пока нет заявок',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.montserrat(
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withValues(alpha: 0.65),
                  ),
                ),
              ),
            ),
          ],
        );
      }
      return Center(
        child: Text(
          widget.emptyMessage ?? 'У вас пока нет заявок',
          textAlign: TextAlign.center,
          style: GoogleFonts.montserrat(
            fontWeight: FontWeight.w600,
            color: cs.onSurface.withValues(alpha: 0.65),
          ),
        ),
      );
    }

    if (displayItems.isEmpty) {
      if (widget.activeOnly) {
        return RefreshIndicator(
          onRefresh: _load,
          color: AppColors.primary,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
            children: [
              Center(
                child: Text(
                  widget.emptyMessage ?? 'Нет активных заявок',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.montserrat(
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface.withValues(alpha: 0.65),
                  ),
                ),
              ),
            ],
          ),
        );
      }
      if (widget.showStatusFilters) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildStatusFilterHeader(context),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                color: AppColors.primary,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                  children: [
                    Center(
                      child: Text(
                        'Список заказов пуст',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.montserrat(
                          fontWeight: FontWeight.w600,
                          fontSize: 15,
                          color: cs.onSurface.withValues(alpha: 0.85),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      }
      return RefreshIndicator(
        onRefresh: _load,
        color: AppColors.primary,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
          children: [
            Center(
              child: Text(
                widget.emptyMessage ?? 'Нет открытых заявок',
                textAlign: TextAlign.center,
                style: GoogleFonts.montserrat(
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface.withValues(alpha: 0.65),
                ),
              ),
            ),
          ],
        ),
      );
    }

    final listView = ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 20),
        itemCount: displayItems.length,
        itemBuilder: (context, i) {
          final r = displayItems[i];
          final id = int.tryParse(r['id']?.toString() ?? '') ?? 0;
          final name = (r['name'] ?? '').toString().trim();
          final isDraft = normRequestStatusCode(r['status']) == 'draft' || (r['_isDraft'] == true);
          final title = isDraft
              ? (name.isNotEmpty ? 'Черновик — $name' : 'Черновик')
              : (name.isNotEmpty ? 'Заявка № $id — $name' : 'Заявка № $id');
          final status = _requestStatusRu(r['status']?.toString());
          final routeLine = _rqListRouteCitiesLine(r);
          final loadD = _formatApiDate((r['load_date'] ?? r['load_date_display'])?.toString());
          final delD = _formatApiDate((r['delivery_date'] ?? r['delivery_date_display'])?.toString());
          final price = _fmtRequestListField(r['price_tjs']?.toString());
          final dist = _fmtRequestListField(r['distance_km']?.toString());
          final ton = _fmtRequestListField(r['tonnage_t']?.toString());
          final dateLine = (loadD == '—' && delD == '—')
              ? '—'
              : 'от $loadD до $delD';
          final shareUrl = (r['tracking_share_url'] ?? '').toString().trim();
          final showShareTrack =
              shareUrl.isNotEmpty && showClientTrackingShareForStatus(r['status']?.toString());
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: cs.surface,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: isDraft
                    ? () {
                        final shell = context.findAncestorStateOfType<_LogisticsShellState>();
                        shell?.selectTab(1); // «Добавить»
                      }
                    : (id > 0
                        ? () {
                        final shell = context.findAncestorStateOfType<_LogisticsShellState>();
                        if (shell == null) return;
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (detailCtx) => _MyRequestDetailPage(
                              accessToken: widget.accessToken,
                              requestId: id,
                              previewTitle: title,
                              role: AppRole.client,
                              navItems: shell.navItems,
                              selectedTabIndex: shell.currentNavIndex,
                              onNavTabTap: (i) {
                                Navigator.of(detailCtx).pop();
                                shell.selectTab(i);
                              },
                              onOpenPush: () {
                                Navigator.of(detailCtx).push(
                                  MaterialPageRoute<void>(
                                    builder: (pushCtx) => PushNotificationsPage(
                                      accessToken: widget.accessToken,
                                      navItems: shell.navItems,
                                      selectedTabIndex: shell.currentNavIndex,
                                      onTabSelected: (i) {
                                        Navigator.of(pushCtx).pop();
                                        Navigator.of(detailCtx).pop();
                                        shell.selectTab(i);
                                      },
                                      onRefresh: () {
                                        ScaffoldMessenger.of(pushCtx).showSnackBar(
                                          const SnackBar(content: Text('Уведомления обновлены')),
                                        );
                                      },
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        );
                      }
                        : null),
                child: Ink(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: cs.primary.withValues(alpha: 0.16)),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Text(
                                title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.montserrat(
                                  fontWeight: FontWeight.w900,
                                  fontSize: 15,
                                  color: cs.onSurface,
                                  height: 1.25,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: cs.onSurface.withValues(alpha: 0.40),
                              size: 26,
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        requestOrderListLrRow(context, 'Маршрут:', routeLine, maxLines: 8),
                        requestOrderListLrRow(context, 'Дата:', dateLine),
                        requestOrderListLrRow(
                          context,
                          'Цена:',
                          price == '—' ? '—' : '$price смн',
                        ),
                        requestOrderListLrRow(
                          context,
                          'Расстояние:',
                          dist == '—' ? '—' : '$dist км',
                        ),
                        requestOrderListLrRow(
                          context,
                          'Общий вес:',
                          ton == '—' ? '—' : '$ton тон',
                        ),
                        if (showShareTrack) ...[
                          const SizedBox(height: 3),
                          Text(
                            'Поделиться ссылкой',
                            style: GoogleFonts.montserrat(
                              fontSize: 10.5,
                              fontWeight: FontWeight.w800,
                              color: cs.onSurface.withValues(alpha: 0.5),
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              Tooltip(
                                message: 'WhatsApp',
                                child: Material(
                                  color: const Color(0xFF25D366),
                                  shape: const CircleBorder(),
                                  child: InkWell(
                                    customBorder: const CircleBorder(),
                                    onTap: () => unawaited(shareTrackingLinkWhatsApp(shareUrl)),
                                    child: const Padding(
                                      padding: EdgeInsets.all(6),
                                      child: Icon(Icons.chat_rounded, color: Colors.white, size: 17),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Tooltip(
                                message: 'Telegram',
                                child: Material(
                                  color: const Color(0xFF229ED9),
                                  shape: const CircleBorder(),
                                  child: InkWell(
                                    customBorder: const CircleBorder(),
                                    onTap: () => unawaited(shareTrackingLinkTelegram(shareUrl)),
                                    child: const Padding(
                                      padding: EdgeInsets.all(6),
                                      child: Icon(Icons.send_rounded, color: Colors.white, size: 16),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Tooltip(
                                message: 'Другие приложения',
                                child: Material(
                                  color: AppColors.primary,
                                  shape: const CircleBorder(),
                                  child: InkWell(
                                    customBorder: const CircleBorder(),
                                    onTap: () async {
                                      await Share.share(shareUrl, subject: 'Somon — отслеживание');
                                    },
                                    child: const Padding(
                                      padding: EdgeInsets.all(6),
                                      child: Icon(Icons.share_rounded, color: Colors.white, size: 17),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                        SizedBox(height: showShareTrack ? 4 : 8),
                        Row(
                          children: [
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: cs.primary.withValues(
                                  alpha: Theme.of(context).brightness == Brightness.dark ? 0.22 : 0.12,
                                ),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: cs.primary.withValues(
                                    alpha: Theme.of(context).brightness == Brightness.dark ? 0.55 : 0.30,
                                  ),
                                ),
                              ),
                              child: Text(
                                status,
                                style: GoogleFonts.montserrat(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: cs.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
    );

    if (widget.showStatusFilters) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildStatusFilterHeader(context),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              color: AppColors.primary,
              child: listView,
            ),
          ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: AppColors.primary,
      child: listView,
    );
  }
}

class _MyRequestDetailPage extends StatefulWidget {
  const _MyRequestDetailPage({
    required this.accessToken,
    required this.requestId,
    required this.previewTitle,
    required this.role,
    required this.navItems,
    required this.selectedTabIndex,
    required this.onNavTabTap,
    required this.onOpenPush,
  });
  final String accessToken;
  final int requestId;
  final String previewTitle;
  final AppRole role;
  final List<NavItem> navItems;
  final int selectedTabIndex;
  final ValueChanged<int> onNavTabTap;
  final VoidCallback onOpenPush;

  @override
  State<_MyRequestDetailPage> createState() => _MyRequestDetailPageState();
}

class _MyRequestDetailPageState extends State<_MyRequestDetailPage> {
  final _api = const RequestsApi();
  final _profileApi = const ProfileApi();
  final _bidPrice = TextEditingController();
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;
  bool _closing = false;
  bool _responding = false;
  String _driverStatus = '';
  double _driverBalance = 0;

  @override
  void initState() {
    super.initState();
    _bidPrice.addListener(() {
      if (!mounted) return;
      // Rebuild to update commission preview.
      setState(() {});
    });
    _load();
  }

  @override
  void dispose() {
    _bidPrice.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final (map, err) = await _api.getRequestDetail(
      accessToken: widget.accessToken,
      id: widget.requestId,
    );
    if (widget.role == AppRole.driver) {
      try {
        final (me, _) = await _profileApi.fetchMeProfile(accessToken: widget.accessToken);
        final status = (me?['status'] ?? '').toString();
        final balRaw = me?['balance'];
        final bal = balRaw == null ? 0.0 : double.tryParse(balRaw.toString().replaceAll(',', '.')) ?? 0.0;
        if (mounted) {
          _driverStatus = status;
          _driverBalance = bal;
        }
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      _data = map;
      _error = err;
    });
  }

  Future<void> _openRouteOnMap(
    List<Map<String, dynamic>> origins,
    List<Map<String, dynamic>> dests,
    double? fallbackDistanceKm,
  ) async {
    final stops = _requestStopsToLatLngs(origins, dests);
    if (stops.length < 2) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Нет координат точек на карте. Заявка создана без привязки к карте.'),
        ),
      );
      return;
    }
    final sc = (_data?['status'] ?? '').toString();
    RouteMapTrackingMode tm = RouteMapTrackingMode.none;
    if (sc == 'awaiting' || sc == 'in_transit') {
      tm = widget.role == AppRole.client ? RouteMapTrackingMode.viewer : RouteMapTrackingMode.driver;
    }
    final shareU = (_data?['tracking_share_url'] ?? '').toString().trim();
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => _RequestDetailRouteMapPage(
          accessToken: widget.accessToken,
          stops: stops,
          fallbackDistanceKm: fallbackDistanceKm,
          requestId: widget.requestId,
          trackingMode: tm,
          shareUrl: shareU.isEmpty ? null : shareU,
        ),
      ),
    );
  }

  Future<void> _confirmCloseOrder() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Закрыть заявку?',
          style: GoogleFonts.montserrat(fontWeight: FontWeight.w800),
        ),
        content: Text(
          'Заказ будет завершён. Продолжить?',
          style: GoogleFonts.montserrat(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Закрыть'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _closing = true);
    final (success, msg) = await const RequestsApi().clientCloseOrder(
      accessToken: widget.accessToken,
      requestId: widget.requestId,
    );
    if (!mounted) return;
    setState(() => _closing = false);
    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Заявка закрыта')),
      );
      await _load();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg ?? 'Не удалось закрыть')),
      );
    }
  }

  Widget _sectionTitle(IconData icon, String title) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: GoogleFonts.montserrat(
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _block({required List<Widget> children}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.primary.withValues(alpha: 0.16)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }

  /// Чап — лейбл (мисли рӯйхати «Мои заявки»), рост — қимат.
  Widget _detailRow(
    String label,
    String value, {
    int maxLines = 4,
    TextStyle? valueStyle,
    bool valueMultiline = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final v = value.trim().isEmpty ? '—' : value.trim();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.montserrat(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              v,
              textAlign: TextAlign.right,
              maxLines: valueMultiline ? null : maxLines,
              overflow: valueMultiline ? TextOverflow.visible : TextOverflow.ellipsis,
              style: valueStyle ??
                  GoogleFonts.montserrat(
                    fontSize: 12.6,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                    height: 1.3,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatStopLine(Map<String, dynamic> s) {
    final addr = (s['address'] ?? '').toString();
    final wh = (s['warehouse'] ?? '').toString().trim();
    final city = (s['city'] ?? '').toString().trim();
    return [
      if (city.isNotEmpty) city,
      if (addr.isNotEmpty) addr,
      if (wh.isNotEmpty) 'Склад: $wh',
    ].join(' · ');
  }

  Widget _stopLines(String heading, IconData icon, List<Map<String, dynamic>> stops) {
    if (stops.isEmpty) {
      return _block(
        children: [
          _sectionTitle(icon, heading),
          _detailRow('Адрес', '—'),
        ],
      );
    }
    return _block(
      children: [
        _sectionTitle(icon, heading),
        ...stops.asMap().entries.map((e) {
          final idx = e.key + 1;
          final line = _formatStopLine(e.value);
          return _detailRow(
            'Пункт $idx',
            line.isEmpty ? '—' : line,
            maxLines: 8,
            valueMultiline: true,
          );
        }),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
              child: _TopBar(
                onBackTap: () => Navigator.of(context).pop(),
                onNotificationsTap: widget.onOpenPush,
                onRefreshTap: () => _load(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                widget.previewTitle,
                style: GoogleFonts.montserrat(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null && _data == null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(_error!, textAlign: TextAlign.center),
                                const SizedBox(height: 16),
                                FilledButton(onPressed: _load, child: const Text('Повторить')),
                              ],
                            ),
                          ),
                        )
                      : _buildBody(_data ?? {}),
            ),
          ],
        ),
      ),
      bottomNavigationBar: _BottomRoleNav(
        items: widget.navItems,
        selectedIndex: widget.selectedTabIndex,
        onTap: widget.onNavTabTap,
      ),
    );
  }

  Widget _buildBody(Map<String, dynamic> r) {
    final name = (r['name'] ?? '').toString().trim();
    final transport = (r['transport'] ?? '').toString();
    final origins = _parseStopList(r['origin_stops']);
    final dests = _parseStopList(r['destination_stops']);
    final price = r['price_tjs']?.toString() ?? '';
    final ton = r['tonnage_t']?.toString() ?? '';
    final dist = r['distance_km']?.toString() ?? '';
    final loadD = _formatApiDate(r['load_date']?.toString());
    final delD = _formatApiDate(r['delivery_date']?.toString());
    final desc = (r['description'] ?? '').toString().trim();
    final senderN = (r['sender_name'] ?? '').toString().trim();
    final senderP = (r['sender_phone'] ?? '').toString().trim();
    final recvN = (r['receiver_name'] ?? '').toString().trim();
    final recvP = (r['receiver_phone'] ?? '').toString().trim();
    final statusCode = (r['status'] ?? '').toString();
    final status = _requestStatusRu(statusCode);
    final showContactPhones = _showPhoneContactsForStatus(statusCode);
    final acceptedBidAt = (r['accepted_bid_at'] ?? '').toString().trim();
    final driverPhone = (r['driver_phone'] ?? '').toString().trim();
    final clientPhone = (r['client_phone'] ?? '').toString().trim();
    final minPrice = double.tryParse((r['price_tjs'] ?? '').toString().replaceAll(',', '.')) ?? 0.0;
    final commissionPctRaw = r['commission_percentage'];
    final commissionPct = commissionPctRaw == null
        ? 5.0
        : (double.tryParse(commissionPctRaw.toString().replaceAll(',', '.')) ?? 5.0);
    final myBid = r['my_bid'];
    final hasMyBid = myBid is Map && (myBid['id'] != null);
    final myBidStatus = hasMyBid ? (myBid['status'] ?? '').toString().toLowerCase() : '';
    final distKm = (dist.isNotEmpty && dist != 'null') ? double.tryParse(dist.replaceAll(',', '.')) : null;

    return RefreshIndicator(
      onRefresh: _load,
      color: AppColors.primary,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 24),
        children: [
          _block(
            children: [
              _sectionTitle(Icons.flag_rounded, 'Статус'),
              _detailRow(
                'Состояние',
                status,
                valueStyle: GoogleFonts.montserrat(
                  fontWeight: FontWeight.w800,
                  fontSize: 12.6,
                  color: AppColors.primary,
                  height: 1.3,
                ),
              ),
              if (acceptedBidAt.isNotEmpty && acceptedBidAt != 'null')
                _detailRow('Время отклика:', _formatApiDateTimeRu(acceptedBidAt)),
              if (showContactPhones) ...[
                if (widget.role == AppRole.client)
                  phoneTappableRow(context, 'Водитель:', driverPhone),
                if (widget.role == AppRole.driver)
                  phoneTappableRow(context, 'Заказчик:', clientPhone),
              ],
              if (statusCode == 'in_transit') ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _closing ? null : _confirmCloseOrder,
                    child: _closing
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : Text(
                            'Закрыть заявку',
                            style: GoogleFonts.montserrat(fontWeight: FontWeight.w700),
                          ),
                  ),
                ),
              ],
            ],
          ),
          _block(
            children: [
              _sectionTitle(Icons.title_rounded, 'Название и транспорт'),
              _detailRow('Название', name.isNotEmpty ? name : '—', maxLines: 3, valueMultiline: true),
              _detailRow('Транспорт', transport.isNotEmpty ? transport : '—', maxLines: 3, valueMultiline: true),
            ],
          ),
          _stopLines('Откуда', Icons.north_east_rounded, origins),
          _stopLines('Куда', Icons.south_west_rounded, dests),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: Color(0x55007D72)),
                  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                ),
                icon: const Icon(Icons.map_rounded),
                label: Text(
                  'Маршрут по карте',
                  style: GoogleFonts.montserrat(fontWeight: FontWeight.w700),
                ),
                onPressed: () => _openRouteOnMap(origins, dests, distKm),
              ),
            ),
          ),
          _block(
            children: [
              _sectionTitle(Icons.route_rounded, 'Маршрут и груз'),
              _detailRow('Расстояние:', dist.isNotEmpty && dist != 'null' ? '$dist км' : '—'),
              _detailRow('Цена:', price.isNotEmpty && price != 'null' ? '$price смн' : '—'),
              _detailRow('Общий вес:', ton.isNotEmpty && ton != 'null' ? '$ton тон' : '—'),
            ],
          ),
          _block(
            children: [
              _sectionTitle(Icons.date_range_rounded, 'Даты'),
              _detailRow('Дата погрузки:', loadD),
              _detailRow('Срок доставки:', delD),
            ],
          ),
          if (senderN.isNotEmpty || senderP.isNotEmpty)
            _block(
              children: [
                _sectionTitle(Icons.person_outline_rounded, 'Данные отправителя'),
                _detailRow('Имя:', senderN.isNotEmpty ? senderN : '—'),
                if (showContactPhones && senderP.isNotEmpty)
                  phoneTappableRow(context, 'Телефон:', senderP)
                else
                  _detailRow('Телефон:', senderP.isNotEmpty ? senderP : '—'),
              ],
            ),
          if (recvN.isNotEmpty || recvP.isNotEmpty)
            _block(
              children: [
                _sectionTitle(Icons.person_pin_outlined, 'Данные получателя'),
                _detailRow('Имя:', recvN.isNotEmpty ? recvN : '—'),
                if (showContactPhones && recvP.isNotEmpty)
                  phoneTappableRow(context, 'Телефон:', recvP)
                else
                  _detailRow('Телефон:', recvP.isNotEmpty ? recvP : '—'),
              ],
            ),
          _block(
            children: [
              _sectionTitle(Icons.description_rounded, 'Описание'),
              _detailRow('Текст:', desc.isNotEmpty ? desc : '—', maxLines: 80, valueMultiline: true),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.primary,
                  side: const BorderSide(color: Color(0x55007D72)),
                  padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
                ),
                icon: const Icon(Icons.support_agent_rounded),
                label: Text(
                  'Связаться с администратором',
                  style: GoogleFonts.montserrat(fontWeight: FontWeight.w700),
                ),
                onPressed: () => showAdminSupportDialog(context),
              ),
            ),
          ),
          if (widget.role == AppRole.driver) ...[
            _block(
              children: [
                _sectionTitle(Icons.payments_outlined, 'Отклик'),
                if (hasMyBid) ...[
                  Builder(
                    builder: (context) {
                      final cs = Theme.of(context).colorScheme;
                      final pending = myBidStatus == 'pending';
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: pending
                              ? cs.secondary.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.20 : 0.12)
                              : cs.primary.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.20 : 0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: pending
                                ? cs.secondary.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.55 : 0.30)
                                : cs.primary.withValues(alpha: Theme.of(context).brightness == Brightness.dark ? 0.55 : 0.30),
                          ),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.2,
                                color: pending ? cs.secondary : cs.primary,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                pending
                                    ? 'Вы уже откликнулись. Ожидается подтверждение заказчика.'
                                    : 'Вы уже откликнулись на этот заказ.',
                                style: GoogleFonts.montserrat(
                                  fontWeight: FontWeight.w800,
                                  color: cs.onSurface.withValues(alpha: 0.86),
                                  height: 1.2,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                ] else ...[
                  Text(
                    'Укажите цену, за которую вы готовы выполнить заказ',
                    style: GoogleFonts.montserrat(
                      fontWeight: FontWeight.w800,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _bidPrice,
                    keyboardType: TextInputType.number,
                    maxLength: 9,
                    buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(9),
                    ],
                    decoration: () {
                      final raw = _bidPrice.text.trim();
                      final v = raw.isEmpty ? null : double.tryParse(raw);
                      final tooLow = (v != null && minPrice > 0 && v < minPrice);
                      return InputDecoration(
                        labelText: 'Сумма',
                        hintText: minPrice > 0 ? '${minPrice.toStringAsFixed(0)} смн' : null,
                        isDense: true,
                        errorText: tooLow ? 'Цена не может быть меньше минимальной' : null,
                      );
                    }(),
                  ),
                  const SizedBox(height: 10),
                  Builder(
                    builder: (context) {
                      final cs = Theme.of(context).colorScheme;
                      final priceNum = double.tryParse(_bidPrice.text.trim());
                      final commission = priceNum == null ? null : (priceNum * commissionPct / 100.0);
                      final tooLow = (priceNum != null && minPrice > 0 && priceNum < minPrice);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(
                            commission == null
                                ? 'Комиссия за заказ: —'
                                : 'Комиссия за заказ: ${commission.toStringAsFixed(2)} смн',
                            style: GoogleFonts.montserrat(
                              fontWeight: FontWeight.w700,
                              color: cs.onSurface.withValues(alpha: 0.75),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Ваш баланс: ${_driverBalance.toStringAsFixed(2)} смн',
                            style: GoogleFonts.montserrat(
                              fontWeight: FontWeight.w700,
                              color: cs.onSurface.withValues(alpha: 0.75),
                            ),
                          ),
                          if (tooLow) ...[
                            const SizedBox(height: 6),
                            Text(
                              'Введите цену не меньше минимальной',
                              style: GoogleFonts.montserrat(
                                fontWeight: FontWeight.w700,
                                color: Colors.red.shade700,
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: (() {
                      final raw = _bidPrice.text.trim();
                      final priceNum = raw.isEmpty ? null : double.tryParse(raw);
                      final invalid = priceNum == null ||
                          priceNum <= 0 ||
                          (minPrice > 0 && priceNum < minPrice);
                      if (hasMyBid || _responding || invalid) return null;
                      return true;
                    }() == null)
                        ? null
                        : () async {
                            final status = _driverStatus.toLowerCase();
                            if (status != 'active') {
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Заполните документы и пройдите верификацию')),
                              );
                              Navigator.of(context).pop();
                              widget.onNavTabTap(2);
                              return;
                            }
                            final priceNum = double.tryParse(_bidPrice.text.trim());
                            if (priceNum == null || priceNum <= 0) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Введите цену')),
                              );
                              return;
                            }
                            if (minPrice > 0 && priceNum < minPrice) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('Цена не может быть меньше ${minPrice.toStringAsFixed(0)} смн')),
                              );
                              return;
                            }
                            final commission = priceNum * commissionPct / 100.0;
                            if (_driverBalance < commission) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Баланс недостаточен. Пополните баланс и попробуйте снова.')),
                              );
                              return;
                            }
                            setState(() => _responding = true);
                            final (ok, msg) = await _api.respondToRequest(
                              accessToken: widget.accessToken,
                              requestId: widget.requestId,
                              price: priceNum,
                            );
                            if (!mounted) return;
                            setState(() => _responding = false);
                            if (!ok) {
                              final m = msg ?? 'Не удалось отправить отклик';
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
                              if (m.toLowerCase().contains('верификац')) {
                                Navigator.of(context).pop();
                                widget.onNavTabTap(2);
                              }
                              return;
                            }
                            if (!mounted) return;
                            unawaited(
                              showDialog<void>(
                                context: context,
                                barrierDismissible: false,
                                builder: (ctx) {
                                  final cs = Theme.of(ctx).colorScheme;
                                  return AlertDialog(
                                    backgroundColor: cs.surface,
                                    title: Text(
                                      'Готово',
                                      style: GoogleFonts.montserrat(
                                        fontWeight: FontWeight.w900,
                                        color: cs.onSurface,
                                      ),
                                    ),
                                    content: Text(
                                      'Ожидает подтверждение заказчика',
                                      style: GoogleFonts.montserrat(
                                        fontWeight: FontWeight.w700,
                                        color: cs.onSurface.withValues(alpha: 0.82),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            );
                            await Future<void>.delayed(const Duration(seconds: 5));
                            if (!mounted) return;
                            // Close popup (if still open) and go to "Мои заказы"
                            Navigator.of(context, rootNavigator: true).pop();
                            widget.onNavTabTap(1);
                          },
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      textStyle: GoogleFonts.montserrat(fontWeight: FontWeight.w900),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    child: _responding
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : Text(hasMyBid ? 'ВЫ УЖЕ ОТКЛИКНУЛИСЬ' : 'ОТКЛИКНУТЬСЯ НА ЗАКАЗ'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _AddRequestContent extends StatefulWidget {
  const _AddRequestContent({
    required this.accessToken,
    this.onNavigateMyRequests,
  });
  final String accessToken;
  final VoidCallback? onNavigateMyRequests;

  @override
  State<_AddRequestContent> createState() => _AddRequestContentState();
}

class _AddRequestContentState extends State<_AddRequestContent> {
  final _api = const RequestsApi();
  final _name = TextEditingController();
  final _originAddress = TextEditingController();
  final _originWarehouse = TextEditingController();
  final _originAddress2 = TextEditingController();
  final _originWarehouse2 = TextEditingController();
  final _destAddress = TextEditingController();
  final _destWarehouse = TextEditingController();
  final _destAddress2 = TextEditingController();
  final _destWarehouse2 = TextEditingController();
  final _senderName = TextEditingController();
  final _senderPhone = TextEditingController();
  final _receiverName = TextEditingController();
  final _receiverPhone = TextEditingController();
  final _price = TextEditingController();
  final _tonnage = TextEditingController();
  final _description = TextEditingController();
  final _loadDateText = TextEditingController();
  final _deliveryDateText = TextEditingController();
  Timer? _draftDebounce;
  bool _draftLoaded = false;

  DateTime? _loadDate;
  DateTime? _deliveryDate;

  List<TransportCategoryDto> _transports = const [];
  int? _transportId;
  bool _loadingTransports = true;
  bool _submitting = false;

  double? _originLat;
  double? _originLon;
  double? _originLat2;
  double? _originLon2;
  double? _destLat;
  double? _destLon;

  double? _roundCoord(double? v, {int places = 9}) {
    if (v == null) return null;
    try {
      return double.parse(v.toStringAsFixed(places));
    } catch (_) {
      return v;
    }
  }
  double? _destLat2;
  double? _destLon2;
  double? _distanceKm;
  List<LatLng> _routePreviewPoints = const [];
  List<LatLng> _routeStops = const [];

  Timer? _originDebounce;
  Timer? _destDebounce;
  Timer? _origin2Debounce;
  Timer? _dest2Debounce;
  List<OsmHit> _originSuggestions = const [];
  List<OsmHit> _destSuggestions = const [];
  List<OsmHit> _originSuggestions2 = const [];
  List<OsmHit> _destSuggestions2 = const [];
  bool _originSearching = false;
  bool _destSearching = false;
  bool _originSearching2 = false;
  bool _destSearching2 = false;

  bool _showOriginAddress2 = false;
  bool _showOriginSenderData = false;
  bool _showDestAddress2 = false;
  bool _showDestReceiverData = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadDraftIfAny());
    _loadTransports();
    for (final c in [
      _name,
      _originAddress,
      _originWarehouse,
      _originAddress2,
      _originWarehouse2,
      _destAddress,
      _destWarehouse,
      _destAddress2,
      _destWarehouse2,
      _senderName,
      _senderPhone,
      _receiverName,
      _receiverPhone,
      _price,
      _tonnage,
      _description,
    ]) {
      c.addListener(_scheduleDraftSave);
    }
  }

  @override
  void dispose() {
    _originDebounce?.cancel();
    _destDebounce?.cancel();
    _origin2Debounce?.cancel();
    _dest2Debounce?.cancel();
    _draftDebounce?.cancel();
    for (final c in [
      _name,
      _originAddress,
      _originWarehouse,
      _originAddress2,
      _originWarehouse2,
      _destAddress,
      _destWarehouse,
      _destAddress2,
      _destWarehouse2,
      _senderName,
      _senderPhone,
      _receiverName,
      _receiverPhone,
      _price,
      _tonnage,
      _description,
    ]) {
      c.removeListener(_scheduleDraftSave);
    }
    _name.dispose();
    _originAddress.dispose();
    _originWarehouse.dispose();
    _originAddress2.dispose();
    _originWarehouse2.dispose();
    _destAddress.dispose();
    _destWarehouse.dispose();
    _destAddress2.dispose();
    _destWarehouse2.dispose();
    _senderName.dispose();
    _senderPhone.dispose();
    _receiverName.dispose();
    _receiverPhone.dispose();
    _price.dispose();
    _tonnage.dispose();
    _description.dispose();
    _loadDateText.dispose();
    _deliveryDateText.dispose();
    super.dispose();
  }

  Future<void> _loadDraftIfAny() async {
    if (_draftLoaded) return;
    _draftLoaded = true;
    final d = await _LocalPrefs.getRequestDraft();
    if (!mounted || d == null) return;
    try {
      _name.text = (d['name'] ?? '').toString();
      _originAddress.text = (d['origin_address'] ?? '').toString();
      _originWarehouse.text = (d['origin_warehouse'] ?? '').toString();
      _originAddress2.text = (d['origin_address2'] ?? '').toString();
      _originWarehouse2.text = (d['origin_warehouse2'] ?? '').toString();
      _destAddress.text = (d['dest_address'] ?? '').toString();
      _destWarehouse.text = (d['dest_warehouse'] ?? '').toString();
      _destAddress2.text = (d['dest_address2'] ?? '').toString();
      _destWarehouse2.text = (d['dest_warehouse2'] ?? '').toString();
      _senderName.text = (d['sender_name'] ?? '').toString();
      _senderPhone.text = (d['sender_phone'] ?? '').toString();
      _receiverName.text = (d['receiver_name'] ?? '').toString();
      _receiverPhone.text = (d['receiver_phone'] ?? '').toString();
      _price.text = (d['price_tjs'] ?? '').toString();
      _tonnage.text = (d['tonnage_t'] ?? '').toString();
      _description.text = (d['description'] ?? '').toString();

      _transportId = int.tryParse((d['transport'] ?? '').toString());
      _originLat = (d['origin_lat'] as num?)?.toDouble();
      _originLon = (d['origin_lng'] as num?)?.toDouble();
      _originLat2 = (d['origin_lat2'] as num?)?.toDouble();
      _originLon2 = (d['origin_lng2'] as num?)?.toDouble();
      _destLat = (d['dest_lat'] as num?)?.toDouble();
      _destLon = (d['dest_lng'] as num?)?.toDouble();
      _destLat2 = (d['dest_lat2'] as num?)?.toDouble();
      _destLon2 = (d['dest_lng2'] as num?)?.toDouble();

      _showOriginAddress2 = _originAddress2.text.trim().isNotEmpty;
      _showDestAddress2 = _destAddress2.text.trim().isNotEmpty;
      _showOriginSenderData = (_senderName.text.trim().isNotEmpty || _senderPhone.text.trim().isNotEmpty);
      _showDestReceiverData = (_receiverName.text.trim().isNotEmpty || _receiverPhone.text.trim().isNotEmpty);

      final dist = (d['distance_km'] as num?)?.toDouble();
      if (dist != null) _distanceKm = double.parse(dist.toStringAsFixed(2));
    } catch (_) {}
    setState(() {});
  }

  void _scheduleDraftSave() {
    _draftDebounce?.cancel();
    _draftDebounce = Timer(const Duration(milliseconds: 450), () {
      unawaited(_saveDraftNow());
    });
  }

  Future<void> _saveDraftNow() async {
    final hasAny = [
      _name.text,
      _originAddress.text,
      _destAddress.text,
      _price.text,
      _tonnage.text,
      _description.text,
      _senderName.text,
      _receiverName.text,
    ].any((s) => s.trim().isNotEmpty);
    if (!hasAny) return;
    final draft = <String, dynamic>{
      'name': _name.text.trim(),
      'transport': _transportId,
      'load_date': _loadDate == null ? null : DateFormat('yyyy-MM-dd').format(_loadDate!),
      'delivery_date': _deliveryDate == null ? null : DateFormat('yyyy-MM-dd').format(_deliveryDate!),
      'origin_address': _originAddress.text.trim(),
      'origin_warehouse': _originWarehouse.text.trim(),
      'origin_address2': _originAddress2.text.trim(),
      'origin_warehouse2': _originWarehouse2.text.trim(),
      'dest_address': _destAddress.text.trim(),
      'dest_warehouse': _destWarehouse.text.trim(),
      'dest_address2': _destAddress2.text.trim(),
      'dest_warehouse2': _destWarehouse2.text.trim(),
      'origin_lat': _originLat,
      'origin_lng': _originLon,
      'origin_lat2': _originLat2,
      'origin_lng2': _originLon2,
      'dest_lat': _destLat,
      'dest_lng': _destLon,
      'dest_lat2': _destLat2,
      'dest_lng2': _destLon2,
      'price_tjs': _price.text.trim(),
      'tonnage_t': _tonnage.text.trim(),
      'distance_km': _distanceKm,
      'description': _description.text.trim(),
      'sender_name': _senderName.text.trim(),
      'sender_phone': _senderPhone.text.trim(),
      'receiver_name': _receiverName.text.trim(),
      'receiver_phone': _receiverPhone.text.trim(),
      'updated_at': DateTime.now().toIso8601String(),
    };
    await _LocalPrefs.setRequestDraft(draft);
  }

  Future<void> _pickDate({
    required bool isLoadDate,
  }) async {
    final now = DateTime.now();
    final initial = (isLoadDate ? _loadDate : _deliveryDate) ?? now;
    final picked = await showDatePicker(
      context: context,
      locale: const Locale('ru', 'RU'),
      initialDate: initial,
      firstDate: DateTime(now.year - 1, 1, 1),
      lastDate: DateTime(now.year + 3, 12, 31),
      builder: (context, child) {
        final base = Theme.of(context);
        return Theme(
          data: base.copyWith(
            colorScheme: base.colorScheme.copyWith(primary: AppColors.primary),
            datePickerTheme: const DatePickerThemeData(
              headerBackgroundColor: AppColors.primary,
              headerForegroundColor: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked == null) return;
    final fmt = DateFormat('dd.MM.yyyy', 'ru_RU');
    setState(() {
      if (isLoadDate) {
        _loadDate = picked;
        _loadDateText.text = fmt.format(picked);
        if (_deliveryDate != null && _deliveryDate!.isBefore(picked)) {
          _deliveryDate = null;
          _deliveryDateText.clear();
        }
      } else {
        _deliveryDate = picked;
        _deliveryDateText.text = fmt.format(picked);
      }
    });
  }

  Future<void> _loadTransports() async {
    final items = await _api.getTransports();
    if (!mounted) return;
    setState(() {
      _transports = items;
      _transportId = items.isNotEmpty ? items.first.id : null;
      _loadingTransports = false;
    });
  }

  Future<void> _recalcDistance() async {
    if (_originLat == null || _originLon == null || _destLat == null || _destLon == null) {
      setState(() => _distanceKm = null);
      return;
    }

    final stops = <LatLng>[
      LatLng(_originLat!, _originLon!),
      if (_showOriginAddress2 && _originLat2 != null && _originLon2 != null)
        LatLng(_originLat2!, _originLon2!),
      LatLng(_destLat!, _destLon!),
      if (_showDestAddress2 && _destLat2 != null && _destLon2 != null) LatLng(_destLat2!, _destLon2!),
    ];

    final (roadKm, routePoints) = await _api.roadDistanceWithRoute(
      accessToken: widget.accessToken,
      points: stops,
    );

    final km = roadKm ?? _haversineKm(stops.first.latitude, stops.first.longitude, stops.last.latitude, stops.last.longitude);
    if (!mounted) return;
    setState(() {
      _distanceKm = double.parse(km.toStringAsFixed(2));
      _routePreviewPoints = routePoints;
      _routeStops = stops;
    });
  }

  double _haversineKm(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371.0;
    final dLat = _degToRad(lat2 - lat1);
    final dLon = _degToRad(lon2 - lon1);
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_degToRad(lat1)) * math.cos(_degToRad(lat2)) * math.sin(dLon / 2) * math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return r * c;
  }

  double _degToRad(double d) => d * math.pi / 180.0;

  void _onOriginChanged(String value) {
    _originDebounce?.cancel();
    setState(() {
      _originSearching = value.trim().length >= 3;
    });
    _originDebounce = Timer(const Duration(milliseconds: 280), () async {
      final q = value.trim();
      if (q.length < 3) {
        if (!mounted) return;
        setState(() {
          _originSuggestions = const [];
          _originSearching = false;
        });
        return;
      }
      final hits = await _api.osmSearch(accessToken: widget.accessToken, query: q);
      if (!mounted) return;
      setState(() {
        _originSuggestions = hits;
        _originSearching = false;
      });
    });
  }

  void _onDestChanged(String value) {
    _destDebounce?.cancel();
    setState(() {
      _destSearching = value.trim().length >= 3;
    });
    _destDebounce = Timer(const Duration(milliseconds: 280), () async {
      final q = value.trim();
      if (q.length < 3) {
        if (!mounted) return;
        setState(() {
          _destSuggestions = const [];
          _destSearching = false;
        });
        return;
      }
      final hits = await _api.osmSearch(accessToken: widget.accessToken, query: q);
      if (!mounted) return;
      setState(() {
        _destSuggestions = hits;
        _destSearching = false;
      });
    });
  }

  void _onOrigin2Changed(String value) {
    _origin2Debounce?.cancel();
    setState(() {
      _originSearching2 = value.trim().length >= 3;
    });
    _origin2Debounce = Timer(const Duration(milliseconds: 280), () async {
      final q = value.trim();
      if (q.length < 3) {
        if (!mounted) return;
        setState(() {
          _originSuggestions2 = const [];
          _originSearching2 = false;
        });
        return;
      }
      final hits = await _api.osmSearch(accessToken: widget.accessToken, query: q);
      if (!mounted) return;
      setState(() {
        _originSuggestions2 = hits;
        _originSearching2 = false;
      });
    });
  }

  void _onDest2Changed(String value) {
    _dest2Debounce?.cancel();
    setState(() {
      _destSearching2 = value.trim().length >= 3;
    });
    _dest2Debounce = Timer(const Duration(milliseconds: 280), () async {
      final q = value.trim();
      if (q.length < 3) {
        if (!mounted) return;
        setState(() {
          _destSuggestions2 = const [];
          _destSearching2 = false;
        });
        return;
      }
      final hits = await _api.osmSearch(accessToken: widget.accessToken, query: q);
      if (!mounted) return;
      setState(() {
        _destSuggestions2 = hits;
        _destSearching2 = false;
      });
    });
  }

  Future<void> _pickFromMap({required bool isOrigin}) async {
    final initial = isOrigin
        ? (_originLat != null && _originLon != null ? LatLng(_originLat!, _originLon!) : const LatLng(38.5598, 68.7870))
        : (_destLat != null && _destLon != null ? LatLng(_destLat!, _destLon!) : const LatLng(38.5598, 68.7870));
    final picked = await Navigator.of(context).push<_MapPickResult>(
      MaterialPageRoute(
        builder: (_) => _MapPickerPage(accessToken: widget.accessToken, initial: initial),
      ),
    );
    if (picked == null) return;
    setState(() {
      if (isOrigin) {
        _originLat = picked.lat;
        _originLon = picked.lon;
        _originAddress.text = picked.address;
        _originSuggestions = const [];
      } else {
        _destLat = picked.lat;
        _destLon = picked.lon;
        _destAddress.text = picked.address;
        _destSuggestions = const [];
      }
    });
    _scheduleDraftSave();
    _recalcDistance();
  }

  Future<void> _pickFromMap2({required bool isOrigin}) async {
    final initial = isOrigin
        ? (_originLat2 != null && _originLon2 != null ? LatLng(_originLat2!, _originLon2!) : const LatLng(38.5598, 68.7870))
        : (_destLat2 != null && _destLon2 != null ? LatLng(_destLat2!, _destLon2!) : const LatLng(38.5598, 68.7870));
    final picked = await Navigator.of(context).push<_MapPickResult>(
      MaterialPageRoute(
        builder: (_) => _MapPickerPage(accessToken: widget.accessToken, initial: initial),
      ),
    );
    if (picked == null) return;
    setState(() {
      if (isOrigin) {
        _originLat2 = picked.lat;
        _originLon2 = picked.lon;
        _originAddress2.text = picked.address;
        _originSuggestions2 = const [];
      } else {
        _destLat2 = picked.lat;
        _destLon2 = picked.lon;
        _destAddress2.text = picked.address;
        _destSuggestions2 = const [];
      }
    });
    _scheduleDraftSave();
    _recalcDistance();
  }

  Future<void> _openRoutePreview() async {
    if (_originLat == null || _originLon == null || _destLat == null || _destLon == null) {
      _toast('Сначала выберите точки Откуда и Куда');
      return;
    }
    final a = LatLng(_originLat!, _originLon!);
    final b = LatLng(_destLat!, _destLon!);
    await showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.18),
      builder: (_) => _RoutePreviewPage(
        from: a,
        to: b,
        fromLabel: _originAddress.text.trim(),
        toLabel: _destAddress.text.trim(),
        distanceKm: _distanceKm,
        routePoints: _routePreviewPoints,
        stops: _routeStops,
      ),
    );
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Widget _sectionTitle(IconData icon, String title) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppColors.primary),
          const SizedBox(width: 8),
          Text(
            title,
            style: GoogleFonts.montserrat(
              fontWeight: FontWeight.w700,
              color: cs.onSurface,
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _dec(String label, {IconData? icon, String? hint}) => InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: icon == null
            ? null
            : Icon(icon, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65), size: 20),
      );

  Widget _actionLink({
    required IconData icon,
    required String text,
    required VoidCallback onTap,
    Color? bg,
    bool selected = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
        decoration: BoxDecoration(
          color: bg ?? cs.primary.withValues(alpha: isDark ? 0.18 : 0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? AppColors.primary : cs.onSurface.withValues(alpha: isDark ? 0.20 : 0.12),
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: AppColors.primary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                text,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.montserrat(
                  fontWeight: FontWeight.w700,
                  color: AppColors.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _addressFieldWithDropdown({
    required TextEditingController controller,
    required ValueChanged<String> onChanged,
    required VoidCallback onMapTap,
    required List<OsmHit> suggestions,
    required bool searching,
    required ValueChanged<OsmHit> onSelect,
    required String label,
  }) {
    const maxItems = 6;
    final visible = suggestions.length > maxItems ? suggestions.sublist(0, maxItems) : suggestions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: controller,
          onChanged: onChanged,
          decoration: _dec(label, icon: Icons.place_outlined).copyWith(
            suffixIcon: IconButton(
              onPressed: onMapTap,
              icon: const Icon(Icons.map_outlined),
              tooltip: 'Выбрать на карте',
            ),
          ),
        ),
        if (searching) ...[
          const SizedBox(height: 6),
          const LinearProgressIndicator(minHeight: 2),
        ],
        if (visible.isNotEmpty) ...[
          const SizedBox(height: 6),
          Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(context).colorScheme.onSurface.withValues(
                        alpha: Theme.of(context).brightness == Brightness.dark ? 0.22 : 0.16,
                      ),
                ),
              ),
              constraints: const BoxConstraints(maxHeight: 240),
              child: ListView.separated(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: visible.length,
                separatorBuilder: (context, index) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final hit = visible[index];
                  return ListTile(
                    dense: true,
                    leading: const Icon(Icons.place_outlined, color: AppColors.primary),
                    title: Text(
                      hit.displayName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: GoogleFonts.montserrat(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    onTap: () => onSelect(hit),
                  );
                },
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _dataTextLink({
    required IconData icon,
    required String text,
    required VoidCallback onTap,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 16, color: cs.onSurface.withValues(alpha: 0.65)),
              const SizedBox(width: 6),
              Text(
                text,
                style: GoogleFonts.montserrat(
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                  color: cs.onSurface.withValues(alpha: 0.78),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<(double?, double?)> _ensureCoords(String address) async {
    final q = address.trim();
    if (q.length < 3) return (null, null);
    final hits = await _api.osmSearch(accessToken: widget.accessToken, query: q);
    if (hits.isEmpty) return (null, null);
    final h = hits.first;
    return (h.lat, h.lon);
  }

  Future<void> _showCreatedCenterAndAutoGo() async {
    if (!mounted) return;
    final nav = Navigator.of(context);
    var dialogOpen = true;

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: true,
        barrierColor: Colors.black.withValues(alpha: 0.20),
        builder: (context) {
          return PopScope(
            canPop: true,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) dialogOpen = false;
            },
            child: Center(
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: math.min(MediaQuery.of(context).size.width * 0.86, 360),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Theme.of(context).colorScheme.onSurface.withValues(
                            alpha: Theme.of(context).brightness == Brightness.dark ? 0.22 : 0.16,
                          ),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 18,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.check_rounded, color: AppColors.primary, size: 28),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        'Заявка создана',
                        style: GoogleFonts.montserrat(
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Переходим в «Мои заявки» через 5 секунд',
                        style: GoogleFonts.montserrat(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.72),
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ).then((_) {
        dialogOpen = false;
      }),
    );

    await Future<void>.delayed(const Duration(seconds: 5));
    if (!mounted) return;
    if (dialogOpen && nav.canPop()) {
      nav.pop();
    }
    widget.onNavigateMyRequests?.call();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    final origin = _originAddress.text.trim();
    final dest = _destAddress.text.trim();
    if (name.isEmpty) {
      _toast('Введите название заявки');
      return;
    }
    if (origin.isEmpty || dest.isEmpty) {
      _toast('Заполните адрес Откуда и Куда');
      return;
    }
    if (_transportId == null) {
      _toast('Выберите транспорт');
      return;
    }

    // Ensure coordinates exist for any filled address fields (auto-pick first suggestion).
    if (_originLat == null || _originLon == null) {
      final (lat, lon) = await _ensureCoords(origin);
      if (lat != null && lon != null) {
        _originLat = lat;
        _originLon = lon;
      } else {
        _toast('Выберите адрес "Откуда" из списка или карты');
        return;
      }
    }
    if (_destLat == null || _destLon == null) {
      final (lat, lon) = await _ensureCoords(dest);
      if (lat != null && lon != null) {
        _destLat = lat;
        _destLon = lon;
      } else {
        _toast('Выберите адрес "Куда" из списка или карты');
        return;
      }
    }
    final origin2Trim = _originAddress2.text.trim();
    if (_showOriginAddress2 && origin2Trim.isNotEmpty && (_originLat2 == null || _originLon2 == null)) {
      final (lat, lon) = await _ensureCoords(origin2Trim);
      if (lat != null && lon != null) {
        _originLat2 = lat;
        _originLon2 = lon;
      } else {
        _toast('Выберите "Адрес (2)" в блоке "Откуда" из списка или карты');
        return;
      }
    }
    final dest2Trim = _destAddress2.text.trim();
    if (_showDestAddress2 && dest2Trim.isNotEmpty && (_destLat2 == null || _destLon2 == null)) {
      final (lat, lon) = await _ensureCoords(dest2Trim);
      if (lat != null && lon != null) {
        _destLat2 = lat;
        _destLon2 = lon;
      } else {
        _toast('Выберите "Адрес (2)" в блоке "Куда" из списка или карты');
        return;
      }
    }

    final originAddresses = <String>[origin];
    final originWarehouses = <String>[_originWarehouse.text.trim()];
    final originLats = <double?>[_roundCoord(_originLat)];
    final originLngs = <double?>[_roundCoord(_originLon)];
    final origin2 = _originAddress2.text.trim();
    if (_showOriginAddress2 && origin2.isNotEmpty) {
      originAddresses.add(origin2);
      originWarehouses.add(_originWarehouse2.text.trim());
      originLats.add(_roundCoord(_originLat2));
      originLngs.add(_roundCoord(_originLon2));
    }

    final destAddresses = <String>[dest];
    final destWarehouses = <String>[_destWarehouse.text.trim()];
    final destLats = <double?>[_roundCoord(_destLat)];
    final destLngs = <double?>[_roundCoord(_destLon)];
    final dest2 = _destAddress2.text.trim();
    if (_showDestAddress2 && dest2.isNotEmpty) {
      destAddresses.add(dest2);
      destWarehouses.add(_destWarehouse2.text.trim());
      destLats.add(_roundCoord(_destLat2));
      destLngs.add(_roundCoord(_destLon2));
    }

    setState(() => _submitting = true);
    final apiDateFmt = DateFormat('yyyy-MM-dd');
    final payload = <String, dynamic>{
      'name': name,
      'transport': _transportId,
      'load_date': _loadDate == null ? null : apiDateFmt.format(_loadDate!),
      'delivery_date': _deliveryDate == null ? null : apiDateFmt.format(_deliveryDate!),
      'origin_address': originAddresses.join('; '),
      'origin_warehouse': originWarehouses.join('; '),
      'dest_address': destAddresses.join('; '),
      'dest_warehouse': destWarehouses.join('; '),
      'origin_lats': originLats,
      'origin_lngs': originLngs,
      'dest_lats': destLats,
      'dest_lngs': destLngs,
      'price_tjs': _price.text.trim(),
      'tonnage_t': _tonnage.text.trim(),
      'distance_km': _distanceKm,
      'description': _description.text.trim(),
      'sender_name': _senderName.text.trim(),
      'sender_phone': _senderPhone.text.trim(),
      'receiver_name': _receiverName.text.trim(),
      'receiver_phone': _receiverPhone.text.trim(),
    };

    final (ok, err) = await _api.createRequest(
      accessToken: widget.accessToken,
      payload: payload,
    );
    if (!mounted) return;
    setState(() => _submitting = false);

    if (ok) {
      unawaited(_LocalPrefs.clearRequestDraft());
      _name.clear();
      _originAddress.clear();
      _originWarehouse.clear();
      _originAddress2.clear();
      _originWarehouse2.clear();
      _destAddress.clear();
      _destWarehouse.clear();
      _destAddress2.clear();
      _destWarehouse2.clear();
      _senderName.clear();
      _senderPhone.clear();
      _receiverName.clear();
      _receiverPhone.clear();
      _price.clear();
      _tonnage.clear();
      _description.clear();
      _loadDate = null;
      _deliveryDate = null;
      _loadDateText.clear();
      _deliveryDateText.clear();
      _originLat = null;
      _originLon = null;
      _originLat2 = null;
      _originLon2 = null;
      _destLat = null;
      _destLon = null;
      _destLat2 = null;
      _destLon2 = null;
      _showOriginAddress2 = false;
      _showOriginSenderData = false;
      _showDestAddress2 = false;
      _showDestReceiverData = false;
      unawaited(_showCreatedCenterAndAutoGo());
      return;
    }
    // If request failed (network/offline/validation), keep draft for later.
    unawaited(_saveDraftNow());
    _toast('${err ?? 'Ошибка'}\n(Сохранено в черновик)');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 20),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isDark ? cs.onSurface.withValues(alpha: 0.28) : cs.primary.withValues(alpha: 0.16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _sectionTitle(Icons.title_rounded, 'Название'),
              TextField(
                controller: _name,
                decoration: _dec('Название заявки', icon: Icons.edit_rounded),
              ),
              const SizedBox(height: 10),

              _sectionTitle(Icons.local_shipping_rounded, 'Транспорт'),
              if (_loadingTransports)
                const LinearProgressIndicator(minHeight: 3)
              else
                DropdownButtonFormField<int>(
                  initialValue: _transportId,
                  items: _transports
                      .map((t) => DropdownMenuItem(value: t.id, child: Text(t.name)))
                      .toList(),
                  onChanged: (v) {
                    setState(() => _transportId = v);
                    _scheduleDraftSave();
                  },
                  decoration: _dec('Категория транспорта', icon: Icons.local_shipping_outlined),
                ),
              const SizedBox(height: 10),

              _sectionTitle(Icons.my_location_rounded, 'Откуда'),
              _addressFieldWithDropdown(
                controller: _originAddress,
                onChanged: _onOriginChanged,
                onMapTap: () => _pickFromMap(isOrigin: true),
                suggestions: _originSuggestions,
                searching: _originSearching,
                label: 'Адрес',
                onSelect: (hit) {
                  _originAddress.text = hit.displayName;
                  setState(() {
                    _originLat = hit.lat;
                    _originLon = hit.lon;
                    _originSuggestions = const [];
                  });
                  _scheduleDraftSave();
                  _recalcDistance();
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _originWarehouse,
                decoration: _dec('Склад (необязательно)', icon: Icons.warehouse_outlined),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: _actionLink(
                      icon: Icons.add_circle_outline_rounded,
                      text: 'Добавить адрес',
                      onTap: () {
                        setState(() {
                          _showOriginAddress2 = !_showOriginAddress2;
                          if (!_showOriginAddress2) {
                            _originAddress2.clear();
                            _originWarehouse2.clear();
                            _originLat2 = null;
                            _originLon2 = null;
                            _originSuggestions2 = const [];
                            _originSearching2 = false;
                            _origin2Debounce?.cancel();
                          }
                        });
                        _recalcDistance();
                      },
                      bg: Theme.of(context).colorScheme.primary.withValues(
                            alpha: Theme.of(context).brightness == Brightness.dark ? 0.18 : 0.10,
                          ),
                      selected: _showOriginAddress2,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _dataTextLink(
                      icon: Icons.person_outline_rounded,
                      text: 'Данные отправителя',
                      onTap: () {
                        setState(() => _showOriginSenderData = !_showOriginSenderData);
                        _scheduleDraftSave();
                      },
                    ),
                  ),
                ],
              ),
              if (_showOriginAddress2) ...[
                const SizedBox(height: 8),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.primary.withValues(alpha: 0.55)),
                    color: const Color(0x08007D72),
                  ),
                  child: Column(
                    children: [
                      _addressFieldWithDropdown(
                        controller: _originAddress2,
                        onChanged: _onOrigin2Changed,
                        onMapTap: () => _pickFromMap2(isOrigin: true),
                        suggestions: _originSuggestions2,
                        searching: _originSearching2,
                        label: 'Адрес (2)',
                        onSelect: (hit) {
                          _originAddress2.text = hit.displayName;
                          setState(() {
                            _originLat2 = hit.lat;
                            _originLon2 = hit.lon;
                            _originSuggestions2 = const [];
                          });
                          _scheduleDraftSave();
                          _recalcDistance();
                        },
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _originWarehouse2,
                        decoration: _dec('Склад (необязательно)', icon: Icons.warehouse_outlined),
                      ),
                    ],
                  ),
                ),
              ],
              if (_showOriginSenderData) ...[
                const SizedBox(height: 8),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.navy.withValues(alpha: 0.30)),
                    color: const Color(0x0609355F),
                  ),
                  child: Column(
                    children: [
                      TextField(
                        controller: _senderName,
                        decoration: _dec('Имя отправителя', icon: Icons.badge_outlined),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _senderPhone,
                        keyboardType: TextInputType.phone,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: _dec('Номер телефона отправителя', icon: Icons.phone_outlined),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 10),

              _sectionTitle(Icons.location_on_rounded, 'Куда'),
              _addressFieldWithDropdown(
                controller: _destAddress,
                onChanged: _onDestChanged,
                onMapTap: () => _pickFromMap(isOrigin: false),
                suggestions: _destSuggestions,
                searching: _destSearching,
                label: 'Адрес',
                onSelect: (hit) {
                  _destAddress.text = hit.displayName;
                  setState(() {
                    _destLat = hit.lat;
                    _destLon = hit.lon;
                    _destSuggestions = const [];
                  });
                  _scheduleDraftSave();
                  _recalcDistance();
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _destWarehouse,
                decoration: _dec('Склад (необязательно)', icon: Icons.warehouse_outlined),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: _actionLink(
                      icon: Icons.add_circle_outline_rounded,
                      text: 'Добавить адрес',
                      onTap: () {
                        setState(() {
                          _showDestAddress2 = !_showDestAddress2;
                          if (!_showDestAddress2) {
                            _destAddress2.clear();
                            _destWarehouse2.clear();
                            _destLat2 = null;
                            _destLon2 = null;
                            _destSuggestions2 = const [];
                            _destSearching2 = false;
                            _dest2Debounce?.cancel();
                          }
                        });
                        _scheduleDraftSave();
                        _recalcDistance();
                      },
                      bg: Theme.of(context).colorScheme.primary.withValues(
                            alpha: Theme.of(context).brightness == Brightness.dark ? 0.18 : 0.10,
                          ),
                      selected: _showDestAddress2,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: _dataTextLink(
                      icon: Icons.person_outline_rounded,
                      text: 'Данные получателя',
                      onTap: () {
                        setState(() => _showDestReceiverData = !_showDestReceiverData);
                        _scheduleDraftSave();
                      },
                    ),
                  ),
                ],
              ),
              if (_showDestAddress2) ...[
                const SizedBox(height: 8),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.primary.withValues(alpha: 0.55)),
                    color: const Color(0x08007D72),
                  ),
                  child: Column(
                    children: [
                      _addressFieldWithDropdown(
                        controller: _destAddress2,
                        onChanged: _onDest2Changed,
                        onMapTap: () => _pickFromMap2(isOrigin: false),
                        suggestions: _destSuggestions2,
                        searching: _destSearching2,
                        label: 'Адрес (2)',
                        onSelect: (hit) {
                          _destAddress2.text = hit.displayName;
                          setState(() {
                            _destLat2 = hit.lat;
                            _destLon2 = hit.lon;
                            _destSuggestions2 = const [];
                          });
                          _scheduleDraftSave();
                          _recalcDistance();
                        },
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _destWarehouse2,
                        decoration: _dec('Склад (необязательно)', icon: Icons.warehouse_outlined),
                      ),
                    ],
                  ),
                ),
              ],
              if (_showDestReceiverData) ...[
                const SizedBox(height: 8),
                AnimatedContainer(
                  duration: const Duration(milliseconds: 160),
                  curve: Curves.easeOut,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.navy.withValues(alpha: 0.30)),
                    color: const Color(0x0609355F),
                  ),
                  child: Column(
                    children: [
                      TextField(
                        controller: _receiverName,
                        decoration: _dec('Имя получателя', icon: Icons.badge_outlined),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _receiverPhone,
                        keyboardType: TextInputType.phone,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        decoration: _dec('Номер телефона получателя', icon: Icons.phone_outlined),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),

              if (_distanceKm != null) ...[
                InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: _openRoutePreview,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: const Color(0x11007D72),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0x22007D72)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.route_rounded, color: AppColors.primary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Расстояние: $_distanceKm км (нажмите, открыть карту)',
                            style: GoogleFonts.montserrat(
                              fontWeight: FontWeight.w700,
                              color: AppColors.navy,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
              ],
              _sectionTitle(Icons.info_outline_rounded, 'Дополнительная информация'),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _price,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: _dec('Сумма', icon: Icons.payments_outlined, hint: 'Введите сумму'),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: TextField(
                      controller: _tonnage,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                      ],
                      decoration: _dec('Тонна (т)', icon: Icons.scale_outlined),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              _sectionTitle(Icons.date_range_rounded, 'Даты'),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _loadDateText,
                      readOnly: true,
                      onTap: () => _pickDate(isLoadDate: true),
                      decoration: _dec('Дата погрузки', icon: Icons.event_available_rounded),
                    ),
                  ),
                  const SizedBox(width: 5),
                  Expanded(
                    child: TextField(
                      controller: _deliveryDateText,
                      readOnly: true,
                      onTap: () => _pickDate(isLoadDate: false),
                      decoration: _dec('Срок доставки', icon: Icons.event_rounded),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              _sectionTitle(Icons.description_rounded, 'Описание (необязательно)'),
              TextField(
                controller: _description,
                maxLines: 3,
                decoration: _dec('Описание', icon: Icons.notes_rounded, hint: 'Подробно укажите в вашей заявке...'),
              ),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: _submitting ? null : _submit,
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF00A38F),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  textStyle: GoogleFonts.montserrat(fontWeight: FontWeight.w900),
                ),
                child: Text(_submitting ? 'Отправка...' : 'Создать заявку'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ProfileContent extends StatelessWidget {
  const _ProfileContent({
    required this.onLogout,
    required this.accessToken,
    required this.role,
    this.onProfileDataChanged,
  });

  final VoidCallback onLogout;
  final String accessToken;
  final AppRole role;
  final VoidCallback? onProfileDataChanged;

  @override
  Widget build(BuildContext context) {
    if (role == AppRole.client) {
      return _ClientProfileContent(
        accessToken: accessToken,
        onLogout: onLogout,
        onProfileDataChanged: onProfileDataChanged,
      );
    }
    return _DriverProfileContent(
      accessToken: accessToken,
      onLogout: onLogout,
      onProfileDataChanged: onProfileDataChanged,
    );
  }
}

class _DriverProfileContent extends StatefulWidget {
  const _DriverProfileContent({
    required this.accessToken,
    required this.onLogout,
    this.onProfileDataChanged,
  });

  final String accessToken;
  final VoidCallback onLogout;
  final VoidCallback? onProfileDataChanged;

  @override
  State<_DriverProfileContent> createState() => _DriverProfileContentState();
}

class _DriverProfileContentState extends State<_DriverProfileContent> {

  final _api = const ProfileApi();
  final _citiesApi = const CitiesApi();
  final _transportsApi = const RequestsApi();

  final _fullName = TextEditingController();
  final _passport = TextEditingController();
  final _inn = TextEditingController();
  final _carNumber = TextEditingController();

  bool _loading = true;
  String? _error;

  DateTime? _birthDate;
  int? _cityId;
  int? _transportCategoryId;
  String _status = 'inactive';
  String _balance = '0';

  List<CityDto> _cities = const [];
  List<TransportCategoryDto> _transports = const [];

  // existing urls
  String? _photoUrl;
  String? _passportFrontUrl;
  String? _passportBackUrl;
  String? _transportPhotoUrl;
  String? _techFrontUrl;
  String? _techBackUrl;
  String? _permissionUrl;
  String? _pravoUrl;
  String? _franchisePartnerName;

  // picked bytes
  Uint8List? _photoBytes;
  String? _photoName;
  Uint8List? _passportFrontBytes;
  String? _passportFrontName;
  Uint8List? _passportBackBytes;
  String? _passportBackName;
  Uint8List? _transportPhotoBytes;
  String? _transportPhotoName;
  Uint8List? _techFrontBytes;
  String? _techFrontName;
  Uint8List? _techBackBytes;
  String? _techBackName;
  Uint8List? _permissionBytes;
  String? _permissionName;
  Uint8List? _pravoBytes;
  String? _pravoName;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _fullName.dispose();
    _passport.dispose();
    _inn.dispose();
    _carNumber.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cacheKey = 'cache_driver_profile_v1:${await _JsonCache._scope()}';
    final cached = await _JsonCache.getMap(cacheKey);
    if (mounted && cached != null && cached.isNotEmpty) {
      // Apply cached profile quickly (offline-friendly).
      final u = cached['user'];
      Map<String, dynamic>? userMap;
      if (u is Map) userMap = u.map((k, v) => MapEntry(k.toString(), v));
      _fullName.text = (userMap?['full_name'] ?? '').toString();
      _birthDate = _parseApiDateOnly(cached['birth_date']);
      _passport.text = (cached['passport'] ?? '').toString();
      _inn.text = (cached['inn'] ?? '').toString();
      _carNumber.text = (cached['car_number'] ?? '').toString();
      _balance = (cached['balance'] ?? '0').toString();
      _status = (cached['status'] ?? 'inactive').toString();
      final cityObj = cached['city'];
      if (cityObj is Map) {
        _cityId = int.tryParse((cityObj['id'] ?? '').toString());
      }
      final transportObj = cached['transport_category_detail'];
      if (transportObj is Map) {
        _transportCategoryId = int.tryParse((transportObj['id'] ?? '').toString());
      }
      _photoUrl = (cached['photo'] ?? '').toString().trim();
      if ((_photoUrl ?? '').isEmpty) _photoUrl = null;
      _passportFrontUrl = (cached['passport_front'] ?? '').toString().trim();
      if ((_passportFrontUrl ?? '').isEmpty) _passportFrontUrl = null;
      _passportBackUrl = (cached['passport_back'] ?? '').toString().trim();
      if ((_passportBackUrl ?? '').isEmpty) _passportBackUrl = null;
      _transportPhotoUrl = (cached['transport_photo'] ?? '').toString().trim();
      if ((_transportPhotoUrl ?? '').isEmpty) _transportPhotoUrl = null;
      _techFrontUrl = (cached['tech_passport_front'] ?? '').toString().trim();
      if ((_techFrontUrl ?? '').isEmpty) _techFrontUrl = null;
      _techBackUrl = (cached['tech_passport_back'] ?? '').toString().trim();
      if ((_techBackUrl ?? '').isEmpty) _techBackUrl = null;
      _permissionUrl = (cached['permission'] ?? '').toString().trim();
      if ((_permissionUrl ?? '').isEmpty) _permissionUrl = null;
      _pravoUrl = (cached['pravo'] ?? '').toString().trim();
      if ((_pravoUrl ?? '').isEmpty) _pravoUrl = null;
      _franchisePartnerName = null;
      final fr = cached['franchise'];
      if (fr is Map) {
        final n = (fr['name'] ?? '').toString().trim();
        if (n.isNotEmpty) _franchisePartnerName = n;
      }
      setState(() {
        _loading = false;
        _error = null;
      });
    } else {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    final citiesF = _citiesApi.list();
    final transportsF = _transportsApi.getTransports();
    final (data, err) = await _api.fetchMeProfile(accessToken: widget.accessToken);
    final cities = await citiesF;
    final transports = await transportsF;
    if (!mounted) return;
    _cities = cities;
    _transports = transports;
    if (data == null) {
      setState(() {
        _loading = false;
        _error = err;
      });
      return;
    }
    unawaited(_JsonCache.setJson(cacheKey, data));
    final u = data['user'];
    Map<String, dynamic>? userMap;
    if (u is Map) userMap = u.map((k, v) => MapEntry(k.toString(), v));
    _fullName.text = (userMap?['full_name'] ?? '').toString();

    _birthDate = _parseApiDateOnly(data['birth_date']);
    _passport.text = (data['passport'] ?? '').toString();
    _inn.text = (data['inn'] ?? '').toString();
    _carNumber.text = (data['car_number'] ?? '').toString();
    _balance = (data['balance'] ?? '0').toString();
    _status = (data['status'] ?? 'inactive').toString();

    final cityObj = data['city'];
    if (cityObj is Map) {
      _cityId = int.tryParse((cityObj['id'] ?? '').toString());
    }
    final transportObj = data['transport_category_detail'];
    if (transportObj is Map) {
      _transportCategoryId = int.tryParse((transportObj['id'] ?? '').toString());
    }

    _photoUrl = (data['photo'] ?? '').toString().trim();
    if (_photoUrl!.isEmpty) _photoUrl = null;
    _passportFrontUrl = (data['passport_front'] ?? '').toString().trim();
    if (_passportFrontUrl!.isEmpty) _passportFrontUrl = null;
    _passportBackUrl = (data['passport_back'] ?? '').toString().trim();
    if (_passportBackUrl!.isEmpty) _passportBackUrl = null;
    _transportPhotoUrl = (data['transport_photo'] ?? '').toString().trim();
    if (_transportPhotoUrl!.isEmpty) _transportPhotoUrl = null;
    _techFrontUrl = (data['tech_passport_front'] ?? '').toString().trim();
    if (_techFrontUrl!.isEmpty) _techFrontUrl = null;
    _techBackUrl = (data['tech_passport_back'] ?? '').toString().trim();
    if (_techBackUrl!.isEmpty) _techBackUrl = null;
    _permissionUrl = (data['permission'] ?? '').toString().trim();
    if (_permissionUrl!.isEmpty) _permissionUrl = null;
    _pravoUrl = (data['pravo'] ?? '').toString().trim();
    if (_pravoUrl!.isEmpty) _pravoUrl = null;

    _franchisePartnerName = null;
    final fr = data['franchise'];
    if (fr is Map) {
      final n = (fr['name'] ?? '').toString().trim();
      if (n.isNotEmpty) _franchisePartnerName = n;
    }

    setState(() => _loading = false);
  }

  void _openProfilePage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _DriverProfileEditPage(
          accessToken: widget.accessToken,
          onSaved: () async {
            await _load();
            widget.onProfileDataChanged?.call();
          },
          cities: _cities,
          transports: _transports,
          fullName: _fullName.text,
          birthDate: _birthDate,
          passport: _passport.text,
          inn: _inn.text,
          carNumber: _carNumber.text,
          cityId: _cityId,
          transportCategoryId: _transportCategoryId,
          photoUrl: _photoUrl,
          photoBytes: _photoBytes,
          photoName: _photoName,
          franchisePartnerName: _franchisePartnerName,
        ),
      ),
    );
  }

  void _openDocumentsPage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _DriverDocumentsEditPage(
          accessToken: widget.accessToken,
          onSaved: _load,
          fullName: _fullName.text,
          // existing urls
          passportFrontUrl: _passportFrontUrl,
          passportBackUrl: _passportBackUrl,
          transportPhotoUrl: _transportPhotoUrl,
          techFrontUrl: _techFrontUrl,
          techBackUrl: _techBackUrl,
          permissionUrl: _permissionUrl,
          pravoUrl: _pravoUrl,
          // picked
          passportFrontBytes: _passportFrontBytes,
          passportFrontName: _passportFrontName,
          passportBackBytes: _passportBackBytes,
          passportBackName: _passportBackName,
          transportPhotoBytes: _transportPhotoBytes,
          transportPhotoName: _transportPhotoName,
          techFrontBytes: _techFrontBytes,
          techFrontName: _techFrontName,
          techBackBytes: _techBackBytes,
          techBackName: _techBackName,
          permissionBytes: _permissionBytes,
          permissionName: _permissionName,
          pravoBytes: _pravoBytes,
          pravoName: _pravoName,
        ),
      ),
    );
  }

  void _openBalancePage() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _DriverBalancePage(balance: _balance),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(_error!, textAlign: TextAlign.center, style: GoogleFonts.montserrat(color: cs.onSurface)),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Повторить')),
            ],
          ),
        ),
      );
    }

    final statusRu = switch (_status.toLowerCase()) {
      'active' => 'Верифицирован',
      'inactive' => 'На проверке',
      'blacklisted' => 'Заблокирован',
      'bad' => 'Отклонён',
      _ => _status,
    };

    return RefreshIndicator(
      color: AppColors.primary,
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
        children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Статус: $statusRu',
                style: GoogleFonts.montserrat(fontWeight: FontWeight.w700, color: cs.onSurface),
              ),
            ),
            InkWell(
              onTap: _openBalancePage,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
                ),
                child: Text(
                  'Баланс: $_balance смн',
                  style: GoogleFonts.montserrat(fontWeight: FontWeight.w700, color: AppColors.primary, fontSize: 12),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: cs.onSurface.withValues(alpha: 0.18)),
          ),
          child: Column(
            children: [
              ListTile(
                leading: const Icon(Icons.person_outline_rounded, color: AppColors.primary),
                title: Text('Профиль', style: GoogleFonts.montserrat(fontWeight: FontWeight.w800)),
                subtitle: Text('ФИО, город, транспорт, дата рождения', style: GoogleFonts.montserrat(fontSize: 12.5)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _openProfilePage,
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.badge_outlined, color: AppColors.primary),
                title: Text('Документы', style: GoogleFonts.montserrat(fontWeight: FontWeight.w800)),
                subtitle: Text('Паспорт, техпаспорт, доверенность, права', style: GoogleFonts.montserrat(fontSize: 12.5)),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: _openDocumentsPage,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: widget.onLogout,
          icon: const Icon(Icons.logout_rounded),
          label: const Text('Выйти'),
        ),
        ],
      ),
    );
  }
}

class _DriverBalancePage extends StatelessWidget {
  const _DriverBalancePage({required this.balance});

  final String balance;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TopBar(
                onBackTap: () => Navigator.of(context).pop(),
                onMenuTap: null,
                onNotificationsTap: () {},
              ),
              const SizedBox(height: 12),
              Text(
                'Баланс',
                style: GoogleFonts.montserrat(
                  fontWeight: FontWeight.w900,
                  fontSize: 22,
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: cs.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: cs.onSurface.withValues(alpha: 0.18)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.account_balance_wallet_outlined, color: AppColors.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Текущий баланс: $balance смн',
                        style: GoogleFonts.montserrat(fontWeight: FontWeight.w800, color: cs.onSurface),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Пополнение баланса будет добавлено позже (платёжные системы/карта).',
                style: GoogleFonts.montserrat(
                  height: 1.35,
                  color: cs.onSurface.withValues(alpha: 0.75),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DriverProfileEditPage extends StatefulWidget {
  const _DriverProfileEditPage({
    required this.accessToken,
    required this.onSaved,
    required this.cities,
    required this.transports,
    required this.fullName,
    required this.birthDate,
    required this.passport,
    required this.inn,
    required this.carNumber,
    required this.cityId,
    required this.transportCategoryId,
    required this.photoUrl,
    required this.photoBytes,
    required this.photoName,
    this.franchisePartnerName,
  });

  final String accessToken;
  final Future<void> Function() onSaved;
  final List<CityDto> cities;
  final List<TransportCategoryDto> transports;

  final String fullName;
  final DateTime? birthDate;
  final String passport;
  final String inn;
  final String carNumber;
  final int? cityId;
  final int? transportCategoryId;

  final String? photoUrl;
  final Uint8List? photoBytes;
  final String? photoName;
  final String? franchisePartnerName;

  @override
  State<_DriverProfileEditPage> createState() => _DriverProfileEditPageState();
}

class _DriverProfileEditPageState extends State<_DriverProfileEditPage> {
  static final _dateFmt = DateFormat('dd.MM.yyyy');
  final _api = const ProfileApi();
  final _picker = ImagePicker();

  late final TextEditingController _fullName;
  late final TextEditingController _passport;
  late final TextEditingController _inn;
  late final TextEditingController _carNumber;
  late final TextEditingController _franchiseJoinCode;

  DateTime? _birthDate;
  int? _cityId;
  int? _transportCategoryId;

  Uint8List? _photoBytes;
  String? _photoName;
  String? _photoUrl;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _fullName = TextEditingController(text: widget.fullName);
    _passport = TextEditingController(text: widget.passport);
    _inn = TextEditingController(text: widget.inn);
    _carNumber = TextEditingController(text: widget.carNumber);
    _franchiseJoinCode = TextEditingController();
    unawaited(() async {
      final saved = await _LocalPrefs.getFranchiseJoinCode();
      if (!mounted) return;
      if (saved.isNotEmpty && _franchiseJoinCode.text.trim().isEmpty) {
        _franchiseJoinCode.text = saved;
      }
    }());
    _birthDate = widget.birthDate;
    _cityId = widget.cityId;
    _transportCategoryId = widget.transportCategoryId;
    _photoBytes = widget.photoBytes;
    _photoName = widget.photoName;
    _photoUrl = widget.photoUrl;
  }

  @override
  void dispose() {
    _fullName.dispose();
    _passport.dispose();
    _inn.dispose();
    _carNumber.dispose();
    _franchiseJoinCode.dispose();
    super.dispose();
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final initial = _birthDate ?? DateTime(now.year - 25);
    final d = await showDatePicker(
      context: context,
      initialDate: initial.isAfter(now) ? now : initial,
      firstDate: DateTime(1900),
      lastDate: now,
      locale: const Locale('ru', 'RU'),
    );
    if (d != null && mounted) setState(() => _birthDate = d);
  }

  Future<void> _pickPhoto() async {
    final x = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 1800, imageQuality: 88);
    if (x == null || !mounted) return;
    final bytes = await x.readAsBytes();
    setState(() {
      _photoBytes = bytes;
      _photoName = x.name.isNotEmpty ? x.name : 'photo.jpg';
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final (ok, err) = await _api.updateDriverProfile(
      accessToken: widget.accessToken,
      fullName: _fullName.text.trim(),
      birthDate: _birthDate,
      cityId: _cityId,
      passport: _passport.text.trim(),
      inn: _inn.text.trim(),
      transportCategoryId: _transportCategoryId,
      carNumber: _carNumber.text.trim(),
      photoBytes: _photoBytes?.toList(),
      photoFilename: _photoName,
      franchiseJoinCode: _franchiseJoinCode.text,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Ошибка')));
      return;
    }
    unawaited(_LocalPrefs.setFranchiseJoinCode(_franchiseJoinCode.text));
    await widget.onSaved();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Сохранено')));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final birthText = _birthDate != null ? _dateFmt.format(_birthDate!) : '—';
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TopBar(
                onBackTap: () => Navigator.of(context).pop(),
                onMenuTap: null,
                onNotificationsTap: () {},
              ),
              const SizedBox(height: 12),
              Text('Профиль', style: GoogleFonts.montserrat(fontWeight: FontWeight.w900, fontSize: 22, color: cs.onSurface)),
              const SizedBox(height: 14),
              Center(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _pickPhoto,
                        customBorder: const CircleBorder(),
                        child: CircleAvatar(
                          radius: 52,
                          backgroundColor: cs.surface,
                          backgroundImage: _photoBytes != null
                              ? MemoryImage(_photoBytes!)
                              : (_photoUrl != null ? NetworkImage(_photoUrl!) : null),
                          child: (_photoBytes == null && _photoUrl == null)
                              ? Icon(Icons.person_rounded, size: 56, color: cs.onSurface.withValues(alpha: 0.35))
                              : null,
                        ),
                      ),
                    ),
                    Positioned(
                      right: -4,
                      bottom: -4,
                      child: Material(
                        color: AppColors.primary,
                        shape: const CircleBorder(),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: _pickPhoto,
                          child: const Padding(
                            padding: EdgeInsets.all(8),
                            child: Icon(Icons.camera_alt_rounded, color: Colors.white, size: 20),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Expanded(
                child: ListView(
                  children: [
                    TextField(controller: _fullName, decoration: const InputDecoration(labelText: 'ФИО', isDense: true)),
                    const SizedBox(height: 10),
                    InkWell(
                      onTap: _pickBirthDate,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
                        decoration: BoxDecoration(
                          color: cs.surface,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: cs.onSurface.withValues(alpha: 0.18)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'Дата рождения: $birthText',
                                style: GoogleFonts.montserrat(fontWeight: FontWeight.w700, color: cs.onSurface),
                              ),
                            ),
                            Icon(Icons.edit_calendar_rounded, color: AppColors.primary.withValues(alpha: 0.85)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(controller: _passport, decoration: const InputDecoration(labelText: 'Паспорт', isDense: true)),
                    const SizedBox(height: 10),
                    TextField(controller: _inn, decoration: const InputDecoration(labelText: 'ИНН', isDense: true)),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int>(
                      initialValue: _cityId,
                      decoration: const InputDecoration(labelText: 'Город', isDense: true),
                      items: widget.cities.map((c) => DropdownMenuItem(value: c.id, child: Text(c.name))).toList(),
                      onChanged: (v) => setState(() => _cityId = v),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int>(
                      initialValue: _transportCategoryId,
                      decoration: const InputDecoration(labelText: 'Тип транспорта', isDense: true),
                      items: widget.transports.map((t) => DropdownMenuItem(value: t.id, child: Text(t.name))).toList(),
                      onChanged: (v) => setState(() => _transportCategoryId = v),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      widget.franchisePartnerName != null && widget.franchisePartnerName!.trim().isNotEmpty
                          ? 'Партнёр: ${widget.franchisePartnerName!.trim()}'
                          : 'Франшиза пока не привязана',
                      style: GoogleFonts.montserrat(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface.withValues(alpha: 0.72),
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _franchiseJoinCode,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        labelText: 'Новый код франшизы (необязательно)',
                        hintText: 'Чтобы сменить партнёра',
                        isDense: true,
                        prefixIcon: const Icon(Icons.storefront_outlined, size: 20),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(controller: _carNumber, decoration: const InputDecoration(labelText: 'Номер машины', isDense: true)),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : Text('Сохранить', style: GoogleFonts.montserrat(fontWeight: FontWeight.w900)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DriverDocumentsEditPage extends StatefulWidget {
  const _DriverDocumentsEditPage({
    required this.accessToken,
    required this.onSaved,
    required this.fullName,
    required this.passportFrontUrl,
    required this.passportBackUrl,
    required this.transportPhotoUrl,
    required this.techFrontUrl,
    required this.techBackUrl,
    required this.permissionUrl,
    required this.pravoUrl,
    required this.passportFrontBytes,
    required this.passportFrontName,
    required this.passportBackBytes,
    required this.passportBackName,
    required this.transportPhotoBytes,
    required this.transportPhotoName,
    required this.techFrontBytes,
    required this.techFrontName,
    required this.techBackBytes,
    required this.techBackName,
    required this.permissionBytes,
    required this.permissionName,
    required this.pravoBytes,
    required this.pravoName,
  });

  final String accessToken;
  final Future<void> Function() onSaved;
  final String fullName;

  final String? passportFrontUrl;
  final String? passportBackUrl;
  final String? transportPhotoUrl;
  final String? techFrontUrl;
  final String? techBackUrl;
  final String? permissionUrl;
  final String? pravoUrl;

  final Uint8List? passportFrontBytes;
  final String? passportFrontName;
  final Uint8List? passportBackBytes;
  final String? passportBackName;
  final Uint8List? transportPhotoBytes;
  final String? transportPhotoName;
  final Uint8List? techFrontBytes;
  final String? techFrontName;
  final Uint8List? techBackBytes;
  final String? techBackName;
  final Uint8List? permissionBytes;
  final String? permissionName;
  final Uint8List? pravoBytes;
  final String? pravoName;

  @override
  State<_DriverDocumentsEditPage> createState() => _DriverDocumentsEditPageState();
}

class _DriverDocumentsEditPageState extends State<_DriverDocumentsEditPage> {
  final _api = const ProfileApi();
  final _picker = ImagePicker();

  bool _saving = false;

  String? _passportFrontUrl;
  String? _passportBackUrl;
  String? _transportPhotoUrl;
  String? _techFrontUrl;
  String? _techBackUrl;
  String? _permissionUrl;
  String? _pravoUrl;

  Uint8List? _passportFrontBytes;
  String? _passportFrontName;
  Uint8List? _passportBackBytes;
  String? _passportBackName;
  Uint8List? _transportPhotoBytes;
  String? _transportPhotoName;
  Uint8List? _techFrontBytes;
  String? _techFrontName;
  Uint8List? _techBackBytes;
  String? _techBackName;
  Uint8List? _permissionBytes;
  String? _permissionName;
  Uint8List? _pravoBytes;
  String? _pravoName;

  @override
  void initState() {
    super.initState();
    _passportFrontUrl = widget.passportFrontUrl;
    _passportBackUrl = widget.passportBackUrl;
    _transportPhotoUrl = widget.transportPhotoUrl;
    _techFrontUrl = widget.techFrontUrl;
    _techBackUrl = widget.techBackUrl;
    _permissionUrl = widget.permissionUrl;
    _pravoUrl = widget.pravoUrl;

    _passportFrontBytes = widget.passportFrontBytes;
    _passportFrontName = widget.passportFrontName;
    _passportBackBytes = widget.passportBackBytes;
    _passportBackName = widget.passportBackName;
    _transportPhotoBytes = widget.transportPhotoBytes;
    _transportPhotoName = widget.transportPhotoName;
    _techFrontBytes = widget.techFrontBytes;
    _techFrontName = widget.techFrontName;
    _techBackBytes = widget.techBackBytes;
    _techBackName = widget.techBackName;
    _permissionBytes = widget.permissionBytes;
    _permissionName = widget.permissionName;
    _pravoBytes = widget.pravoBytes;
    _pravoName = widget.pravoName;
  }

  Future<void> _pickInto(void Function(Uint8List b, String n) setValue) async {
    final x = await _picker.pickImage(source: ImageSource.gallery, maxWidth: 1800, imageQuality: 88);
    if (x == null || !mounted) return;
    final bytes = await x.readAsBytes();
    setState(() => setValue(bytes, x.name.isNotEmpty ? x.name : 'doc.jpg'));
  }

  Widget _docTile({
    required String title,
    String? url,
    Uint8List? bytes,
    required VoidCallback onPick,
  }) {
    final cs = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onPick,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        height: 108,
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.onSurface.withValues(alpha: 0.18)),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: bytes != null
                    ? Image.memory(bytes, fit: BoxFit.cover)
                    : (url != null
                        ? Image.network(url, fit: BoxFit.cover)
                        : Center(child: Icon(Icons.add_a_photo_outlined, color: cs.onSurface.withValues(alpha: 0.55)))),
              ),
            ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 8,
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.montserrat(
                  fontWeight: FontWeight.w700,
                  fontSize: 11.5,
                  color: (bytes != null || url != null) ? Colors.white : cs.onSurface.withValues(alpha: 0.75),
                  shadows: (bytes != null || url != null)
                      ? const [Shadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, 2))]
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final (ok, err) = await _api.updateDriverProfile(
      accessToken: widget.accessToken,
      fullName: widget.fullName.trim().isEmpty ? '—' : widget.fullName.trim(),
      passportFrontBytes: _passportFrontBytes?.toList(),
      passportFrontFilename: _passportFrontName,
      passportBackBytes: _passportBackBytes?.toList(),
      passportBackFilename: _passportBackName,
      transportPhotoBytes: _transportPhotoBytes?.toList(),
      transportPhotoFilename: _transportPhotoName,
      techPassportFrontBytes: _techFrontBytes?.toList(),
      techPassportFrontFilename: _techFrontName,
      techPassportBackBytes: _techBackBytes?.toList(),
      techPassportBackFilename: _techBackName,
      permissionBytes: _permissionBytes?.toList(),
      permissionFilename: _permissionName,
      pravoBytes: _pravoBytes?.toList(),
      pravoFilename: _pravoName,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err ?? 'Ошибка')));
      return;
    }
    await widget.onSaved();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Сохранено')));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: AppColors.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TopBar(
                onBackTap: () => Navigator.of(context).pop(),
                onMenuTap: null,
                onNotificationsTap: () {},
              ),
              const SizedBox(height: 12),
              Text('Документы', style: GoogleFonts.montserrat(fontWeight: FontWeight.w900, fontSize: 22, color: cs.onSurface)),
              const SizedBox(height: 12),
              Expanded(
                child: GridView.count(
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 1.55,
                  children: [
                    _docTile(
                      title: 'Паспорт (спереди)',
                      url: _passportFrontUrl,
                      bytes: _passportFrontBytes,
                      onPick: () => _pickInto((b, n) {
                        _passportFrontBytes = b;
                        _passportFrontName = n;
                      }),
                    ),
                    _docTile(
                      title: 'Паспорт (сзади)',
                      url: _passportBackUrl,
                      bytes: _passportBackBytes,
                      onPick: () => _pickInto((b, n) {
                        _passportBackBytes = b;
                        _passportBackName = n;
                      }),
                    ),
                    _docTile(
                      title: 'Транспорт',
                      url: _transportPhotoUrl,
                      bytes: _transportPhotoBytes,
                      onPick: () => _pickInto((b, n) {
                        _transportPhotoBytes = b;
                        _transportPhotoName = n;
                      }),
                    ),
                    _docTile(
                      title: 'Техпаспорт (спереди)',
                      url: _techFrontUrl,
                      bytes: _techFrontBytes,
                      onPick: () => _pickInto((b, n) {
                        _techFrontBytes = b;
                        _techFrontName = n;
                      }),
                    ),
                    _docTile(
                      title: 'Техпаспорт (сзади)',
                      url: _techBackUrl,
                      bytes: _techBackBytes,
                      onPick: () => _pickInto((b, n) {
                        _techBackBytes = b;
                        _techBackName = n;
                      }),
                    ),
                    _docTile(
                      title: 'Доверенность',
                      url: _permissionUrl,
                      bytes: _permissionBytes,
                      onPick: () => _pickInto((b, n) {
                        _permissionBytes = b;
                        _permissionName = n;
                      }),
                    ),
                    _docTile(
                      title: 'Вод. права',
                      url: _pravoUrl,
                      bytes: _pravoBytes,
                      onPick: () => _pickInto((b, n) {
                        _pravoBytes = b;
                        _pravoName = n;
                      }),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text('Сохранить', style: GoogleFonts.montserrat(fontWeight: FontWeight.w900)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ClientProfileContent extends StatefulWidget {
  const _ClientProfileContent({
    required this.accessToken,
    required this.onLogout,
    this.onProfileDataChanged,
  });

  final String accessToken;
  final VoidCallback onLogout;
  final VoidCallback? onProfileDataChanged;

  @override
  State<_ClientProfileContent> createState() => _ClientProfileContentState();
}

class _ClientProfileContentState extends State<_ClientProfileContent> {
  static final _dateFmt = DateFormat('dd.MM.yyyy');

  final _api = const ProfileApi();
  final _fullName = TextEditingController();
  final _franchiseJoinCode = TextEditingController();
  final _picker = ImagePicker();

  bool _loading = true;
  bool _saving = false;
  bool _deleting = false;
  String? _error;
  String? _photoUrl;
  DateTime? _birthDate;
  String _phone = '';
  String _roleCode = 'client';
  String? _franchisePartnerName;
  Uint8List? _pickedBytes;
  String? _pickedName;

  @override
  void initState() {
    super.initState();
    unawaited(() async {
      final saved = await _LocalPrefs.getFranchiseJoinCode();
      if (!mounted) return;
      if (saved.isNotEmpty && _franchiseJoinCode.text.trim().isEmpty) {
        _franchiseJoinCode.text = saved;
      }
    }());
    _load();
  }

  @override
  void dispose() {
    _fullName.dispose();
    _franchiseJoinCode.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final (data, err) = await _api.fetchMeProfile(accessToken: widget.accessToken);
    if (!mounted) return;
    if (data == null) {
      setState(() {
        _loading = false;
        _error = err;
      });
      return;
    }
    final u = data['user'];
    Map<String, dynamic>? userMap;
    if (u is Map) {
      userMap = u.map((k, v) => MapEntry(k.toString(), v));
    }
    _fullName.text = (userMap?['full_name'] ?? '').toString();
    _phone = (userMap?['phone'] ?? '').toString();
    _roleCode = (userMap?['role'] ?? 'client').toString();
    _birthDate = _parseApiDateOnly(data['birth_date']);
    _photoUrl = (data['photo'] ?? '').toString().trim();
    if (_photoUrl!.isEmpty) _photoUrl = null;
    _franchisePartnerName = null;
    final fr = data['franchise'];
    if (fr is Map) {
      final n = (fr['name'] ?? '').toString().trim();
      if (n.isNotEmpty) _franchisePartnerName = n;
    }
    _franchiseJoinCode.clear();
    setState(() => _loading = false);
  }

  Future<void> _pickPhoto() async {
    try {
      final x = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        imageQuality: 88,
      );
      if (x == null || !mounted) return;
      final bytes = await x.readAsBytes();
      setState(() {
        _pickedBytes = bytes;
        _pickedName = x.name.isNotEmpty ? x.name : 'photo.jpg';
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось выбрать фото')),
      );
    }
  }

  Future<void> _pickBirthDate() async {
    final now = DateTime.now();
    final initial = _birthDate ?? DateTime(now.year - 25);
    final d = await showDatePicker(
      context: context,
      initialDate: initial.isAfter(now) ? now : initial,
      firstDate: DateTime(1900),
      lastDate: now,
      locale: const Locale('ru', 'RU'),
    );
    if (d != null && mounted) setState(() => _birthDate = d);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final (ok, err) = await _api.updateMeProfile(
      accessToken: widget.accessToken,
      fullName: _fullName.text.trim(),
      birthDate: _birthDate,
      photoBytes: _pickedBytes?.toList(),
      photoFilename: _pickedName,
      franchiseJoinCode: _franchiseJoinCode.text,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(err ?? 'Ошибка')),
      );
      return;
    }
    unawaited(_LocalPrefs.setFranchiseJoinCode(_franchiseJoinCode.text));
    setState(() {
      _pickedBytes = null;
      _pickedName = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Сохранено')),
    );
    widget.onProfileDataChanged?.call();
    await _load();
  }

  Future<void> _confirmDeleteAccount() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Удалить аккаунт?',
          style: GoogleFonts.montserrat(fontWeight: FontWeight.w800),
        ),
        content: Text(
          'Вход будет отключён. История заявок и данные останутся у администратора '
          'и не удаляются из системы. Продолжить?',
          style: GoogleFonts.montserrat(height: 1.35),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red.shade700),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _deleting = true);
    final (success, msg) = await _api.deactivateAccount(accessToken: widget.accessToken);
    if (!mounted) return;
    setState(() => _deleting = false);
    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg ?? 'Не удалось удалить аккаунт')),
      );
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Аккаунт отключён')),
    );
    widget.onLogout();
  }

  Widget _lrRow(String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: GoogleFonts.montserrat(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: GoogleFonts.montserrat(
                fontSize: 12.6,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
                height: 1.25,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: AppColors.primary));
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: GoogleFonts.montserrat(color: cs.onSurface),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _load, child: const Text('Повторить')),
            ],
          ),
        ),
      );
    }

    final birthText = _birthDate != null ? _dateFmt.format(_birthDate!) : '—';

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
      children: [
        Center(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _pickPhoto,
                  customBorder: const CircleBorder(),
                  child: CircleAvatar(
                    radius: 52,
                    backgroundColor: isDark ? cs.surface : const Color(0xFFE8F2F5),
                    backgroundImage: _pickedBytes != null
                        ? MemoryImage(_pickedBytes!)
                        : (_photoUrl != null ? NetworkImage(_photoUrl!) : null),
                    child: (_pickedBytes == null && _photoUrl == null)
                        ? Icon(
                            Icons.person_rounded,
                            size: 56,
                            color: cs.onSurface.withValues(alpha: 0.35),
                          )
                        : null,
                  ),
                ),
              ),
              Positioned(
                right: -4,
                bottom: -4,
                child: Material(
                  color: AppColors.primary,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _pickPhoto,
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(Icons.camera_alt_rounded, color: Colors.white, size: 20),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            'Нажмите на фото, чтобы изменить',
            style: GoogleFonts.montserrat(
              fontSize: 11.5,
              color: cs.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ),
        const SizedBox(height: 18),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? cs.onSurface.withValues(alpha: 0.26) : cs.primary.withValues(alpha: 0.16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'ФИО',
                style: GoogleFonts.montserrat(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface.withValues(alpha: 0.60),
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _fullName,
                textCapitalization: TextCapitalization.words,
                style: GoogleFonts.montserrat(
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface,
                  fontSize: 14,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  filled: true,
                  fillColor: isDark ? const Color(0xFF121A22) : const Color(0xFFF4F8FB),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: isDark ? cs.onSurface.withValues(alpha: 0.30) : cs.onSurface.withValues(alpha: 0.12),
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: isDark ? cs.onSurface.withValues(alpha: 0.30) : cs.onSurface.withValues(alpha: 0.12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              InkWell(
                onTap: _pickBirthDate,
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Дата рождения',
                              style: GoogleFonts.montserrat(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: cs.onSurface.withValues(alpha: 0.60),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              birthText,
                              style: GoogleFonts.montserrat(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                                color: cs.onSurface,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.edit_calendar_rounded, color: AppColors.primary.withValues(alpha: 0.85)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark ? cs.onSurface.withValues(alpha: 0.26) : cs.primary.withValues(alpha: 0.16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.badge_outlined, size: 18, color: AppColors.primary),
                  const SizedBox(width: 8),
                  Text(
                    'Аккаунт',
                    style: GoogleFonts.montserrat(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      color: cs.onSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              _lrRow('Тип аккаунта:', _accountRoleRu(_roleCode)),
              _lrRow('Телефон:', _phone.isEmpty ? '—' : _phone),
              _lrRow(
                'Партнёр (франшиза):',
                _franchisePartnerName != null && _franchisePartnerName!.trim().isNotEmpty
                    ? _franchisePartnerName!.trim()
                    : 'не указана',
              ),
              const SizedBox(height: 10),
              Text(
                'Новый код франшизы',
                style: GoogleFonts.montserrat(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface.withValues(alpha: 0.60),
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _franchiseJoinCode,
                textCapitalization: TextCapitalization.characters,
                style: GoogleFonts.montserrat(fontWeight: FontWeight.w600, fontSize: 14),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'необязательно',
                  prefixIcon: const Icon(Icons.storefront_outlined, size: 20),
                  filled: true,
                  fillColor: isDark ? const Color(0xFF121A22) : const Color(0xFFF4F8FB),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: isDark ? cs.onSurface.withValues(alpha: 0.30) : cs.onSurface.withValues(alpha: 0.12),
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: isDark ? cs.onSurface.withValues(alpha: 0.30) : cs.onSurface.withValues(alpha: 0.12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : Text('Сохранить', style: GoogleFonts.montserrat(fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: widget.onLogout,
          icon: const Icon(Icons.logout_rounded),
          label: const Text('Выйти'),
        ),
        const SizedBox(height: 20),
        Center(
          child: TextButton(
            onPressed: _deleting ? null : _confirmDeleteAccount,
            child: _deleting
                ? SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.red.shade700,
                    ),
                  )
                : Text(
                    'Удалить аккаунт',
                    style: GoogleFonts.montserrat(
                      fontWeight: FontWeight.w700,
                      color: Colors.red.shade700,
                      fontSize: 14,
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _MapPickResult {
  const _MapPickResult({required this.lat, required this.lon, required this.address});
  final double lat;
  final double lon;
  final String address;
}

class _MapPickerPage extends StatefulWidget {
  const _MapPickerPage({required this.accessToken, required this.initial});
  final String accessToken;
  final LatLng initial;

  @override
  State<_MapPickerPage> createState() => _MapPickerPageState();
}

class _MapPickerPageState extends State<_MapPickerPage> {
  final _api = const RequestsApi();
  final _mapController = MapController();
  LatLng? _selected;
  LatLng? _myLocation;
  String _address = '';
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _selected = widget.initial;
    _reverse(widget.initial);
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _goToMyLocation() async {
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _toast('Включите GPS/геолокацию');
      return;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      _toast('Нет доступа к геолокации');
      return;
    }

    try {
      final pos = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
      final ll = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _myLocation = ll;
        _selected = ll;
      });
      _mapController.move(ll, 16);
      _reverse(ll);
    } catch (_) {
      _toast('Не удалось получить местоположение');
    }
  }

  Future<void> _reverse(LatLng ll) async {
    setState(() => _loading = true);
    final name = await _api.osmReverse(
      accessToken: widget.accessToken,
      lat: ll.latitude,
      lon: ll.longitude,
    );
    if (!mounted) return;
    setState(() {
      _address = (name ?? '').trim();
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sel = _selected ?? widget.initial;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Выбор на карте'),
        actions: [
          TextButton(
            onPressed: _address.isEmpty
                ? null
                : () => Navigator.of(context).pop(
                      _MapPickResult(
                        lat: sel.latitude,
                        lon: sel.longitude,
                        address: _address,
                      ),
                    ),
            child: const Text('Готово'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: widget.initial,
                    initialZoom: 13,
                    onTap: (tapPosition, latLng) {
                      setState(() => _selected = latLng);
                      _reverse(latLng);
                    },
                  ),
                  children: [
                    // OpenStreetMap tiles
                    TileLayer(
                      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.somon.logistics',
                    ),
                    MarkerLayer(
                      markers: [
                        if (_myLocation != null)
                          Marker(
                            point: _myLocation!,
                            width: 22,
                            height: 22,
                            child: Container(
                              decoration: BoxDecoration(
                                color: Colors.blueAccent,
                                borderRadius: BorderRadius.circular(11),
                                border: Border.all(color: cs.surface, width: 2),
                              ),
                            ),
                          ),
                        Marker(
                          point: sel,
                          width: 40,
                          height: 40,
                          child: const Icon(Icons.location_on_rounded, color: AppColors.primary, size: 36),
                        ),
                      ],
                    ),
                  ],
                ),
                Positioned(
                  right: 12,
                  bottom: 12,
                  child: FloatingActionButton.small(
                    heroTag: 'my_location_fab',
                    onPressed: _goToMyLocation,
                    backgroundColor: cs.surface,
                    foregroundColor: cs.onSurface,
                    child: const Icon(Icons.my_location_rounded),
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: cs.surface),
            child: Text(
              _address.isEmpty ? 'Нажмите на карту, чтобы выбрать адрес' : _address,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.montserrat(fontWeight: FontWeight.w600, color: cs.onSurface),
            ),
          ),
        ],
      ),
    );
  }
}

class _RequestDetailRouteMapPage extends StatefulWidget {
  const _RequestDetailRouteMapPage({
    required this.accessToken,
    required this.stops,
    this.fallbackDistanceKm,
    this.requestId,
    this.trackingMode = RouteMapTrackingMode.none,
    this.shareUrl,
  });

  final String accessToken;
  final List<LatLng> stops;
  final double? fallbackDistanceKm;
  final int? requestId;
  final RouteMapTrackingMode trackingMode;
  /// Публичная ссылка для браузера (из API `tracking_share_url`).
  final String? shareUrl;

  @override
  State<_RequestDetailRouteMapPage> createState() => _RequestDetailRouteMapPageState();
}

class _RequestDetailRouteMapPageState extends State<_RequestDetailRouteMapPage> {
  final _api = const RequestsApi();
  final MapController _mapController = MapController();
  bool _loading = true;
  List<LatLng> _routePoints = const [];
  double? _routeKm;
  Timer? _pollTimer;
  StreamSubscription<Position>? _posSub;
  LatLng? _driverMarkerPos;
  double _carBearingDeg = 0;
  LatLng? _lastPosForBearing;
  double? _remainingKmHud;
  String? _roadHud;
  DateTime? _lastReverseGeo;
  /// Ҳангоми истодан дар Б stream бо distanceFilter шиддат намефиристад — барои auto-close дар сервер.
  Timer? _driverGpsHbTimer;

  @override
  void initState() {
    super.initState();
    unawaited(_fetch());
    _startTracking();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _driverGpsHbTimer?.cancel();
    _posSub?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  void _startTracking() {
    final rid = widget.requestId;
    if (rid == null || rid <= 0) return;
    if (widget.trackingMode == RouteMapTrackingMode.viewer) {
      _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) => unawaited(_pollTracking()));
      unawaited(_pollTracking());
    } else if (widget.trackingMode == RouteMapTrackingMode.driver) {
      unawaited(_startDriverGps());
    }
  }

  Future<void> _pollTracking() async {
    final rid = widget.requestId;
    if (rid == null || rid <= 0) return;
    final m = await _api.getRequestLiveTracking(accessToken: widget.accessToken, requestId: rid);
    if (!mounted || m == null) return;
    final lat = m['lat'];
    final lng = m['lng'];
    if (lat != null && lng != null) {
      final next = LatLng(double.parse(lat.toString()), double.parse(lng.toString()));
      if (_driverMarkerPos != null) {
        _carBearingDeg = _bearingBetweenLatLng(_driverMarkerPos!, next);
      }
      final rk = m['remaining_km'];
      final rh = (m['road_hint'] ?? '').toString().trim();
      setState(() {
        _driverMarkerPos = next;
        _remainingKmHud = rk == null ? null : double.tryParse(rk.toString());
        _roadHud = rh.isEmpty ? _roadHud : rh;
      });
    }
  }

  Future<void> _startDriverGps() async {
    final rid = widget.requestId;
    if (rid == null || rid <= 0) return;
    final ok = await Geolocator.isLocationServiceEnabled();
    if (!ok) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Включите геолокацию, чтобы отправлять координаты.')),
        );
      }
      return;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (!mounted) return;
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Нужен доступ к геолокации для трекинга.')),
      );
      return;
    }
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 15,
      ),
    ).listen((pos) => unawaited(_onDriverPosition(pos)));
    _driverGpsHbTimer?.cancel();
    _driverGpsHbTimer = Timer.periodic(const Duration(seconds: 28), (_) {
      unawaited(_driverGpsHeartbeat());
    });
    unawaited(_driverGpsHeartbeat());
  }

  Future<void> _driverGpsHeartbeat() async {
    final rid = widget.requestId;
    if (rid == null || rid <= 0 || !mounted) return;
    try {
      final last = await Geolocator.getLastKnownPosition();
      final Position pos =
          last ?? await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.medium);
      await _onDriverPosition(pos);
    } catch (_) {}
  }

  Future<void> _onDriverPosition(Position pos) async {
    final rid = widget.requestId;
    if (rid == null || rid <= 0) return;
    final ll = LatLng(pos.latitude, pos.longitude);
    if (_lastPosForBearing != null) {
      _carBearingDeg = _bearingBetweenLatLng(_lastPosForBearing!, ll);
    }
    _lastPosForBearing = ll;
    if (mounted) {
      setState(() => _driverMarkerPos = ll);
    }

    String? road;
    final now = DateTime.now();
    if (_lastReverseGeo == null || now.difference(_lastReverseGeo!) > const Duration(seconds: 40)) {
      _lastReverseGeo = now;
      road = await _api.osmReverse(
        accessToken: widget.accessToken,
        lat: pos.latitude,
        lon: pos.longitude,
      );
      if (road != null && road.length > 420) {
        road = road.substring(0, 420);
      }
    }

    final res = await _api.postDriverRequestLocation(
      accessToken: widget.accessToken,
      requestId: rid,
      lat: pos.latitude,
      lng: pos.longitude,
      roadHint: road,
    );
    if (!mounted || res == null) return;
    if (res['success'] == true) {
      final rk = res['remaining_km'];
      final rh = (res['road_hint'] ?? '').toString().trim();
      setState(() {
        _remainingKmHud = rk == null ? null : double.tryParse(rk.toString());
        if (rh.isNotEmpty) _roadHud = rh;
      });
    }
  }

  Future<void> _fetch() async {
    final (km, pts) = await _api.roadDistanceWithRoute(
      accessToken: widget.accessToken,
      points: widget.stops,
    );
    if (!mounted) return;
    final poly = pts.length >= 2 ? pts : widget.stops;
    setState(() {
      _loading = false;
      _routeKm = km ?? widget.fallbackDistanceKm;
      _routePoints = poly;
    });
  }

  LatLngBounds _mapBounds(List<LatLng> polyPoints) {
    final pts = <LatLng>[...polyPoints];
    if (_driverMarkerPos != null) {
      pts.add(_driverMarkerPos!);
    }
    if (pts.length >= 2) {
      return LatLngBounds.fromPoints(pts);
    }
    if (pts.length == 1) {
      final p = pts.first;
      return LatLngBounds(
        LatLng(p.latitude - 0.02, p.longitude - 0.02),
        LatLng(p.latitude + 0.02, p.longitude + 0.02),
      );
    }
    return LatLngBounds(const LatLng(38.55, 68.75), const LatLng(38.60, 68.82));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final polyPoints = _routePoints.length >= 2 ? _routePoints : widget.stops;
    final bounds = _mapBounds(polyPoints);

    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        surfaceTintColor: Colors.transparent,
        foregroundColor: cs.onSurface,
        title: Text(
          'Маршрут по карте',
          style: GoogleFonts.montserrat(fontWeight: FontWeight.w700, fontSize: 17),
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCameraFit: CameraFit.bounds(
                  bounds: bounds,
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 120),
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.somon.logistics',
                ),
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: polyPoints,
                      strokeWidth: 4,
                      color: AppColors.primary,
                    ),
                  ],
                ),
                MarkerLayer(
                  markers: [
                    for (int i = 0; i < widget.stops.length; i++)
                      Marker(
                        point: widget.stops[i],
                        width: 30,
                        height: 30,
                        child: Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: i == 0
                                ? Colors.green
                                : (i == widget.stops.length - 1 ? Colors.redAccent : AppColors.primary),
                            borderRadius: BorderRadius.circular(15),
                            border: Border.all(color: cs.surface, width: 2),
                          ),
                          child: Text(
                            '${i + 1}',
                            style: GoogleFonts.montserrat(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                    if (_driverMarkerPos != null)
                      Marker(
                        point: _driverMarkerPos!,
                        width: 48,
                        height: 48,
                        alignment: Alignment.center,
                        child: Transform.rotate(
                          angle: _carBearingDeg * math.pi / 180.0,
                          child: Icon(
                            Icons.local_shipping_rounded,
                            size: 40,
                            color: AppColors.navy,
                            shadows: const [Shadow(color: Colors.white, blurRadius: 6)],
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          Positioned(
            top: 10,
            right: 10,
            child: Material(
              elevation: 6,
              borderRadius: BorderRadius.circular(14),
              color: cs.surface,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if ((widget.shareUrl ?? '').trim().isNotEmpty)
                    IconButton(
                      tooltip: 'Поделиться ссылкой (браузер)',
                      onPressed: () async {
                        final u = widget.shareUrl!.trim();
                        await Share.share(u, subject: 'Трекинг доставки Somon');
                      },
                      icon: Icon(Icons.share_rounded, color: AppColors.primary),
                    ),
                  IconButton(
                    tooltip: widget.trackingMode == RouteMapTrackingMode.viewer
                        ? 'Показать машину на карте (зум 13)'
                        : 'К моей позиции на карте',
                    onPressed: () {
                      final p = _driverMarkerPos;
                      if (p != null) {
                        final zoom = widget.trackingMode == RouteMapTrackingMode.viewer
                            ? 13.0
                            : 14.0;
                        _mapController.move(p, zoom);
                      } else {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Позиция водителя ещё не получена')),
                        );
                      }
                    },
                    icon: Icon(
                      widget.trackingMode == RouteMapTrackingMode.viewer
                          ? Icons.local_shipping_rounded
                          : Icons.my_location_rounded,
                      color: AppColors.primary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_loading)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x99FFFFFF),
                child: Center(child: CircularProgressIndicator(color: AppColors.primary)),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Material(
              elevation: 10,
              color: Colors.white,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _routeKm == null
                            ? 'Линия маршрута по дорогам (если сервер вернёт точки)'
                            : 'Расстояние по маршруту: ${_routeKm!.toStringAsFixed(2)} км',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.montserrat(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          color: AppColors.navy,
                        ),
                      ),
                      if (_remainingKmHud != null) ...[
                        const SizedBox(height: 6),
                        Text(
                          'До точки назначения ≈ ${_remainingKmHud!.toStringAsFixed(2)} км (по прямой)',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.montserrat(
                            fontWeight: FontWeight.w800,
                            fontSize: 12.5,
                            color: AppColors.primary,
                          ),
                        ),
                      ],
                      if (_roadHud != null && _roadHud!.trim().isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          _roadHud!,
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.montserrat(
                            fontWeight: FontWeight.w600,
                            fontSize: 11.5,
                            color: AppColors.navy.withValues(alpha: 0.85),
                            height: 1.25,
                          ),
                        ),
                      ],
                      if (widget.trackingMode == RouteMapTrackingMode.driver) ...[
                        const SizedBox(height: 6),
                        Text(
                          'GPS отправляется на сервер (водитель).',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.montserrat(fontSize: 10.5, color: cs.onSurface.withValues(alpha: 0.55)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoutePreviewPage extends StatelessWidget {
  const _RoutePreviewPage({
    required this.from,
    required this.to,
    required this.fromLabel,
    required this.toLabel,
    required this.distanceKm,
    required this.routePoints,
    required this.stops,
  });

  final LatLng from;
  final LatLng to;
  final String fromLabel;
  final String toLabel;
  final double? distanceKm;
  final List<LatLng> routePoints;
  final List<LatLng> stops;

  @override
  Widget build(BuildContext context) {
    final polyPoints = routePoints.length >= 2 ? routePoints : [from, to];
    final bounds = LatLngBounds.fromPoints(polyPoints);
    final size = MediaQuery.of(context).size;
    return Dialog(
      insetPadding: EdgeInsets.symmetric(
        horizontal: size.width * 0.10,
        vertical: size.height * 0.10,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: size.width * 0.80,
        height: size.height * 0.80,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      distanceKm == null ? 'Маршрут A → B' : 'Маршрут A → B (${distanceKm!.toStringAsFixed(2)} км)',
                      style: GoogleFonts.montserrat(fontWeight: FontWeight.w700, color: AppColors.navy),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Expanded(
              child: FlutterMap(
                options: MapOptions(
                  initialCameraFit: CameraFit.bounds(
                    bounds: bounds,
                    padding: const EdgeInsets.all(28),
                  ),
                ),
                children: [
                  TileLayer(
                    urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'com.somon.logistics',
                  ),
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: polyPoints,
                        strokeWidth: 4,
                        color: AppColors.primary,
                      ),
                    ],
                  ),
                  MarkerLayer(
                    markers: [
                      for (int i = 0; i < (stops.isNotEmpty ? stops.length : 2); i++)
                        Marker(
                          point: stops.isNotEmpty ? stops[i] : (i == 0 ? from : to),
                          width: 30,
                          height: 30,
                          child: Container(
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: i == 0
                                  ? Colors.green
                                  : (i == (stops.isNotEmpty ? stops.length - 1 : 1)
                                      ? Colors.redAccent
                                      : AppColors.primary),
                              borderRadius: BorderRadius.circular(15),
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                            child: Text(
                              '${i + 1}',
                              style: GoogleFonts.montserrat(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('A: $fromLabel', maxLines: 1, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  Text('B: $toLabel', maxLines: 1, overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// _SimpleTile removed (was demo-only)
