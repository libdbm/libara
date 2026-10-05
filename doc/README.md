# libara documentation

The [README](../README.md) introduces the library and its API. These pages
go further.

- [Theory](theory.md): the problem with markup embedded in data, and the
  model the reference papers define: Core Range Algebra, Range
  Constructors, and Attributed Range Algebra, with Allen's interval
  algebra cast as compositions of range operations. It ends with where
  libara follows, corrects, and extends them, and a consolidated
  bibliography.
- [Architecture](architecture.md): the modules and their dependencies,
  the conventions they share, and the structure of a document, a layered
  document, and a replica.
- [Algorithms](algorithms.md): how each part works and what it costs:
  persistent treaps, endpoint trees, labels, gravity, the containment
  sweep, incremental derivation of layers, selector evaluation, and
  replica merging.
- [Example](example.md): a melody as a sequence of notes, where bars and
  phrases overlap, from `example/music/main.dart`.

