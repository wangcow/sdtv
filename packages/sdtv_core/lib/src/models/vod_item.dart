/// Xtream VOD (`get_vod_streams`) row.
class VodItem {
  const VodItem({
    required this.streamId,
    required this.name,
    required this.categoryId,
    this.streamIcon = '',
    this.containerExtension = 'mp4',
    this.plot = '',
    this.rating = '',
    this.durationSecs = 0,
    this.num = 0,
  });

  final int streamId;
  final String name;
  final String categoryId;
  final String streamIcon;
  final String containerExtension;
  final String plot;
  final String rating;
  final int durationSecs;
  final int num;

  String get favoriteKey => streamId != 0 ? 'v:$streamId' : 'vn:${name.trim().toLowerCase()}|$categoryId';

  factory VodItem.fromJson(Map<String, dynamic> json) {
    return VodItem(
      streamId: _asInt(json['stream_id']),
      name: '${json['name'] ?? ''}',
      categoryId: '${json['category_id'] ?? ''}',
      streamIcon: '${json['stream_icon'] ?? json['cover'] ?? ''}',
      containerExtension: _ext(json['container_extension']),
      plot: '${json['plot'] ?? ''}',
      rating: '${json['rating'] ?? json['rating_5based'] ?? ''}',
      durationSecs: _asInt(json['duration_secs'] ?? json['episode_run_time']),
      num: _asInt(json['num']),
    );
  }

  Map<String, dynamic> toJson() => {
        'stream_id': streamId,
        'name': name,
        'category_id': categoryId,
        'stream_icon': streamIcon,
        'container_extension': containerExtension,
        'plot': plot,
        'rating': rating,
        'duration_secs': durationSecs,
        'num': num,
      };

  static String _ext(Object? raw) {
    final s = '${raw ?? 'mp4'}'.trim().replaceAll('.', '');
    return s.isEmpty ? 'mp4' : s;
  }
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
