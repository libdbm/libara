/// Attributed Range Algebra: sequences, ranges over them, and attributed
/// ranges for modelling markup outside the data it describes.
library;

export 'src/attributed/attributed.dart' hide alike;
export 'src/format/format.dart' hide read, write;
export 'src/constructor/constructor.dart';
export 'src/coordinate/coordinate.dart';
export 'src/layered/layered.dart' hide Projections, check, mapped, spliced;
export 'src/range/range.dart' hide Hierarchy, extent, outside;
export 'src/persistent/persistent.dart' hide DocumentMeasures;
export 'src/replica/replica.dart' hide Clock;
export 'src/selector/selector.dart';
export 'src/sequence/sequence.dart';
