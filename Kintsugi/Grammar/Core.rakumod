grammar Kintsugi::Grammar::Core {
    rule TOP { <header> <block-items> }

    rule header { 'Kintsugi/Core' <.ws> <block> }
    
    rule block { '[' ~ ']' <block-items> }
    token block-items { <datatype>* % <.ws> }

    proto token datatype { * }
    token datatype:sym<block> { <block> }
    token datatype:sym<directive> { <directive> }
    token datatype:sym<file> { <file> }
    token datatype:sym<function> { <function> }
    token datatype:sym<operator> { <operator> }
    token datatype:sym<lit-word> { <lit-word> }
    token datatype:sym<get-word> { <get-word> }
    token datatype:sym<set-word> { <set-word> }
    token datatype:sym<none> { <sym> }
    token datatype:sym<float> { <float> }
    token datatype:sym<integer> { <integer> }
    token datatype:sym<word> { <word> }
    token datatype:sym<comment> { <comment> }

    token directive {
        '#'
        < include macro >
    }
    
    token file { '%' <any-safe-file-char>+ }
    token function { 'function' <.ws> <block> <.ws> <block> }
    token operator { <[+\-*/\^=]> }
    
    token lit-word { '\'' <word> }
    token get-word { ':' <word> }
    token set-word { <word> ':' }
    token word { <any-word-char>+ }

    token float { \d* '.' \d+ }
    token integer { \d+ }

    token comment { ';' \V+ }

    token string-contents { <-["]>* }
    token strictly-word-char { <[\w\-]> }
    token any-safe-file-char { <[\w\-\/\.]> }
    token any-word-char { <[\w\-/?_!]> }
    token any-char { . }
}
