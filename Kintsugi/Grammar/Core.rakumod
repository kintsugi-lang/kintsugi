grammar Kintsugi::Grammar::Core {
    rule TOP { <preamble>? <header> <block-items> }
    token preamble { [<.ws> <comment> <.ws>]+ }

    rule header { 'Kintsugi/Core' <.ws> <block> }
    
    rule block { '[' ~ ']' <block-items> }
    token block-items { <datatype>* % <.ws> }

    proto token datatype { * }
    token datatype:sym<block> { <block> }
    token datatype:sym<directive> { <directive> }
    token datatype:sym<file> { <file> }
    token datatype:sym<comment> { <comment> }
    token datatype:sym<lit-word> { <lit-word> }
    token datatype:sym<get-word> { <get-word> }
    token datatype:sym<set-word> { <set-word> }
    token datatype:sym<float> { <float> }
    token datatype:sym<integer> { <integer> }
    token datatype:sym<none> { <sym> }
    token datatype:sym<word> { <word> }
    token datatype:sym<function> { <function> }
    token datatype:sym<operator> { <operator> }
    token datatype:sym<char> { <char> }
    token datatype:sym<binary> { <binary> }
    token datatype:sym<paren> { <paren> }

    token directive {
        '#'
        < comptime >
    }
    
    token file { '%' <any-safe-file-char>+ }
    token function { 'function' <.ws> <block> <.ws> <block> }
    token operator { <unary-op> | <binary-op> }
    token unary-op { <[+\-*/\^=\<\>%|]> }
    token binary-op { '->' }
    
    
    token lit-word { '\'' <word> }
    token get-word { ':' <word> }
    token set-word { <word> ':' }
    token word { <any-word-char>+ }

    token float { '-'? \d* '.' \d+ }
    token integer { '-'? \d+ }
    token char { '#"' \w '"' }
    token binary { '#{' <[0..9 A..F a..f]>+ '}' }
    rule paren { '(' ~ ')' <block-items> }

    token comment { ';' \N* }

    token string-contents { <-["]>* }
    token strictly-word-char { <[\w\-]> }
    token any-safe-file-char { <[\w\-\/\.]> }
    token any-word-char { <[\w\-/?_!~]> }
    token any-char { . }
}
