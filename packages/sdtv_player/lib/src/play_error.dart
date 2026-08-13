/// Couch-visible play error: short code + line.
///
/// `E` + HTTP status = provider/network.
/// `A-` = sdtv / mpv process (not the panel).
class SdtvPlayError {
  const SdtvPlayError(this.code, this.message);

  final String code;
  final String message;

  /// e.g. `E403  HTTP 403 Forbidden`
  String get line => '$code  $message';

  @override
  String toString() => line;
}

/// Map mpv stderr (and optional stall probe) to a [SdtvPlayError].
SdtvPlayError classifyPlayError(
  String logBlob, {
  String? stallKind,
}) {
  final blob = logBlob.toLowerCase();

  if (RegExp(r'\b403\b|http error 403|forbidden').hasMatch(blob)) {
    return const SdtvPlayError('E403', 'HTTP 403 Forbidden');
  }
  if (RegExp(r'\b401\b|unauthorized').hasMatch(blob)) {
    return const SdtvPlayError('E401', 'HTTP 401 Unauthorized');
  }
  if (RegExp(r'\b404\b|not found').hasMatch(blob)) {
    return const SdtvPlayError('E404', 'HTTP 404 Not Found');
  }
  if (RegExp(r'\b502\b').hasMatch(blob)) {
    return const SdtvPlayError('E502', 'HTTP 502 Bad Gateway');
  }
  if (RegExp(r'\b503\b').hasMatch(blob)) {
    return const SdtvPlayError('E503', 'HTTP 503 Unavailable');
  }
  if (RegExp(r'\b504\b').hasMatch(blob)) {
    return const SdtvPlayError('E504', 'HTTP 504 Gateway Timeout');
  }
  if (blob.contains('ssl') || blob.contains('certificate')) {
    return const SdtvPlayError('E-TLS', 'TLS/SSL error');
  }
  if (blob.contains('timed out') || blob.contains('timeout')) {
    return const SdtvPlayError('E-TMO', 'Connection timed out');
  }
  if (blob.contains('connection refused') ||
      blob.contains('network is unreachable') ||
      blob.contains('no route to host')) {
    return const SdtvPlayError('E-NET', 'Network error');
  }
  if (blob.contains('no decoder') ||
      (blob.contains('codec') && blob.contains('error'))) {
    return const SdtvPlayError('E-DEC', 'Codec / decode error');
  }
  if (blob.contains('failed to recognize file format') ||
      blob.contains('failed to open') ||
      blob.contains('error opening') ||
      blob.contains('opening failed')) {
    return const SdtvPlayError('E-OPEN', 'Failed to open stream');
  }

  switch (stallKind) {
    case 'cache':
      return const SdtvPlayError('A-BUF', 'Buffering timed out');
    case 'eof':
      return const SdtvPlayError('A-EOF', 'Stream ended');
    case 'idle':
      return const SdtvPlayError('A-IDLE', 'Player idle (no file)');
    case 'core-idle':
      return const SdtvPlayError('A-HOLD', 'Playback stopped');
    case 'clock':
      return const SdtvPlayError('A-STALL', 'Clock frozen');
    case 'mpv-missing':
      return const SdtvPlayError('A-MPV', 'mpv failed to start');
    case 'ipc':
      return const SdtvPlayError('A-IPC', 'Lost mpv control');
  }

  return const SdtvPlayError('A-UNK', 'Playback failed');
}
