/// Live / VOD / series category from Xtream `get_*_categories`.
class MediaCategory {
  const MediaCategory({
    required this.categoryId,
    required this.categoryName,
    this.parentId = 0,
  });

  final String categoryId;
  final String categoryName;
  final int parentId;

  factory MediaCategory.fromJson(Map<String, dynamic> json) {
    return MediaCategory(
      categoryId: '${json['category_id'] ?? ''}',
      categoryName: '${json['category_name'] ?? ''}',
      parentId: _asInt(json['parent_id']),
    );
  }

  Map<String, dynamic> toJson() => {
        'category_id': categoryId,
        'category_name': categoryName,
        'parent_id': parentId,
      };
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is String) return int.tryParse(value) ?? 0;
  return 0;
}
