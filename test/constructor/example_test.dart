import 'package:libara/src/attributed/attributed.dart';
import 'package:libara/src/constructor/constructor.dart';
import 'package:libara/src/range/range.dart';
import 'package:libara/src/sequence/sequence.dart';
import 'package:test/test.dart';

import '../support.dart';

List<String> notation(Result<Ranges> result) => result.fold(
  (ranges) => [for (final range in ranges.items) '$range'],
  (failure) => ['$failure'],
);

void main() {
  group('the word constructor from the Range Constructors draft', () {
    final text = Text.of("That's Anne-Marie?!");

    test('gives the paper four ranges', () {
      final words = regex(
        RegExp('[a-zA-Z]+'),
        attributes: {'type': Value.of('word').unwrap()},
      );
      expect(notation(words(text)), [
        '{0,4,type:word}',
        '{5,1,type:word}',
        '{7,4,type:word}',
        '{12,5,type:word}',
      ]);
    });

    test('the paper context pattern, written with lookarounds, agrees', () {
      final plain = regex(RegExp('[a-zA-Z]+'));
      final context = regex(RegExp('(?<![a-zA-Z])[a-zA-Z]+(?![a-zA-Z])'));
      expect(context(text), plain(text));
    });
  });

  group('the day example from the Range Constructors draft', () {
    Constructor<int> day(String pattern, String name) => regex(
      RegExp(pattern),
      attributes: {'pattern': Value.of(name).unwrap()},
    );
    final any = day(r'\w*day', 'any');
    final tuesFri = day('(Tues|Fri)day', 'tuesfri');
    final monWednes = day('(Mon|Wednes)day', 'monwednes');
    final text = Text.of('Monday Friday');

    test('union keeps overlapping ranges from different patterns', () {
      expect(notation(union([any, tuesFri, monWednes])(text)), [
        '{0,6,pattern:any}',
        '{0,6,pattern:monwednes}',
        '{7,6,pattern:any}',
        '{7,6,pattern:tuesfri}',
      ]);
    });

    test('union removes a range produced twice with equal attributes', () {
      expect(
        union([any, tuesFri, monWednes, any])(text),
        union([any, tuesFri, monWednes])(text),
      );
      expect(
        concat([any, tuesFri, monWednes, any])(text).or(Ranges.empty()).length,
        6,
      );
    });
  });

  group('the layers from the attributed range algebra paper', () {
    final text = Text.of('<P>THE @I{CAT} UNDER THE HAT.{/P]');

    Constructor<int> tag(String pattern, String type, String label) => regex(
      RegExp(pattern),
      attributes: {
        'type': Value.of(type).unwrap(),
        'label': Value.of(label).unwrap(),
      },
    );

    final lexical = union([
      tag('<P>', 'stag', 'P'),
      tag(r'@I\{', 'stag', 'I'),
      tag(r'\}', 'etag', 'I'),
      tag(r'\{/P\]', 'etag', 'P'),
    ]);

    /// Pairs each start tag with the next end tag of the same label, giving
    /// one element per pair, positioned by token index.
    Ranges elements(Ranges tokens) {
      final open = <(int, Value)>[];
      final found = <ARange>[];
      for (final (index, token) in tokens.items.cast<ARange>().indexed) {
        final label = token.get('label')!;
        if (token.get('type') == Value.of('stag').unwrap()) {
          open.add((index, label));
        } else {
          final start = open.lastIndexWhere((entry) => entry.$2 == label);
          found.add(
            tagged(
              open[start].$1,
              index - open[start].$1 + 1,
              attributes: {'type': Value.of('elem').unwrap(), 'label': label},
            ),
          );
          open.removeAt(start);
        }
      }
      return Ranges.of(found).startOrder();
    }

    test('four tag constructors give the lexical layer', () {
      expect(notation(lexical(text)), [
        '{0,3,label:P,type:stag}',
        '{7,3,label:I,type:stag}',
        '{13,1,label:I,type:etag}',
        '{29,4,label:P,type:etag}',
      ]);
    });

    test('a layer over it gives the application layer, indexed by token', () {
      final application = layer(lexical, elements)(text).or(Ranges.empty());
      expect(notation(Success(application)), [
        '{0,4,label:P,type:elem}',
        '{1,2,label:I,type:elem}',
      ]);
      final first = application.item(0)!;
      final second = application.item(1)!;
      expect(application.parent(second), first);
    });
  });
}
