grammar Kintsugi::Standard::Grammar {
    rule TOP { <header> <block-items> }
    token header { 'Kintsugi' <.ws> <block> }
    rule block { '[' ~ ']' <block-items> }
    token block-items { <datatype>* % <.ws> }

    proto token datatype { * }
    token datatype:sym<block> { <block> }
    token datatype:sym<directive> { <directive> }
    token datatype:sym<scope> { <scope> }
    token datatype:sym<operator> { <operator> }
    token datatype:sym<file> { <file> }
    token datatype:sym<date> { <date> }
    token datatype:sym<lit-word> { <lit-word> }
    token datatype:sym<get-word> { <get-word> }
    token datatype:sym<set-word> { <set-word> }
    token datatype:sym<string> { <string> }
    token datatype:sym<float> { <float> }
    token datatype:sym<integer> { <integer> }
    token datatype:sym<any-word> { <any-word> }
    token datatype:sym<comment> { <comment> }

    token directive {
        '#'
        [
            | 'include'
            | 'macro'
        ]
    }
    
    token scope {
        '@'
        [
            | 'enter'
            | 'exit'
        ]
    }

    # Datatypes
    token operator {
        | <[+\-*/\^=]>
        | '|>'
    }
    token date {
        | \d ** 4 '-' \d ** 2 '-' \d ** 2
        | \d ** 2 '-' \d ** 2 '-' \d ** 2
        | \d ** 2 '-' \d ** 2 '-' \d ** 4
    }
    token file { '%' <any-safe-file-char>+ }

    # Words
    token lit-word { '\'' <any-word-char>+ }
    token get-word { ':' <any-word-char>+ }
    token set-word { <any-word-char>+ ':' }
    token any-word { <any-word-char>+ }

    # Primitives
    token string { '"' ~ '"' <string-contents> }
    token float { \d* '.' \d+ }
    token integer { \d+ }

    # Special
    token comment { ';' \V+ }

    # Charsets
    token string-contents { <-["]>* }
    token strictly-word-char { <[\w\-]> }
    token any-safe-file-char { <[\w\-\/\.]> }
    token any-word-char { <[\w\-/?_!]> }
    token any-char { . }
}
