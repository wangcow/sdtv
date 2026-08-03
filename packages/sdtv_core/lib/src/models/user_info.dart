/// Subset of Xtream auth / account payload.
class UserInfo {
  const UserInfo({
    required this.username,
    required this.status,
    this.expDate,
    this.isTrial = false,
    this.activeConnections,
    this.maxConnections,
  });

  final String username;
  final String status;
  final String? expDate;
  final bool isTrial;
  final String? activeConnections;
  final String? maxConnections;

  /// Many panels return `Active`; some omit status when OK.
  bool get isActive {
    final s = status.toLowerCase().trim();
    if (s.isEmpty) return true;
    return s == 'active' || s == 'true' || s == '1';
  }

  factory UserInfo.fromPlayerApiJson(Map<String, dynamic> root) {
    final user = root['user_info'];
    final map = user is Map<String, dynamic>
        ? user
        : (user is Map ? Map<String, dynamic>.from(user) : <String, dynamic>{});

    return UserInfo(
      username: '${map['username'] ?? ''}',
      status: '${map['status'] ?? ''}',
      expDate: map['exp_date']?.toString(),
      isTrial: _asBool(map['is_trial']),
      activeConnections: map['active_cons']?.toString(),
      maxConnections: map['max_connections']?.toString(),
    );
  }
}

bool _asBool(Object? value) {
  if (value is bool) return value;
  if (value is int) return value != 0;
  if (value is String) {
    final v = value.toLowerCase();
    return v == '1' || v == 'true' || v == 'yes';
  }
  return false;
}
