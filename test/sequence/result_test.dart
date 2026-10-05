import 'package:libara/src/sequence/result.dart';
import 'package:test/test.dart';

void main() {
  group('Success', () {
    test('map transforms the value', () {
      final Result<int> result = Success(2);
      expect(result.map((value) => value * 3), Success<int>(6));
    });

    test('flatMap chains to the next result', () {
      final Result<int> result = Success(2);
      expect(
        result.flatMap((value) => Success<String>('$value')),
        Success<String>('2'),
      );
    });

    test('or returns the value, ignoring the fallback', () {
      final Result<int> result = Success(2);
      expect(result.or(9), 2);
    });

    test('fold calls the success branch', () {
      final Result<int> result = Success(2);
      expect(result.fold((value) => 'ok $value', (failure) => 'no'), 'ok 2');
    });
  });

  group('Failure', () {
    test('map keeps the failure', () {
      final Result<int> result = Failure(Kind.missing, 'gone');
      expect(
        result.map((value) => value * 3),
        Failure<int>(Kind.missing, 'gone'),
      );
    });

    test('flatMap keeps the failure and never calls the function', () {
      final Result<int> result = Failure(Kind.missing, 'gone');
      var called = false;
      final chained = result.flatMap((value) {
        called = true;
        return Success<String>('$value');
      });
      expect(chained, Failure<String>(Kind.missing, 'gone'));
      expect(called, isFalse);
    });

    test('or returns the fallback', () {
      final Result<int> result = Failure(Kind.missing, 'gone');
      expect(result.or(9), 9);
    });

    test('fold calls the failure branch', () {
      final Result<int> result = Failure(Kind.missing, 'gone');
      expect(
        result.fold((value) => 'ok', (failure) => failure.message),
        'gone',
      );
    });

    test('equality is by kind and message', () {
      expect(Failure<int>(Kind.bounds, 'x'), Failure<int>(Kind.bounds, 'x'));
      expect(
        Failure<int>(Kind.bounds, 'x'),
        isNot(Failure<int>(Kind.invalid, 'x')),
      );
      expect(
        Failure<int>(Kind.bounds, 'x'),
        isNot(Failure<int>(Kind.bounds, 'y')),
      );
    });

    test('bounds builds a consistent message', () {
      final failure = Failure<int>.bounds('insert', 7);
      expect(failure.kind, Kind.bounds);
      expect(failure.message, 'insert: position 7 is out of bounds');
    });
  });

  test('Success equality is by value', () {
    expect(Success<int>(1), Success<int>(1));
    expect(Success<int>(1), isNot(Success<int>(2)));
  });

  test('Success hashCode agrees with equality', () {
    expect(Success<int>(1).hashCode, Success<int>(1).hashCode);
  });

  test('Failure hashCode agrees with equality', () {
    expect(
      Failure<int>(Kind.bounds, 'x').hashCode,
      Failure<int>(Kind.bounds, 'x').hashCode,
    );
  });

  test('toString names the case and its contents', () {
    expect(Success<int>(1).toString(), 'Success(1)');
    expect(Failure<int>(Kind.bounds, 'x').toString(), 'Failure(bounds: x)');
  });

  group('or through a wider static type', () {
    test('a Success held as a supertype returns its value', () {
      final Result<num> result = Success<int>(1);
      expect(result.or(1.5), 1);
    });

    test('a Failure held as a supertype accepts a supertype fallback', () {
      final Result<num> result = Failure<int>(Kind.missing, 'gone');
      expect(result.or(1.5), 1.5);
    });
  });
}
