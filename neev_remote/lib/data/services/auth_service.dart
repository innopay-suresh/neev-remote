import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:hashlib/hashlib.dart';

/// Produces Argon2id password hashes in the exact wire format the Go
/// signaling server expects.
///
/// The Go agent ([agent/auth/auth.go]) encodes a hash as:
///
///   base64(salt) + ":" + base64(argon2idKey)
///
/// with parameters time=1, memory=64MiB, threads=4, keyLen=32, saltLen=16.
/// The server's `VerifyPassword` re-derives the key from the supplied
/// plaintext using the embedded salt and compares — so any salt works as
/// long as these parameters match.
class AuthService {
  // Must mirror agent/auth/auth.go.
  static const int _time = 1; // iterations
  static const int _memoryKiB = 64 * 1024; // 64 MiB
  static const int _threads = 4; // parallelism
  static const int _keyLen = 32;
  static const int _saltLen = 16;

  static final Random _rng = Random.secure();

  /// Hashes [password] into the `base64(salt):base64(hash)` format used by the
  /// host agent when registering with the signaling server.
  static String hashPassword(String password) {
    final salt = Uint8List(_saltLen);
    for (var i = 0; i < _saltLen; i++) {
      salt[i] = _rng.nextInt(256);
    }

    final digest = Argon2(
      type: Argon2Type.argon2id,
      version: Argon2Version.v13,
      parallelism: _threads,
      memorySizeKB: _memoryKiB,
      iterations: _time,
      hashLength: _keyLen,
      salt: salt,
    ).convert(utf8.encode(password));

    return '${base64.encode(salt)}:${base64.encode(digest.bytes)}';
  }

  /// Generates a random session password matching the agent's alphabet
  /// (ambiguous characters removed) — see `GenerateRandomPassword` in Go.
  static String generatePassword({int length = 8}) {
    const chars =
        'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789';
    return List.generate(length, (_) => chars[_rng.nextInt(chars.length)])
        .join();
  }
}
