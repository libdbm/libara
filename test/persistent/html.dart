import 'dart:math';

/// One generated element: where it starts and ends in the text, and where
/// its start and end tags sit.
typedef Element = ({
  String name,
  int start,
  int end,
  int open,
  int close,
  int depth,
});

/// A deterministic simulated HTML document: nested elements with word text,
/// plus one chain of [chain] directly nested divs.
final class Html {
  Html._(this.text, this.elements);

  /// Generates roughly [target] elements from [seed], nesting at most
  /// [depth] levels except for the deep chain.
  factory Html.generate({
    required int seed,
    required int target,
    int depth = 12,
    int chain = 500,
  }) {
    final random = Random(seed);
    final buffer = StringBuffer();
    final elements = <Element>[];
    const names = ['div', 'p', 'span', 'em', 'a', 'section', 'ul', 'li', 'b'];
    const words = [
      'lorem',
      'ipsum',
      'dolor',
      'sit',
      'amet',
      'consectetur',
      'adipiscing',
      'elit',
    ];

    void words3() {
      for (var count = random.nextInt(4); count > 0; count--) {
        buffer
          ..write(words[random.nextInt(words.length)])
          ..write(' ');
      }
    }

    void element(String name, int level, void Function() body) {
      final start = buffer.length;
      buffer.write('<$name>');
      final open = buffer.length - start;
      body();
      final close = buffer.length;
      buffer.write('</$name>');
      elements.add((
        name: name,
        start: start,
        end: buffer.length,
        open: open,
        close: buffer.length - close,
        depth: level,
      ));
    }

    void tree(int level) {
      element(names[random.nextInt(names.length)], level, () {
        words3();
        if (level < depth) {
          for (
            var count = random.nextInt(5);
            count > 0 && elements.length < target;
            count--
          ) {
            tree(level + 1);
            words3();
          }
        }
      });
    }

    void nest(int level) {
      element('div', level, () {
        if (level < chain) {
          nest(level + 1);
        } else {
          words3();
        }
      });
    }

    element('html', 0, () {
      element('body', 1, () {
        while (elements.length < target ~/ 2) {
          tree(2);
        }
        nest(2);
        while (elements.length < target) {
          tree(2);
        }
      });
    });
    return Html._(buffer.toString(), elements);
  }

  /// The document text.
  final String text;

  /// Every element, in the order its end tag was written.
  final List<Element> elements;
}
