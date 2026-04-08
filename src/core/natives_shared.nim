## Shared native function arity table.
## Single source of truth for how many arguments each built-in consumes.
## Used by both the emitter (prescan + argument consumption) and potentially
## the interpreter (validation).

let nativeArities*: seq[tuple[name: string, arity: int]] = @[
  # Output
  ("print", 1), ("probe", 1), ("assert", 1),
  # Control flow
  ("if", 2), ("either", 3), ("unless", 2), ("not", 1),
  ("return", 1), ("break", 0),
  # Type introspection
  ("type", 1), ("is?", 2),
  # Series
  ("size?", 1), ("length?", 1), ("empty?", 1),
  ("first", 1), ("second", 1), ("last", 1), ("pick", 2),
  ("append", 2), ("copy", 1), ("select", 2), ("has?", 2),
  ("find", 2), ("reverse", 1), ("insert", 3), ("remove", 2),
  # String ops
  ("join", 2), ("rejoin", 1), ("trim", 1),
  ("uppercase", 1), ("lowercase", 1),
  ("split", 2), ("replace", 3), ("substring", 3),
  ("starts-with?", 2), ("ends-with?", 2),
  ("byte", 1), ("char", 1),
  # Math
  ("abs", 1), ("negate", 1), ("min", 2), ("max", 2),
  ("round", 1), ("odd?", 1), ("even?", 1),
  ("sqrt", 1), ("sin", 1), ("cos", 1), ("tan", 1),
  ("asin", 1), ("acos", 1), ("atan2", 2), ("pow", 2),
  ("exp", 1), ("log", 1), ("log10", 1),
  ("to-degrees", 1), ("to-radians", 1),
  ("floor", 1), ("ceil", 1), ("random", 1),
  # Block evaluation
  ("reduce", 1), ("all", 1), ("any", 1),
  # Function creation
  ("function", 2), ("does", 1),
  # Context/Object
  ("context", 1), ("scope", 1), ("words-of", 1),
  # Type conversion
  ("to", 2),
  # Apply/Sort/Set
  ("apply", 2), ("sort", 1), ("set", 2),
  # Error handling
  ("error", 3), ("try", 1),
  # Match/Make
  ("match", 2), ("make", 2),
  # IO
  ("read", 1), ("write", 2), ("dir?", 1), ("file?", 1),
  ("exit", 1), ("load", 1), ("save", 2), ("import", 1), ("exports", 1),
  # Set operations
  ("charset", 1), ("union", 2), ("intersect", 2),
  # Compile-time
  ("bindings", 1), ("capture", 2),
]

## Type predicates — all arity 1
let typePredNames*: seq[string] = @[
  "integer", "float", "string", "logic", "none", "money",
  "pair", "tuple", "date", "time", "file", "url", "email",
  "block", "paren", "map", "set", "context", "prototype",
  "function", "native", "word", "type", "number"
]
