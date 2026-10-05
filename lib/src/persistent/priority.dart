/// Pseudo-random treap priorities from a fixed seed.
///
/// A counter mixed through a 32-bit hash gives every node a well spread
/// priority, and the same sequence on every run, so trees and results are
/// deterministic, on the native VM and on the web alike.
int _counter = 0x2545F491;

/// The next priority, a non-negative 31-bit integer.
int priority() => mix(_counter = (_counter + 0x9E3779B9) & 0xFFFFFFFF);

/// The 32-bit [value] hashed to a non-negative 31-bit integer.
int mix(int value) {
  var hashed = _multiply(value ^ (value >> 16), 0x85EBCA6B);
  hashed = _multiply(hashed ^ (hashed >> 13), 0xC2B2AE35);
  return (hashed ^ (hashed >> 16)) & 0x7FFFFFFF;
}

/// The low 32 bits of [a] times [b], for 32-bit [a] and [b].
///
/// Multiplies in 16-bit halves so no intermediate exceeds 2^48. On the web
/// integers are doubles, exact only below 2^53, and a full 32-by-32-bit
/// product would lose its low bits.
int _multiply(int a, int b) {
  final low = (a & 0xFFFF) * b;
  final high = ((a >> 16) * b) & 0xFFFF;
  return (low + high * 0x10000) & 0xFFFFFFFF;
}
