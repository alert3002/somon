// Филтрҳои рӯйхати заявкаҳо (ҳамоҳанг бо Request.status дар backend).

/// Барои «Главная»: танҳо заявкаҳо бо статуси [active].
bool isRequestActiveOnClientHome(String? statusCode) {
  return (statusCode ?? '').toString().toLowerCase().trim() == 'active';
}

String normRequestStatusCode(dynamic raw) => (raw ?? '').toString().toLowerCase().trim();

/// Нишон додани тугмаи «поделиться» треком — вақте ки маршрут амалӣ аст ё интизор аст.
bool showClientTrackingShareForStatus(String? status) {
  final s = (status ?? '').toLowerCase();
  return s == 'active' ||
      s == 'awaiting_confirmation' ||
      s == 'awaiting' ||
      s == 'in_transit';
}
