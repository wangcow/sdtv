/// Live TV stream entry from Xtream `get_live_streams` or M3U `#EXTINF`.
class LiveChannel {
  const LiveChannel({
    required this.streamId,
    required this.name,
    required this.categoryId,
    this.streamIcon = '',
    this.epgChannelId = '',
    this.num = 0,
    this.streamUrl,
  });

  final int streamId;
  final String name;
  final String categoryId;
  final String streamIcon;
  final String epgChannelId;
  final int num;

  /// Direct play URL (M3U). When null, Xtream builds the URL at play time.
  final String? streamUrl;

  bool get hasDirectUrl =>
      streamUrl != null && streamUrl!.trim().isNotEmpty;

  factory LiveChannel.fromJson(Map<String, dynamic> json) {
    return LiveChannel(
      streamId: _asInt(json['stream_id']),
      name: '${json['name'] ?? ''}',
      categoryId: '${json['category_id'] ?? ''}',
      streamIcon: '${json['stream_icon'] ?? ''}',
      epgChannelId: '${json['epg_channel_id'] ?? ''}',
      num: _asInt(json['num']),
      streamUrl: json['stream_url']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'stream_id': streamId,
        'name': name,
        'category_id': categoryId,
        'stream_icon': streamIcon,
        'epg_channel_id': epgChannelId,
        'num': num,
        if (streamUrl != null) 'stream_url': streamUrl,
      };
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
