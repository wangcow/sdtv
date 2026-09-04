import 'dart:io';

import 'package:flutter/material.dart';

import '../../services/artwork_cache.dart';

/// Loads provider art through [ArtworkCache]; shows [placeholder] until ready.
class CachedArtwork extends StatefulWidget {
  const CachedArtwork({
    super.key,
    required this.cache,
    required this.scope,
    required this.kind,
    required this.id,
    required this.url,
    required this.placeholder,
    this.fit = BoxFit.contain,
  });

  final ArtworkCache cache;
  final String scope;
  final String kind;
  final String id;
  final String url;
  final Widget placeholder;
  final BoxFit fit;

  @override
  State<CachedArtwork> createState() => _CachedArtworkState();
}

class _CachedArtworkState extends State<CachedArtwork> {
  File? _file;
  Object? _token;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CachedArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.id != widget.id ||
        oldWidget.scope != widget.scope) {
      _file = null;
      _load();
    }
  }

  void _load() {
    final url = widget.url.trim();
    if (url.isEmpty) return;
    final token = Object();
    _token = token;
    widget.cache
        .getFile(
          scope: widget.scope,
          kind: widget.kind,
          id: widget.id,
          url: url,
        )
        .then((file) {
      if (!mounted || !identical(_token, token)) return;
      setState(() => _file = file);
    });
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    if (file == null) return widget.placeholder;
    return Image.file(
      file,
      fit: widget.fit,
      alignment: Alignment.topCenter,
      width: double.infinity,
      height: double.infinity,
      errorBuilder: (_, _, _) => widget.placeholder,
      filterQuality: FilterQuality.medium,
    );
  }
}
