module Kintsugi::Dictionary::Core {
    our %words =
        'print' => { arity => 1, native => -> $a { say $a; $a } },
        'compose' => { arity => 1, native => -> $a { !!! } },

        '+' => { arity => 2, native => -> $a, $b { $a + $b } },
        '-' => { arity => 2, native => -> $a, $b { $a - $b } },
        '*' => { arity => 2, native => -> $a, $b { $a * $b } },
        '/' => { arity => 2, native => -> $a, $b { $a / $b } },
        '^' => { arity => 2, native => -> $a, $b { $a ^ $b } },
        '%' => { arity => 2, native => -> $a, $b { $a % $b } },

        '>' => { arity => 2, native => -> $a, $b { $a > $b } },
        '>=' => { arity => 2, native => -> $a, $b { $a >= $b } },
        '<>' => { arity => 2, native => -> $a, $b { $a !== $b } },
        '=' => { arity => 2, native => -> $a, $b { $a == $b } },
        '<=' => { arity => 2, native => -> $a, $b { $a <= $b } },
        ANNOYING-CHARACTER => { arity => 2, native => -> $a, $b { $a < $b } },

        '->' => { arity => 2, native => -> $a, $b { !!! } },
}

module Kintsugi::Dictionary::Systems {
    our %words =
        'rejoin' => { arity => 1, native => -> $a { !!! } },

}

module Kintsugi::Dictionary::Full {
    our %words;
}


# This is down here in hell because the Raku major mode has a bug.
constant ANNOYING-CHARACTER = '<';

