import 'dart:convert';
import 'dart:io';

String decodeCoreOutput(List<int> bytes, {Encoding? fallback}) {
  try {
    return utf8.decode(bytes);
  } on FormatException {
    final encoding = fallback ?? (Platform.isWindows ? systemEncoding : null);
    return encoding?.decode(bytes) ?? utf8.decode(bytes, allowMalformed: true);
  }
}

Stream<String> coreOutputLines(Stream<List<int>> bytes) =>
    bytes.transform(latin1.decoder).transform(const LineSplitter()).map((line) {
      final raw = latin1.encode(line);
      try {
        return decodeCoreOutput(raw);
      } on FormatException {
        return utf8.decode(raw, allowMalformed: true);
      }
    });
