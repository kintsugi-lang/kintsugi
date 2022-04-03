grammar Kintsugi::Foundation::Grammar {
    rule TOP { <header> <block-items> }
    token header { 'Kintsugi/Foundation' <.ws> <block> }
    rule block { '[' ~ ']' <block-items> }
    token block-items { <datatype>* % <.ws> }

    proto token datatype { * }
    token datatype:sym<block> { <block> }
    token datatype:sym<directive> { <directive> }
    token datatype:sym<file> { <file> }
    token datatype:sym<lit-word> { <lit-word> }
    token datatype:sym<get-word> { <get-word> }
    token datatype:sym<set-word> { <set-word> }
    token datatype:sym<string> { <string> }
    token datatype:sym<logic> { <logic> }
    token datatype:sym<none> { <none> }
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
    
    token file { '%' <any-safe-file-char>+ }

    token lit-word { '\'' <any-word-char>+ }
    token get-word { ':' <any-word-char>+ }
    token set-word { <any-word-char>+ ':' }
    token any-word { <any-word-char>+ }

    token string { '"' ~ '"' <string-contents> }
    token logic { 'true' | 'false' }
    token none { 'none' }
    token float { \d* '.' \d+ }
    token integer { \d+ }

    token comment { ';' \V+ }

    token string-contents { <-["]>* }
    token strictly-word-char { <[\w\-]> }
    token any-safe-file-char { <[\w\-\/\.]> }
    token any-word-char { <[\w\-/?_!]> }
    token any-char { . }
}
