/// Failure talking to an Xtream Codes endpoint.
class XtreamException implements Exception {
  XtreamException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() =>
      statusCode == null ? 'XtreamException: $message' : 'XtreamException($statusCode): $message';
}
